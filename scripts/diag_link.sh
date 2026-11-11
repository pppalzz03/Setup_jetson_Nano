#!/usr/bin/env bash
# =============================================================================
# diag_link.sh — find out WHICH action makes the GMSL camera link disappear
#
# Background: on this hardware the cameras were detected (link value 0xc8) after a full power
# cycle, and later - after some use - every port showed "detect error" (link 0x00). Reloading the
# drivers or rebooting only the Jetson did not bring the link back; powering off the Jetson AND
# the SG4A board did. This script runs the usual actions one after another and, after each one,
# reloads the camera driver (./setup.sh step2 --force-reload) and records what the driver sees.
# The first action after which the cameras vanish is the suspect.
#
# Run it right after a full power cycle and a passing ./setup.sh step2. It stops at the first loss.
#
# Usage: scripts/diag_link.sh [--rounds N] [--live-secs SEC] [--ports 2,3] [--dry-run]
# Actions per round: test -> live (SEC seconds, closed by the script) -> check-frame
# =============================================================================
set -u
set -o pipefail
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

ROUNDS=1
LIVE_SECS=10
PORTS_OPT=""
S2="${SG4A_SCRIPTS_DIR}/step2_after_reboot.sh"
S3="${SG4A_SCRIPTS_DIR}/step3_test_camera.sh"

usage() {
  cat <<EOT
Usage: $0 [options]

  --rounds N        repeat the whole sequence N times (default: ${ROUNDS})
  --live-secs SEC   how long the live view runs in each round (default: ${LIVE_SECS})
  --ports 2,3       ports to use for the camera tests (default: auto-detect)
  --dry-run         print what would be run
  -h, --help        show this help

Run it right after a full power cycle and a passing ./setup.sh step2.
EOT
}
bad_arg() { usage >&2; printf '\nInvalid argument: %s\n' "$1" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds)    [ $# -ge 2 ] || bad_arg "$1"; ROUNDS="$2"; shift 2 ;;
    --live-secs) [ $# -ge 2 ] || bad_arg "$1"; LIVE_SECS="$2"; shift 2 ;;
    --ports)     [ $# -ge 2 ] || bad_arg "$1"; PORTS_OPT="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           bad_arg "$1" ;;
  esac
done
{ [[ "$ROUNDS" =~ ^[0-9]+$ ]] && [ "$ROUNDS" -gt 0 ]; } || bad_arg "--rounds $ROUNDS"
{ [[ "$LIVE_SECS" =~ ^[0-9]+$ ]] && [ "$LIVE_SECS" -ge 5 ]; } || bad_arg "--live-secs $LIVE_SECS (at least 5)"
[ -z "$PORTS_OPT" ] || [[ "$PORTS_OPT" =~ ^[0-9]+(,[0-9]+)*$ ]] || bad_arg "--ports $PORTS_OPT"
PORT_ARGS=(); [ -z "$PORTS_OPT" ] || PORT_ARGS=(--ports "$PORTS_OPT")

ROWS=()
# one action, then reload + check what the driver sees; returns 1 if the cameras are gone
check_after() {   # check_after LABEL
  local label="$1" ports links
  if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] bash %s --force-reload   (after: %s)\n' "$S2" "$label"; return 0; fi
  bash "$S2" --force-reload >/tmp/sg4a_diag_step2.log 2>&1
  local dm; dm="$(dmesg_all)"
  ports="$(detected_ports_from "$dm")"; links="$(link_values_from "$dm")"
  if [ -n "$ports" ]; then
    ok "after ${label}: cameras detected on port(s) ${ports}   [${links}]"
    ROWS+=("${label}|OK|${ports}|${links}"); return 0
  fi
  fail "after ${label}: NO camera detected   [${links:-no link values}]"
  ROWS+=("${label}|LOST|-|${links}"); return 1
}

print_table() {
  local r a b c d
  printf '\n%sResult%s\n' "$C_BOLD" "$C_0"
  printf '  %-28s %-6s %-10s %s\n' "after action" "state" "ports" "link values"
  for r in "${ROWS[@]}"; do IFS='|' read -r a b c d <<<"$r"; printf '  %-28s %-6s %-10s %s\n' "$a" "$b" "$c" "$d"; done
}

if [ "$DRY_RUN" -eq 0 ] && ! step2_ok_this_boot; then
  die "Step 2 has not passed in this boot" "Run ./setup.sh step2 first (right after a full power cycle)"
fi
if [ "$DRY_RUN" -eq 0 ]; then
  info "Baseline: step 2 passed in this boot; recording the link values before any action"
  dm="$(dmesg_all)"; base_ports="$(detected_ports_from "$dm")"
  [ -n "$base_ports" ] || die "No cameras detected right now" "Power off the Jetson and the SG4A board for 10 s, power on, ./setup.sh step2, then run this script"
  ROWS+=("(baseline)|OK|${base_ports}|$(link_values_from "$dm")")
fi

lost=""
for round in $(seq 1 "$ROUNDS"); do
  printf '\n%s== Round %s/%s ==%s\n' "$C_BOLD" "$round" "$ROUNDS" "$C_0"
  # 1. capture test
  info "Action: capture test"
  run bash "$S3" test "${PORT_ARGS[@]}" >/tmp/sg4a_diag_test.log 2>&1 || warn "capture test reported a failure (log: /tmp/sg4a_diag_test.log)"
  check_after "test (round ${round})" || { lost="test (round ${round})"; break; }
  # 2. live view for LIVE_SECS, then Ctrl+C-equivalent (a SIGTERM makes the script close its windows)
  info "Action: live view for ${LIVE_SECS} s, then closed (SIGTERM; the script closes its windows)"
  if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] bash %s live %s  (stopped after %s s with SIGTERM)\n' "$S3" "${PORT_ARGS[*]:-}" "$((LIVE_SECS + 10))"
  else
    bash "$S3" live "${PORT_ARGS[@]}" >/tmp/sg4a_diag_live.log 2>&1 </dev/null &
    lp=$!; sleep "$((LIVE_SECS + 10))"; kill -TERM "$lp" 2>/dev/null; sleep 2; pkill -x gst-launch-1.0 2>/dev/null; wait "$lp" 2>/dev/null
    sleep 2
  fi
  check_after "live ${LIVE_SECS}s (round ${round})" || { lost="live (round ${round})"; break; }
  # 3. frame check
  info "Action: frame check"
  run bash "$S3" check-frame "${PORT_ARGS[@]}" >/tmp/sg4a_diag_frame.log 2>&1 || warn "frame check reported a failure (log: /tmp/sg4a_diag_frame.log)"
  check_after "check-frame (round ${round})" || { lost="check-frame (round ${round})"; break; }
done

[ "$DRY_RUN" -eq 1 ] && { printf '\nDry run finished.\n'; exit 0; }
print_table
if [ -n "$lost" ]; then
  printf '\n%sThe cameras disappeared after: %s%s\n' "$C_R" "$lost" "$C_0"
  printf 'Logs: /tmp/sg4a_diag_test.log /tmp/sg4a_diag_live.log /tmp/sg4a_diag_frame.log /tmp/sg4a_diag_step2.log\n'
  printf 'Send the table above and: sudo dmesg | tail -n 120\n'
  printf 'To recover: power off the Jetson AND the SG4A board for 10 s, power on, ./setup.sh step2\n'
  exit 1
fi
printf '\n%sNo loss in %s round(s).%s The link was stable during these actions.\n' "$C_G" "$ROUNDS" "$C_0"
