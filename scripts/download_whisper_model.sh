#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

MODE="cache"
DESTINATION_DIR=""
MODEL_ID=""
VAD_MODEL_ID="$(spk_default_vad_model_id)"
DOWNLOAD_WHISPER=1
DOWNLOAD_VAD=1

usage() {
  cat <<'EOF'
Usage: ./scripts/download_whisper_model.sh [--cache | --bundle] [--model <id>] [--vad-model <id>] [--whisper-only | --vad-only] [--destination <dir>]

Downloads the local model assets used by spk.

Options:
  --cache              Download to ~/Library/Application Support/spk/Models (default)
  --bundle             Download to spk/Resources/Models so future builds embed the assets
  --model <id>         Override the Whisper model id, for example base.en-q5_1
  --vad-model <id>     Override the VAD model id, for example silero-v6.2.0
  --whisper-only       Download only the Whisper model
  --vad-only           Download only the VAD model
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
    --vad-model)
      if [[ $# -lt 2 ]]; then
        echo "Missing model id after --vad-model" >&2
        exit 1
      fi
      VAD_MODEL_ID="$2"
      shift 2
      ;;
    --whisper-only)
      DOWNLOAD_VAD=0
      shift
      ;;
    --vad-only)
      DOWNLOAD_WHISPER=0
      shift
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

if [[ "$DOWNLOAD_WHISPER" == "0" && "$DOWNLOAD_VAD" == "0" ]]; then
  echo "At least one asset type must be selected." >&2
  exit 1
fi

if [[ -z "$DESTINATION_DIR" ]]; then
  if [[ "$MODE" == "bundle" ]]; then
    DESTINATION_DIR="$(spk_bundled_models_dir)"
  else
    DESTINATION_DIR="$(spk_model_cache_dir)"
  fi
fi

if [[ -z "$MODEL_ID" ]]; then
  MODEL_ID="$(spk_default_whisper_model_id)"
fi

WHISPER_MODEL_FILE="${DESTINATION_DIR}/ggml-${MODEL_ID}.bin"
VAD_MODEL_FILE="${DESTINATION_DIR}/ggml-${VAD_MODEL_ID}.bin"
WHISPER_DOWNLOAD_SCRIPT="${PROJECT_ROOT}/Vendor/whisper.cpp/models/download-ggml-model.sh"
VAD_DOWNLOAD_SCRIPT="${PROJECT_ROOT}/Vendor/whisper.cpp/models/download-vad-model.sh"

mkdir -p "$DESTINATION_DIR"

if [[ "$DOWNLOAD_WHISPER" == "1" ]]; then
  echo "Ensuring Whisper model '${MODEL_ID}' is available at:"
  echo "  $DESTINATION_DIR"
  bash "$WHISPER_DOWNLOAD_SCRIPT" "$MODEL_ID" "$DESTINATION_DIR"
fi

if [[ "$DOWNLOAD_VAD" == "1" ]]; then
  echo "Ensuring VAD model '${VAD_MODEL_ID}' is available at:"
  echo "  $DESTINATION_DIR"
  bash "$VAD_DOWNLOAD_SCRIPT" "$VAD_MODEL_ID" "$DESTINATION_DIR"
fi

echo
echo "Local model assets ready:"
if [[ "$DOWNLOAD_WHISPER" == "1" ]]; then
  echo "  $WHISPER_MODEL_FILE"
fi
if [[ "$DOWNLOAD_VAD" == "1" ]]; then
  echo "  $VAD_MODEL_FILE"
fi

if [[ "$MODE" == "bundle" ]]; then
  echo "Future app builds will embed these assets automatically."
else
  echo "spk will reuse these locally cached assets at runtime."
fi
