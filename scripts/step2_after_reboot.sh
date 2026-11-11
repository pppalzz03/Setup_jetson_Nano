#!/usr/bin/env bash
# =============================================================================
# step2_after_reboot.sh — run after EVERY reboot (until step2b_persist.sh is used)
#
#   1. Check the overlay is active (/dev/media0, MAX96712 0x6b node on i2c-9)
#   2. Load max96712.ko if needed
#   3. Unload sgx_yuv_gmsl2 and reload with GMSLMODE_1=2,2,2,2 (skipped if already correct)
#      If rmmod is blocked, show users of /dev/video* (fuser -v) and stop. Never uses -f.
#   4. Check dmesg: ###GMSLMODE=...### and "been detected!" ports (auto-detected),
#      and diagnose known problems (i2c-w write failed / detect error everywhere)
#   5. Run clock_config.sh
#   6. Set bypass_mode=0,sensor_mode=N on every detected port
#
# Usage: scripts/step2_after_reboot.sh [--pkg DIR] [--gmsl A,B,C,D] [--mode N]
#                                      [--ports 0,3] [--force-reload] [--wait SEC] [--dry-run]
# =============================================================================
set -u
set -o pipefail
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

readonly SYS_I2C="${SG4A_SYS_I2C:-/sys/bus/i2c/devices}"
readonly I2C_NODE="${SYS_I2C}/9-006b"
readonly MOD_DER="max96712"
readonly MOD_CAM="sgx_yuv_gmsl2"
readonly KO_CAM="sgx-yuv-gmsl2.ko"
readonly KO_DER="max96712.ko"

FORCE_RELOAD=0
RELOAD_DER=0
GMSL="2,2,2,2"
MODE=1
PORTS_OPT=""
WAIT_SEC=20
PKG="$(default_pkg_dir)"

usage() {
  cat <<EOF
Usage: $0 [options]

After-reboot setup: load the camera driver with the right GMSLMODE, set clocks and sensor mode.

Options:
  --pkg DIR         driver package folder (default: ${PKG})
  --gmsl A,B,C,D    GMSLMODE per port: 0=GMSL, 1=GMSL2/6G, 2=GMSL2/3G (default: ${GMSL})
  --mode N          sensor_mode 0=1920x1080 1=1920x1536 2=2880x1860 3=3840x2160 4=1280x720 (default: ${MODE})
  --ports 0,3       use these ports (default: auto-detect from dmesg "been detected!")
  --force-reload    reload sgx_yuv_gmsl2 even if GMSLMODE is already correct
  --reload-der      also unload/reload max96712.ko (use if its boot-time probe failed; off by default)
  --wait SEC        max seconds to wait for camera detection after insmod (default: ${WAIT_SEC})
  --dry-run         print commands that change the system, do not run them
  -h, --help        show this help
EOF
}
bad_arg() { usage >&2; printf '\nInvalid argument: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg)          [ $# -ge 2 ] || bad_arg "$1"; PKG="$2"; shift 2 ;;
    --pkg=*)        PKG="${1#*=}"; shift ;;
    --gmsl)         [ $# -ge 2 ] || bad_arg "$1"; GMSL="$2"; shift 2 ;;
    --gmsl=*)       GMSL="${1#*=}"; shift ;;
    --mode)         [ $# -ge 2 ] || bad_arg "$1"; MODE="$2"; shift 2 ;;
    --mode=*)       MODE="${1#*=}"; shift ;;
    --ports)        [ $# -ge 2 ] || bad_arg "$1"; PORTS_OPT="$2"; shift 2 ;;
    --ports=*)      PORTS_OPT="${1#*=}"; shift ;;
    --wait)         [ $# -ge 2 ] || bad_arg "$1"; WAIT_SEC="$2"; shift 2 ;;
    --force-reload) FORCE_RELOAD=1; shift ;;
    --reload-der)   RELOAD_DER=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              bad_arg "$1" ;;
  esac
