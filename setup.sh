#!/usr/bin/env bash
# =============================================================================
# setup.sh — single entry point for the SENSING SG4A camera setup on Jetson Orin Nano
#
#   ./setup.sh               run the next step that is needed (step1 -> reboot -> step2 -> step3)
#   ./setup.sh status        overall checklist and progress
#   ./setup.sh step1|step2|step3 [options]   run one step (options are passed through)
#   ./setup.sh test|check-frame|formats|live|stop [options]   camera test commands
#   ./setup.sh persist [inspect|enable-modprobe|enable-service|status|revert]   optional, untested
#   ./setup.sh reset         forget the recorded progress (does not change the system)
#   Add --dry-run to any command to print what would be done.
# =============================================================================
set -u
set -o pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${REPO_DIR}/lib/common.sh"

S1="${SG4A_SCRIPTS_DIR}/step1_before_reboot.sh"
S2="${SG4A_SCRIPTS_DIR}/step2_after_reboot.sh"
S2B="${SG4A_SCRIPTS_DIR}/step2b_persist.sh"
S3="${SG4A_SCRIPTS_DIR}/step3_test_camera.sh"

usage() {
  cat <<EOF
Usage: ./setup.sh [command] [options]

  (no command)     run the next needed step automatically
  status           show the checklist and overall progress
  step1 [opts]     setup before reboot   (install driver, select overlay)
  step2 [opts]     setup after reboot    (load driver with GMSLMODE, clocks, sensor_mode)
  step3 [opts]     camera tests          (formats + capture test + frame check)
  test | check-frame | formats   run one camera test
  live [opts]      live view on the Jetson monitor (over SSH is fine)
  stop             stop the live view
  persist [cmd]    optional: keep GMSLMODE after reboot (untested) - inspect|enable-modprobe|enable-service|status|revert
  reset            forget recorded progress (state file only)

Common options: --dry-run, --pkg DIR, --gmsl A,B,C,D, --mode N, --ports 0,3
Per-step help:  ./setup.sh step1 --help   (or step2 / step3 / persist)
State file:     ${SG4A_STATE_FILE}
EOF
}

# ---------- status helpers ----------
cur_boot() { [ "$(state_field "$1" 4)" = "$SG4A_BOOT_ID" ]; }
script_status() { state_field "$1" 2; }
reboot_pending() { [ "$(state_field step1.reboot 2)" = "REQUIRED" ] && cur_boot step1.reboot; }

count_done() {   # count_done ID N [current-boot-only]
  local id="$1" n="$2" cb="${3:-0}" i st c=0
  for i in $(seq 1 "$n"); do
    st="$(state_field "${id}.${i}" 2)"
    case "$st" in DONE|SKIP|WARN)
      if [ "$cb" -eq 0 ] || cur_boot "${id}.${i}"; then c=$((c + 1)); fi ;;
    esac
  done
  echo "$c"
}

stage_line() {   # stage_line LABEL ID NTOTAL CURRENT_BOOT_ONLY
  local label="$1" id="$2" n="$3" cb="$4" st note when tag
  st="$(script_status "$id")"; note="$(state_field "$id" 5)"; when="$(state_field "$id" 3)"
  if [ "$cb" -eq 1 ] && [ -n "$st" ] && ! cur_boot "$id"; then st="STALE"; fi
  if [ "$id" = step1 ] && [ "$note" = "reboot pending" ] && ! reboot_pending; then note="rebooted since"; fi
  case "$st" in
    DONE)    tag="${C_G}[DONE]${C_0}" ;;
    WARN|PARTIAL) tag="${C_Y}[${st}]${C_0}" ;;
    FAIL)    tag="${C_R}[FAIL]${C_0}" ;;
    RUNNING) tag="${C_Y}[STOPPED]${C_0}" ;;
    STALE)   tag="${C_Y}[REDO]${C_0}"; note="done on a previous boot - run again after every reboot" ;;
    *)       tag="${C_D}[TODO]${C_0}" ;;
  esac
  printf '\n  %s %s%s%s %s%s%s\n' "$tag" "$C_BOLD" "$label" "$C_0" "$C_D" "${when:+($when) }${note}" "$C_0"
}

