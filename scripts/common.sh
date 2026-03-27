#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

spk_cd_project_root() {
  cd "$PROJECT_ROOT"
}

spk_require_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    return 0
  fi

  echo "${command_name} is required but was not found in PATH." >&2
  exit 1
}

spk_xcodebuild_bin() {
  if [[ -n "${DEVELOPER_DIR:-}" && -x "${DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
    printf '%s\n' "${DEVELOPER_DIR}/usr/bin/xcodebuild"
    return 0
  fi

  if command -v xcrun >/dev/null 2>&1; then
    local resolved_path=""
    resolved_path="$(xcrun -f xcodebuild 2>/dev/null || true)"
    if [[ -n "$resolved_path" && -x "$resolved_path" ]]; then
      printf '%s\n' "$resolved_path"
      return 0
    fi
  fi

  if command -v xcodebuild >/dev/null 2>&1; then
    command -v xcodebuild
    return 0
  fi

  echo "xcodebuild is required but was not found. Install Xcode and the Xcode Command Line Tools." >&2
  exit 1
}

spk_derived_data_path() {
  printf '%s\n' "${SPK_DERIVED_DATA_PATH:-${PROJECT_ROOT}/.build}"
}

spk_model_cache_dir() {
  printf '%s\n' "${SPK_MODEL_CACHE_DIR:-${HOME}/Library/Application Support/spk/Models}"
}

spk_bundled_models_dir() {
  printf '%s\n' "${SPK_BUNDLED_MODELS_DIR:-${PROJECT_ROOT}/spk/Resources/Models}"
}

spk_whisperkit_model_cache_dir() {
  printf '%s\n' "${SPK_WHISPERKIT_MODEL_CACHE_DIR:-${HOME}/Library/Application Support/spk/WhisperKitModels}"
}

spk_whisperkit_documents_cache_dir() {
  printf '%s\n' "${SPK_WHISPERKIT_DOCUMENTS_CACHE_DIR:-${HOME}/Documents/huggingface/models/argmaxinc/whisperkit-coreml}"
}

spk_whisperkit_bundled_models_dir() {
  printf '%s\n' "${SPK_WHISPERKIT_BUNDLED_MODELS_DIR:-${PROJECT_ROOT}/spk/Resources/WhisperKitModels}"
}

spk_whisperkit_is_valid_model_dir() {
  local model_dir="$1"

  [[ -d "$model_dir" ]] || return 1
  [[ -e "$model_dir/AudioEncoder.mlmodelc" ]] || return 1
  [[ -e "$model_dir/TextDecoder.mlmodelc" ]] || return 1
  [[ -e "$model_dir/MelSpectrogram.mlmodelc" ]] || return 1

  /usr/bin/find "$model_dir" -maxdepth 5 -name tokenizer.json -print -quit | /usr/bin/grep -q .
}

spk_whisperkit_preferred_model_dir() {
  local roots=()
  local app_support_dir
  local documents_cache_dir
  local root
  local candidate
  local best_path=""
  local best_rank=999

  app_support_dir="$(spk_whisperkit_model_cache_dir)"
  documents_cache_dir="$(spk_whisperkit_documents_cache_dir)"

  [[ -d "$app_support_dir" ]] && roots+=("$app_support_dir")
  [[ -d "$documents_cache_dir" ]] && roots+=("$documents_cache_dir")

  for root in "${roots[@]}"; do
    if spk_whisperkit_is_valid_model_dir "$root"; then
      candidate="$root"
      local name
      local rank
      name="$(basename "$candidate" | tr '[:upper:]' '[:lower:]')"
      rank=50
      case "$name" in
        *whisper-medium.en*|*medium.en*) rank=0 ;;
        *whisper-medium*|*medium*) rank=1 ;;
        *whisper-base.en*|*base.en*) rank=10 ;;
        *whisper-base*|*base*) rank=11 ;;
      esac
      if [[ "$rank" -lt "$best_rank" ]] || [[ "$rank" -eq "$best_rank" && ( -z "$best_path" || "$candidate" < "$best_path" ) ]]; then
        best_path="$candidate"
        best_rank="$rank"
      fi
    fi

    while IFS= read -r candidate; do
      spk_whisperkit_is_valid_model_dir "$candidate" || continue

      local name
      local rank
      name="$(basename "$candidate" | tr '[:upper:]' '[:lower:]')"
      rank=50
      case "$name" in
        *whisper-medium.en*|*medium.en*) rank=0 ;;
        *whisper-medium*|*medium*) rank=1 ;;
        *whisper-base.en*|*base.en*) rank=10 ;;
        *whisper-base*|*base*) rank=11 ;;
      esac

      if [[ "$rank" -lt "$best_rank" ]] || [[ "$rank" -eq "$best_rank" && ( -z "$best_path" || "$candidate" < "$best_path" ) ]]; then
        best_path="$candidate"
        best_rank="$rank"
      fi
    done < <(/usr/bin/find "$root" -mindepth 1 -maxdepth 3 -type d ! -name '.*' | sort)
  done

  if [[ -n "$best_path" ]]; then
    printf '%s\n' "$best_path"
  fi
}

spk_default_whisper_model_id() {
  if defaults read -g AppleLanguages 2>/dev/null | grep -qi "en"; then
    printf '%s\n' "base.en-q5_1"
  else
    printf '%s\n' "base-q5_1"
  fi
}

spk_default_vad_model_id() {
  printf '%s\n' "${SPK_VAD_MODEL_ID:-silero-v6.2.0}"
}

spk_cloned_source_packages_dir() {
  printf '%s\n' "${SPK_CLONED_SOURCE_PACKAGES_DIR:-$(spk_derived_data_path)/SourcePackages}"
}

spk_macos_destination() {
  local host_arch=""
  host_arch="$(uname -m)"

  case "$host_arch" in
    arm64|x86_64)
      printf 'platform=macOS,arch=%s\n' "$host_arch"
      ;;
    *)
      printf 'platform=macOS\n'
      ;;
  esac
}

spk_ensure_xcode_project() {
  local project_file="${PROJECT_ROOT}/spk.xcodeproj/project.pbxproj"

  if [[ -f "$project_file" && "$project_file" -nt "${PROJECT_ROOT}/project.yml" ]]; then
    return 0
  fi

  spk_require_command xcodegen

  echo "Generating Xcode project from project.yml..."
  xcodegen generate
}

spk_prefetch_models_if_needed() {
  if [[ "${SPK_SKIP_MODEL_PREFETCH:-0}" == "1" ]]; then
    return 0
  fi

  echo "Ensuring Whisper and VAD models are cached locally..."
  /bin/bash "${PROJECT_ROOT}/scripts/download_whisper_model.sh" --cache
  echo
}
