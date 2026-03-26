#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/check.sh [--skip-model-prefetch]

Run the full local verification flow:
1. Prepare the workspace
2. Build the Debug app
3. Run the unit test suite

Options:
  --skip-model-prefetch   Skip prefetching the default Whisper model during setup
  -h, --help              Show this help text
EOF
}

SETUP_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-model-prefetch)
      SETUP_ARGS+=("$1")
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

if [[ "${#SETUP_ARGS[@]}" -gt 0 ]]; then
  /bin/bash "${SCRIPT_DIR}/setup.sh" "${SETUP_ARGS[@]}"
else
  /bin/bash "${SCRIPT_DIR}/setup.sh"
fi
/bin/bash "${SCRIPT_DIR}/run_dev.sh" --build-only --skip-model-prefetch
/bin/bash "${SCRIPT_DIR}/test.sh"

echo "Full local verification passed."
