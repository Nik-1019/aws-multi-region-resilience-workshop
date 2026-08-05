#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# heartbeat.sh -- poll the workshop app once a second and show which region is
# answering. Leave this running on the projector while you break things.
#
#   ./scripts/heartbeat.sh <url>
#   ./scripts/heartbeat.sh https://d1234abcd.cloudfront.net
#
# Environment overrides:
#   INTERVAL  seconds between requests (default 1)
#   TIMEOUT   per-request timeout in seconds (default 3)
# ---------------------------------------------------------------------------
set -euo pipefail

INTERVAL="${INTERVAL:-1}"
TIMEOUT="${TIMEOUT:-3}"

usage() {
  cat <<'EOF'
Usage: ./heartbeat.sh <cloudfront-url>

Polls <url>/api/status every second and prints the serving region, latency and
database state. Press Ctrl+C for a session summary.

Examples:
  ./scripts/heartbeat.sh https://d111111abcdef8.cloudfront.net
  ./scripts/heartbeat.sh http://my-alb-123456.us-east-1.elb.amazonaws.com
  INTERVAL=0.5 ./scripts/heartbeat.sh https://example.com
EOF
}

if [ $# -ne 1 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "heartbeat: curl is required" >&2; exit 1; }

# Normalise the URL: accept bare hostnames, drop any trailing slash.
URL="$1"
case "$URL" in
  http://*|https://*) ;;
  *) URL="http://$URL" ;;
esac
URL="${URL%/}"
STATUS_URL="$URL/api/status"

# --- colours ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[36m'; MAGENTA=$'\033[35m'; BOLD=$'\033[1m'
  DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; BOLD=""; DIM=""; RESET=""
fi

BOX_W=59   # printable characters between the two vertical borders

# --- portable millisecond clock -------------------------------------------
# GNU date supports %N; BSD date does not. Fall back through python3/perl and
# finally to whole seconds so the script still runs on a bare box.
_probe="$(date +%s%N 2>/dev/null || true)"
case "$_probe" in
  ''|*N*) if command -v python3 >/dev/null 2>&1; then TIME_MODE=python
          elif command -v perl >/dev/null 2>&1; then TIME_MODE=perl
          else TIME_MODE=seconds; fi ;;
  *)      TIME_MODE=date ;;
esac

now_ms() {
  case "$TIME_MODE" in
    date)   echo $(( $(date +%s%N) / 1000000 )) ;;
    python) python3 -c 'import time; print(int(time.time()*1000))' ;;
    perl)   perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' ;;
    *)      echo $(( $(date +%s) * 1000 )) ;;
  esac
}

# --- JSON field extraction -------------------------------------------------
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

json_get() {
  # json_get <json> <key>  -> string value, or empty
  if [ "$HAVE_JQ" -eq 1 ]; then
    printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null || true
  else
    printf '%s' "$1" \
      | tr ',' '\n' \
      | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -n 1 \
      | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/' || true
  fi
}

# --- session state ---------------------------------------------------------
TOTAL=0
OK_COUNT=0
FAIL_COUNT=0
FAILOVERS=0
RECOVERY_LIST=""          # space-separated seconds, e.g. "2.1 0.9"
CURRENT_REGION=""
LAST_GOOD_MS=""
OUTAGE_START_MS=""
SESSION_START_MS="$(now_ms)"

pad() { printf "%-${2}s" "$1"; }

# Built by concatenation, not `tr`: tr operates on bytes and would shred the
# multibyte box-drawing characters into mojibake.
box_line() {
  local ch="$1" out="" i=0
  while [ "$i" -lt "$BOX_W" ]; do
    out="${out}${ch}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

print_header() {
  printf "%s╔%s╗%s\n" "$BOLD" "$(box_line '═')" "$RESET"
  printf "%s║%s║%s\n" "$BOLD" "$(pad "  HEARTBEAT MONITOR - Press Ctrl+C to stop" $BOX_W)" "$RESET"
  printf "%s║%s║%s\n" "$BOLD" "$(pad "  $(printf '%.55s' "$URL")" $BOX_W)" "$RESET"
  printf "%s╠%s╣%s\n" "$BOLD" "$(box_line '═')" "$RESET"
}

print_footer() {
  printf "%s╚%s╝%s\n" "$BOLD" "$(box_line '═')" "$RESET"
}

print_row() {
  # print_row <timestamp> <colour> <mark> <code> <region-colour> <region> <latency> <db>
  local ts="$1" colour="$2" mark="$3" code="$4" rcolour="$5"
  local region="$6" latency="$7" db="$8"
  printf "║ [%s] %s%s %s%s │ %s%s%s │ %s │ DB: %s ║\n" \
    "$ts" \
    "$colour" "$mark" "$(pad "$code" 3)" "$RESET" \
    "$rcolour" "$(pad "$region" 10)" "$RESET" \
    "$(printf '%6s' "$latency")" \
    "$(pad "$db" 12)"
}

print_failover() {
  # print_failover <from> <to> <recovery-seconds>
  local banner=">>> FAILOVER DETECTED - Recovery time: ${3}s <<<"
  local detail="    ${1:-?} -> ${2}"
  printf "%s%s║%s║%s\n" "$BOLD" "$YELLOW" \
    "$(pad "$(printf '%.57s' "  $banner")" $BOX_W)" "$RESET"
  printf "%s%s║%s║%s\n" "$YELLOW" "$DIM" \
    "$(pad "$(printf '%.57s' "$detail")" $BOX_W)" "$RESET"
}

seconds_between() {
  # seconds_between <start_ms> <end_ms> -> "2.1"
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000 }'
}

