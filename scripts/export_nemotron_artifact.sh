#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_SCRIPT="${PROJECT_ROOT}/scripts/package_nemotron_artifact.sh"
. "${PROJECT_ROOT}/scripts/nemotron_artifact_common.sh"

VERSION="$(nemotron_release_version)"
WORK_DIR=""
OUTPUT_PATH=""

usage() {
  cat <<EOF
Usage: ./scripts/export_nemotron_artifact.sh \
  --output <zip> \
  [--version <version>] \
  [--work-dir <dir>]

Maintainer-only helper that downloads the Nemotron English checkpoint from Hugging Face,
prepares the local checkpoint-backed runtime, and packages it into a macOS zip.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
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

if [[ -z "$OUTPUT_PATH" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d)"
  CLEANUP_WORK_DIR=1
else
  mkdir -p "$WORK_DIR"
  CLEANUP_WORK_DIR=0
fi

cleanup() {
  if [[ "${CLEANUP_WORK_DIR:-0}" == "1" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "Preparing Nemotron runtime from the upstream checkpoint..."
SPK_NEMOTRON_ARTIFACT_VERSION="${VERSION}" \
  "${PROJECT_ROOT}/scripts/download_nemotron_artifact.sh" --destination "$WORK_DIR"

ARTIFACT_DIR="${WORK_DIR}/${VERSION}"
if [[ ! -d "$ARTIFACT_DIR" ]]; then
  echo "Expected prepared runtime at ${ARTIFACT_DIR}, but it was not produced." >&2
  exit 1
fi

echo
echo "Packaging runtime zip..."
"$PACKAGE_SCRIPT" \
  --artifact-dir "$ARTIFACT_DIR" \
  --output "$OUTPUT_PATH" \
  --root-name "nemotron-en-${VERSION}"

echo
echo "Nemotron runtime packaging complete."
