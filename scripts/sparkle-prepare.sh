#!/bin/bash
# Turn the SPARKLE_PRIVATE_KEY secret into SUPublicEDKey and a key file for sign_update.
# The secret is the one-line base64 seed written by Sparkle's `generate_keys -x`.
set -euo pipefail

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_PRIVATE_KEY is not set. The updater stays dormant and this release will not be signed."
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "SPARKLE_SIGNING=0" >> "$GITHUB_ENV"
  fi
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SPARKLE_WORK_DIR:-${TMPDIR:-/tmp}/sathariels-sparkle}"
mkdir -p "$WORK"
chmod 700 "$WORK"
KEY_FILE="$WORK/sparkle-private-key.txt"
umask 077
printf '%s\n' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

BYTES="$(python3 - "$KEY_FILE" <<'PY'
import base64, sys
raw = base64.b64decode(open(sys.argv[1], encoding="utf-8").read().strip(), validate=True)
if len(raw) not in (32, 96):
    raise SystemExit(f"decoded length {len(raw)} is not a Sparkle Ed25519 seed")
print(len(raw))
PY
)"
echo "Sparkle private key decoded length: $BYTES"

if [[ ! -x "$WORK/bin/sign_update" ]]; then
  curl -fsSL -o "$WORK/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz"
  tar -xJf "$WORK/Sparkle.tar.xz" -C "$WORK"
fi
TOOL_DIR="$(find "$WORK" -type f -name sign_update -exec dirname {} \; | head -n 1)"
if [[ -z "$TOOL_DIR" || ! -x "$TOOL_DIR/generate_keys" || ! -x "$TOOL_DIR/sign_update" ]]; then
  echo "Sparkle 2.10.1 tools were not found after extracting the archive." >&2
  exit 1
fi

derive_with_python() {
  python3 -m pip install --quiet --user --disable-pip-version-check pynacl >&2 \
    || python3 -m pip install --quiet --user --break-system-packages --disable-pip-version-check pynacl >&2
  PYTHONPATH="$(python3 -m site --user-site)" python3 - "$KEY_FILE" <<'PY'
import base64, sys
from nacl.signing import SigningKey
seed = base64.b64decode(open(sys.argv[1], encoding="utf-8").read().strip())
if len(seed) != 32:
    raise SystemExit("The older 96-byte Sparkle export needs generate_keys, not this derivation.")
print(base64.b64encode(SigningKey(seed).verify_key.encode()).decode())
PY
}

derive_with_generate_keys() {
  local keychain="$WORK/sparkle.keychain-db"
  local password
  password="$(uuidgen)"
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 600 "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  security list-keychains -d user -s "$keychain"
  security default-keychain -s "$keychain"
  "$TOOL_DIR/generate_keys" -f "$KEY_FILE" >/dev/null
  "$TOOL_DIR/generate_keys" -p
}

PUB=""
if [[ "$BYTES" == "32" ]]; then
  PUB="$(derive_with_python)"
  echo "Derived SUPublicEDKey from the Sparkle seed."
else
  echo "Importing the legacy Sparkle key with generate_keys."
  PUB="$(derive_with_generate_keys)"
fi

if [[ -z "$PUB" ]]; then
  echo "Could not derive SUPublicEDKey." >&2
  exit 1
fi
echo "SUPublicEDKey length: ${#PUB}"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "SPARKLE_SIGNING=1"
    printf 'SU_PUBLIC_ED_KEY=%s\n' "$PUB"
    printf 'SPARKLE_KEY_FILE=%s\n' "$KEY_FILE"
    printf 'SPARKLE_BIN=%s\n' "$TOOL_DIR"
  } >> "$GITHUB_ENV"
else
  printf 'SU_PUBLIC_ED_KEY=%s\n' "$PUB"
  printf 'SPARKLE_KEY_FILE=%s\n' "$KEY_FILE"
  printf 'SPARKLE_BIN=%s\n' "$TOOL_DIR"
fi
