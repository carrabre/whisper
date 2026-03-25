#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
NEMOTRON_RELEASE_CONFIG_PATH="${PROJECT_ROOT}/spk/Resources/Config/nemotron-artifact-release.json"

nemotron_default_release_version() {
  if [[ -f "$NEMOTRON_RELEASE_CONFIG_PATH" ]]; then
    /usr/bin/plutil -extract version raw -o - "$NEMOTRON_RELEASE_CONFIG_PATH" 2>/dev/null || printf '2026-03-13\n'
    return
  fi

  printf '2026-03-13\n'
}

nemotron_default_runner_protocol_version() {
  if [[ -f "$NEMOTRON_RELEASE_CONFIG_PATH" ]]; then
    /usr/bin/plutil -extract runnerProtocolVersion raw -o - "$NEMOTRON_RELEASE_CONFIG_PATH" 2>/dev/null || printf '1\n'
    return
  fi

  printf '1\n'
}

nemotron_release_version() {
  printf '%s\n' "${SPK_NEMOTRON_ARTIFACT_VERSION:-$(nemotron_default_release_version)}"
}

nemotron_runner_protocol_version() {
  printf '%s\n' "${SPK_NEMOTRON_RUNNER_PROTOCOL_VERSION:-$(nemotron_default_runner_protocol_version)}"
}

nemotron_archive_name() {
  local version
  version="$(nemotron_release_version)"
  printf 'nemotron-en-%s-macos.zip\n' "$version"
}

nemotron_release_tag() {
  local version
  version="$(nemotron_release_version)"
  printf 'nemotron-en-%s\n' "$version"
}

nemotron_download_url() {
  if [[ -n "${SPK_NEMOTRON_ARTIFACT_URL:-}" ]]; then
    printf '%s\n' "$SPK_NEMOTRON_ARTIFACT_URL"
    return
  fi

  printf 'https://github.com/carrabre/whisper/releases/download/%s/%s\n' \
    "$(nemotron_release_tag)" \
    "$(nemotron_archive_name)"
}

nemotron_checkpoint_file_name() {
  printf 'nemotron-speech-streaming-en-0.6b.nemo\n'
}

nemotron_checkpoint_url() {
  if [[ -n "${SPK_NEMOTRON_CHECKPOINT_URL:-}" ]]; then
    printf '%s\n' "$SPK_NEMOTRON_CHECKPOINT_URL"
    return
  fi

  printf 'https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b/resolve/main/%s\n' \
    "$(nemotron_checkpoint_file_name)"
}
