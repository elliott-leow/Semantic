#!/bin/bash
# Builds SemBar.app into ./build and installs it to ~/Applications.
#   ./build.sh           build + install + (re)launch
#   ./build.sh --no-run      build + install only
#   ./build.sh --build-only  leave the result in ./build
set -euo pipefail
cd "$(dirname "$0")"
L=vendor/llama.cpp
MODELS="$HOME/Library/Application Support/SemBar/models"
HF=https://huggingface.co/unsloth/embeddinggemma-2-GGUF/resolve/main

# llama.cpp: EmbeddingGemma 2 support is newer than the last tagged release, so build master
if [ ! -f $L/build/src/libllama.a ]; then
    [ -d $L ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp $L
    CMAKE=$(command -v cmake || echo "uvx cmake")
    $CMAKE -S $L -B $L/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    $CMAKE --build $L/build -j --target llama mtmd
fi

mkdir -p "$MODELS"
[ -f "$MODELS/embeddinggemma-2-Q4.gguf" ] || curl -L -o "$MODELS/embeddinggemma-2-Q4.gguf" $HF/embeddinggemma-2-UD-Q4_K_XL.gguf
[ -f "$MODELS/mmproj-Q8_0.gguf" ] || curl -L -o "$MODELS/mmproj-Q8_0.gguf" $HF/mmproj-Q8_0.gguf

# small language model that parses commands ("remind me…", "turn this into…"); optional, rules still work without it
[ -f "$MODELS/command-model.gguf" ] || curl -L -o "$MODELS/command-model.gguf" \
    https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf

APP=build/SemBar.app
SWIFT_EXTRA=()
if [ "${1:-}" = "--test" ]; then
    APP=build/SearchTests.app
    SWIFT_EXTRA=(-D SEARCH_TESTS Tests/*.swift)
fi
mkdir -p build/obj $APP/Contents/MacOS
clang++ -std=c++17 -O2 -w -mmacosx-version-min=14.0 -c Sources/shim/sb_embed.cpp -o build/obj/sb_embed.o \
    -I$L/include -I$L/ggml/include -I$L/tools/mtmd

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -suppress-warnings \
    -import-objc-header Sources/shim/sb_embed.h Sources/SemBar/*.swift ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} build/obj/sb_embed.o \
    $L/build/tools/mtmd/libmtmd.a $L/build/src/libllama.a $L/build/ggml/src/libggml.a \
    $L/build/ggml/src/libggml-cpu.a $L/build/ggml/src/ggml-metal/libggml-metal.a \
    $L/build/ggml/src/ggml-blas/libggml-blas.a $L/build/ggml/src/libggml-base.a \
    -lc++ -lsqlite3 -framework Accelerate -framework EventKit -framework Contacts -framework Metal -framework MetalKit \
    -Xlinker -dead_strip -o $APP/Contents/MacOS/SemBar
strip -x $APP/Contents/MacOS/SemBar
cp Info.plist $APP/Contents/Info.plist
codesign --force --sign - $APP 2>/dev/null

if [ "${1:-}" = "--test" ]; then
    "$APP/Contents/MacOS/SemBar"
    exit $?
fi
[ "${1:-}" = "--build-only" ] && exit 0

mkdir -p ~/Applications
pkill -x SemBar 2>/dev/null || true
rm -rf ~/Applications/SemBar.app
cp -R $APP ~/Applications/SemBar.app
echo "installed ~/Applications/SemBar.app ($(du -sh $APP | cut -f1))"
[ "${1:-}" = "--no-run" ] || open ~/Applications/SemBar.app
