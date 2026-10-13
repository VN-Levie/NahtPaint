#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/NathPaint.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/NathPaint" "$APP/Contents/MacOS/NathPaint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -d Resources/NathPaint.icon ]]; then
  ICON_OUTPUT="$PWD/build/icon-compiled"
  mkdir -p "$ICON_OUTPUT"
  xcrun actool "$PWD/Resources/NathPaint.icon" --compile "$ICON_OUTPUT" \
    --app-icon NathPaint --target-device mac --platform macosx \
    --minimum-deployment-target 14.0 --bundle-identifier com.levie.NathPaint \
    --output-partial-info-plist "$ICON_OUTPUT/icon.plist" \
    --output-format human-readable-text --warnings --errors --notices
  cp "$ICON_OUTPUT/Assets.car" "$APP/Contents/Resources/Assets.car"
  cp "$ICON_OUTPUT/NathPaint.icns" "$APP/Contents/Resources/NathPaint.icns"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile NathPaint' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string NathPaint' "$APP/Contents/Info.plist"
elif [[ -f Resources/AppIcon.icns ]]; then
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
