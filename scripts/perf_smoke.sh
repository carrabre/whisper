#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/perf_smoke.sh [--audio-file <path>]

Run a local replay-based performance smoke test for the Voxtral realtime helper.
This never downloads models or contacts a remote service.
EOF
}

AUDIO_FILE="${ROOT_DIR}/spk/Resources/VoxtralRuntime/voxtral_strict_preview_smoke_test.wav"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audio-file)
      AUDIO_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$AUDIO_FILE" || ! -f "$AUDIO_FILE" ]]; then
  echo "Missing replay audio file: ${AUDIO_FILE}" >&2
  exit 1
fi

start_ms="$(
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

"${SCRIPT_DIR}/probe_voxtral_realtime_local.sh" --audio-file "$AUDIO_FILE"

end_ms="$(
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

echo "Voxtral replay perf smoke elapsed_ms=$((end_ms - start_ms)) audio_file=${AUDIO_FILE}"
