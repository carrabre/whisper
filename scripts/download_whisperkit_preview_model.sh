#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/download_whisperkit_preview_model.sh [--destination <dir>] [--model <id>] [--hf-bin <path>]

Downloads a local WhisperKit preview model into the app-managed cache.

Options:
  --destination <dir>  Override the destination root directory
  --model <id>         WhisperKit model folder name to download (default: openai_whisper-medium)
  --hf-bin <path>      Override the Hugging Face CLI binary to use
  -h, --help           Show this help text
EOF
}

MODEL_ID="${SPK_WHISPERKIT_MODEL_ID:-openai_whisper-medium}"
DESTINATION_DIR="$(spk_whisperkit_model_cache_dir)"
HF_BIN_DEFAULT="${HOME}/Library/Application Support/spk/Tools/nemotron-python/bin/hf"
HF_BIN="${SPK_WHISPERKIT_HF_BIN:-${HF_BIN_DEFAULT}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --destination" >&2
        exit 1
      fi
      DESTINATION_DIR="$2"
      shift 2
      ;;
    --model)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --model" >&2
        exit 1
      fi
      MODEL_ID="$2"
      shift 2
      ;;
    --hf-bin)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --hf-bin" >&2
        exit 1
      fi
      HF_BIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "$HF_BIN" ]]; then
  echo "Expected Hugging Face CLI at ${HF_BIN}, but it was not found or is not executable." >&2
  exit 1
fi

tokenizer_repo_for_model() {
  local model_id="$1"

  case "$model_id" in
    openai_whisper-*)
      printf 'openai/%s\n' "${model_id#openai_}"
      ;;
    *)
      echo "Do not know which tokenizer repo to use for '${model_id}'." >&2
      exit 1
      ;;
  esac
}

spk_cd_project_root
mkdir -p "$DESTINATION_DIR"

TOKENIZER_REPO="$(tokenizer_repo_for_model "$MODEL_ID")"
TOKENIZER_DESTINATION="${DESTINATION_DIR}/${MODEL_ID}/models/${TOKENIZER_REPO}"

echo "Downloading WhisperKit preview model '${MODEL_ID}' into:"
echo "  ${DESTINATION_DIR}"
"$HF_BIN" download argmaxinc/whisperkit-coreml \
  --include "${MODEL_ID}/*" \
  --local-dir "$DESTINATION_DIR"

mkdir -p "$TOKENIZER_DESTINATION"

echo
echo "Downloading tokenizer repo '${TOKENIZER_REPO}' into:"
echo "  ${TOKENIZER_DESTINATION}"
"$HF_BIN" download "$TOKENIZER_REPO" \
  --include "config.json" \
  --include "tokenizer.json" \
  --include "tokenizer_config.json" \
  --local-dir "$TOKENIZER_DESTINATION"

echo
echo "WhisperKit preview assets ready:"
echo "  Model folder: ${DESTINATION_DIR}/${MODEL_ID}"
