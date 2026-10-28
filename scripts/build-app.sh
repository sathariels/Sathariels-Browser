#!/bin/bash
# Build a standalone Lumen.app, a zip, and a DMG. Ad-hoc signed so it can
# launch outside Xcode. Run this on a Mac with Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
DERIVED="$ROOT/build/DerivedData"
mkdir -p "$DIST"

echo "Building Lumen (Release)…"
xcodebuild \
  -project "$ROOT/Lumen.xcodeproj" \
  -scheme Lumen \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  DEVELOPMENT_TEAM="" \
  build

APP_SRC="$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name 'Lumen.app' -print -quit)"
if [[ -z "$APP_SRC" ]]; then
  echo "xcodebuild did not produce Lumen.app" >&2
  exit 1
fi

rm -rf "$DIST/Lumen.app"
cp -R "$APP_SRC" "$DIST/Lumen.app"

echo "Ad-hoc signing…"
codesign --force --sign - \
  --entitlements "$ROOT/Lumen/Lumen.entitlements" \
  "$DIST/Lumen.app"
codesign --verify --verbose=2 "$DIST/Lumen.app"

echo "Zipping…"
rm -f "$DIST/Lumen-macos.zip"
ditto -c -k --keepParent "$DIST/Lumen.app" "$DIST/Lumen-macos.zip"

if command -v hdiutil >/dev/null 2>&1; then
  echo "Creating DMG…"
  rm -f "$DIST/Lumen.dmg"
  hdiutil create \
    -volname "Lumen" \
    -srcfolder "$DIST/Lumen.app" \
    -ov \
    -format UDZO \
    "$DIST/Lumen.dmg"
else
  echo "hdiutil is not available; skipped the DMG."
fi

echo
echo "App:  $DIST/Lumen.app"
echo "Zip:  $DIST/Lumen-macos.zip"
if [[ -f "$DIST/Lumen.dmg" ]]; then
  echo "DMG:  $DIST/Lumen.dmg"
fi
echo
echo "Install: drag Lumen.app to /Applications."
echo "First launch: right-click the app, choose Open, then Open again."
echo "Gatekeeper does not trust an ad-hoc signature the way it trusts a Developer ID."
