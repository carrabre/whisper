#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/install_release.sh --development-team <TEAM_ID> [--no-open] [--dry-run]

Canonical one-command local installer for spk.
Build a Release copy, verify that it is team-signed, prefetch Whisper,
replace /Applications/spk.app, reset Accessibility and Microphone permissions,
and relaunch the app.

Options:
  --development-team <TEAM_ID>  Required Apple Development team identifier
  --no-open                     Install without relaunching the app
  --dry-run                     Print the install steps without mutating the system
  -h, --help                    Show this help text
EOF
}

TEAM_ID=""
OPEN_AFTER_INSTALL=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --development-team)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --development-team" >&2
        exit 1
      fi
      TEAM_ID="$2"
      shift 2
      ;;
    --no-open)
      OPEN_AFTER_INSTALL=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

if [[ -z "$TEAM_ID" ]]; then
  echo "Missing required --development-team <TEAM_ID> argument." >&2
  exit 1
fi

DERIVED_DATA_PATH="${SPK_INSTALL_DERIVED_DATA_PATH:-${PROJECT_ROOT}/.release}"
BUILT_APP_PATH="${SPK_INSTALL_BUILT_APP_PATH:-${DERIVED_DATA_PATH}/Build/Products/Release/spk.app}"
CLONED_SOURCE_PACKAGES_DIR="${SPK_INSTALL_CLONED_SOURCE_PACKAGES_DIR:-${DERIVED_DATA_PATH}/SourcePackages}"
INSTALL_PATH="${SPK_INSTALL_APP_PATH:-/Applications/spk.app}"
BUNDLE_ID="${SPK_INSTALL_BUNDLE_ID:-com.acfinc.spk}"

print_cmd() {
  printf '[dry-run]'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    print_cmd "$@"
    return 0
  fi

  "$@"
}

prefetch_models() {
  if [[ "${SPK_SKIP_MODEL_PREFETCH:-0}" == "1" ]]; then
    return 0
  fi

  echo "Prefetching Whisper..."
  if ! run_cmd /bin/bash "${PROJECT_ROOT}/scripts/download_whisper_model.sh" --cache; then
    echo >&2
    echo "Installation stopped because the preferred Whisper model could not be downloaded." >&2
    echo "The existing /Applications/spk.app was left untouched." >&2
    exit 1
  fi
}

codesign_info() {
  if [[ -n "${SPK_INSTALL_CODESIGN_OUTPUT_FILE:-}" ]]; then
    cat "$SPK_INSTALL_CODESIGN_OUTPUT_FILE"
    return 0
  fi

  if [[ -n "${SPK_INSTALL_CODESIGN_OUTPUT:-}" ]]; then
    printf '%s\n' "$SPK_INSTALL_CODESIGN_OUTPUT"
    return 0
  fi

  /usr/bin/codesign -dv --verbose=4 "$BUILT_APP_PATH" 2>&1
}

verify_signed_build() {
  local output="$1"

  if grep -qE 'Signature=adhoc|flags=.*\(adhoc\)' <<<"$output"; then
    echo "Refusing to install an ad hoc-signed build. Set a real Apple Development team and rebuild." >&2
    return 1
  fi

  if ! grep -q "^TeamIdentifier=${TEAM_ID}$" <<<"$output"; then
    echo "Refusing to install because TeamIdentifier did not match ${TEAM_ID}." >&2
    return 1
  fi
}

spk_cd_project_root
spk_ensure_xcode_project
prefetch_models

XCODEBUILD_BIN="$(spk_xcodebuild_bin)"
MACOS_DESTINATION="$(spk_macos_destination)"

if [[ "$DRY_RUN" != "1" ]]; then
  run_cmd "${XCODEBUILD_BIN}" \
    -project "spk.xcodeproj" \
    -scheme "spk" \
    -configuration Release \
    -destination "$MACOS_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    build

  if [[ ! -d "$BUILT_APP_PATH" ]]; then
    echo "Expected built app at ${BUILT_APP_PATH}, but it was not produced." >&2
    exit 1
  fi
fi

SIGNED_BUILD_INFO="$(codesign_info)"
verify_signed_build "$SIGNED_BUILD_INFO"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "$SIGNED_BUILD_INFO"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  print_cmd /usr/bin/killall spk
else
  /usr/bin/killall spk >/dev/null 2>&1 || true
fi

run_cmd /bin/rm -rf "$INSTALL_PATH"
run_cmd /bin/cp -R "$BUILT_APP_PATH" "$INSTALL_PATH"
run_cmd /usr/bin/tccutil reset Accessibility "$BUNDLE_ID"
run_cmd /usr/bin/tccutil reset Microphone "$BUNDLE_ID"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  run_cmd /usr/bin/open "$INSTALL_PATH"
fi

echo "Installed ${INSTALL_PATH} with team ${TEAM_ID}."
