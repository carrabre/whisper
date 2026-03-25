#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

ARTIFACT_DIR=""
OUTPUT_PATH=""
ROOT_NAME=""

usage() {
  cat <<'EOF'
Usage: ./scripts/package_nemotron_artifact.sh \
  --artifact-dir <dir> \
  --output <zip> \
  [--root-name <name>]

Package a prepared Nemotron English runtime directory into a versioned macOS zip.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-dir)
      ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --root-name)
      ROOT_NAME="${2:-}"
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

if [[ -z "$ARTIFACT_DIR" || -z "$OUTPUT_PATH" ]]; then
  usage >&2
  exit 1
fi

ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
mkdir -p "$(dirname "$OUTPUT_PATH")"
OUTPUT_PATH="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)/$(basename "$OUTPUT_PATH")"

"${PROJECT_ROOT}/scripts/validate_nemotron_artifact.sh" --artifact-dir "$ARTIFACT_DIR" >/dev/null

TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ -z "$ROOT_NAME" ]]; then
  ROOT_NAME="$(basename "$ARTIFACT_DIR")"
fi

cp -R "$ARTIFACT_DIR" "${TEMP_DIR}/${ROOT_NAME}"
rm -f "$OUTPUT_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${TEMP_DIR}/${ROOT_NAME}" "$OUTPUT_PATH"

echo "Packaged Nemotron runtime zip at:"
echo "  $OUTPUT_PATH"
shasum -a 256 "$OUTPUT_PATH"
