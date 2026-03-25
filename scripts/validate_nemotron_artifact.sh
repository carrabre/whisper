#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${PROJECT_ROOT}/scripts/nemotron_artifact_common.sh"

ARTIFACT_DIR=""

usage() {
  cat <<EOF
Usage: ./scripts/validate_nemotron_artifact.sh --artifact-dir <dir>

Validate a versioned Nemotron English runtime directory for startup and install use.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-dir)
      ARTIFACT_DIR="${2:-}"
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

if [[ -z "$ARTIFACT_DIR" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -d "$ARTIFACT_DIR" ]]; then
  echo "Nemotron artifact directory does not exist: $ARTIFACT_DIR" >&2
  exit 1
fi

MANIFEST_PATH="${ARTIFACT_DIR}/manifest.json"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "Nemotron artifact is missing manifest.json: $MANIFEST_PATH" >&2
  exit 1
fi

manifest_value() {
  local key="$1"
  /usr/bin/plutil -extract "$key" raw -o - "$MANIFEST_PATH" 2>/dev/null
}

EXPECTED_VERSION="$(nemotron_release_version)"
EXPECTED_PROTOCOL_VERSION="$(nemotron_runner_protocol_version)"
ACTUAL_VERSION="$(manifest_value version || true)"
ACTUAL_PROTOCOL_VERSION="$(manifest_value runnerProtocolVersion || true)"
RUNNER_RELATIVE_PATH="$(manifest_value runnerExecutableRelativePath || true)"
RUNNER_SOURCE_RELATIVE_PATH="$(manifest_value runnerSourceRelativePath || true)"
CHECKPOINT_RELATIVE_PATH="$(manifest_value checkpointRelativePath || true)"

if [[ -z "$ACTUAL_VERSION" || -z "$ACTUAL_PROTOCOL_VERSION" || -z "$RUNNER_RELATIVE_PATH" || -z "$RUNNER_SOURCE_RELATIVE_PATH" || -z "$CHECKPOINT_RELATIVE_PATH" ]]; then
  echo "Nemotron artifact manifest is missing one or more required fields." >&2
  exit 1
fi

if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Nemotron artifact version mismatch. Expected ${EXPECTED_VERSION}, found ${ACTUAL_VERSION}." >&2
  exit 1
fi

if [[ "$ACTUAL_PROTOCOL_VERSION" != "$EXPECTED_PROTOCOL_VERSION" ]]; then
  echo "Nemotron runner protocol mismatch. Expected ${EXPECTED_PROTOCOL_VERSION}, found ${ACTUAL_PROTOCOL_VERSION}." >&2
  exit 1
fi

RUNNER_PATH="${ARTIFACT_DIR}/${RUNNER_RELATIVE_PATH}"
RUNNER_SOURCE_PATH="${ARTIFACT_DIR}/${RUNNER_SOURCE_RELATIVE_PATH}"
CHECKPOINT_PATH="${ARTIFACT_DIR}/${CHECKPOINT_RELATIVE_PATH}"

if [[ ! -x "$RUNNER_PATH" ]]; then
  echo "Nemotron artifact runner is missing or not executable: $RUNNER_PATH" >&2
  exit 1
fi

if [[ ! -f "$RUNNER_SOURCE_PATH" ]]; then
  echo "Nemotron artifact is missing runner source: $RUNNER_SOURCE_PATH" >&2
  exit 1
fi

if [[ ! -f "$CHECKPOINT_PATH" ]]; then
  echo "Nemotron artifact is missing checkpoint.nemo: $CHECKPOINT_PATH" >&2
  exit 1
fi

"$RUNNER_PATH" --healthcheck --artifact-dir "$ARTIFACT_DIR" >/dev/null

echo "Validated Nemotron runtime:"
echo "  $ARTIFACT_DIR"
