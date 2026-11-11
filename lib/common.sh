#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — shared helpers for the SG4A camera setup scripts
#   * colored output, progress bar (%), per-step checklist
#   * persistent state (survives reboot) so setup.sh / status know what is done
#   * --dry-run helpers, confirmation prompts, package-path detection, LFS check
# Source it from a script:  . "$(dirname "$0")/../lib/common.sh"
# =============================================================================
# shellcheck disable=SC2034   # variables are used by the scripts that source this file

[ -n "${SG4A_COMMON_LOADED:-}" ] && return 0
SG4A_COMMON_LOADED=1

# ---------- constants ----------
SG4A_PKG_NAME="SG4A_NONX_G2Y_A1_ORIN_NANO_YUV_JP6.2_L4TR36.4.3"
SG4A_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG4A_REPO_DIR="$(cd "${SG4A_LIB_DIR}/.." && pwd)"
SG4A_SCRIPTS_DIR="${SG4A_REPO_DIR}/scripts"

# Step titles: single source of truth for progress, checklist and `setup.sh status`
STEP1_TITLES=(
  "Check L4T / kernel version"
  "Check driver package"
  "Install driver (install.sh)"
  "Verify files in /boot"
  "Select camera overlay (extlinux.conf)"
  "Reboot decision"
)
STEP2_TITLES=(
  "Check overlay is active"
  "Load max96712.ko"
  "Reload sgx-yuv-gmsl2.ko with GMSLMODE"
  "Check camera detection in dmesg"
  "Configure clocks (clock_config.sh)"
  "Set sensor_mode on detected ports"
)
STEP3_TITLES=(
  "Detect camera ports"
  "List driver resolutions"
  "Capture test (fps / uncorr_err)"
  "Frame check (Y/UV) + save JPEG"
)
STEP3_LIVE_TITLES=(
  "Detect camera ports"
  "Find local display"
  "Start live view"
  "Verify live view"
)
SG4A_SCRIPT_IDS=(step1 step2 step3)

# ---------- user / paths ----------
SG4A_USER="${SUDO_USER:-$(id -un)}"
SG4A_HOME="$(getent passwd "$SG4A_USER" | cut -d: -f6)"
SG4A_HOME="${SG4A_HOME:-$HOME}"
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
SG4A_STATE_DIR="${SG4A_STATE_DIR:-${SG4A_HOME}/.local/state/sg4a}"
SG4A_STATE_FILE="${SG4A_STATE_DIR}/state"
SG4A_BOOT_ID="${SG4A_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)}"

# Default package dir: repo driver/ folder first, then ~/<package>
default_pkg_dir() {
  if [ -d "${SG4A_REPO_DIR}/driver/${SG4A_PKG_NAME}" ]; then
    echo "${SG4A_REPO_DIR}/driver/${SG4A_PKG_NAME}"
  else
    echo "${SG4A_HOME}/${SG4A_PKG_NAME}"
  fi
}

DRY_RUN="${DRY_RUN:-0}"

# ---------- output ----------
if [ -t 1 ]; then
  C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_BOLD=$'\e[1m'; C_0=$'\e[0m'
else
  C_G=""; C_R=""; C_Y=""; C_B=""; C_D=""; C_BOLD=""; C_0=""
fi
ok()    { printf '  %s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '  %s[WARN]%s %s\n' "$C_Y" "$C_0" "$*"; }
info()  { printf '         %s\n' "$*"; }
fail()  { printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; }

# ---------- state file ----------
# line format: key|status|timestamp|boot_id|note      (key: step1.3, step1, step1.reboot)
state_get() {   # state_get KEY -> prints the line (empty if none)
  [ -r "$SG4A_STATE_FILE" ] || return 0
  awk -F'|' -v k="$1" '$1==k { l=$0 } END { if (l!="") print l }' "$SG4A_STATE_FILE"
}
state_field() { state_get "$1" | cut -d'|' -f"$2"; }   # 2=status 3=time 4=boot 5=note
state_set() {   # state_set KEY STATUS [NOTE]
  [ "$DRY_RUN" -eq 1 ] && return 0
  local key="$1" status="$2" note="${3:-}" tmp
  note="${note//|//}"; note="${note//$'\n'/ }"
  mkdir -p "$SG4A_STATE_DIR" 2>/dev/null || return 0
  tmp="$(mktemp "${SG4A_STATE_DIR}/.state.XXXXXX")" || return 0
  { [ -r "$SG4A_STATE_FILE" ] && awk -F'|' -v k="$key" '$1!=k' "$SG4A_STATE_FILE"
    printf '%s|%s|%s|%s|%s\n' "$key" "$status" "$(date '+%Y-%m-%d %H:%M:%S')" "$SG4A_BOOT_ID" "$note"
  } > "$tmp"
  mv -f "$tmp" "$SG4A_STATE_FILE"
  # when run as root on behalf of a user (sudo / systemd), keep files owned by that user
  if [ "$(id -u)" -eq 0 ]; then
    local owner="${SG4A_STATE_OWNER:-${SUDO_USER:-}}"
    [ -n "$owner" ] && chown -R "$owner" "$SG4A_STATE_DIR" 2>/dev/null
  fi
  return 0
}
state_clear_prefix() {  # remove all keys of one script (e.g. step2.)
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ -w "$SG4A_STATE_FILE" ] || return 0
  local tmp; tmp="$(mktemp "${SG4A_STATE_DIR}/.state.XXXXXX")" || return 0
  awk -F'|' -v p="$1" 'index($1, p)!=1' "$SG4A_STATE_FILE" > "$tmp"; mv -f "$tmp" "$SG4A_STATE_FILE"
}

