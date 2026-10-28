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

resign_sparkle() {
  local app="$1"
  local framework="${app}/Contents/Frameworks/Sparkle.framework"
  local version="${framework}/Versions/B"
  if [[ ! -d "${version}/XPCServices/Installer.xpc" ]]; then
    echo "Sparkle Installer.xpc is missing from ${framework}" >&2
    exit 1
  fi
  codesign --force --sign - -o runtime "${version}/XPCServices/Installer.xpc"
  if [[ -d "${version}/XPCServices/Downloader.xpc" ]]; then
    if ! codesign --force --sign - -o runtime --preserve-metadata=entitlements "${version}/XPCServices/Downloader.xpc"; then
      codesign --force --sign - -o runtime "${version}/XPCServices/Downloader.xpc"
    fi
  fi
  if [[ -e "${version}/Autoupdate" ]]; then
    codesign --force --sign - -o runtime "${version}/Autoupdate"
  fi
  if [[ -d "${version}/Updater.app" ]]; then
    codesign --force --sign - -o runtime "${version}/Updater.app"
  fi
  codesign --force --sign - -o runtime "$framework"
}

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
  SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-}" \
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
resign_sparkle "$DIST/${APP_NAME}.app"
codesign --force --sign - \
  --entitlements "$ROOT/Lumen/SatharielsBrowser.entitlements" \
  "$DIST/${APP_NAME}.app"
codesign --verify --verbose=2 "$DIST/${APP_NAME}.app"

echo "Zipping…"
rm -f "$DIST/${APP_NAME}-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST/${APP_NAME}.app" "$DIST/${APP_NAME}-macos.zip"

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
