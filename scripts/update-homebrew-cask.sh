#!/bin/bash
# Point Casks/sathariels-browser.rb at the zip just published, then push that
# change to main. HOMEBREW_TAP_TOKEN is a PAT with contents:write on this
# repository. GITHUB_TOKEN is used when the secret is unset.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-${RELEASE_TAG:-}}"
ZIP="${2:-$ROOT/dist/Sathariels Browser-macos.zip}"
if [[ -z "$TAG" || ! -f "$ZIP" ]]; then
  echo "usage: RELEASE_TAG=v0.6.0 $0 [tag] [zip]" >&2
  exit 1
fi

VERSION="${TAG#v}"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
TOKEN="${HOMEBREW_TAP_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "${HOMEBREW_TAP_TOKEN:-}" ]]; then
  echo "HOMEBREW_TAP_TOKEN is not set. Using GITHUB_TOKEN."
  echo "If the push to main is rejected, add a repository secret named HOMEBREW_TAP_TOKEN."
  echo "It needs Contents read and write on ${GITHUB_REPOSITORY:-sathariels/Sathariels-Browser}."
fi
if [[ -z "$TOKEN" ]]; then
  echo "No token available to update the Homebrew cask." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

BASIC="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
HEADER="AUTHORIZATION: basic ${BASIC}"
git -c "http.https://github.com/.extraheader=${HEADER}" \
  clone --depth 1 --branch main \
  "https://github.com/${GITHUB_REPOSITORY}.git" "$WORKDIR"

python3 - "$WORKDIR/Casks/sathariels-browser.rb" "$VERSION" "$SHA" <<'PY'
import pathlib, re, sys
path, version, sha = sys.argv[1:]
file = pathlib.Path(path)
text = file.read_text()
text2, n1 = re.subn(r'version "[^"]+"', f'version "{version}"', text, count=1)
text3, n2 = re.subn(r'sha256 "[^"]+"', f'sha256 "{sha}"', text2, count=1)
if n1 != 1 or n2 != 1:
    raise SystemExit("cask is missing version or sha256")
file.write_text(text3)
PY

if git -C "$WORKDIR" diff --quiet; then
  echo "Homebrew cask already matches ${VERSION} ${SHA}"
  exit 0
fi

git -C "$WORKDIR" config user.email "github-actions[bot]@users.noreply.github.com"
git -C "$WORKDIR" config user.name "github-actions[bot]"
git -C "$WORKDIR" add Casks/sathariels-browser.rb
git -C "$WORKDIR" commit -m "Bump Homebrew cask to ${VERSION}"
git -C "$WORKDIR" -c "http.https://github.com/.extraheader=${HEADER}" push origin HEAD:main
echo "Pushed Homebrew cask ${VERSION} ${SHA}"
