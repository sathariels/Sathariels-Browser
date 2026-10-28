#!/bin/bash
# Sign the release zip with Sparkle's sign_update and write a signed appcast.
# The private key file is the base64 Ed25519 seed produced by generate_keys -x.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="${1:-$ROOT/dist/Sathariels Browser-macos.zip}"
VERSION="${2:?marketing version such as 0.4.0}"
TAG="${3:?release tag such as v0.4.0}"
KEY_FILE="${4:?path to the Sparkle private key file}"
TOOL_DIR="${5:?directory containing sign_update}"
OUT="${6:-$ROOT/dist/appcast.xml}"

SIGN_UPDATE="$TOOL_DIR/sign_update"
if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "sign_update is missing at $SIGN_UPDATE" >&2
  exit 1
fi

META="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ZIP")"
echo "$META"
SIGNATURE="$(printf '%s\n' "$META" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s\n' "$META" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
if [[ -z "$SIGNATURE" || -z "$LENGTH" ]]; then
  echo "sign_update did not return an EdDSA signature" >&2
  exit 1
fi
"$SIGN_UPDATE" --verify --ed-key-file "$KEY_FILE" "$ZIP" "$SIGNATURE" >/dev/null

PUB_DATE="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"
REPO="sathariels/Sathariels-Browser"
ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/Sathariels.Browser-macos.zip"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sathariels Browser</title>
    <link>https://github.com/${REPO}</link>
    <description>Sathariels Browser updates</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      <description>Version ${VERSION}.</description>
      <enclosure url="${ZIP_URL}" sparkle:edSignature="${SIGNATURE}" length="${LENGTH}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

"$SIGN_UPDATE" --ed-key-file "$KEY_FILE" --disable-signing-warning "$OUT"
"$SIGN_UPDATE" --verify --ed-key-file "$KEY_FILE" "$OUT"
echo "Wrote $OUT"