# --- summary ---------------------------------------------------------------
summary() {
  local end_ms duration rate fastest average
  end_ms="$(now_ms)"
  duration="$(seconds_between "$SESSION_START_MS" "$end_ms")"

  if [ "$TOTAL" -gt 0 ]; then
    rate="$(awk -v ok="$OK_COUNT" -v t="$TOTAL" 'BEGIN { printf "%.1f", ok*100/t }')"
  else
    rate="0.0"
  fi

  if [ -n "$RECOVERY_LIST" ]; then
    fastest="$(printf '%s\n' $RECOVERY_LIST | sort -n | head -n 1)"
    average="$(printf '%s ' $RECOVERY_LIST \
      | awk '{ s=0; for (i=1; i<=NF; i++) s+=$i; printf "%.1f", s/NF }')"
  else
    fastest="n/a"
    average="n/a"
  fi

  print_footer
  printf "\n%s  SESSION SUMMARY%s\n" "$BOLD" "$RESET"
  printf "  %-22s %s\n" "Duration"          "${duration}s"
  printf "  %-22s %s\n" "Total requests"    "$TOTAL"
  printf "  %-22s %s%s%%%s (%s ok / %s failed)\n" "Success rate" \
         "$GREEN" "$rate" "$RESET" "$OK_COUNT" "$FAIL_COUNT"
  printf "  %-22s %s%s%s\n" "Failovers detected" "$MAGENTA" "$FAILOVERS" "$RESET"
  printf "  %-22s %s\n" "Fastest recovery"  "${fastest}$([ "$fastest" = "n/a" ] || echo 's')"
  printf "  %-22s %s\n" "Average recovery"  "${average}$([ "$average" = "n/a" ] || echo 's')"
  printf "  %-22s %s\n" "Last region seen"  "${CURRENT_REGION:-none}"
  printf "\n"
}

on_exit() {
  trap - INT TERM EXIT
  printf "\n"
  summary
  exit 0
}
trap on_exit INT TERM

# --- main loop -------------------------------------------------------------
print_header

while true; do
  loop_start_ms="$(now_ms)"
  stamp="$(date +%H:%M:%S)"
  TOTAL=$((TOTAL + 1))

  # Body, then http_code and time_total on their own trailing lines.
  raw="$(curl -sS -m "$TIMEOUT" -H 'Accept: application/json' \
           -w '\n%{http_code}\n%{time_total}' "$STATUS_URL" 2>/dev/null || true)"

  code=""
  elapsed=""
  body=""
  if [ -n "$raw" ]; then
    code="$(printf '%s\n' "$raw" | tail -n 2 | head -n 1)"
    elapsed="$(printf '%s\n' "$raw" | tail -n 1)"
    body="$(printf '%s\n' "$raw" | sed '$d' | sed '$d')"
  fi

  case "$code" in
    ''|*[!0-9]*) code="000" ;;
  esac

  if [ "$code" = "200" ]; then
    region="$(json_get "$body" region)"
    db="$(json_get "$body" db)"
    [ -n "$region" ] || region="unknown"
    case "$db" in
      connected)    db_label="Connected" ;;
      disconnected) db_label="Disconnected" ;;
      *)            db_label="unknown" ;;
    esac

    latency_ms="$(awk -v t="${elapsed:-0}" 'BEGIN { printf "%d", t*1000 }')"
    latency_label="${latency_ms}ms"

    OK_COUNT=$((OK_COUNT + 1))
    row_colour="$GREEN"
    region_colour=""
    [ "$db_label" = "Disconnected" ] && row_colour="$YELLOW" || true

    # A region we have not seen before (and not the first sample) is a failover.
    if [ -n "$CURRENT_REGION" ] && [ "$region" != "$CURRENT_REGION" ]; then
      reference_ms="${OUTAGE_START_MS:-${LAST_GOOD_MS:-$loop_start_ms}}"
      recovery="$(seconds_between "$reference_ms" "$(now_ms)")"
      FAILOVERS=$((FAILOVERS + 1))
      RECOVERY_LIST="$RECOVERY_LIST $recovery"
      print_failover "$CURRENT_REGION" "$region" "$recovery"
      region_colour="$BLUE"
    fi

    print_row "$stamp" "$row_colour" "✓" "$code" "$region_colour" \
              "$region" "$latency_label" "$db_label"

    CURRENT_REGION="$region"
    LAST_GOOD_MS="$(now_ms)"
    OUTAGE_START_MS=""
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [ -n "$OUTAGE_START_MS" ] || OUTAGE_START_MS="$loop_start_ms"

    if [ "$code" = "000" ]; then
      label="TIMEOUT"
      shown_code="---"
    else
      label="ERROR"
      shown_code="$code"
    fi

    print_row "$stamp" "$RED" "✗" "$shown_code" "$RED" "$label" "---" "---"
  fi

  # Keep a steady cadence regardless of how long the request took.
  remaining="$(awk -v start="$loop_start_ms" -v now="$(now_ms)" -v iv="$INTERVAL" \
    'BEGIN { r = iv - (now - start)/1000; printf "%.2f", (r > 0 ? r : 0) }')"
  case "$remaining" in
    0.00) ;;
    *) sleep "$remaining" ;;
  esac
done
