#!/usr/bin/env bash
# Build "Claude Notch.app" and a shareable zip from the SwiftPM package.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Claude Notch"
DIST="$ROOT/dist"
APPDIR="$DIST/$APP_NAME.app"

echo "▸ Release build…"
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release/ClaudeNotch"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$DIST"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/ClaudeNotch"
cp "$ROOT/Resources/Info.plist" "$APPDIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APPDIR/Contents/Resources/AppIcon.icns"

echo "▸ Ad-hoc code signing…"
codesign --force --deep --options runtime --sign - "$APPDIR" 2>/dev/null \
  || codesign --force --deep --sign - "$APPDIR"

echo "▸ Zipping…"
cp "$ROOT/Resources/README.txt" "$DIST/README.txt"
( cd "$DIST" && zip -r -q -y "$APP_NAME.zip" "$APP_NAME.app" README.txt )

echo "✓ Done:"
echo "   app: $APPDIR"
echo "   zip: $DIST/$APP_NAME.zip"
