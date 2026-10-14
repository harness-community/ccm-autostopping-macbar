#!/bin/bash
# Builds a release binary and wraps it into a double-clickable CCMAutoStoppingBar.app,
# then zips it for sharing. Run from anywhere; paths are resolved relative to this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CCMAutoStoppingBar"
BUNDLE_ID="io.harness.ccm-autostopping-macbar"
VERSION="${1:-0.0.1}"

OUT_DIR="$ROOT/dist"
APP_DIR="$OUT_DIR/$APP_NAME.app"

echo "==> Building release binary"
cd "$ROOT"
swift build -c release

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT/.build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>CCM AutoStopping</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Internal tool, not for distribution outside Harness.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing (lets it run locally; still shows an 'unidentified developer' prompt on first launch for other users)"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Zipping for distribution"
ZIP_PATH="$OUT_DIR/$APP_NAME-$VERSION-macos-arm64.zip"
rm -f "$ZIP_PATH"
(cd "$OUT_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$(basename "$ZIP_PATH")")

echo
echo "Built: $APP_DIR"
echo "Zipped: $ZIP_PATH"
echo "Share the zip. First launch needs right-click > Open (see README)."
