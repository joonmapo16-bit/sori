#!/bin/bash
# Build a macOS-only whisper.xcframework into ~/VoiceInk-Dependencies,
# where the Xcode project expects it.
#
# Why not the stock script: whisper.cpp's build-xcframework.sh builds for
# iOS/visionOS/tvOS too, which fails on a default Xcode install (those
# platform SDKs are not installed) and wastes tens of GB if you install
# them. This app is macOS-only.
#
# Strategy: reuse the helper functions from the stock script verbatim
# (everything above the first per-platform build), then run only the
# macOS build and xcframework assembly.
set -euo pipefail

DEPS_DIR="$HOME/VoiceInk-Dependencies"
WHISPER_DIR="$DEPS_DIR/whisper.cpp"

mkdir -p "$DEPS_DIR"
if [ ! -d "$WHISPER_DIR" ]; then
    git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi

cd "$WHISPER_DIR"

CUT_LINE=$(grep -n 'Building for iOS simulator' build-xcframework.sh | head -1 | cut -d: -f1)
if [ -z "$CUT_LINE" ]; then
    echo "error: could not locate the per-platform section in build-xcframework.sh (upstream layout changed?)" >&2
    exit 1
fi
head -n $((CUT_LINE - 1)) build-xcframework.sh > build-xcframework-macos.sh

cat >> build-xcframework-macos.sh << 'EOF'
echo "Building for macOS..."
cmake -B build-macos -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DWHISPER_COREML="ON" \
    -DWHISPER_COREML_ALLOW_FALLBACK="ON" \
    -S .
cmake --build build-macos --config Release -- -quiet

echo "Setting up framework structures..."
setup_framework_structure "build-macos" ${MACOS_MIN_OS_VERSION} "macos"

echo "Creating dynamic libraries from static libraries..."
combine_static_libraries "build-macos" "Release" "macos" "false"

echo "Creating XCFramework..."
xcodebuild -create-xcframework \
    -framework $(pwd)/build-macos/framework/whisper.framework \
    -debug-symbols $(pwd)/build-macos/dSYMs/whisper.dSYM \
    -output $(pwd)/build-apple/whisper.xcframework
EOF

chmod +x build-xcframework-macos.sh
rm -rf build-macos build-apple
./build-xcframework-macos.sh

echo "Done: $WHISPER_DIR/build-apple/whisper.xcframework"
