#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENDOR_DIR="${PROJECT_ROOT}/Vendor"
WHISPER_SRC_DIR="${VENDOR_DIR}/whisper.cpp"
BUILD_DIR="${WHISPER_SRC_DIR}/build-macos"
FRAMEWORK_ROOT="${VENDOR_DIR}/build-artifacts"
FRAMEWORK_DIR="${FRAMEWORK_ROOT}/whisper.framework"
XCFRAMEWORK_PATH="${VENDOR_DIR}/whisper.xcframework"
TEMP_DIR="${FRAMEWORK_ROOT}/temp"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-13.3}"

if [[ ! -d "${WHISPER_SRC_DIR}" ]]; then
  echo "Missing whisper.cpp source at ${WHISPER_SRC_DIR}"
  exit 1
fi

rm -rf "${BUILD_DIR}" "${FRAMEWORK_ROOT}" "${XCFRAMEWORK_PATH}"
mkdir -p "${FRAMEWORK_DIR}/Versions/A/Headers" "${FRAMEWORK_DIR}/Versions/A/Modules" "${FRAMEWORK_DIR}/Versions/A/Resources" "${TEMP_DIR}"

pushd "${WHISPER_SRC_DIR}" >/dev/null

cmake -B "${BUILD_DIR}" -G Xcode \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN_VERSION}" \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS_DEFAULT=ON \
  -DGGML_METAL_USE_BF16=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DWHISPER_COREML=ON \
  -DWHISPER_COREML_ALLOW_FALLBACK=ON \
  -S .

cmake --build "${BUILD_DIR}" --config Release -- -quiet

cp include/whisper.h "${FRAMEWORK_DIR}/Versions/A/Headers/"
cp ggml/include/ggml.h "${FRAMEWORK_DIR}/Versions/A/Headers/"
cp ggml/include/ggml-alloc.h "${FRAMEWORK_DIR}/Versions/A/Headers/"
cp ggml/include/ggml-backend.h "${FRAMEWORK_DIR}/Versions/A/Headers/"
cp ggml/include/ggml-metal.h "${FRAMEWORK_DIR}/Versions/A/Headers/"
cp ggml/include/ggml-cpu.h "${FRAMEWORK_DIR}/Versions/A/Headers/"
cp ggml/include/ggml-blas.h "${FRAMEWORK_DIR}/Versions/A/Headers/"
cp ggml/include/gguf.h "${FRAMEWORK_DIR}/Versions/A/Headers/"

cat > "${FRAMEWORK_DIR}/Versions/A/Modules/module.modulemap" <<'EOF'
framework module whisper {
  header "whisper.h"
  header "ggml.h"
  header "ggml-alloc.h"
  header "ggml-backend.h"
  header "ggml-metal.h"
  header "ggml-cpu.h"
  header "ggml-blas.h"
  header "gguf.h"

  link "c++"
  link framework "Accelerate"
  link framework "CoreML"
  link framework "Foundation"
  link framework "Metal"

  export *
}
EOF

cat > "${FRAMEWORK_DIR}/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>whisper</string>
  <key>CFBundleIdentifier</key>
  <string>com.acfinc.whisper</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>whisper</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>MinimumOSVersion</key>
  <string>${MACOS_MIN_VERSION}</string>
</dict>
</plist>
EOF

ln -sfn A "${FRAMEWORK_DIR}/Versions/Current"
ln -sfn Versions/Current/Headers "${FRAMEWORK_DIR}/Headers"
ln -sfn Versions/Current/Modules "${FRAMEWORK_DIR}/Modules"
ln -sfn Versions/Current/Resources "${FRAMEWORK_DIR}/Resources"
ln -sfn Versions/Current/whisper "${FRAMEWORK_DIR}/whisper"

libtool -static -o "${TEMP_DIR}/combined.a" \
  "${BUILD_DIR}/src/Release/libwhisper.a" \
  "${BUILD_DIR}/ggml/src/Release/libggml.a" \
  "${BUILD_DIR}/ggml/src/Release/libggml-base.a" \
  "${BUILD_DIR}/ggml/src/Release/libggml-cpu.a" \
  "${BUILD_DIR}/ggml/src/ggml-metal/Release/libggml-metal.a" \
  "${BUILD_DIR}/ggml/src/ggml-blas/Release/libggml-blas.a" \
  "${BUILD_DIR}/src/Release/libwhisper.coreml.a" 2>/dev/null

xcrun -sdk macosx clang++ -dynamiclib \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min="${MACOS_MIN_VERSION}" \
  -Wl,-force_load,"${TEMP_DIR}/combined.a" \
  -framework Accelerate \
  -framework CoreML \
  -framework Foundation \
  -framework Metal \
  -install_name "@rpath/whisper.framework/Versions/Current/whisper" \
  -o "${FRAMEWORK_DIR}/Versions/A/whisper"

xcodebuild -create-xcframework \
  -framework "${FRAMEWORK_DIR}" \
  -output "${XCFRAMEWORK_PATH}"

popd >/dev/null

echo "Built ${XCFRAMEWORK_PATH}"
