#!/bin/bash
# Builds Semantic.app and installs it to ~/Applications.
#   ./build.sh               build + install + (re)launch
#   ./build.sh --no-run      build + install only
#   ./build.sh --build-only  leave the result in $BUILD (default ./build)
#   ./build.sh --test        build and run the regression checks
#   ./build.sh --uninstall   quit Semantic and remove the app, its models, index and settings
# Environment:
#   BUILD=dir          build output directory (lets several builds run side by side)
#   SIGN_IDENTITY=…    code-signing identity; default: the first valid "Apple Development"
#                      identity in the keychain, else a self-signed "Semantic Local Signing"
#                      identity created on first build. A stable identity keeps macOS privacy
#                      permissions (Accessibility, Screen Recording, Full Disk Access) across
#                      rebuilds; ad-hoc signatures change every build and lose them.
set -euo pipefail
cd "$(dirname "$0")"
L=vendor/llama.cpp
# EmbeddingGemma 2 support is newer than the last tagged llama.cpp release; this commit is known good
LLAMA_COMMIT=c479922ac520a08969b4c1dc154d7bbb3c386d85
BUILD=${BUILD:-build}
SUPPORT="$HOME/Library/Application Support/Semantic"
MODELS="$SUPPORT/models"
OLD_MODELS="$HOME/Library/Application Support/SemBar/models"
HF=https://huggingface.co/unsloth/embeddinggemma-2-GGUF/resolve/main
LOCAL_ID="Semantic Local Signing"
MODE=${1:-}

if [ -t 1 ]; then B=$'\033[1m' G=$'\033[32m' R=$'\033[31m' D=$'\033[2m' N=$'\033[0m'; else B= G= R= D= N=; fi
STEP=0 STEPS=5
step() { STEP=$((STEP + 1)); echo; echo "${B}[$STEP/$STEPS] $*${N}"; }
note() { echo "${D}      $*${N}"; }
die() { echo; echo "${R}${B}✗ $1${N}" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; exit 1; }
# runs a noisy command into a log; shows the end of the log only if it fails
quiet() {
    local log=$1; shift
    if ! "$@" >"$log" 2>&1; then
        tail -25 "$log" >&2
        die "that step failed" "full log: $PWD/$log"
    fi
}

if [ "$MODE" = "--uninstall" ]; then
    echo "This removes ~/Applications/Semantic.app, its models and index ($SUPPORT)"
    echo "and its settings (~/.config/semantic). Your own files are not touched."
    if [ "${2:-}" != --yes ]; then
        (exec </dev/tty) 2>/dev/null || die "No terminal to confirm in; run it as: $0 --uninstall --yes"
        read -r -p "Continue? [y/N] " answer </dev/tty
        [[ $answer = [yY]* ]] || { echo "Nothing removed."; exit 0; }
    fi
    pkill -x Semantic 2>/dev/null || true
    rm -rf ~/Applications/Semantic.app "$SUPPORT" ~/.config/semantic
    tccutil reset All local.semantic >/dev/null 2>&1 || true
    echo "${G}✓ Semantic removed.${N} ${D}(The \"$LOCAL_ID\" keychain item, if any, is harmless; delete it in Keychain Access if you like.)${N}"
    exit 0
fi

# ---- 1. check this Mac can build it, before spending any time or bandwidth
step "Checking this Mac"
[ "$(uname -m)" = arm64 ] || die "Semantic needs an Apple Silicon Mac (M1 or later)." "This Mac reports $(uname -m)."
OS=$(sw_vers -productVersion)
[ "${OS%%.*}" -ge 14 ] || die "Semantic needs macOS 14 Sonoma or later; this Mac runs $OS." "Update in System Settings > General > Software Update."
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "      Apple's Command Line Tools are needed to compile Semantic."
    echo "      ${B}A macOS dialog is opening: click Install${N} (about 5 minutes). This continues on its own afterwards."
    xcode-select --install >/dev/null 2>&1 || true
    until xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; do sleep 5; done
