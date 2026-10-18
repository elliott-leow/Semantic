#!/bin/bash
# Builds Semantic.app and installs it to ~/Applications.
#   ./build.sh               build + install + (re)launch
#   ./build.sh --no-run      build + install only
#   ./build.sh --build-only  leave the result in $BUILD (default ./build)
#   ./build.sh --test        build and run the regression checks
# Environment:
#   BUILD=dir          build output directory (lets several builds run side by side)
#   SIGN_IDENTITY=…    code-signing identity; default: the first valid "Apple Development"
#                      identity in the keychain, else ad-hoc ("-"). A stable identity keeps
#                      macOS privacy permissions (Accessibility, Screen Recording, Full Disk
#                      Access) across rebuilds; ad-hoc signatures change every build and lose them.
set -euo pipefail
cd "$(dirname "$0")"
L=vendor/llama.cpp
# EmbeddingGemma 2 support is newer than the last tagged llama.cpp release; this commit is known good
LLAMA_COMMIT=c479922ac520a08969b4c1dc154d7bbb3c386d85
BUILD=${BUILD:-build}
MODELS="$HOME/Library/Application Support/Semantic/models"
OLD_MODELS="$HOME/Library/Application Support/SemBar/models"
HF=https://huggingface.co/unsloth/embeddinggemma-2-GGUF/resolve/main

if [ ! -f $L/build/src/libllama.a ]; then
    if [ ! -d $L ]; then
        git init -q $L
        git -C $L remote add origin https://github.com/ggml-org/llama.cpp
        git -C $L fetch -q --depth 1 origin $LLAMA_COMMIT
        git -C $L checkout -q FETCH_HEAD
    fi
    CMAKE=$(command -v cmake || echo "uvx cmake")
    $CMAKE -S $L -B $L/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    $CMAKE --build $L/build -j --target llama mtmd
fi

# the app used to be called SemBar; reuse models it already downloaded
if [ ! -d "$MODELS" ] && [ -d "$OLD_MODELS" ] && [ ! -d "$HOME/Library/Application Support/Semantic" ]; then
    mv "$HOME/Library/Application Support/SemBar" "$HOME/Library/Application Support/Semantic"
fi
mkdir -p "$MODELS"

# download once, refuse anything whose checksum does not match (an HTTP error page, a truncated file)
fetch() {
    local file="$MODELS/$1" url=$2 sum=$3
    if [ ! -f "$file" ]; then
        curl -fL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    if [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sum" ]; then
        echo "checksum mismatch for $1; delete it and run again" >&2
        exit 1
    fi
}
fetch embeddinggemma-2-Q4.gguf $HF/embeddinggemma-2-UD-Q4_K_XL.gguf ea905fd08e8061db77a0031cbb5096d459d7cfd2bdd0ad2ba66e483f16719493
fetch mmproj-Q8_0.gguf $HF/mmproj-Q8_0.gguf 90e7b0238009e2954f856f2081dcf7f35af026b64c765e98f4777053e1754460
# small language model that parses commands ("remind me…", "turn this into…"); optional, rules still work without it
fetch command-model.gguf https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf \
    b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5

APP=$BUILD/Semantic.app
SWIFT_EXTRA=()
if [ "${1:-}" = "--test" ]; then
    APP=$BUILD/SearchTests.app
    SWIFT_EXTRA=(-D SEARCH_TESTS Tests/*.swift)
fi
mkdir -p $BUILD/obj $APP/Contents/MacOS
clang++ -std=c++17 -O3 -mmacosx-version-min=14.0 -c Sources/shim/sb_embed.cpp -o $BUILD/obj/sb_embed.o \
    -I$L/include -I$L/ggml/include -I$L/tools/mtmd

swiftc -O -wmo -swift-version 5 -target arm64-apple-macos14.0 \
    -import-objc-header Sources/shim/sb_embed.h Sources/Semantic/*.swift ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} $BUILD/obj/sb_embed.o \
    $L/build/tools/mtmd/libmtmd.a $L/build/src/libllama.a $L/build/ggml/src/libggml.a \
    $L/build/ggml/src/libggml-cpu.a $L/build/ggml/src/ggml-metal/libggml-metal.a \
    $L/build/ggml/src/ggml-blas/libggml-blas.a $L/build/ggml/src/libggml-base.a \
    -lc++ -lsqlite3 -framework Accelerate -framework EventKit -framework Contacts -framework Metal -framework MetalKit \
    -Xlinker -dead_strip -o $APP/Contents/MacOS/Semantic
strip -x $APP/Contents/MacOS/Semantic
cp Info.plist $APP/Contents/Info.plist
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}
codesign --force --sign "${IDENTITY:--}" $APP 2>/dev/null || codesign --force --sign - $APP

if [ "${1:-}" = "--test" ]; then
    "$APP/Contents/MacOS/Semantic"
    exit $?
fi
[ "${1:-}" = "--build-only" ] && exit 0

mkdir -p ~/Applications
pkill -x Semantic 2>/dev/null || true
pkill -x SemBar 2>/dev/null || true
rm -rf ~/Applications/SemBar.app ~/Applications/Semantic.app
cp -R $APP ~/Applications/Semantic.app
echo "installed ~/Applications/Semantic.app ($(du -sh $APP | cut -f1)), signed by ${IDENTITY:-ad-hoc}"
[ "${1:-}" = "--no-run" ] || open ~/Applications/Semantic.app
