#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/stage_self_contained_realtime_assets.sh (--app-path <spk.app> | --resource-root <Resources>) [--dry-run]

Copy the required WhisperKit and Voxtral realtime payloads into an app bundle
or a resource root and write the managed realtime bundle manifest consumed on first launch.

Options:
  --app-path <spk.app>      Target app bundle to stage
  --resource-root <path>    Resource root to stage before build, for example spk/Resources
  --dry-run             Print the copy and manifest steps without mutating
  -h, --help            Show this help text
EOF
}

APP_PATH=""
RESOURCE_ROOT=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --app-path" >&2
        exit 1
      fi
      APP_PATH="$2"
      shift 2
      ;;
    --resource-root)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --resource-root" >&2
        exit 1
      fi
      RESOURCE_ROOT="$2"
      shift 2
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

if [[ -n "$APP_PATH" && -n "$RESOURCE_ROOT" ]]; then
  echo "Pass either --app-path or --resource-root, but not both." >&2
  exit 1
fi

if [[ -z "$APP_PATH" && -z "$RESOURCE_ROOT" ]]; then
  echo "Missing required --app-path <spk.app> or --resource-root <Resources> argument." >&2
  exit 1
fi

if [[ -n "$APP_PATH" ]]; then
  RESOURCE_ROOT="${APP_PATH}/Contents/Resources"
fi

WHISPERKIT_SOURCE_DIR="$(spk_release_whisperkit_model_source_dir)"
VOXTRAL_MODEL_SOURCE_DIR="$(spk_release_voxtral_model_source_dir)"
VOXTRAL_RUNTIME_SOURCE_DIR="$(spk_release_voxtral_runtime_source_dir)"
WHISPERKIT_DEST_DIR="${RESOURCE_ROOT}/WhisperKitModels/$(spk_required_whisperkit_model_id)"
VOXTRAL_MODEL_DEST_DIR="${RESOURCE_ROOT}/VoxtralModels/$(basename "$VOXTRAL_MODEL_SOURCE_DIR")"
VOXTRAL_RUNTIME_DEST_DIR="${RESOURCE_ROOT}/VoxtralRuntime/$(basename "$VOXTRAL_RUNTIME_SOURCE_DIR")"
HELPERS_ROOT="${RESOURCE_ROOT}/Helpers"
MANIFEST_PATH="${HELPERS_ROOT}/$(spk_managed_realtime_manifest_name)"

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

fail_missing_source() {
  local source_path="$1"
  local description="$2"
  echo "Missing ${description} at ${source_path}." >&2
  echo "Prepare the local release payload first, then rerun this staging step." >&2
  exit 1
}

if ! spk_whisperkit_is_valid_model_dir "$WHISPERKIT_SOURCE_DIR"; then
  fail_missing_source "$WHISPERKIT_SOURCE_DIR" "WhisperKit preview model payload"
fi

if ! spk_voxtral_is_valid_model_dir "$VOXTRAL_MODEL_SOURCE_DIR"; then
  fail_missing_source "$VOXTRAL_MODEL_SOURCE_DIR" "Voxtral model payload"
fi

if ! spk_voxtral_is_valid_runtime_dir "$VOXTRAL_RUNTIME_SOURCE_DIR"; then
  fail_missing_source "$VOXTRAL_RUNTIME_SOURCE_DIR" "Voxtral runtime payload"
fi

WHISPERKIT_FINGERPRINT="$(spk_directory_fingerprint "$WHISPERKIT_SOURCE_DIR")"
VOXTRAL_MODEL_FINGERPRINT="$(spk_directory_fingerprint "$VOXTRAL_MODEL_SOURCE_DIR")"
VOXTRAL_RUNTIME_FINGERPRINT="$(spk_directory_fingerprint "$VOXTRAL_RUNTIME_SOURCE_DIR")"

run_cmd /bin/mkdir -p "${RESOURCE_ROOT}/WhisperKitModels"
run_cmd /bin/mkdir -p "${RESOURCE_ROOT}/VoxtralModels"
run_cmd /bin/mkdir -p "${RESOURCE_ROOT}/VoxtralRuntime"
run_cmd /bin/mkdir -p "$HELPERS_ROOT"

if [[ "$DRY_RUN" == "1" ]]; then
  print_cmd /bin/rm -rf "$WHISPERKIT_DEST_DIR"
  print_cmd /bin/rm -rf "$VOXTRAL_MODEL_DEST_DIR"
  print_cmd /bin/rm -rf "$VOXTRAL_RUNTIME_DEST_DIR"
else
  /bin/rm -rf "$WHISPERKIT_DEST_DIR" "$VOXTRAL_MODEL_DEST_DIR" "$VOXTRAL_RUNTIME_DEST_DIR"
fi

run_cmd /bin/cp -R "$WHISPERKIT_SOURCE_DIR" "$WHISPERKIT_DEST_DIR"
run_cmd /bin/cp -R "$VOXTRAL_MODEL_SOURCE_DIR" "$VOXTRAL_MODEL_DEST_DIR"
run_cmd /bin/cp -R "$VOXTRAL_RUNTIME_SOURCE_DIR" "$VOXTRAL_RUNTIME_DEST_DIR"

MANIFEST_JSON="$(cat <<EOF
{
  "schema_version": 1,
  "whisperkit_model_relative_path": "WhisperKitModels/$(spk_required_whisperkit_model_id)",
  "whisperkit_model_fingerprint": "${WHISPERKIT_FINGERPRINT}",
  "voxtral_model_relative_path": "VoxtralModels/$(basename "$VOXTRAL_MODEL_SOURCE_DIR")",
  "voxtral_model_fingerprint": "${VOXTRAL_MODEL_FINGERPRINT}",
  "voxtral_runtime_relative_path": "VoxtralRuntime/$(basename "$VOXTRAL_RUNTIME_SOURCE_DIR")",
  "voxtral_runtime_fingerprint": "${VOXTRAL_RUNTIME_FINGERPRINT}"
}
EOF
)"

if [[ "$DRY_RUN" == "1" ]]; then
  print_cmd /bin/sh -lc "printf '%s\n' '$MANIFEST_JSON' > '$MANIFEST_PATH'"
else
  printf '%s\n' "$MANIFEST_JSON" > "$MANIFEST_PATH"
fi

echo "Staged self-contained realtime assets into:"
echo "  ${RESOURCE_ROOT}"
