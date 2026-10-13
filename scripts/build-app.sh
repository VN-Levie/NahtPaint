#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/NathPaint.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/NathPaint" "$APP/Contents/MacOS/NathPaint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -f Resources/MenuBarIcon.png ]]; then
  cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
fi
if [[ -d "$BIN_DIR/NathPaint_PaintCore.bundle" ]]; then
  ditto "$BIN_DIR/NathPaint_PaintCore.bundle" "$APP/Contents/Resources/NathPaint_PaintCore.bundle"
fi
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
