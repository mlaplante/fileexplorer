#!/bin/bash
# Assemble FileExplorer.app from the SPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swift build -c release --disable-sandbox -debug-info-format none --product FileExplorer

BIN_PATH="$(swift build -c release --disable-sandbox --show-bin-path)"

APP="build/FileExplorer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/FileExplorer" "$APP/Contents/MacOS/FileExplorer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/FileExplorer.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