done
PKG="${PKG%/}"
GMSL="${GMSL// /}"
[[ "$GMSL" =~ ^[0-2],[0-2],[0-2],[0-2]$ ]] || bad_arg "--gmsl '$GMSL' (need four values 0-2, e.g. 2,2,2,2)"
[[ "$MODE" =~ ^[0-4]$ ]] || bad_arg "--mode '$MODE' (0-4)"
[[ "$WAIT_SEC" =~ ^[0-9]+$ ]] || bad_arg "--wait '$WAIT_SEC'"
[ -z "$PORTS_OPT" ] || [[ "$PORTS_OPT" =~ ^[0-3](,[0-3])*$ ]] || bad_arg "--ports '$PORTS_OPT' (e.g. 0,3)"

DM=""
refresh_dmesg() { DM="$(dmesg_all)"; }
gmslmode_count() { printf '%s\n' "$DM" | grep -c 'GMSLMODE=' || true; }
last_gmslmode() { printf '%s\n' "$DM" | grep -o '###GMSLMODE=[^#]*###' | tail -n1 | sed 's/###GMSLMODE=//; s/###//; s/[[:space:]]//g'; }

sg_init step2 "STEP 2/3 - Setup after reboot (GMSLMODE_1=${GMSL}, sensor_mode=${MODE})" "${STEP2_TITLES[@]}"

# =============================================================================
step_begin 1
[ -d "$PKG" ] || check_fail "Driver package folder not found: $PKG" "Pass --pkg DIR (see driver/README.md)"
check_pkg_lfs "$PKG"
for f in "ko/$KO_CAM" "ko/$KO_DER" clock_config.sh; do
  [ -e "$PKG/$f" ] || check_fail "Missing $PKG/$f" "Check the package, or run step 1 first"
done
if [ -e /dev/media0 ]; then ok "/dev/media0 exists"
else check_fail "/dev/media0 missing - camera overlay is not active" \
  "Run ./setup.sh step1 until it passes, then reboot (check DEFAULT JetsonIO in /boot/extlinux/extlinux.conf)"; fi
if [ -e "$I2C_NODE" ]; then ok "MAX96712 node (0x6b) on i2c-9: $I2C_NODE"
else check_fail "$I2C_NODE missing - overlay did not create the MAX96712 node on i2c-9" \
  "Make sure the system booted LABEL JetsonIO with overlay \"Jetson Sensing YUV GMSLx4\""; fi
# Does the MAX96712 answer on i2c-9 at 0x6b right now? (read-only i2cdetect -r)
#   UU = a driver is bound   6b = chip answers, no driver bound   -- = no answer
I2C_ACK="unknown"
if command -v i2cdetect >/dev/null 2>&1; then
  ROW60="$($SUDO i2cdetect -y -r 9 2>/dev/null | grep '^60:' || true)"
  if [ -n "$ROW60" ]; then
    info "i2cdetect -y -r 9 (row 0x60): $ROW60"
    case "$(awk '{print $13}' <<<"$ROW60")" in
      UU) I2C_ACK="bound" ;;
      6b) I2C_ACK="free" ;;
      --) I2C_ACK="none" ;;
    esac
  fi
fi
case "$I2C_ACK" in
  bound) ok "MAX96712 answers at 0x6b and a driver is bound (UU)" ;;
  free)  ok "MAX96712 answers at 0x6b (no driver bound yet) - the hardware path on i2c-9 is alive" ;;
  none)  warn "Nothing answers at 0x6b on i2c-9 (shows --)" ;;
  *)     info "Could not read i2c-9 (i2cdetect missing?)" ;;
