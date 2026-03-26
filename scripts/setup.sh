#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup.sh [--skip-model-prefetch]

Prepare the local spk workspace by generating the Xcode project,
resolving Swift packages, and caching the default Whisper model.

Options:
  --skip-model-prefetch   Skip prefetching the default Whisper model
  -h, --help              Show this help text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

echo "Resolving Swift packages..."
"${XCODEBUILD_BIN}" \
  -resolvePackageDependencies \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR" \
  -quiet

echo "Local setup is ready."
