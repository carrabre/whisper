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

  echo "Ensuring Whisper is cached..."
  /bin/bash "${PROJECT_ROOT}/scripts/download_whisper_model.sh" --cache
  echo
}