fi
note "Apple Silicon, macOS $OS, Command Line Tools present"
missing=0
for f in embeddinggemma-2-Q4.gguf mmproj-Q8_0.gguf command-model.gguf; do [ -f "$MODELS/$f" ] || missing=1; done
if [ $missing = 1 ]; then
    free_gb=$(( $(df -k "$HOME" | awk 'NR==2 {print $4}') / 1048576 ))
    [ "$free_gb" -ge 3 ] || die "Not enough free disk space: ${free_gb} GB free, about 3 GB needed (1.5 GB of models plus the build)."
fi

# ---- 2. llama.cpp, once
step "Building the local AI engine (llama.cpp)"
if [ -f $L/build/src/libllama.a ]; then
    note "already built"
else
    note "one-time, about 2–4 minutes"
    if [ ! -d $L/.git ]; then
        rm -rf $L
        git init -q $L
        git -C $L remote add origin https://github.com/ggml-org/llama.cpp
        git -C $L fetch -q --depth 1 origin $LLAMA_COMMIT || die "Could not download llama.cpp from GitHub." "Check your internet connection and run this again."
        git -C $L checkout -q FETCH_HEAD
    fi
    if command -v cmake >/dev/null; then CMAKE=(cmake)
    elif command -v uvx >/dev/null; then CMAKE=(uvx cmake)
    else
        # no cmake anywhere: a private copy from PyPI, which needs only the python3 the Command Line Tools ship
        if [ ! -x $L/.cmake/bin/cmake ]; then
            note "fetching cmake"
            quiet $L/cmake-install.log sh -c "python3 -m venv $L/.cmake && $L/.cmake/bin/pip install -q cmake"
        fi
        CMAKE=($L/.cmake/bin/cmake)
    fi
    quiet $L/build.log "${CMAKE[@]}" -S $L -B $L/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    quiet $L/build.log "${CMAKE[@]}" --build $L/build -j --target llama mtmd
    note "done"
fi

# ---- 3. models
step "Downloading the models"
# the app used to be called SemBar; reuse models it already downloaded
if [ ! -d "$MODELS" ] && [ -d "$OLD_MODELS" ] && [ ! -d "$SUPPORT" ]; then
    mv "$HOME/Library/Application Support/SemBar" "$SUPPORT"
fi
mkdir -p "$MODELS"
[ $missing = 1 ] && note "about 1.5 GB, once; an interrupted download resumes where it stopped"

