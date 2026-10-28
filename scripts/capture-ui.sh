#!/bin/bash
# Launch a Release build on a Mac with a window server and save two screenshots.
# Usage: scripts/capture-ui.sh [path/to/Sathariels Browser.app] [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/DerivedData/Build/Products/Release/Sathariels Browser.app}"
OUT="${2:-$ROOT/dist/screenshots}"
mkdir -p "$OUT"

if [[ ! -d "$APP" ]]; then
  echo "App not found: $APP" >&2
  exit 1
fi

quit_app() {
  killall "Sathariels Browser" >/dev/null 2>&1 || true
  sleep 0.4
}

WINDOW_BIN="$OUT/window-id"
cat > "$OUT/window-id.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in info {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    guard owner.contains("Sathariels"), layer == 0 else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    guard width > 400, height > 300 else { continue }
    if let id = window[kCGWindowNumber as String] as? Int {
        print(id)
        exit(0)
    }
}
exit(1)
SWIFT
swiftc -O -o "$WINDOW_BIN" "$OUT/window-id.swift"

window_id() {
  "$WINDOW_BIN"
}

capture_window() {
  local dest="$1"
  local id=""
  id="$(window_id)" || id=""
  if [[ -n "$id" ]]; then
    echo "Capturing window $id -> $dest"
    screencapture -x -o -l "$id" "$dest" || true
  fi
  local bytes=0
  if [[ -f "$dest" ]]; then
    bytes="$(stat -f%z "$dest")"
  fi
  if [[ "$bytes" -lt 10000 ]]; then
    echo "Window capture was $bytes bytes; capturing the whole display."
    screencapture -x "$dest"
    bytes="$(stat -f%z "$dest")"
  fi
  echo "Wrote $dest ($bytes bytes)"
  [[ "$bytes" -gt 10000 ]]
}

container_ready() {
  local home="${HOME}/Library/Containers/com.sathariels.browser/Data/Library/Application Support/screenshot-ready"
  [[ -f "$home" ]]
}

launch_and_capture() {
  local name="$1"
  local settle="$2"
  shift 2
  local ready="$OUT/$name.ready"
  rm -f "$ready" "$OUT/$name.png"
  rm -f "${HOME}/Library/Containers/com.sathariels.browser/Data/Library/Application Support/screenshot-ready" || true
  quit_app
  echo "Launching for $name"
  open -n "$APP" --args --screenshot-ready "$ready" "$@"
  local appeared=""
  for _ in $(seq 1 40); do
    if [[ -f "$ready" ]] || container_ready || window_id >/dev/null 2>&1; then
      appeared=1
      break
    fi
    sleep 0.5
  done
  if [[ -z "$appeared" ]]; then
    echo "App window did not appear for $name" >&2
    ps aux | grep -i "[S]athariel" || true
    ls -lt "${HOME}/Library/Logs/DiagnosticReports" 2>/dev/null | head -20 || true
    log show --last 2m --style compact --predicate 'process CONTAINS "Sathariel"' 2>/dev/null | tail -80 || true
    exit 1
  fi
  echo "Window is up; waiting ${settle}s for $name"
  sleep "$settle"
  capture_window "$OUT/$name.png"
  quit_app
}

launch_and_capture "screenshot_new_tab" 2
launch_and_capture "screenshot_address_bar" 8 --screenshot-url "https://example.com" --focus-address
echo "Screenshots are in $OUT"