# ---------- progress / steps ----------
SG_ID=""; SG_TITLE=""; SG_TITLES=(); SG_TOTAL=0; SG_CUR=0; SG_DONE=0
sg_init() {   # sg_init ID "Script title" title1 title2 ...
  SG_ID="$1"; SG_TITLE="$2"; shift 2
  SG_TITLES=("$@"); SG_TOTAL=${#SG_TITLES[@]}; SG_CUR=0; SG_DONE=0
  printf '\n%s%s%s\n' "$C_BOLD" "$SG_TITLE" "$C_0"
  [ "$DRY_RUN" -eq 1 ] && printf '%s*** DRY RUN: commands that change the system are printed, not executed; state is not recorded ***%s\n' "$C_Y" "$C_0"
  state_clear_prefix "${SG_ID}."
  state_set "$SG_ID" "RUNNING" "started"
  return 0
}
progress_bar() {   # progress_bar DONE TOTAL -> "[#########-----------]  45%"
  local d="$1" t="$2" w=20 pct fill
  [ "$t" -gt 0 ] || t=1
  pct=$(( d * 100 / t )); fill=$(( d * w / t ))
  printf '[%s%s] %3d%%' "$(printf '%*s' "$fill" '' | tr ' ' '#')" "$(printf '%*s' $((w - fill)) '' | tr ' ' '-')" "$pct"
}
step_begin() {   # step_begin N
  SG_CUR="$1"
  printf '\n%s%s  Step %d/%d: %s%s\n' "$C_B" "$(progress_bar "$SG_DONE" "$SG_TOTAL")" "$SG_CUR" "$SG_TOTAL" "${SG_TITLES[$((SG_CUR - 1))]}" "$C_0"
}
_step_end() {   # _step_end STATUS COLOR NOTE
  SG_DONE=$((SG_DONE + 1))
  state_set "${SG_ID}.${SG_CUR}" "$1" "${3:-}"
  printf '  %s%-6s%s Step %d/%d %s  %s\n' "$2" "$1" "$C_0" "$SG_CUR" "$SG_TOTAL" "$(progress_bar "$SG_DONE" "$SG_TOTAL")" "${3:-}"
}
step_done() { _step_end DONE "$C_G" "${1:-}"; }
step_skip() { _step_end SKIP "$C_G" "${1:-already done}"; }   # already done earlier -> counts as complete
step_warn() { _step_end WARN "$C_Y" "${1:-}"; }               # finished, but needs attention

# print the checklist of one script from the state file
# usage: print_checklist ID TITLES...
print_checklist() {
  local id="$1"; shift
  local titles=("$@") i st tm bt nt mark line done=0 total
  total=${#titles[@]}
  for i in $(seq 1 "$total"); do
    line="$(state_get "${id}.${i}")"
    st="$(cut -d'|' -f2 <<<"$line")"; tm="$(cut -d'|' -f3 <<<"$line")"
    bt="$(cut -d'|' -f4 <<<"$line")"; nt="$(cut -d'|' -f5 <<<"$line")"
    case "$st" in
      DONE) mark="${C_G}[DONE]${C_0}"; done=$((done + 1)) ;;
      SKIP) mark="${C_G}[SKIP]${C_0}"; done=$((done + 1)) ;;
      WARN) mark="${C_Y}[WARN]${C_0}"; done=$((done + 1)) ;;
      FAIL) mark="${C_R}[FAIL]${C_0}" ;;
      *)    mark="${C_D}[ -- ]${C_0}" ;;
    esac
    local prev=""; [ -n "$bt" ] && [ "$bt" != "$SG4A_BOOT_ID" ] && prev=" (previous boot)"
    printf '    %s %d. %-42s %s%s%s%s%s\n' "$mark" "$i" "${titles[$((i - 1))]}" "$C_D" "$tm" "$prev" "${nt:+  - $nt}" "$C_0"
  done
  printf '    %s\n' "$(progress_bar "$done" "$total")"
}

