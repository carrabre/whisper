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
PREPARED_AUDIO_FILE_IS_TEMP=0
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
  if [[ "$PREPARED_AUDIO_FILE_IS_TEMP" -eq 1 && -n "$PREPARED_AUDIO_FILE" && -f "$PREPARED_AUDIO_FILE" ]]; then
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

  audio_extension="$(printf '%s' "${AUDIO_FILE##*.}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$audio_extension" == "wav" ]]; then
    PREPARED_AUDIO_FILE="$AUDIO_FILE"
  else
    FFMPEG_BIN="${FFMPEG_BIN:-$(command -v ffmpeg || true)}"
    if [[ -z "$FFMPEG_BIN" ]]; then
      echo "ffmpeg is required for non-WAV --audio-file inputs." >&2
      exit 1
    fi

    PREPARED_AUDIO_FILE="$(mktemp /tmp/voxtral-probe-audio.XXXXXX.wav)"
    PREPARED_AUDIO_FILE_IS_TEMP=1
    "$FFMPEG_BIN" -y -v error -i "$AUDIO_FILE" -ac 1 -ar 16000 -c:a pcm_s16le "$PREPARED_AUDIO_FILE"
  fi
fi

"$VENV_PYTHON" - "$VENV_PYTHON" "$HELPER_PATH" "$MODEL_PATH" "$PREPARED_AUDIO_FILE" "$READINESS_MANIFEST_PATH" "$APP_VERSION" "$WRITE_READINESS_MANIFEST" <<'PY'
import base64
import hashlib
import json
import os
import select
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
preview_wait_timeout_seconds = float(os.environ.get("SPK_VOXTRAL_PROBE_PREVIEW_WAIT_SECONDS", "180"))
request_timeout_seconds = float(os.environ.get("SPK_VOXTRAL_PROBE_REQUEST_TIMEOUT_SECONDS", "300"))
offline_request_timeout_seconds = float(os.environ.get("SPK_VOXTRAL_PROBE_OFFLINE_TIMEOUT_SECONDS", "180"))
streaming_finalization_timeout_seconds = float(os.environ.get("SPK_VOXTRAL_PROBE_FINALIZATION_TIMEOUT_SECONDS", "300"))
schema_version = 2


def read_stderr(process):
    try:
        return process.stderr.read().strip()
    except Exception:
        return ""


def send_request(process, payload, timeout_seconds=request_timeout_seconds):
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()
    ready, _, _ = select.select([process.stdout], [], [], timeout_seconds)
    if not ready:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        raise SystemExit(f"Timed out after {timeout_seconds}s waiting for Voxtral helper response to {payload.get('type')}.")
    raw_line = process.stdout.readline()
    if not raw_line:
        stderr = read_stderr(process)
        raise SystemExit(f"Voxtral helper exited before replying to {payload.get('type')}: {stderr}")
    response = json.loads(raw_line)
    if response.get("type") == "error":
        raise SystemExit(f"Voxtral helper returned an error for {payload.get('type')}: {response}")
    return response


def finish_helper(process):
    if process.poll() is not None:
        return
    try:
        if process.stdin:
            process.stdin.close()
    except Exception:
        pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def iter_wave_streaming_chunks(path, first_chunk_size, steady_chunk_size):
    with wave.open(path, "rb") as wav_file:
        if wav_file.getframerate() != 16000 or wav_file.getnchannels() != 1 or wav_file.getsampwidth() != 2:
            raise SystemExit("Prepared probe audio must be 16 kHz mono PCM16 WAV.")

        frames_per_chunk = first_chunk_size
        while True:
            frames = wav_file.readframes(frames_per_chunk)
            if not frames:
                return
            yield frames
            frames_per_chunk = steady_chunk_size


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


def require_mps_runtime():
    import platform
    import torch

    torch_version = getattr(torch, "__version__", "unknown")
    macos_version = platform.mac_ver()[0] or "unknown"
    machine = platform.machine()
    prefix = "PyTorch MPS is unavailable, so Voxtral Realtime cannot stream locally."

    def fail(reason):
        raise SystemExit(
            f"{prefix} {reason} torch={torch_version} macos={macos_version} machine={machine}. "
            "Reinstall the managed Voxtral runtime so spk can use a PyTorch build with working MPS."
        )

    if machine != "arm64":
        fail("Apple Silicon arm64 hardware is required.")
    if not torch.backends.mps.is_built():
        fail("This PyTorch build was not compiled with MPS support.")
    if not torch.backends.mps.is_available():
        fail("torch.backends.mps.is_available() returned false.")
    try:
        torch.ones(1, device="mps")
    except Exception as error:
        fail(f"A tiny MPS tensor allocation failed: {error}")


def write_manifest(startup_mode, startup_mode_reason=None):
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
        "startup_mode": startup_mode,
        "startup_mode_reason": startup_mode_reason,
        "preflighted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    with open(readiness_manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return manifest


require_mps_runtime()

process = subprocess.Popen(
    [venv_python, helper_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

try:
    print("Loading Voxtral helper/model...", flush=True)
    ready = send_request(process, {
        "request_id": "probe-load",
        "type": "load_model",
        "model_path": model_path,
    })
    first_chunk_size = int(ready.get("first_streaming_chunk_sample_count") or chunk_size)
    steady_chunk_size = int(ready.get("streaming_chunk_sample_count") or first_chunk_size)

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
            "finalization_timeout_seconds": streaming_finalization_timeout_seconds,
        })
        if final_response.get("type") != "final_transcript":
            raise SystemExit(f"Voxtral streaming probe failed to finalize a transcript: {final_response}")

        send_request(process, {
            "request_id": "probe-shutdown",
            "type": "shutdown",
        })
        manifest = write_manifest("unverified") if write_readiness_manifest else None
        print(
            f"Voxtral helper ready. model={ready.get('model_display_name')} "
            f"streaming_preview={ready.get('supports_streaming_preview')} "
            f"final_text={final_response.get('text', '')!r}"
        )
        if manifest:
            print(f"Readiness manifest: {readiness_manifest_path}")
    else:
        print("Running paced live streaming probe...", flush=True)
        session_started = send_request(process, {
            "request_id": "probe-stream-start",
            "type": "start_session",
            "session_id": "probe-audio-session",
        })
        if session_started.get("type") != "session_started":
            raise SystemExit(f"Voxtral live probe failed to start a session: {session_started}")

        preview_updates = []
        last_preview_text = None
        for index, chunk in enumerate(iter_wave_streaming_chunks(audio_path, first_chunk_size, steady_chunk_size), start=1):
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
            time.sleep(len(chunk) / 2 / 16000)

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
            if index == 1 or index % 10 == 0:
                print(f"  streamed chunk {index}; partial updates={len(preview_updates)}", flush=True)

        if not preview_updates:
            preview_wait_started = time.monotonic()
            print("Waiting for first live preview text before finalization...", flush=True)
            while time.monotonic() - preview_wait_started < preview_wait_timeout_seconds:
                drain_response = send_request(process, {
                    "request_id": f"probe-drain-wait-{int((time.monotonic() - preview_wait_started) * 1000)}",
                    "type": "append_audio",
                    "session_id": "probe-audio-session",
                    "samples_base64": "",
                })
                last_preview_text = record_preview_text(
                    drain_response.get("text", ""),
                    preview_updates,
                    last_preview_text,
                )
                if preview_updates:
                    break
                time.sleep(drain_poll_delay_seconds)

        if not preview_updates:
            send_request(process, {
                "request_id": "probe-cancel-no-preview",
                "type": "cancel_session",
                "session_id": "probe-audio-session",
            }, timeout_seconds=10)
            raise SystemExit("Live Voxtral probe produced no partial preview updates before the warmup timeout.")

        final_response = send_request(process, {
            "request_id": "probe-stream-finish",
            "type": "finish_session",
            "session_id": "probe-audio-session",
            "finalization_timeout_seconds": streaming_finalization_timeout_seconds,
        })
        final_text = final_response.get("text", "")

        if not final_text.strip():
            raise SystemExit("Live Voxtral final transcript was empty.")

        print("Running offline transcription probe...", flush=True)
        offline_response = send_request(process, {
            "request_id": "probe-offline",
            "type": "transcribe_file",
            "audio_path": audio_path,
        }, timeout_seconds=offline_request_timeout_seconds)
        offline_text = offline_response.get("text", "")
        if not offline_text.strip():
            raise SystemExit("Offline Voxtral transcription was empty.")

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

        if write_readiness_manifest:
            manifest = write_manifest("live_ready")
            print(f"Readiness manifest: {readiness_manifest_path}")
finally:
    finish_helper(process)
PY
