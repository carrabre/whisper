#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"

HELPER_PATH="${SPK_VOXTRAL_REALTIME_HELPER_PATH:-$ROOT_DIR/spk/Resources/Helpers/spk_voxtral_realtime_helper.py}"
MODEL_PATH="$(spk_voxtral_model_dir)"
VENV_PYTHON="$(spk_voxtral_python_path)"
READINESS_MANIFEST_PATH="$(spk_voxtral_readiness_manifest_path)"
AUDIO_FILE=""
PREPARED_AUDIO_FILE=""
WRITE_READINESS_MANIFEST=0
APP_VERSION="standalone"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/probe_voxtral_realtime_local.sh
  ./scripts/probe_voxtral_realtime_local.sh --audio-file "/path/to/audio.m4a"
  ./scripts/probe_voxtral_realtime_local.sh --write-readiness-manifest --app-version "1.0-1"
EOF
}

cleanup() {
  if [[ -n "$PREPARED_AUDIO_FILE" && -f "$PREPARED_AUDIO_FILE" ]]; then
    rm -f "$PREPARED_AUDIO_FILE"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audio-file)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --audio-file" >&2
        usage
        exit 1
      fi
      AUDIO_FILE="$2"
      shift 2
      ;;
    --write-readiness-manifest)
      WRITE_READINESS_MANIFEST=1
      shift
      ;;
    --app-version)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --app-version" >&2
        usage
        exit 1
      fi
      APP_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$HELPER_PATH" ]]; then
  echo "Missing helper script: $HELPER_PATH" >&2
  exit 1
fi

if [[ ! -d "$MODEL_PATH" ]]; then
  echo "Missing model folder: $MODEL_PATH" >&2
  exit 1
fi

if [[ ! -x "$VENV_PYTHON" ]]; then
  echo "Missing Voxtral runtime Python: $VENV_PYTHON" >&2
  echo "Run ./scripts/install_voxtral_realtime_model.sh first." >&2
  exit 1
fi

if [[ -n "$AUDIO_FILE" ]]; then
  if [[ ! -f "$AUDIO_FILE" ]]; then
    echo "Missing audio file: $AUDIO_FILE" >&2
    exit 1
  fi

  FFMPEG_BIN="${FFMPEG_BIN:-$(command -v ffmpeg || true)}"
  if [[ -z "$FFMPEG_BIN" ]]; then
    echo "ffmpeg is required for --audio-file mode." >&2
    exit 1
  fi

  PREPARED_AUDIO_FILE="$(mktemp /tmp/voxtral-probe-audio.XXXXXX.wav)"
  "$FFMPEG_BIN" -y -v error -i "$AUDIO_FILE" -ac 1 -ar 16000 -c:a pcm_s16le "$PREPARED_AUDIO_FILE"
fi

"$VENV_PYTHON" - "$VENV_PYTHON" "$HELPER_PATH" "$MODEL_PATH" "$PREPARED_AUDIO_FILE" "$READINESS_MANIFEST_PATH" "$APP_VERSION" "$WRITE_READINESS_MANIFEST" <<'PY'
import base64
import hashlib
import json
import os
import struct
import subprocess
import sys
import time
import wave

venv_python = sys.argv[1]
helper_path = sys.argv[2]
model_path = sys.argv[3]
audio_path = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
readiness_manifest_path = sys.argv[5] if len(sys.argv) > 5 else None
app_version = sys.argv[6] if len(sys.argv) > 6 else "standalone"
write_readiness_manifest = (sys.argv[7] if len(sys.argv) > 7 else "0") == "1"
chunk_size = 3840
chunk_delay_seconds = 0.24
drain_poll_delay_seconds = 0.12
drain_poll_count = 3
schema_version = 1


def read_stderr(process):
    try:
        return process.stderr.read().strip()
    except Exception:
        return ""


def send_request(process, payload):
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()
    raw_line = process.stdout.readline()
    if not raw_line:
        stderr = read_stderr(process)
        raise SystemExit(f"Voxtral helper exited before replying to {payload.get('type')}: {stderr}")
    response = json.loads(raw_line)
    if response.get("type") == "error":
        raise SystemExit(f"Voxtral helper returned an error for {payload.get('type')}: {response}")
    return response


def iter_wave_chunks(path, frames_per_chunk):
    with wave.open(path, "rb") as wav_file:
        if wav_file.getframerate() != 16000 or wav_file.getnchannels() != 1 or wav_file.getsampwidth() != 2:
            raise SystemExit("Prepared probe audio must be 16 kHz mono PCM16 WAV.")

        while True:
            frames = wav_file.readframes(frames_per_chunk)
            if not frames:
                return
            yield frames


def record_preview_text(preview_text, preview_updates, last_preview_text):
    if preview_text and preview_text != last_preview_text:
        preview_updates.append(preview_text)
        return preview_text
    return last_preview_text


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def model_fingerprint(path):
    entries = []
    for root, _, files in os.walk(path):
        files = sorted(file_name for file_name in files if not file_name.startswith("."))
        for file_name in files:
            file_path = os.path.join(root, file_name)
            stat = os.stat(file_path)
            relative_path = os.path.relpath(file_path, path).replace(os.sep, "/")
            entries.append(f"{relative_path}|{stat.st_size}|{stat.st_mtime_ns}")
    digest = hashlib.sha256()
    digest.update("\n".join(entries).encode("utf-8"))
    return digest.hexdigest()


