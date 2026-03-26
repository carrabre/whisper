#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

ensure_xcode_project() {
  local project_file="${PROJECT_ROOT}/spk.xcodeproj/project.pbxproj"

  if [[ -f "$project_file" && "$project_file" -nt "${PROJECT_ROOT}/project.yml" ]]; then
    return 0
  fi

  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required to generate spk.xcodeproj from project.yml." >&2
    exit 1
  fi

  echo "Generating Xcode project from project.yml..."
  xcodegen generate
}

ensure_xcode_project

if [[ "${SPK_SKIP_MODEL_PREFETCH:-0}" != "1" ]]; then
  echo "Ensuring Whisper is cached..."
  "${PROJECT_ROOT}/scripts/download_whisper_model.sh" --cache
  echo
fi

echo "Building spk (Debug)..."
xcodebuild \
  -project "spk.xcodeproj" \
  -scheme "spk" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath ".build" \
  -quiet \
  build

APP_EXE=".build/Build/Products/Debug/spk.app/Contents/MacOS/spk"
if [[ ! -x "$APP_EXE" ]]; then
  echo "Executable not found: $APP_EXE" >&2
  exit 1
fi

echo "Running spk (logs below)..."
exec "$APP_EXE"