show_status() {
  local d1 d2 d3 t1=${#STEP1_TITLES[@]} t2=${#STEP2_TITLES[@]} t3=${#STEP3_TITLES[@]} total ndone
  d1="$(count_done step1 "$t1" 0)"; d2="$(count_done step2 "$t2" 1)"; d3="$(count_done step3 "$t3" 1)"
  total=$((t1 + t2 + t3)); ndone=$((d1 + d2 + d3))
  printf '\n%sSG4A camera setup - overall progress%s  %s\n' "$C_BOLD" "$C_0" "$(progress_bar "$ndone" "$total")"
  info "Host: $(hostname)  User: ${SG4A_USER}  Boot: ${SG4A_BOOT_ID:0:8}  Package: $(default_pkg_dir)"

  stage_line "Step 1 - Setup before reboot (one time)" step1 "$t1" 0
  print_checklist step1 "${STEP1_TITLES[@]}"
  if reboot_pending; then
    printf '    %s[ !! ] Reboot required before step 2%s\n' "$C_Y" "$C_0"
  fi
  stage_line "Step 2 - Setup after reboot (every boot)" step2 "$t2" 1
  print_checklist step2 "${STEP2_TITLES[@]}"
  stage_line "Step 3 - Camera tests (every boot)" step3 "$t3" 1
  print_checklist step3 "${STEP3_TITLES[@]}"
  if [ -n "$(script_status live)" ]; then
    stage_line "Live view" live "${#STEP3_LIVE_TITLES[@]}" 1
    print_checklist live "${STEP3_LIVE_TITLES[@]}"
  fi
  printf '\n  Next: %s\n' "$(next_hint)"
}

next_hint() {
  if [ "$(script_status step1)" != "DONE" ]; then echo "./setup.sh   (runs step 1)"
  elif reboot_pending; then echo "sudo reboot, then ./setup.sh"
  elif [ "$(script_status step2)" != "DONE" ] || ! cur_boot step2; then echo "./setup.sh   (runs step 2)"
  elif [ "$(script_status step3)" != "DONE" ] || ! cur_boot step3; then echo "./setup.sh   (runs step 3)"
  else echo "all done for this boot - ./setup.sh live   (live view)"; fi
}

run_next() {
  local args=("$@")
  if [ "$(script_status step1)" != "DONE" ]; then
    printf '%sNext needed: Step 1 (before reboot)%s\n' "$C_BOLD" "$C_0"
    exec bash "$S1" "${args[@]}"
  elif reboot_pending; then
    printf '%sStep 1 is done, but the system has not been rebooted yet.%s\n' "$C_Y" "$C_0"
    if confirm "Reboot now?"; then run $SUDO reboot; else printf 'Run: sudo reboot   then ./setup.sh\n'; fi
    exit 0
  elif [ "$(script_status step2)" != "DONE" ] || ! cur_boot step2; then
    printf '%sNext needed: Step 2 (after reboot)%s\n' "$C_BOLD" "$C_0"
    exec bash "$S2" "${args[@]}"
  elif [ "$(script_status step3)" != "DONE" ] || ! cur_boot step3; then
    printf '%sNext needed: Step 3 (camera tests)%s\n' "$C_BOLD" "$C_0"
    exec bash "$S3" all "${args[@]}"
  else
    show_status
  fi
}

CMD="${1:-next}"
case "$CMD" in
  -h|--help|help) usage ;;
  --*)            run_next "$@" ;;            # e.g. ./setup.sh --dry-run
  next)           shift || true; run_next "$@" ;;
  status)         show_status ;;
  step1)          shift; exec bash "$S1" "$@" ;;
  step2)          shift; exec bash "$S2" "$@" ;;
  step3|test-all) shift; exec bash "$S3" all "$@" ;;
  test|check-frame|formats|live|stop) shift; exec bash "$S3" "$CMD" "$@" ;;
  persist)        shift; exec bash "$S2B" "$@" ;;
  reset)
    if confirm "Forget recorded progress in ${SG4A_STATE_FILE}? (the system is not changed)"; then
      rm -f "$SG4A_STATE_FILE" && ok "Progress reset"
    fi ;;
  *)              usage >&2; printf '\nUnknown command: %s\n' "$CMD" >&2; exit 2 ;;
esac