def python_version(python_path):
    result = subprocess.run(
        [python_path, "--version"],
        check=True,
        capture_output=True,
        text=True,
    )
    version_text = (result.stdout or result.stderr).strip()
    if not version_text:
        raise SystemExit("Could not determine Voxtral Python runtime version.")
    return version_text


def write_manifest():
    if not readiness_manifest_path:
        raise SystemExit("Missing readiness manifest path.")
    manifest_dir = os.path.dirname(readiness_manifest_path)
    os.makedirs(manifest_dir, exist_ok=True)
    manifest = {
        "schema_version": schema_version,
        "app_build_version": app_version,
        "helper_path": helper_path,
        "helper_fingerprint": sha256_file(helper_path),
        "python_path": venv_python,
        "python_version": python_version(venv_python),
        "model_path": model_path,
        "model_fingerprint": model_fingerprint(model_path),
        "preflighted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    with open(readiness_manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return manifest


process = subprocess.Popen(
    [venv_python, helper_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

try:
    ready = send_request(process, {
        "request_id": "probe-load",
        "type": "load_model",
        "model_path": model_path,
    })

    if not audio_path:
        session_started = send_request(process, {
            "request_id": "probe-start-session",
            "type": "start_session",
            "session_id": "probe-session",
        })
        if session_started.get("type") != "session_started":
            raise SystemExit(f"Voxtral streaming probe failed to start a session: {session_started}")

        silent_pcm = struct.pack("<" + "h" * 1600, *([0] * 1600))
        preview_response = send_request(process, {
            "request_id": "probe-append-audio",
            "type": "append_audio",
            "session_id": "probe-session",
            "samples_base64": base64.b64encode(silent_pcm).decode("ascii"),
        })
        if preview_response.get("type") != "preview_update":
            raise SystemExit(f"Voxtral streaming probe failed to produce a preview update: {preview_response}")

        final_response = send_request(process, {
            "request_id": "probe-finish-session",
            "type": "finish_session",
            "session_id": "probe-session",
        })
        if final_response.get("type") != "final_transcript":
            raise SystemExit(f"Voxtral streaming probe failed to finalize a transcript: {final_response}")

        send_request(process, {
            "request_id": "probe-shutdown",
            "type": "shutdown",
        })
        manifest = write_manifest() if write_readiness_manifest else None
        print(
            f"Voxtral helper ready. model={ready.get('model_display_name')} "
            f"streaming_preview={ready.get('supports_streaming_preview')} "
            f"final_text={final_response.get('text', '')!r}"
        )
        if manifest:
            print(f"Readiness manifest: {readiness_manifest_path}")
    else:
        offline_response = send_request(process, {
            "request_id": "probe-offline",
            "type": "transcribe_file",
            "audio_path": audio_path,
        })
        offline_text = offline_response.get("text", "")

        session_started = send_request(process, {
            "request_id": "probe-stream-start",
            "type": "start_session",
            "session_id": "probe-audio-session",
        })
        if session_started.get("type") != "session_started":
            raise SystemExit(f"Voxtral live probe failed to start a session: {session_started}")

        preview_updates = []
        last_preview_text = None
        for index, chunk in enumerate(iter_wave_chunks(audio_path, chunk_size), start=1):
            preview_response = send_request(process, {
                "request_id": f"probe-append-{index}",
                "type": "append_audio",
                "session_id": "probe-audio-session",
                "samples_base64": base64.b64encode(chunk).decode("ascii"),
            })
            last_preview_text = record_preview_text(
                preview_response.get("text", ""),
                preview_updates,
                last_preview_text,
            )
            time.sleep(chunk_delay_seconds)

            for drain_poll in range(drain_poll_count):
                drain_response = send_request(process, {
                    "request_id": f"probe-drain-{index}-{drain_poll}",
                    "type": "append_audio",
                    "session_id": "probe-audio-session",
                    "samples_base64": "",
                })
                last_preview_text = record_preview_text(
                    drain_response.get("text", ""),
                    preview_updates,
                    last_preview_text,
                )
                time.sleep(drain_poll_delay_seconds)

        final_response = send_request(process, {
            "request_id": "probe-stream-finish",
            "type": "finish_session",
            "session_id": "probe-audio-session",
        })
        final_text = final_response.get("text", "")

        send_request(process, {
            "request_id": "probe-shutdown",
            "type": "shutdown",
        })

        print(f"Voxtral helper ready. model={ready.get('model_display_name')} streaming_preview={ready.get('supports_streaming_preview')}")
        print(f"Audio file: {audio_path}")
        print(f"Offline transcript: {offline_text}")
        print("Live partial updates:")
        for update in preview_updates:
            print(f"  - {update}")
        print(f"Live final transcript: {final_text}")

        if not offline_text.strip():
            raise SystemExit("Offline Voxtral transcription was empty.")
        if not preview_updates:
            raise SystemExit("Live Voxtral probe produced no partial preview updates.")
        if not final_text.strip():
            raise SystemExit("Live Voxtral final transcript was empty.")
        if write_readiness_manifest:
            manifest = write_manifest()
            print(f"Readiness manifest: {readiness_manifest_path}")
finally:
    try:
        process.stdin.close()
    except Exception:
        pass
    process.wait(timeout=10)
    if process.returncode not in (0, None):
        stderr = read_stderr(process)
        raise SystemExit(f"Voxtral helper exited with {process.returncode}: {stderr}")
PY
