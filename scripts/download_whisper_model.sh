#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="cache"
DESTINATION_DIR=""
MODEL_ID=""

default_model_id() {
  if defaults read -g AppleLanguages 2>/dev/null | grep -qi "en"; then
    printf '%s\n' "base.en-q5_1"
  else
    printf '%s\n' "base-q5_1"
  fi
}

usage() {
  cat <<'EOF'
Usage: ./scripts/download_whisper_model.sh [--cache | --bundle] [--model <id>] [--destination <dir>]

Downloads the default low-latency Whisper model used by spk.

Options:
  --cache              Download to ~/Library/Application Support/spk/Models (default)
  --bundle             Download to spk/Resources/Models so future builds embed it
  --model <id>         Override the model id, for example base-q5_1 or large-v3-turbo-q5_0
  --destination <dir>  Override the destination directory
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache)
      MODE="cache"
      shift
      ;;
    --bundle)
      MODE="bundle"
      shift
      ;;
    --model)
      if [[ $# -lt 2 ]]; then
        echo "Missing model id after --model" >&2
        exit 1
      fi
      MODEL_ID="$2"
      shift 2
      ;;
    --destination)
      if [[ $# -lt 2 ]]; then
        echo "Missing directory after --destination" >&2
        exit 1
      fi
      DESTINATION_DIR="$2"
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

if [[ -z "$DESTINATION_DIR" ]]; then
  if [[ "$MODE" == "bundle" ]]; then
    DESTINATION_DIR="${PROJECT_ROOT}/spk/Resources/Models"
  else
    DESTINATION_DIR="${HOME}/Library/Application Support/spk/Models"
  fi
fi

if [[ -z "$MODEL_ID" ]]; then
  MODEL_ID="$(default_model_id)"
fi

MODEL_FILE="${DESTINATION_DIR}/ggml-${MODEL_ID}.bin"
UPSTREAM_SCRIPT="${PROJECT_ROOT}/Vendor/whisper.cpp/models/download-ggml-model.sh"

mkdir -p "$DESTINATION_DIR"

if [[ -f "$MODEL_FILE" ]]; then
  echo "Whisper model already present at:"
  echo "  $MODEL_FILE"
  exit 0
fi

echo "Downloading whisper model '${MODEL_ID}' to:"
echo "  $DESTINATION_DIR"

bash "$UPSTREAM_SCRIPT" "$MODEL_ID" "$DESTINATION_DIR"

echo
echo "Model ready at:"
echo "  $MODEL_FILE"

if [[ "$MODE" == "bundle" ]]; then
  echo "Future app builds will embed this model automatically."
else
  echo "spk will reuse the cached model on launch."
fi
