#!/bin/bash
# Build a standalone Sathariels Browser.app, a zip, and a DMG. Ad-hoc signed so it can
# launch outside Xcode. Run this on a Mac with Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Sathariels Browser"
DIST="$ROOT/dist"
# Keep signed intermediates out of iCloud-managed Documents folders.
DERIVED="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/SatharielsBrowser-build}"
mkdir -p "$DIST"

echo "Building ${APP_NAME} (Release)…"
xcodebuild \
  -project "$ROOT/SatharielsBrowser.xcodeproj" \
  -scheme SatharielsBrowser \
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

APP_SRC="$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "${APP_NAME}.app" -print -quit)"
if [[ -z "$APP_SRC" ]]; then
  echo "xcodebuild did not produce ${APP_NAME}.app" >&2
  exit 1
fi

rm -rf "$DIST/${APP_NAME}.app"
cp -R "$APP_SRC" "$DIST/${APP_NAME}.app"

# Finder metadata on copied bundles is rejected by codesign.
xattr -cr "$DIST/${APP_NAME}.app"
echo "Ad-hoc signing…"
codesign --force --sign - \
  --entitlements "$ROOT/Lumen/SatharielsBrowser.entitlements" \
  "$DIST/${APP_NAME}.app"
codesign --verify --verbose=2 "$DIST/${APP_NAME}.app"

echo "Zipping…"
rm -f "$DIST/${APP_NAME}-macos.zip"
ditto -c -k --keepParent "$DIST/${APP_NAME}.app" "$DIST/${APP_NAME}-macos.zip"

if command -v hdiutil >/dev/null 2>&1; then
  echo "Creating DMG…"
  rm -f "$DIST/${APP_NAME}.dmg"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DIST/${APP_NAME}.app" \
    -ov \
    -format UDZO \
    "$DIST/${APP_NAME}.dmg"
else
  echo "hdiutil is not available; skipped the DMG."
fi

echo
echo "App:  $DIST/${APP_NAME}.app"
echo "Zip:  $DIST/${APP_NAME}-macos.zip"
if [[ -f "$DIST/${APP_NAME}.dmg" ]]; then
  echo "DMG:  $DIST/${APP_NAME}.dmg"
fi
echo
echo "Install: drag \"${APP_NAME}.app\" to /Applications."
echo "First launch: right-click the app, choose Open, then Open again."
echo "Gatekeeper does not trust an ad-hoc signature the way it trusts a Developer ID."
