#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${PROJECT_ROOT}/scripts/nemotron_artifact_common.sh"

MODE="cache"
DESTINATION_DIR=""
VERSION="$(nemotron_release_version)"
CHECKPOINT_FILE_NAME="$(nemotron_checkpoint_file_name)"
CHECKPOINT_URL="$(nemotron_checkpoint_url)"
VALIDATE_SCRIPT="${PROJECT_ROOT}/scripts/validate_nemotron_artifact.sh"
SETUP_PYTHON_SCRIPT="${PROJECT_ROOT}/scripts/setup_nemotron_python.sh"
RUNNER_SOURCE_SCRIPT="${PROJECT_ROOT}/spk/Resources/NemotronRuntime/nemotron_runner.py"

usage() {
  cat <<EOF
Usage: ./scripts/download_nemotron_artifact.sh [--cache] [--destination <dir>]

Ensures the Nemotron English runtime used by spk is available locally.
By default this downloads the upstream \`.nemo\` checkpoint directly from Hugging Face,
installs the managed NeMo Python runtime, stages the local runner, and validates the
resulting runtime directory. If SPK_NEMOTRON_ARTIFACT_URL is set, the script instead
downloads a prebuilt artifact zip from that URL and validates it after unpacking.

Options:
  --cache              Download to ~/Library/Application Support/spk/Models/nemotron-en (default)
  --destination <dir>  Override the destination root directory
  -h, --help           Show this help

Environment:
  SPK_NEMOTRON_ARTIFACT_VERSION   Override the runtime version (default: ${VERSION})
  SPK_NEMOTRON_RUNNER_PROTOCOL_VERSION  Override the runner protocol version
  SPK_NEMOTRON_ARTIFACT_URL       Override the prebuilt artifact zip URL
  SPK_NEMOTRON_CHECKPOINT_URL     Override the Hugging Face .nemo checkpoint URL
  SPK_NEMOTRON_RUNTIME_PYTHON     Preferred base Python interpreter for the managed runtime
  SPK_NEMOTRON_EXPORT_PYTHON      Backwards-compatible fallback base interpreter
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache)
      MODE="cache"
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

if [[ "$MODE" == "cache" && -z "$DESTINATION_DIR" ]]; then
  DESTINATION_DIR="${HOME}/Library/Application Support/spk/Models/nemotron-en"
fi

if [[ -z "$DESTINATION_DIR" ]]; then
  echo "A destination directory is required." >&2
  exit 1
fi

ARTIFACT_DIR="${DESTINATION_DIR}/${VERSION}"
MANIFEST_FILE="${ARTIFACT_DIR}/manifest.json"

mkdir -p "$DESTINATION_DIR"

if [[ -f "$MANIFEST_FILE" ]]; then
  if "$VALIDATE_SCRIPT" --artifact-dir "$ARTIFACT_DIR" >/dev/null; then
    echo "Nemotron runtime already present at:"
    echo "  $ARTIFACT_DIR"
    exit 0
  fi

  echo "Existing Nemotron runtime is invalid. Re-preparing..."
  rm -rf "$ARTIFACT_DIR"
fi

TEMP_DIR="$(mktemp -d)"
STAGING_DIR="${TEMP_DIR}/nemotron-en-${VERSION}"
ARCHIVE_PATH="${TEMP_DIR}/$(nemotron_archive_name)"
UNPACK_DIR="${TEMP_DIR}/unpack"
mkdir -p "$UNPACK_DIR"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

write_runner_wrapper() {
  local runner_path="$1"
  local managed_python="$2"

  cat > "$runner_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
ARTIFACT_DIR="\$(cd "\${SCRIPT_DIR}/.." && pwd)"
CANDIDATE_PYTHONS=()

if [[ -n "\${SPK_NEMOTRON_RUNTIME_PYTHON:-}" ]]; then
  CANDIDATE_PYTHONS+=("\${SPK_NEMOTRON_RUNTIME_PYTHON}")
fi

if [[ -n "\${SPK_NEMOTRON_EXPORT_PYTHON:-}" ]]; then
  CANDIDATE_PYTHONS+=("\${SPK_NEMOTRON_EXPORT_PYTHON}")
fi

CANDIDATE_PYTHONS+=(
  "${managed_python}"
  "\${HOME}/Library/Application Support/spk/Tools/nemotron-python/bin/python3"
  "python3"
)

for candidate in "\${CANDIDATE_PYTHONS[@]}"; do
  if [[ -x "\$candidate" ]]; then
    exec "\$candidate" "\${ARTIFACT_DIR}/runtime/nemotron_runner.py" "\$@"
  fi
  if command -v "\$candidate" >/dev/null 2>&1; then
    exec "\$candidate" "\${ARTIFACT_DIR}/runtime/nemotron_runner.py" "\$@"
  fi
done

while IFS= read -r _line; do
  printf '%s\\n' '{"type":"error","message":"Nemotron runtime Python is unavailable. Run ./scripts/install_release.sh or ./scripts/run_dev.sh to install the managed NeMo runtime."}'
  exit 1
done
EOF

  chmod 755 "$runner_path"
}

write_manifest() {
  local artifact_root="$1"

  cat > "${artifact_root}/manifest.json" <<EOF
{
  "version": "${VERSION}",
  "runnerProtocolVersion": "$(nemotron_runner_protocol_version)",
  "runnerExecutableRelativePath": "bin/nemotron-runner",
  "runnerSourceRelativePath": "runtime/nemotron_runner.py",
  "checkpointRelativePath": "${CHECKPOINT_FILE_NAME}"
}
EOF
}

prepare_local_runtime() {
  local managed_python
  managed_python="$(/bin/bash "$SETUP_PYTHON_SCRIPT")"

  echo "Using managed Nemotron Python runtime:"
  echo "  ${managed_python}"
  echo
  echo "Downloading Nemotron checkpoint directly from Hugging Face:"
  echo "  $CHECKPOINT_URL"

  mkdir -p "${STAGING_DIR}/bin" "${STAGING_DIR}/runtime"
  cp "$RUNNER_SOURCE_SCRIPT" "${STAGING_DIR}/runtime/nemotron_runner.py"
  curl -fL "$CHECKPOINT_URL" -o "${STAGING_DIR}/${CHECKPOINT_FILE_NAME}"
  write_runner_wrapper "${STAGING_DIR}/bin/nemotron-runner" "$managed_python"
  write_manifest "$STAGING_DIR"
}

unpack_prebuilt_artifact() {
  echo "Downloading prebuilt Nemotron runtime zip:"
  echo "  $(nemotron_download_url)"
  curl -fL "$(nemotron_download_url)" -o "$ARCHIVE_PATH"
  echo
  echo "Unpacking prebuilt runtime zip..."
  /usr/bin/ditto -x -k "$ARCHIVE_PATH" "$UNPACK_DIR"

  if [[ -f "${UNPACK_DIR}/manifest.json" ]]; then
    mv "$UNPACK_DIR" "$STAGING_DIR"
    return 0
  fi

  local resolved_manifest_path
  resolved_manifest_path="$(find "$UNPACK_DIR" -mindepth 1 -maxdepth 2 -type f -name manifest.json -print -quit)"
  if [[ -z "${resolved_manifest_path:-}" ]]; then
    echo "Downloaded Nemotron runtime zip did not contain manifest.json." >&2
    exit 1
  fi

  mv "$(dirname "$resolved_manifest_path")" "$STAGING_DIR"
}

if [[ -n "${SPK_NEMOTRON_ARTIFACT_URL:-}" ]]; then
  unpack_prebuilt_artifact
else
  prepare_local_runtime
fi

echo
echo "Validating prepared Nemotron runtime..."
"$VALIDATE_SCRIPT" --artifact-dir "$STAGING_DIR" >/dev/null

rm -rf "$ARTIFACT_DIR"
mv "$STAGING_DIR" "$ARTIFACT_DIR"

echo
echo "Nemotron runtime ready at:"
echo "  $ARTIFACT_DIR"
echo
echo "spk will use this for the default English realtime mode."
