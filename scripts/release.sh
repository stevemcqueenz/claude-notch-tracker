#!/usr/bin/env bash
# Build, sign, notarize and upload a release from a clean, pushed main — in one go.
#
#   bash scripts/release.sh "One-line release notes"
#
# Run it in your own Terminal: codesign, notarytool and sign_update need your login Keychain
# (approve its prompts). The version comes from Resources/Info.plist. It ends by printing the
# Sparkle signature line; the appcast entry is published only after the upload is checked, so
# no installed copy is ever offered a zip that isn't there yet.
set -euo pipefail

NOTES="${1:?usage: bash scripts/release.sh \"release notes\"}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-notch-notary}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
ZIP="$ROOT/dist/ClaudeNotch.zip"
APP="$ROOT/dist/Claude Notch.app"

# Release only what is on GitHub: the tag must point at exactly this commit.
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "✗ not on main"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "✗ uncommitted changes"; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "✗ main differs from origin/main — pull or push first"; exit 1; }
grep -q "static let version = \"$VERSION\"" Sources/ClaudeNotch/UI/AvatarStyle.swift \
  || { echo "✗ AppInfo.version doesn't match Info.plist ($VERSION)"; exit 1; }
command -v gh >/dev/null || { echo "✗ gh not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh isn't logged in (gh auth login)"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then echo "✗ release $TAG already exists"; exit 1; fi

echo "▸ $TAG: build, Developer ID sign, notarize…"
NOTARY_PROFILE="$NOTARY_PROFILE" bash scripts/make-app.sh

# make-app.sh refuses ad-hoc signing without ALLOW_ADHOC; check anyway before shipping.
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "✗ not signed with a Developer ID"; exit 1; }
xcrun stapler validate "$APP" >/dev/null || { echo "✗ notarization ticket missing"; exit 1; }

SIGN_UPDATE="$(find .build/artifacts -name sign_update -type f | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "✗ sign_update not found (run swift build once)"; exit 1; }
echo "▸ Sparkle signature…"
SPARKLE="$("$SIGN_UPDATE" "$ZIP")"

echo "▸ Uploading $TAG…"
gh release create "$TAG" "$ZIP" --title "$VERSION" --notes "$NOTES" --target main

echo
echo "✓ $TAG is up. Paste this line back for the appcast:"
echo "$SPARKLE"
