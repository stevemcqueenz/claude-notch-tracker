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
rm -rf "$DIST"; mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/ClaudeNotch"
cp "$ROOT/Resources/Info.plist" "$APPDIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APPDIR/Contents/Resources/AppIcon.icns"

echo "▸ Signing as: $SIGN_ID"
# No --deep (Quinn: "considered harmful"): the bundle has no nested code, just the
# main executable, so signing the bundle is sufficient and correct.
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$APPDIR"
else
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
ditto -c -k --sequesterRsrc --keepParent "$APPDIR" "$DIST/$APP_NAME.zip"

echo "✓ Done:"
echo "   app: $APPDIR"
echo "   zip: $DIST/$APP_NAME.zip"
[ -n "$NOTARY_PROFILE" ] && echo "   (signed + notarized)" || echo "   (signed: $SIGN_ID)"
