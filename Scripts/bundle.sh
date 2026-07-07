#!/bin/bash
# Assemble FileExplorer.app from the SPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

APP="build/FileExplorer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/FileExplorer" "$APP/Contents/MacOS/FileExplorer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
