#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

APP_PATH="${1:-$(spk_derived_data_path)/Build/Products/Debug/spk.app}"
FAILURES=0
WHISPERKIT_LOCAL_ONLY_STATUS="unknown"

report_failure() {
  echo "privacy_check: $1" >&2
  FAILURES=1
}

check_source_patterns() {
  local pattern="$1"
  local description="$2"

  if rg -n --glob '*.swift' "$pattern" "${PROJECT_ROOT}/spk" >/dev/null; then
    report_failure "$description"
    rg -n --glob '*.swift' "$pattern" "${PROJECT_ROOT}/spk" >&2
  fi
}

source_pattern_exists() {
  local pattern="$1"
  rg -n --glob '*.swift' "$pattern" "${PROJECT_ROOT}/spk" >/dev/null
}

check_required_source_pattern() {
  local pattern="$1"
  local description="$2"

  if ! source_pattern_exists "$pattern"; then
    report_failure "$description"
  fi
}

check_binary_strings() {
  local binary_path="$1"

  if strings "$binary_path" | rg -qi 'URLSession|NSURLSession|NSURLConnection|CFNetwork|WebSocket|huggingface|firebase|crashlytics|sentry|analytics|telemetry'; then
    report_failure "found suspicious network-oriented runtime strings in ${binary_path}"
  fi
}

check_binary_links() {
  local binary_path="$1"
  local linked_frameworks=""

  linked_frameworks="$(otool -L "$binary_path")"

  if echo "$linked_frameworks" | rg -q 'CFNetwork|WebKit'; then
    report_failure "found unexpected network-linked frameworks in ${binary_path}"
    echo "$linked_frameworks" >&2
    return
  fi

  if echo "$linked_frameworks" | rg -q 'Network\.framework' && ! whisperkit_local_only_usage_is_allowed; then
    report_failure "found unexpected network-linked frameworks in ${binary_path}"
    echo "$linked_frameworks" >&2
  fi
}

should_skip_binary() {
  local binary_path="$1"
  local file_name=""
  file_name="$(basename "$binary_path")"

  [[ "$binary_path" == *"/Frameworks/XCTest"* ]] || \
    [[ "$binary_path" == *"/Frameworks/Testing"* ]] || \
    [[ "$file_name" == libXCTest* ]] || \
    [[ "$file_name" == *XCTest* ]] || \
    [[ "$file_name" == *Testing* ]]
}

whisperkit_local_only_usage_is_allowed() {
  if [[ "$WHISPERKIT_LOCAL_ONLY_STATUS" == "allowed" ]]; then
    return 0
  fi

  if [[ "$WHISPERKIT_LOCAL_ONLY_STATUS" == "blocked" ]]; then
    return 1
  fi

  if ! source_pattern_exists '^import WhisperKit$'; then
    WHISPERKIT_LOCAL_ONLY_STATUS="blocked"
    return 1
  fi

  check_source_patterns 'WhisperKit\.download\(' \
    "found WhisperKit runtime download entrypoints in app sources"
  check_source_patterns '\bHubApi\b' \
    "found direct Hugging Face Hub API usage in app sources"
  check_source_patterns 'download:\s*true' \
    "found download-enabled WhisperKit configuration in app sources"
  check_source_patterns 'endpoint:\s*URL\(' \
    "found explicit remote WhisperKit endpoint configuration in app sources"
  check_required_source_pattern 'SPK_WHISPERKIT_MODEL_PATH|WhisperKitModels|Application Support/spk/WhisperKitModels|huggingface/models/argmaxinc/whisperkit-coreml' \
    "WhisperKit integration must resolve models only from local overrides, bundled assets, or local caches"
  check_required_source_pattern 'download:\s*false' \
    "WhisperKit integration must explicitly disable model downloads"

  if [[ "$FAILURES" == "0" ]]; then
    WHISPERKIT_LOCAL_ONLY_STATUS="allowed"
    return 0
  fi

  WHISPERKIT_LOCAL_ONLY_STATUS="blocked"
  return 1
}

echo "Running privacy/static audit..."

check_source_patterns 'URLSession|NSURLSession|NSURLConnection|NWConnection|NWPathMonitor|URLRequest\(' \
  "found runtime networking APIs in app sources"
check_source_patterns 'https?://' \
  "found external URL literals in app sources"
check_source_patterns 'Application Support/spk/Recordings|Application Support/spk/Logs|spk/Recordings|spk/Logs|logFilePath\(|revealInFinder\(' \
  "found persistent recording or logging paths in app sources"

if [[ ! -d "$APP_PATH" ]]; then
  report_failure "expected built app at ${APP_PATH}"
else
  while IFS= read -r binary_path; do
    if should_skip_binary "$binary_path"; then
      continue
    fi
    check_binary_links "$binary_path"
    check_binary_strings "$binary_path"
  done < <(find "$APP_PATH/Contents" -type f \( -path '*/MacOS/*' -o -path '*/Frameworks/*' \))
fi

if [[ "$FAILURES" != "0" ]]; then
  exit 1
fi

echo "Privacy/static audit passed."
