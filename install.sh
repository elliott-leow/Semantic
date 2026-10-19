#!/bin/bash
# Installs or updates Semantic:
#   curl -fsSL https://raw.githubusercontent.com/elliott-leow/Semantic/main/install.sh | bash
# Fetches the source into ~/Library/Application Support/Semantic/source (keeping the llama.cpp build
# and models from a previous install, so updates take seconds) and runs build.sh, which checks the
# Mac, installs anything missing and launches the app. Run from a checkout, it just builds that.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/build.sh" ] && [ -f "$here/Info.plist" ]; then
    exec "$here/build.sh" "$@"
fi

REPO=${SEMANTIC_REPO:-elliott-leow/Semantic}
REF=${SEMANTIC_REF:-main}
SRC="$HOME/Library/Application Support/Semantic/source"
if [ "${1:-}" = --uninstall ] && [ -f "$SRC/build.sh" ]; then
    exec "$SRC/build.sh" "$@"
fi
echo "Downloading Semantic ($REPO@$REF)…"
mkdir -p "$(dirname "$SRC")"
rm -rf "$SRC.new"
mkdir "$SRC.new"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz --strip-components 1 -C "$SRC.new" || {
    echo "Could not download Semantic from GitHub. Check your internet connection and try again." >&2
    exit 1
}
# a fresh tree (so files deleted upstream go away), with the expensive parts carried over
for keep in vendor build; do
    [ -d "$SRC/$keep" ] && mv "$SRC/$keep" "$SRC.new/$keep"
done
rm -rf "$SRC"
mv "$SRC.new" "$SRC"
exec "$SRC/build.sh" "$@"
