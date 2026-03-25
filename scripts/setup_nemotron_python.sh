#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REQUIREMENTS_FILE="${PROJECT_ROOT}/spk/Resources/NemotronRuntime/requirements.txt"
RUNTIME_ROOT="${SPK_NEMOTRON_RUNTIME_ROOT:-${HOME}/Library/Application Support/spk/Tools/nemotron-python}"
STAMP_FILE="${RUNTIME_ROOT}/.requirements-stamp"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup_nemotron_python.sh

Create or refresh the managed Python runtime used by the Nemotron English backend.

Environment:
  SPK_NEMOTRON_RUNTIME_PYTHON   Preferred base Python interpreter
  SPK_NEMOTRON_EXPORT_PYTHON    Backwards-compatible fallback base interpreter
  SPK_NEMOTRON_AUTO_INSTALL_PYTHON  Set to 0 to disable automatic Homebrew python@3.12 install
  SPK_NEMOTRON_RUNTIME_ROOT     Override the managed runtime directory
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

python_version_supported() {
  local python_bin="$1"
  "$python_bin" - <<'PY' >/dev/null 2>&1
import sys
major, minor = sys.version_info[:2]
raise SystemExit(0 if major == 3 and 10 <= minor <= 12 else 1)
PY
}

find_base_python() {
  local candidates=()

  if [[ -n "${SPK_NEMOTRON_RUNTIME_PYTHON:-}" ]]; then
    candidates+=("${SPK_NEMOTRON_RUNTIME_PYTHON}")
  fi

  if [[ -n "${SPK_NEMOTRON_EXPORT_PYTHON:-}" ]]; then
    candidates+=("${SPK_NEMOTRON_EXPORT_PYTHON}")
  fi

  candidates+=(python3.12 python3.11 python3.10 python3)

  for candidate in "${candidates[@]}"; do
    if command -v "$candidate" >/dev/null 2>&1 && python_version_supported "$candidate"; then
      command -v "$candidate"
      return 0
    fi
  done

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix=""
    local brew_python=""

    brew_prefix="$(brew --prefix python@3.12 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
      brew_python="${brew_prefix}/bin/python3.12"
    fi

    if [[ -x "$brew_python" ]] && python_version_supported "$brew_python"; then
      printf '%s\n' "$brew_python"
      return 0
    fi

    if [[ "${SPK_NEMOTRON_AUTO_INSTALL_PYTHON:-1}" != "0" ]]; then
      echo "Installing python@3.12 with Homebrew for the Nemotron runtime..." >&2
      brew install python@3.12 >/dev/null
      brew_prefix="$(brew --prefix python@3.12 2>/dev/null || true)"
      if [[ -n "$brew_prefix" ]]; then
        brew_python="${brew_prefix}/bin/python3.12"
      fi
      if [[ -x "$brew_python" ]] && python_version_supported "$brew_python"; then
        printf '%s\n' "$brew_python"
        return 0
      fi
    fi
  fi

  echo "Nemotron runtime setup requires Python 3.10, 3.11, or 3.12." >&2
  echo "Install python@3.12 with Homebrew or set SPK_NEMOTRON_RUNTIME_PYTHON." >&2
  exit 1
}

BASE_PYTHON="$(find_base_python)"
mkdir -p "$(dirname "$RUNTIME_ROOT")"

if [[ ! -x "${RUNTIME_ROOT}/bin/python3" ]]; then
  echo "Creating managed Nemotron Python runtime at:"
  echo "  ${RUNTIME_ROOT}"
  "$BASE_PYTHON" -m venv "$RUNTIME_ROOT"
fi

VENV_PYTHON="${RUNTIME_ROOT}/bin/python3"
REQUIREMENTS_HASH="$(shasum -a 256 "$REQUIREMENTS_FILE" | awk '{print $1}')"
INSTALLED_HASH="$(cat "$STAMP_FILE" 2>/dev/null || true)"

if [[ "$REQUIREMENTS_HASH" != "$INSTALLED_HASH" ]] || ! "$VENV_PYTHON" - <<'PY' >/dev/null 2>&1
from nemo.collections.asr.models import ASRModel  # noqa: F401
import torch  # noqa: F401
PY
then
  echo "Installing Nemotron Python dependencies..."
  "$VENV_PYTHON" -m pip install --upgrade pip setuptools wheel
  "$VENV_PYTHON" -m pip install -r "$REQUIREMENTS_FILE"
  printf '%s\n' "$REQUIREMENTS_HASH" > "$STAMP_FILE"
fi

printf '%s\n' "$VENV_PYTHON"