esac
refresh_dmesg
LAST_ADAPT="$(printf '%s\n' "$DM" | grep -E 'i2c-w, write failed|can.t find DER adapt broad|adapt broad success' | tail -n1 || true)"
case "$LAST_ADAPT" in
  *"adapt broad success"*) ok "MAX96712 init OK in dmesg: $(printf '%s' "$LAST_ADAPT" | sed 's/^\[[^]]*\] *//')" ;;
  *"write failed"*|*"adapt broad"*)
    if [ "$I2C_ACK" = none ]; then
      check_fail "MAX96712 does not answer at 0x6b on i2c-9 and dmesg shows \"i2c-w, write failed\"" \
        "Check: MIPI cable on the 22-pin CAM1 connector, 12V power to the SG4A board, then power-cycle and boot again"
    else
      warn "dmesg has an OLD \"i2c-w, write failed\" / \"can't find DER adapt broad\" line, but the chip answers now"
      info "Likely the driver probed at boot before the board was ready. Continuing: the modules are reloaded below"
      info "and dmesg is checked again only for messages produced AFTER the reload."
    fi ;;
  *) info "No 'adapt broad' message in dmesg yet (driver may not be loaded)" ;;
esac
step_done "overlay active"

# =============================================================================
step_begin 2
if lsmod | awk '{print $1}' | grep -qx "$MOD_DER" && [ "$RELOAD_DER" -eq 1 ]; then
  shopt -s nullglob; VD=(/dev/video*); shopt -u nullglob
  if [ ${#VD[@]} -gt 0 ] && command -v fuser >/dev/null 2>&1 && $SUDO fuser -s "${VD[@]}" 2>/dev/null; then
    fail "Programs are using /dev/video*, modules cannot be unloaded:"
    $SUDO fuser -v "${VD[@]}" 2>&1 | sed 's/^/         /'
    die "Not unloading while cameras are in use (rmmod -f is never used)" "Run ./setup.sh stop (or close the programs above) and try again"
  fi
  if lsmod | awk '{print $1}' | grep -qx "$MOD_CAM"; then
    run $SUDO rmmod "$MOD_CAM" || die "rmmod ${MOD_CAM} failed (-f is never used)" "Close programs using the cameras, then try again"
    ok "Unloaded ${MOD_CAM} (it depends on ${MOD_DER})"
  fi
  run $SUDO rmmod "$MOD_DER" || die "rmmod ${MOD_DER} failed (-f is never used)" "Check: lsmod | grep -E '${MOD_DER}|${MOD_CAM}'"
  run $SUDO insmod "$PKG/ko/$KO_DER" || die "insmod ${KO_DER} failed" "See: sudo dmesg | tail -n 30"
  step_done "${MOD_DER} reloaded"
elif lsmod | awk '{print $1}' | grep -qx "$MOD_DER"; then
  step_skip "${MOD_DER} already loaded"
else
  run $SUDO insmod "$PKG/ko/$KO_DER" || die "insmod ${KO_DER} failed" "See: sudo dmesg | tail -n 30"
  step_done "${KO_DER} loaded"
fi

# =============================================================================
step_begin 3
CAM_LOADED=0
lsmod | awk '{print $1}' | grep -qx "$MOD_CAM" && CAM_LOADED=1
CUR_MODE=""
if [ -r "/sys/module/${MOD_CAM}/parameters/GMSLMODE_1" ]; then
  CUR_MODE="$(tr -d ' \n' < "/sys/module/${MOD_CAM}/parameters/GMSLMODE_1")"
elif [ "$CAM_LOADED" -eq 1 ]; then
  CUR_MODE="$(last_gmslmode)"
fi
CUR_PORTS="$(detected_ports_from "$DM")"

if [ "$CAM_LOADED" -eq 1 ] && [ "$CUR_MODE" = "$GMSL" ] && [ -n "$CUR_PORTS" ] && [ "$FORCE_RELOAD" -eq 0 ]; then
  ok "${MOD_CAM} already loaded with GMSLMODE=${CUR_MODE}, cameras on port(s) ${CUR_PORTS} (use --force-reload to reload)"
  step_skip "GMSLMODE already ${GMSL}"
else
  if [ "$CAM_LOADED" -eq 1 ]; then
    info "Current GMSLMODE=${CUR_MODE:-unknown} -> reloading with ${GMSL}"
    shopt -s nullglob; VDEVS=(/dev/video*); shopt -u nullglob
    show_users() { [ ${#VDEVS[@]} -gt 0 ] && command -v fuser >/dev/null 2>&1 && $SUDO fuser -v "${VDEVS[@]}" 2>&1 | sed 's/^/         /'; }
    if [ ${#VDEVS[@]} -gt 0 ] && command -v fuser >/dev/null 2>&1 && $SUDO fuser -s "${VDEVS[@]}" 2>/dev/null; then
      fail "Programs are using /dev/video*, the module cannot be unloaded:"
      show_users
      die "Not unloading while cameras are in use (rmmod -f is never used)" \
          "Close the programs above (e.g. ./setup.sh stop  or  pkill gst-launch-1.0) and run again"
    fi
    if ! run $SUDO rmmod "$MOD_CAM"; then
      show_users
      die "rmmod ${MOD_CAM} failed (rmmod -f is never used)" "Close programs using the cameras, then run again. Check: lsmod | grep ${MOD_CAM}"
    fi
    ok "Unloaded ${MOD_CAM}"
  else
    info "${MOD_CAM} is not loaded yet"
  fi
  BEFORE="$(gmslmode_count)"
  run $SUDO insmod "$PKG/ko/$KO_CAM" "GMSLMODE_1=${GMSL}" || die "insmod ${KO_CAM} failed" "See: sudo dmesg | tail -n 30"
  ok "insmod ${KO_CAM} GMSLMODE_1=${GMSL}"
  if [ "$DRY_RUN" -eq 0 ]; then
    info "Waiting for camera detection (max ${WAIT_SEC}s)..."
    t=0
    while [ "$t" -lt "$WAIT_SEC" ]; do
      sleep 1; t=$((t + 1)); refresh_dmesg
      if [ "$(gmslmode_count)" -gt "$BEFORE" ]; then
        n="$(dmesg_last_load_from "$DM" | grep -cE 'been detected|detect error' || true)"
        [ "$n" -ge 4 ] && break
      fi
      printf '\r         waited %2ds' "$t"
    done
    printf '\r'
    [ "$(gmslmode_count)" -gt "$BEFORE" ] || die "No new ###GMSLMODE### line in dmesg after insmod" \
      "Check: sudo dmesg | tail -n 50"
  fi
  step_done "reloaded with GMSLMODE_1=${GMSL}"
fi

# =============================================================================
step_begin 4
refresh_dmesg
GOT_MODE="$(last_gmslmode)"
if [ "$DRY_RUN" -eq 1 ]; then
  info "(dry run: current dmesg GMSLMODE=${GOT_MODE:-none}; module not really reloaded)"
elif [ "$GOT_MODE" = "$GMSL" ]; then
  ok "dmesg: ###GMSLMODE=${GMSL//,/, }###"
else
  die "dmesg shows GMSLMODE=${GOT_MODE:-none}, expected ${GMSL}" "Run: ./setup.sh step2 --force-reload"
fi
SECTION="$(dmesg_last_load_from "$DM")"
N_DET_ERR="$(printf '%s\n' "$SECTION" | grep -c 'detect error' || true)"
N_WFAIL="$(printf '%s\n' "$SECTION" | grep -c 'i2c-w, write failed' || true)"
PORTS="$(detected_ports_from "$DM")"
if [ -n "$PORTS" ]; then
  ok "Cameras detected on port(s): ${PORTS}"
  printf '%s\n' "$SECTION" | grep 'been detected' | sed 's/^/         /'
  [ "$N_DET_ERR" -gt 0 ] && info "Ports without a camera show \"detect error\" (${N_DET_ERR} lines) - this is normal"
elif [ "$DRY_RUN" -eq 1 ]; then
  info "(dry run: no \"been detected!\" in dmesg yet)"
else
  fail "No camera detected on any port"
  if [ "$N_WFAIL" -gt 0 ]; then
    if [ "$I2C_ACK" = none ]; then
      die "dmesg shows \"i2c-w, write failed\" and 0x6b does not answer" "The MIPI cable must be on the 22-pin CAM1 connector, and the board needs 12V (power off before moving the cable)"
    else
      die "\"i2c-w, write failed\" again after the reload, although 0x6b answers on i2c-9" \
          "The cable connector is probably right. Try ./setup.sh step2 --reload-der; if it repeats, power-cycle the SG4A board (12V) and the cameras, then send: sudo dmesg | grep -iE 'max96712|sgx|i2c-w' | tail -n 40"
    fi
  elif [[ "$GOT_MODE" == *0* ]]; then
    die "\"detect error\" on every port and GMSLMODE=${GOT_MODE} (0 = first-generation GMSL)" \
        "Wrong serializer type: the cameras are GMSL2. Run: ./setup.sh step2 --gmsl 2,2,2,2  (or 1 for GMSL2/6G)"
  else
    die "\"detect error\" on every port (${N_DET_ERR} lines) although GMSLMODE=${GOT_MODE}" \
        "Check 12V power to the board, GMSL coax cables, PoC support and GMSL type (try --gmsl 1,1,1,1)"
  fi
fi
if [ -n "$PORTS_OPT" ]; then PORTS="${PORTS_OPT//,/ }"; info "Using ports from --ports: ${PORTS}"; fi
step_done "port(s): ${PORTS:-none}"

# =============================================================================
step_begin 5
if [ ! -x "$PKG/clock_config.sh" ]; then
  run chmod a+x "$PKG/clock_config.sh" || die "chmod a+x clock_config.sh failed" "Check permissions of $PKG"
fi
run_in "$PKG" ${SUDO:+"$SUDO"} ./clock_config.sh || die "clock_config.sh failed" "Read the output above"
step_done "clocks configured"

# =============================================================================
step_begin 6
SET_OK=(); SET_FAIL=()
for p in $PORTS; do
  dev="/dev/video${p}"   # observed on the test unit: port N -> /dev/videoN
  if [ ! -e "$dev" ] && [ "$DRY_RUN" -eq 0 ]; then
    for _ in 1 2 3 4 5; do [ -e "$dev" ] && break; sleep 1; done
  fi
  if [ ! -e "$dev" ] && [ "$DRY_RUN" -eq 0 ]; then
    fail "${dev} not found for port ${p}"
    info "Available: $(compgen -G '/dev/video*' | tr '\n' ' ')"
    info "If video numbers do not match port numbers, pass --ports"
    SET_FAIL+=("$p"); continue
  fi
  if ! run v4l2-ctl -d "$dev" --set-ctrl "bypass_mode=0,sensor_mode=${MODE}"; then
    fail "${dev}: could not set controls (is your user in the 'video' group? check: id -nG)"
    SET_FAIL+=("$p"); continue
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    got="$(v4l2-ctl -d "$dev" --get-ctrl sensor_mode 2>/dev/null | awk -F': *' '{print $2}')"
    if [ "$got" != "$MODE" ]; then fail "${dev}: read back sensor_mode=${got:-?}, expected ${MODE}"; SET_FAIL+=("$p"); continue; fi
  fi
  ok "${dev}: bypass_mode=0, sensor_mode=${MODE}"
  SET_OK+=("$p")
done
if [ ${#SET_FAIL[@]} -gt 0 ] || { [ ${#SET_OK[@]} -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; }; then
  die "Could not configure port(s): ${SET_FAIL[*]:-none ready}" "Fix the messages above and run ./setup.sh step2 again"
fi
state_set step2.ports OK "${SET_OK[*]:-}"
state_set step2.mode OK "${MODE}"
step_done "ready: /dev/video$(printf '%s' "${SET_OK[*]:-?}" | sed 's/ /, \/dev\/video/g')"

sg_finish DONE "ports ${SET_OK[*]:-}"
info "Note: these settings are lost on reboot. Re-run ./setup.sh after each boot, or see ./setup.sh persist (optional, untested)."
printf '\n%sNext:%s ./setup.sh   (runs step 3: camera tests)\n' "$C_BOLD" "$C_0"
