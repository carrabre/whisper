#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

PYTHON312_BIN="/opt/homebrew/bin/python3.12"
APP_SUPPORT_ROOT="$(spk_app_support_root)"
DEFAULT_MODEL_PATH="$(spk_voxtral_model_dir)"
VENV_DIR="$(spk_voxtral_runtime_dir)/py312"
VENV_PYTHON="$(spk_voxtral_python_path)"
MODEL_PATH="$DEFAULT_MODEL_PATH"
MODEL_ID="mistralai/Voxtral-Mini-4B-Realtime-2602"
APP_VERSION="standalone"
SKIP_PREFLIGHT=0

info() {
  printf '[voxtral-setup] %s\n' "$1"
}

fail() {
  printf '[voxtral-setup] %s\n' "$1" >&2
  exit 1
}

is_valid_model_dir() {
  local model_dir="$1"

  [[ -d "$model_dir" ]] || return 1
  [[ -f "$model_dir/config.json" ]] || return 1

  if [[ ! -f "$model_dir/preprocessor_config.json" && ! -f "$model_dir/processor_config.json" ]]; then
    return 1
  fi

  if [[ ! -f "$model_dir/tokenizer.json" && ! -f "$model_dir/tokenizer.model" && ! -f "$model_dir/tekken.json" ]]; then
    return 1
  fi

  local child_name=""
  while IFS= read -r child_name; do
    case "${child_name##*/}" in
      *.safetensors|model-*|pytorch_model*)
        return 0
        ;;
    esac
  done < <(/usr/bin/find "$model_dir" -maxdepth 1 -mindepth 1 -print)

  return 1
}

download_model() {
  local downloader_bin="$1"
  local output_path="$2"
  local stderr_file="$3"
  local rc=0

  set +e
  "$downloader_bin" download "$MODEL_ID" --local-dir "$output_path" 2>"$stderr_file"
  rc=$?
  set -e

  return "$rc"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/install_voxtral_realtime_model.sh [--app-version <SHORT-BUILD>] [--skip-preflight]
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app-version)
        if [[ $# -lt 2 ]]; then
          fail "Missing value for --app-version"
        fi
        APP_VERSION="$2"
        shift 2
        ;;
      --skip-preflight)
        SKIP_PREFLIGHT=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unsupported argument: $1"
        ;;
    esac
  done

  if [[ ! -x "$PYTHON312_BIN" ]]; then
    fail "Python 3.12 is required at $PYTHON312_BIN. Install it with Homebrew before running this setup."
  fi

  info "Using Python interpreter: $PYTHON312_BIN"
  info "Runtime venv: $VENV_DIR"
  info "Model directory: $MODEL_PATH"

  mkdir -p "${APP_SUPPORT_ROOT}/VoxtralRuntime"
  mkdir -p "$(dirname "$MODEL_PATH")"

  if [[ ! -x "$VENV_PYTHON" ]]; then
    info "Creating Python 3.12 virtual environment..."
    "$PYTHON312_BIN" -m venv "$VENV_DIR"
  fi

  info "Upgrading packaging tools..."
  "$VENV_PYTHON" -m pip install --upgrade pip wheel "setuptools<82"

  info "Installing Voxtral runtime dependencies into the venv..."
  "$VENV_PYTHON" -m pip install \
    "transformers>=5.2.0" \
    torch \
    accelerate \
    "mistral-common[audio]" \
    "huggingface_hub[cli]"

  info "Verifying Python imports..."
  "$VENV_PYTHON" - <<'PY'
import importlib
import sys

for module_name in ("transformers", "torch", "accelerate", "mistral_common", "huggingface_hub"):
    importlib.import_module(module_name)

print(sys.executable)
PY

  if is_valid_model_dir "$MODEL_PATH"; then
    info "Model directory is already populated and valid."
  else
    info "Downloading ${MODEL_ID} into ${MODEL_PATH}..."
    mkdir -p "$MODEL_PATH"

    local downloader_bin=""
    if [[ -x "${VENV_DIR}/bin/hf" ]]; then
      downloader_bin="${VENV_DIR}/bin/hf"
    elif [[ -x "${VENV_DIR}/bin/huggingface-cli" ]]; then
      downloader_bin="${VENV_DIR}/bin/huggingface-cli"
    else
      fail "Could not find a Hugging Face CLI in ${VENV_DIR}/bin after dependency install."
    fi

    local stderr_file
    stderr_file="$(mktemp)"
    if ! download_model "$downloader_bin" "$MODEL_PATH" "$stderr_file"; then
      local stderr_output=""
      stderr_output="$(cat "$stderr_file")"
      rm -f "$stderr_file"

      if [[ "$stderr_output" == *"401"* || "$stderr_output" == *"403"* || "$stderr_output" == *"gated"* || "$stderr_output" == *"token"* || "$stderr_output" == *"login"* || "$stderr_output" == *"access"* ]]; then
        fail "The Voxtral model download requires Hugging Face authentication or gated access. Run \`${downloader_bin##*/} login\` in ${VENV_DIR} and then rerun this script."
      fi

      fail "Failed to download ${MODEL_ID}. Hugging Face CLI output:\n${stderr_output}"
    fi
    rm -f "$stderr_file"
  fi

  if ! is_valid_model_dir "$MODEL_PATH"; then
    fail "The downloaded model directory is still incomplete: $MODEL_PATH"
  fi

  if [[ "$SKIP_PREFLIGHT" == "1" ]]; then
    info "Skipping Voxtral preflight by request."
  else
    info "Running Voxtral readiness preflight..."
    /bin/bash "${SCRIPT_DIR}/probe_voxtral_realtime_local.sh" \
      --write-readiness-manifest \
      --app-version "$APP_VERSION"
  fi

  info "Voxtral runtime is ready."
  info "Readiness manifest: $(spk_voxtral_readiness_manifest_path)"
}

main "$@"
