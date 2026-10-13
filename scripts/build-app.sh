#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_ARGS=()
case "${1:-}" in
  "") ;;
  --universal) BUILD_ARGS=(--arch arm64 --arch x86_64) ;;
  *) printf 'Usage: %s [--universal]\n' "$0" >&2; exit 2 ;;
esac
swift build -c release "${BUILD_ARGS[@]}"
APP="$PWD/build/NathPaint.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release "${BUILD_ARGS[@]}" --show-bin-path)"
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
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# SwiftPM release binaries retain debug-map entries with absolute source/object paths.
# Remove only debug symbols, before signing, so they cannot leak into release archives.
codesign --remove-signature "$APP/Contents/MacOS/NathPaint"
xcrun strip -S "$APP/Contents/MacOS/NathPaint"
python3 - "$APP/Contents/MacOS/NathPaint" <<'PY'
import sys
from pathlib import Path
binary = Path(sys.argv[1]).read_bytes()
if any(prefix in binary for prefix in (b"/Users/", b"/home/", b"/private/var/", b"/var/folders/")):
    raise SystemExit("Build contains a local user or temporary path; refusing to package it.")
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict --all-architectures "$APP"
printf 'Built: %s\n' "$APP"