# download once (resuming a partial file), refuse anything whose checksum does not match
# (an HTTP error page, a truncated file); a bad file is fetched again once before giving up
fetch() {
    local name=$1 file="$MODELS/$1" url=$2 sum=$3 label=$4 try
    for try in 1 2; do
        if [ ! -f "$file" ]; then
            echo "      $label"
            curl -fL --retry 5 --retry-delay 2 -C - --progress-bar -o "$file.part" "$url" \
                || die "Download of $name failed." "Check your internet connection and run this again; it resumes."
            mv "$file.part" "$file"
        fi
        [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sum" ] && { note "✓ $label"; return; }
        rm -f "$file"
    done
    die "$name did not match its checksum twice." "The download source may have changed; please report it."
}
fetch embeddinggemma-2-Q4.gguf $HF/embeddinggemma-2-UD-Q4_K_XL.gguf ea905fd08e8061db77a0031cbb5096d459d7cfd2bdd0ad2ba66e483f16719493 \
    "search model (176 MB)"
fetch mmproj-Q8_0.gguf $HF/mmproj-Q8_0.gguf 90e7b0238009e2954f856f2081dcf7f35af026b64c765e98f4777053e1754460 \
    "image and audio model (555 MB)"
# small language model that parses commands ("remind me…", "turn this into…"); optional, rules still work without it
fetch command-model.gguf https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf \
    b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5 "command model (730 MB)"

# ---- 4. the app
step "Compiling Semantic"
note "about 3 minutes"
APP=$BUILD/Semantic.app
SWIFT_EXTRA=()
if [ "$MODE" = "--test" ]; then
    APP=$BUILD/SearchTests.app
    SWIFT_EXTRA=(-D SEARCH_TESTS Tests/*.swift)
fi
mkdir -p $BUILD/obj $APP/Contents/MacOS
quiet $BUILD/compile.log clang++ -std=c++17 -O3 -mmacosx-version-min=14.0 -c Sources/shim/sb_embed.cpp -o $BUILD/obj/sb_embed.o \
    -I$L/include -I$L/ggml/include -I$L/tools/mtmd

quiet $BUILD/compile.log swiftc -O -wmo -swift-version 5 -target arm64-apple-macos14.0 \
    -import-objc-header Sources/shim/sb_embed.h Sources/Semantic/*.swift ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} $BUILD/obj/sb_embed.o \
    $L/build/tools/mtmd/libmtmd.a $L/build/src/libllama.a $L/build/ggml/src/libggml.a \
    $L/build/ggml/src/libggml-cpu.a $L/build/ggml/src/ggml-metal/libggml-metal.a \
    $L/build/ggml/src/ggml-blas/libggml-blas.a $L/build/ggml/src/libggml-base.a \
    -lc++ -lsqlite3 -framework Accelerate -framework EventKit -framework Contacts -framework Metal -framework MetalKit \
    -Xlinker -dead_strip -o $APP/Contents/MacOS/Semantic
strip -x $APP/Contents/MacOS/Semantic
cp Info.plist $APP/Contents/Info.plist

# a self-signed identity, used only to make the signature identical across rebuilds (so macOS keeps
# the permissions you granted); it is trusted by nothing and grants nothing
local_identity() {
    security find-certificate -c "$LOCAL_ID" >/dev/null 2>&1 && return
    local t ok=0; t=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$LOCAL_ID" \
        -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:false" -keyout "$t/key.pem" -out "$t/cert.pem" >/dev/null 2>&1 &&
    /usr/bin/openssl pkcs12 -export -inkey "$t/key.pem" -in "$t/cert.pem" -name "$LOCAL_ID" \
        -passout pass:semantic -out "$t/id.p12" >/dev/null 2>&1 &&
    security import "$t/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P semantic -T /usr/bin/codesign >/dev/null 2>&1 || ok=1
    rm -rf "$t"
    return $ok
}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}
if [ -z "$IDENTITY" ] && local_identity; then IDENTITY=$LOCAL_ID; fi
if ! codesign --force --sign "${IDENTITY:--}" $APP 2>/dev/null; then
    IDENTITY=
    codesign --force --sign - $APP
fi
note "signed by ${IDENTITY:-ad-hoc (permissions will need re-granting after each rebuild)}"

if [ "$MODE" = "--test" ]; then
    "$APP/Contents/MacOS/Semantic"
    exit $?
fi
[ "$MODE" = "--build-only" ] && exit 0

# ---- 5. install
step "Installing to ~/Applications"
mkdir -p ~/Applications
pkill -x Semantic 2>/dev/null || true
pkill -x SemBar 2>/dev/null || true
rm -rf ~/Applications/SemBar.app ~/Applications/Semantic.app
cp -R $APP ~/Applications/Semantic.app
note "~/Applications/Semantic.app ($(du -sh $APP | cut -f1))"
[ "$MODE" = "--no-run" ] || open ~/Applications/Semantic.app

HOTKEY=$(sed -n 's/.*"hotkey"[^"]*"\([^"]*\)".*/\1/p' ~/.config/semantic/config.json 2>/dev/null | head -1)
echo
echo "${G}${B}✓ Semantic is installed.${N}"
[ "$MODE" = "--no-run" ] && echo "  Open it from ~/Applications." || echo "  It is running in your menu bar and opens at login."
echo "  Press ${B}${HOTKEY:-⌘Y}${N} anywhere and describe what you want."
echo "  Your files are indexed in the background; searches improve over the first few minutes."
echo "  The Permissions window lists optional access (each one says what it adds). You can skip it."
echo "${D}  Update: run the same install command again.  Uninstall: \"$PWD/build.sh\" --uninstall${N}"
