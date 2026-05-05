#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/run_dev.sh [--build-only] [--skip-model-prefetch]

Build the Debug app and run it locally.

Options:
  --build-only            Stop after the Debug build succeeds
  --skip-model-prefetch   Skip prefetching the default Whisper model
  -h, --help              Show this help text
EOF
}

BUILD_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --skip-model-prefetch)
      export SPK_SKIP_MODEL_PREFETCH=1
      shift
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

spk_cd_project_root
spk_ensure_xcode_project
spk_prefetch_models_if_needed

XCODEBUILD_BIN="$(spk_xcodebuild_bin)"
DERIVED_DATA_PATH="$(spk_derived_data_path)"
CLONED_SOURCE_PACKAGES_DIR="$(spk_cloned_source_packages_dir)"
MACOS_DESTINATION="$(spk_macos_destination)"
XCODEBUILD_SIGNING_ARGS=()
if [[ -n "${SPK_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}" ]]; then
  XCODEBUILD_SIGNING_ARGS+=("DEVELOPMENT_TEAM=${SPK_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}")
fi

echo "Building spk (Debug)..."
"${XCODEBUILD_BIN}" \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -configuration Debug \
  -destination "$MACOS_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR" \
  "${XCODEBUILD_SIGNING_ARGS[@]}" \
  -quiet \
  build

APP_EXE="${DERIVED_DATA_PATH}/Build/Products/Debug/spk.app/Contents/MacOS/spk"
if [[ ! -x "$APP_EXE" ]]; then
  echo "Executable not found: $APP_EXE" >&2
  exit 1
fi

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo "Debug build is ready at:"
  echo "  $APP_EXE"
  exit 0
fi

echo "Running spk (logs below)..."
exec "$APP_EXE"
