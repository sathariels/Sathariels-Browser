#!/bin/bash
# First launch, second launch, and a 10-tab launch. RSS is kilobytes from ps.
set +e
APP="${1:-dist/Sathariels Browser.app}"
cleanup() { killall "Sathariels Browser" >/dev/null 2>&1 || true; }
trap cleanup EXIT

sample_once() {
  local label="$1"
  local extra="$2"
  local settle="$3"
  cleanup
  sleep 0.4
  local before
  before="$(mktemp)"
  pgrep -f "com.apple.WebKit" | sort > "$before" || true
  echo "RAM_BEGIN $label"
  if [ -n "$extra" ]; then
    # shellcheck disable=SC2086
    open -n "$APP" --args $extra
  else
    open -n "$APP"
  fi
  local root=""
  for _ in $(seq 1 40); do
    root="$(pgrep -x "Sathariels Browser" | head -n 1)"
    if [ -n "$root" ]; then
      break
    fi
    sleep 0.25
  done
  sleep "$settle"
  root="$(pgrep -x "Sathariels Browser" | head -n 1)"
  echo "RAM_ROOT $label ${root:-missing}"
  if [ -z "$root" ]; then
    echo "RAM_APP_MB $label missing"
    rm -f "$before"
    return
  fi
  local seen=" $root "
  local queue="$root"
  local app_sum=0
  while [ -n "$queue" ]; do
    local next=""
    for pid in $queue; do
      local rss comm
      rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
      comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
      if [ -n "$rss" ]; then
        echo "pid=$pid rss_kb=$rss comm=$comm"
        app_sum=$((app_sum + rss))
      fi
      local kids
      kids="$(pgrep -P "$pid" || true)"
      for kid in $kids; do
        case "$seen" in
          *" $kid "*) ;;
          *) seen="$seen$kid "; next="$next $kid" ;;
        esac
      done
    done
    queue="$next"
  done
  local web_sum=0
  local after
  after="$(mktemp)"
  pgrep -f "com.apple.WebKit" | sort > "$after" || true
  local new_pids
  new_pids="$(comm -13 "$before" "$after" || true)"
  for pid in $new_pids; do
    local rss comm
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
    if [ -n "$rss" ]; then
      echo "webkit_pid=$pid rss_kb=$rss comm=$comm"
      web_sum=$((web_sum + rss))
    fi
  done
  echo "RAM_APP_KB $label $app_sum"
  echo "RAM_APP_MB $label $((app_sum / 1024))"
  echo "RAM_WEBKIT_KB $label $web_sum"
  echo "RAM_WEBKIT_MB $label $((web_sum / 1024))"
  echo "RAM_TOTAL_MB $label $(((app_sum + web_sum) / 1024))"
  rm -f "$before" "$after"
  cleanup
}

sample_once first "" 4
sample_once second "" 4
sample_once ten "--memory-tabs 10" 10
exit 0
