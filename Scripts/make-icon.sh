#!/bin/bash
# Regenerate Resources/FileExplorer.icns from the IconGen target.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product IconGen
BIN_PATH="$(swift build -c release --show-bin-path)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$BIN_PATH/IconGen" "$TMP/icon_1024.png"

ICONSET="$TMP/FileExplorer.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$TMP/icon_1024.png" \
        --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$TMP/icon_1024.png" \
        --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/FileExplorer.icns
echo "Wrote Resources/FileExplorer.icns"
