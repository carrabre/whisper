#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

APP_SUPPORT_ROOT="${HOME}/Library/Application Support/spk"
VENV_DIR="${APP_SUPPORT_ROOT}/VoxtralRuntime/py312"
VENV_BIN="${VENV_DIR}/bin"
MODEL_PATH="${SPK_VOXTRAL_REALTIME_MODEL_PATH:-${APP_SUPPORT_ROOT}/VoxtralModels/Voxtral-Mini-4B-Realtime-2602}"
REPLAY_AUDIO_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audio-file)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --audio-file" >&2
        exit 1
      fi
      REPLAY_AUDIO_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "${VENV_BIN}/python" ]]; then
  echo "Missing Voxtral runtime venv at ${VENV_DIR}" >&2
  echo "Run ./scripts/install_voxtral_realtime_model.sh first." >&2
  exit 1
fi

export PATH="${VENV_BIN}:${PATH}"
export SPK_TRANSCRIPTION_BACKEND="voxtralRealtime"
export SPK_VOXTRAL_REALTIME_MODEL_PATH="${MODEL_PATH}"
export SPK_SKIP_MODEL_PREFETCH="1"

if [[ -n "${REPLAY_AUDIO_FILE}" ]]; then
  if [[ ! -f "${REPLAY_AUDIO_FILE}" ]]; then
    echo "Missing replay audio file: ${REPLAY_AUDIO_FILE}" >&2
    exit 1
  fi
  export SPK_DEBUG_VOXTRAL_LIVE_AUDIO_FILE="${REPLAY_AUDIO_FILE}"
fi

echo "Running Voxtral local probe..."
if [[ -n "${REPLAY_AUDIO_FILE}" ]]; then
  "${SCRIPT_DIR}/probe_voxtral_realtime_local.sh" --audio-file "${REPLAY_AUDIO_FILE}"
else
  "${SCRIPT_DIR}/probe_voxtral_realtime_local.sh"
fi

cat <<EOF

Voxtral smoke test environment is ready.

Manual smoke steps after the app launches:
1. Confirm the transcription backend readies as Voxtral without showing "unavailable".
2. Record one short utterance.
3. Verify preview text appears during recording.
4. Verify the final transcript completes after you stop recording.

Launching spk from this shell so /usr/bin/env python3 resolves to ${VENV_BIN}/python.
EOF

if [[ -n "${REPLAY_AUDIO_FILE}" ]]; then
  cat <<EOF

Replay-file mode is enabled for this launch:
- SPK_DEBUG_VOXTRAL_LIVE_AUDIO_FILE=${REPLAY_AUDIO_FILE}
- The next Voxtral recording will replay that file through the app's live pipeline instead of the microphone.
EOF
fi

exec "${SCRIPT_DIR}/run_dev.sh" --skip-model-prefetch
