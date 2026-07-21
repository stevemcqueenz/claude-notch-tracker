#!/usr/bin/env bash
# Build "Claude Notch.app" and a shareable zip from the SwiftPM package.
#
#   bash scripts/make-app.sh
#
# Signing:
#   • Auto-uses a "Developer ID Application" identity if one is in your keychain,
#     otherwise falls back to ad-hoc ("-"). Override with SIGN_ID="…".
# Notarizing (removes the "unverified developer" warning for other users):
#   • Set up once:  xcrun notarytool store-credentials "claude-notch-notary" \
#                       --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
#   • Then:  NOTARY_PROFILE=claude-notch-notary bash scripts/make-app.sh
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Claude Notch"
DIST="$ROOT/dist"
APPDIR="$DIST/$APP_NAME.app"

# Pick a signing identity.
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  [ -z "$SIGN_ID" ] && SIGN_ID="-"
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "▸ Release build…"
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release/ClaudeNotch"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$DIST"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$APPDIR/Contents/Frameworks"
cp "$BIN" "$APPDIR/Contents/MacOS/ClaudeNotch"
cp "$ROOT/Resources/Info.plist" "$APPDIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APPDIR/Contents/Resources/AppIcon.icns"

# Preserve SwiftPM's resource bundle inside the conventional app resources directory.
RESOURCE_BUNDLE="$(find "$ROOT/.build" -path "*/release/ClaudeNotch_ClaudeNotch.bundle" -type d 2>/dev/null | head -1)"
[ -d "$RESOURCE_BUNDLE" ] || { echo "✗ ClaudeNotch resource bundle not found"; exit 1; }
ditto "$RESOURCE_BUNDLE" "$APPDIR/Contents/Resources/ClaudeNotch_ClaudeNotch.bundle"

# Embed Sparkle.framework (SwiftPM builds it as an xcframework) + let the binary find it.
SPARKLE_FW="$(find "$ROOT/.build/artifacts" -path "*macos-arm64_x86_64/Sparkle.framework" -type d 2>/dev/null | head -1)"
[ -d "$SPARKLE_FW" ] || { echo "✗ Sparkle.framework not found — run 'swift build' first"; exit 1; }
ditto "$SPARKLE_FW" "$APPDIR/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APPDIR/Contents/MacOS/ClaudeNotch" 2>/dev/null || true

echo "▸ Signing as: $SIGN_ID"
FW="$APPDIR/Contents/Frameworks/Sparkle.framework"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$FW"
  codesign --force --sign - "$APPDIR"
else
  # Sign Sparkle inside-out (no --deep), then the app last.
  codesign -f -o runtime --timestamp -s "$SIGN_ID" "$FW/Versions/B/XPCServices/Installer.xpc"
  codesign -f -o runtime --timestamp -s "$SIGN_ID" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  codesign -f -o runtime --timestamp -s "$SIGN_ID" "$FW/Versions/B/Autoupdate"
  codesign -f -o runtime --timestamp -s "$SIGN_ID" "$FW/Versions/B/Updater.app"
  codesign -f -o runtime --timestamp -s "$SIGN_ID" "$FW"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APPDIR"
  codesign --verify --strict --verbose=2 "$APPDIR"
fi

if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_ID" != "-" ]; then
  echo "▸ Notarizing (this uploads to Apple and waits)…"
  ditto -c -k --sequesterRsrc --keepParent "$APPDIR" "$DIST/notary.zip"
  xcrun notarytool submit "$DIST/notary.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▸ Stapling ticket…"
  xcrun stapler staple "$APPDIR"
  rm -f "$DIST/notary.zip"
  xcrun stapler validate "$APPDIR" && echo "  ✓ stapled + valid"
fi

echo "▸ Zipping (ditto, signature-safe)…"
ditto -c -k --sequesterRsrc --keepParent "$APPDIR" "$DIST/ClaudeNotch.zip"

echo "✓ Done:"
echo "   app: $APPDIR"
echo "   zip: $DIST/$APP_NAME.zip"
[ -n "$NOTARY_PROFILE" ] && echo "   (signed + notarized)" || echo "   (signed: $SIGN_ID)"
