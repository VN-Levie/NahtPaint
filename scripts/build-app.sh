#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_ARGS=(-c release)
case "${1:-}" in
  "") ;;
  --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
  *) printf 'Usage: %s [--universal]\n' "$0" >&2; exit 2 ;;
esac
swift build "${BUILD_ARGS[@]}"
APP="${NAHTPAINT_APP_OUTPUT:-$PWD/build/NahtPaint.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
cp "$BIN_DIR/NahtPaint" "$APP/Contents/MacOS/NahtPaint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -d Resources/NahtPaint.icon ]]; then
  ICON_OUTPUT="$PWD/build/icon-compiled"
  mkdir -p "$ICON_OUTPUT"
  xcrun actool "$PWD/Resources/NahtPaint.icon" --compile "$ICON_OUTPUT" \
    --app-icon NahtPaint --target-device mac --platform macosx \
    --minimum-deployment-target 14.0 --bundle-identifier com.levie.NathPaint \
    --output-partial-info-plist "$ICON_OUTPUT/icon.plist" \
    --output-format human-readable-text --warnings --errors --notices
  cp "$ICON_OUTPUT/Assets.car" "$APP/Contents/Resources/Assets.car"
  cp "$ICON_OUTPUT/NahtPaint.icns" "$APP/Contents/Resources/NahtPaint.icns"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile NahtPaint' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string NahtPaint' "$APP/Contents/Info.plist"
elif [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -f Resources/MenuBarIcon.png ]]; then
  cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
fi
if [[ -d "$BIN_DIR/NahtPaint_PaintCore.bundle" ]]; then
  ditto "$BIN_DIR/NahtPaint_PaintCore.bundle" "$APP/Contents/Resources/NahtPaint_PaintCore.bundle"
fi
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# SwiftPM release binaries retain debug-map entries with absolute source/object paths.
# Remove only debug symbols, before signing, so they cannot leak into release archives.
codesign --remove-signature "$APP/Contents/MacOS/NahtPaint"
xcrun strip -S "$APP/Contents/MacOS/NahtPaint"
python3 - "$APP/Contents/MacOS/NahtPaint" <<'PY'
import sys
from pathlib import Path
binary = Path(sys.argv[1]).read_bytes()
if any(prefix in binary for prefix in (b"/Users/", b"/home/", b"/private/var/", b"/var/folders/")):
    raise SystemExit("Build contains a local user or temporary path; refusing to package it.")
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict --all-architectures "$APP"
printf 'Built: %s\n' "$APP"
