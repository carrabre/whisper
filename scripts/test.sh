#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/test.sh

Run the hosted macOS unit test suite for spk.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "Unknown argument: $1" >&2
  usage >&2
  exit 1
fi

spk_cd_project_root
spk_ensure_xcode_project

XCODEBUILD_BIN="$(spk_xcodebuild_bin)"
DERIVED_DATA_PATH="$(spk_derived_data_path)"
CLONED_SOURCE_PACKAGES_DIR="$(spk_cloned_source_packages_dir)"
MACOS_DESTINATION="$(spk_macos_destination)"

echo "Running spk tests..."
"${XCODEBUILD_BIN}" \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -destination "$MACOS_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR" \
  -quiet \
  test

echo "All tests passed."
