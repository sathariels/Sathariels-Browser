#!/bin/bash
# Install the cask from a local tap, launch it, then install a higher version
# of the same zip to simulate brew upgrade. Uninstall --zap must leave the
# app container in place.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK="$ROOT/Casks/sathariels-browser.rb"
TAP_NAME="sathariels/sathariels-browser"
APP="/Applications/Sathariels Browser.app"
CONTAINER="${HOME}/Library/Containers/com.sathariels.browser"
MARKER="$CONTAINER/Data/Library/Cookies/homebrew-zap-keep.txt"

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_ASK=1

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is not installed" >&2
  exit 1
fi

TAP_DIR="$(mktemp -d)"
UPGRADE_DIR="$(mktemp -d)"
cleanup() {
  brew uninstall --zap --cask sathariels-browser >/dev/null 2>&1 || true
  brew untap "$TAP_NAME" >/dev/null 2>&1 || true
  rm -rf "$TAP_DIR" "$UPGRADE_DIR"
  killall "Sathariels Browser" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$TAP_DIR/Casks" "$UPGRADE_DIR/Casks"
cp "$CASK" "$TAP_DIR/Casks/sathariels-browser.rb"
git -C "$TAP_DIR" init -q
git -C "$TAP_DIR" add Casks
git -C "$TAP_DIR" -c user.email="ci@example.com" -c user.name="ci" commit -q -m "tap"
# Same artifact, higher cask version, so brew upgrade has something to install.
sed 's/version "0.6.0"/version "0.6.1"/; s|download/v#{version}/|download/v0.6.0/|' \
  "$CASK" > "$UPGRADE_DIR/Casks/sathariels-browser.rb"
grep -q 'version "0.6.1"' "$UPGRADE_DIR/Casks/sathariels-browser.rb"
grep -q 'download/v0.6.0/' "$UPGRADE_DIR/Casks/sathariels-browser.rb"

brew untap "$TAP_NAME" >/dev/null 2>&1 || true
brew tap "$TAP_NAME" "$TAP_DIR"
brew install --cask --no-quarantine "${TAP_NAME}/sathariels-browser"
test -d "$APP"
IDENT="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
test "$IDENT" = "com.sathariels.browser"
test "$VERSION" = "0.6.0"
xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1 && echo "quarantine still set" >&2 && exit 1 || true

open -n "$APP"
for _ in $(seq 1 40); do
  pgrep -x "Sathariels Browser" >/dev/null && break
  sleep 0.25
done
pgrep -x "Sathariels Browser" >/dev/null
killall "Sathariels Browser" >/dev/null 2>&1 || true

# Swap the tap contents to the higher version and upgrade in place.
TAP_PATH="$(brew --repo "$TAP_NAME")"
mkdir -p "$TAP_PATH/Casks"
cp "$UPGRADE_DIR/Casks/sathariels-browser.rb" "$TAP_PATH/Casks/sathariels-browser.rb"
brew upgrade --cask --no-quarantine sathariels-browser
test -d "$APP"
test "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = "com.sathariels.browser"

mkdir -p "$(dirname "$MARKER")"
echo keep > "$MARKER"
brew uninstall --zap --cask sathariels-browser
test -f "$MARKER"
echo "Homebrew install, launch, and upgrade succeeded. Bundle id stayed com.sathariels.browser."