# finish the script: record overall status and show checklist
sg_finish() {   # sg_finish [STATUS] [NOTE]
  local st="${1:-DONE}" note="${2:-}"
  state_set "$SG_ID" "$st" "$note"
  printf '\n%sChecklist: %s%s\n' "$C_BOLD" "$SG_TITLE" "$C_0"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "(dry run: state not recorded)"
  else
    print_checklist "$SG_ID" "${SG_TITLES[@]}"
  fi
}

# fail the current step, show checklist, exit
die() {
  fail "$1"
  [ $# -gt 1 ] && printf '  %sFix:%s %s\n' "$C_Y" "$C_0" "$2" >&2
  if [ -n "$SG_ID" ] && [ "$SG_CUR" -gt 0 ]; then
    state_set "${SG_ID}.${SG_CUR}" FAIL "$1"
    sg_finish FAIL "step ${SG_CUR}: $1"
  fi
  printf '\n%sStopped.%s Fix the problem above and run the script again (it is safe to re-run).\n' "$C_R" "$C_0" >&2
  exit 1
}
# precondition failed: stop for real, but continue in --dry-run so the remaining commands can be shown
check_fail() {
  if [ "$DRY_RUN" -eq 1 ]; then fail "$1"; info "(dry run: a real run would stop here; continuing to show commands)"; return 0; fi
  die "$@"
}

# ---------- command execution ----------
run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '  %s[dry-run]%s %s\n' "$C_D" "$C_0" "$(printf '%q ' "$@")"; return 0; fi
  "$@"
}
run_in() {   # run_in DIR cmd...
  local dir="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then printf '  %s[dry-run]%s cd %q && %s\n' "$C_D" "$C_0" "$dir" "$(printf '%q ' "$@")"; return 0; fi
  ( cd "$dir" && "$@" )
}
write_root() {   # write_root FILE CONTENT
  if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] write %s:\n' "$1"; printf '%s\n' "$2" | sed 's/^/            | /'; return 0; fi
  printf '%s\n' "$2" | $SUDO tee "$1" >/dev/null
}
confirm() {   # confirm "question" -> 0 if yes. No terminal = "no".
  local ans=""
  if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] would ask: %s -> assuming "y"\n' "$1"; return 0; fi
  if [ ! -r /dev/tty ] || ! { : </dev/tty; } 2>/dev/null; then warn "No terminal to answer, treating as \"no\": $1"; return 1; fi
  printf '  %s?%s %s [y/N]: ' "$C_Y" "$C_0" "$1"
  read -r ans </dev/tty || ans=""
  case "$ans" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# ---------- checks ----------
# Git LFS pointer files instead of real binaries -> driver was cloned without git-lfs
lfs_pointer_files() {   # prints pointer files found under DIR
  [ -d "$1" ] || return 0
  find "$1" -type f -size -300c -exec grep -l '^version https://git-lfs.github.com/spec/v1' {} + 2>/dev/null
}
check_pkg_lfs() {   # check_pkg_lfs DIR -> dies if LFS pointers are present
  local ptr; ptr="$(lfs_pointer_files "$1" | head -n 5)"
  [ -z "$ptr" ] && return 0
  fail "The driver package contains Git LFS pointer files, not the real binaries:"
  printf '%s\n' "$ptr" | sed 's/^/         /' >&2
  check_fail "Driver binaries were not downloaded by Git LFS" \
    "sudo apt install git-lfs && git lfs install && git lfs pull   (run inside the repo)"
}

# dmesg helpers (dmesg needs root on Ubuntu)
dmesg_all() { $SUDO dmesg 2>/dev/null; }
# lines after the last sgx_yuv_gmsl2 load (from the last ###GMSLMODE### line)
dmesg_last_load_from() { printf '%s\n' "$1" | awk '/GMSLMODE=/ { buf="" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
detected_ports_from() {
  dmesg_last_load_from "$1" | grep -E 'port [0-9]+ camera.*been detected' | grep -oE 'port [0-9]+' \
    | awk '{print $2}' | sort -un | tr '\n' ' ' | sed 's/ $//'
}
uncorr_count() { dmesg_all | grep -c 'uncorr_err' || true; }

# sensor_mode -> "W H"
mode_res() {
  case "$1" in 0) echo "1920 1080" ;; 1) echo "1920 1536" ;; 2) echo "2880 1860" ;;
               3) echo "3840 2160" ;; 4) echo "1280 720" ;; *) echo "" ;; esac
}
