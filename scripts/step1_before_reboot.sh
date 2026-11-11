#!/usr/bin/env bash
# =============================================================================
# step1_before_reboot.sh — one-time setup before reboot
# SENSING SG4A-NONX-G2Y-A1 (MAX96712) on Jetson Orin Nano, JetPack 6.2 / L4T R36.4.3
#
#   1. Check L4T R36.4.3 and kernel 5.15.148-tegra
#   2. Check the driver package folder (and Git LFS binaries)
#   3. chmod a+x *.sh, run the package's install.sh (skipped if /boot already matches)
#   4. Verify /boot/tegra234-camera-yuv-gmslx4-overlay.dtbo and the new /boot/Image
#   5. Select overlay "Jetson Sensing YUV GMSLx4" (config-by-hardware.py, or guided
#      jetson-io.py menu), backing up extlinux.conf first; verify DEFAULT JetsonIO + OVERLAYS
#   6. Ask before rebooting (never reboots on its own)
#
# Usage: scripts/step1_before_reboot.sh [--pkg DIR] [--overlay-name NAME] [--reinstall] [--manual] [--dry-run]
# =============================================================================
set -u
set -o pipefail
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

readonly EXPECT_L4T="36.4.3"
readonly EXPECT_KERNEL="5.15.148-tegra"
readonly DTBO_NAME="tegra234-camera-yuv-gmslx4-overlay.dtbo"
readonly BOOT_DTBO="/boot/${DTBO_NAME}"
readonly EXTLINUX="${SG4A_EXTLINUX:-/boot/extlinux/extlinux.conf}"
readonly JIO_DIR="/opt/nvidia/jetson-io"
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"; readonly BACKUP_TS

REINSTALL=0
MANUAL=0
OVERLAY_NAME="Jetson Sensing YUV GMSLx4"
PKG="$(default_pkg_dir)"

usage() {
  cat <<EOF
Usage: $0 [options]

One-time setup before reboot: install the SENSING driver and select the camera overlay.

Options:
  --pkg DIR            driver package folder (default: ${PKG})
  --overlay-name NAME  overlay name in jetson-io (default: "${OVERLAY_NAME}")
  --reinstall          run install.sh again even if /boot already matches the package
  --manual             do not use config-by-hardware.py; show the jetson-io menu steps instead
  --dry-run            print commands that change the system, do not run them
  -h, --help           show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg)          [ $# -ge 2 ] || { usage >&2; exit 2; }; PKG="$2"; shift 2 ;;
    --pkg=*)        PKG="${1#*=}"; shift ;;
    --overlay-name) [ $# -ge 2 ] || { usage >&2; exit 2; }; OVERLAY_NAME="$2"; shift 2 ;;
    --reinstall)    REINSTALL=1; shift ;;
    --manual)       MANUAL=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
PKG="${PKG%/}"

CHANGED_BOOT=0
INSTALL_START=0

# "<DEFAULT label> <1 if LABEL JetsonIO has OVERLAYS dtbo>"
extlinux_state() {
  [ -r "$EXTLINUX" ] || { echo "- 0"; return; }
  awk -v dtbo="$BOOT_DTBO" '
    /^[[:space:]]*DEFAULT[[:space:]]/  { def=$2 }
    /^[[:space:]]*LABEL[[:space:]]/    { label=$2 }
    /^[[:space:]]*OVERLAYS[[:space:]]/ { if (label=="JetsonIO" && index($0, dtbo)) ov=1 }
    END { printf "%s %d\n", (def==""?"-":def), ov+0 }' "$EXTLINUX"
}
extlinux_ok() { [ "$(extlinux_state)" = "JetsonIO 1" ]; }

# back up extlinux.conf before every change (keep the very first copy as .bak)
backup_extlinux() {
  [ -f "$EXTLINUX" ] || { warn "$EXTLINUX not found, nothing to back up"; return 0; }
  if [ ! -e "${EXTLINUX}.bak" ]; then
    run $SUDO cp -p "$EXTLINUX" "${EXTLINUX}.bak" || die "Could not create ${EXTLINUX}.bak"
  fi
  run $SUDO cp -p "$EXTLINUX" "${EXTLINUX}.bak-${BACKUP_TS}" || die "Could not back up extlinux.conf"
  ok "Backed up extlinux.conf -> ${EXTLINUX}.bak-${BACKUP_TS}"
}

sg_init step1 "STEP 1/3 - Setup before reboot" "${STEP1_TITLES[@]}"

# =============================================================================
step_begin 1
L4T_VER=""
if [ -r /etc/nv_tegra_release ]; then
  L4T_VER="$(sed -n 's/^# R\([0-9]*\) (release), REVISION: \([0-9.]*\),.*/\1.\2/p' /etc/nv_tegra_release | head -n1)"
fi
if [ "$L4T_VER" = "$EXPECT_L4T" ]; then ok "L4T R${L4T_VER}"
else check_fail "L4T mismatch: found '${L4T_VER:-no /etc/nv_tegra_release}', expected R${EXPECT_L4T}" \
  "This driver package is built for JetPack 6.2 / L4T R36.4.3 only. Use the package matching your L4T."; fi
KVER="$(uname -r)"
if [ "$KVER" = "$EXPECT_KERNEL" ]; then ok "Kernel ${KVER}"
else check_fail "Kernel mismatch: found ${KVER}, expected ${EXPECT_KERNEL}" \
  "The .ko modules in the package are built for ${EXPECT_KERNEL} only."; fi
step_done "L4T R${L4T_VER:-?}, kernel ${KVER}"

# =============================================================================
step_begin 2
if [ -d "$PKG" ]; then ok "Package folder: $PKG"
else check_fail "Driver package folder not found: $PKG" \
  "Put the package in ${SG4A_REPO_DIR}/driver/ (see driver/README.md) or ~/${SG4A_PKG_NAME}, or pass --pkg DIR"; fi
check_pkg_lfs "$PKG"
MISSING=()
for f in install.sh clock_config.sh ko/max96712.ko ko/sgx-yuv-gmsl2.ko; do
  [ -e "$PKG/$f" ] || MISSING+=("$f")
done
if [ ${#MISSING[@]} -eq 0 ]; then ok "Required files present (install.sh, clock_config.sh, ko/max96712.ko, ko/sgx-yuv-gmsl2.ko)"
else check_fail "Package is missing: ${MISSING[*]}" "Re-extract / re-download the driver package"; fi
# the package may hold several copies/variants of Image and the overlay (boot/, dtb/, ...): keep them all
PKG_IMAGES=(); PKG_DTBOS=()
if [ -d "$PKG" ]; then
  mapfile -t PKG_IMAGES < <(find "$PKG" -maxdepth 4 -type f -name Image 2>/dev/null | sort)
  mapfile -t PKG_DTBOS  < <(find "$PKG" -maxdepth 4 -type f -name "$DTBO_NAME" 2>/dev/null | sort)
fi
for f in "${PKG_IMAGES[@]}"; do info "Package Image:   ${f#"$PKG"/}"; done
for f in "${PKG_DTBOS[@]}";  do info "Package overlay: ${f#"$PKG"/}"; done
[ ${#PKG_IMAGES[@]} -eq 0 ] && warn "No Image file in package; /boot/Image will be checked by change time"
[ ${#PKG_DTBOS[@]} -eq 0 ]  && warn "No ${DTBO_NAME} in package; will only check it exists in /boot"
step_done "${PKG#"${SG4A_REPO_DIR}"/}"

# =============================================================================
step_begin 3
run chmod a+x "$PKG"/*.sh || check_fail "chmod a+x *.sh failed" "Check permissions of $PKG"
ok "chmod a+x *.sh"
# same_as_any TARGET CANDIDATE... -> 0 if TARGET is byte-identical to one candidate (sets MATCHED)
MATCHED=""
same_as_any() {
  local t="$1" c; shift; MATCHED=""
  [ -f "$t" ] || return 1
  for c in "$@"; do cmp -s "$c" "$t" && { MATCHED="$c"; return 0; }; done
  return 1
}
boot_matches_pkg() {
  [ -f "$BOOT_DTBO" ] || return 1
  if [ ${#PKG_DTBOS[@]} -gt 0 ]; then same_as_any "$BOOT_DTBO" "${PKG_DTBOS[@]}" || return 1; fi
  [ ${#PKG_IMAGES[@]} -gt 0 ] || return 1
  same_as_any /boot/Image "${PKG_IMAGES[@]}"
}
if [ "$REINSTALL" -eq 0 ] && boot_matches_pkg; then
  ok "/boot already matches the package (use --reinstall to force)"
  step_skip "install.sh not needed"
else
  if [ -f /boot/Image ] && ! compgen -G '/boot/Image.bak-sg4a-*' >/dev/null; then
    run $SUDO cp -p /boot/Image "/boot/Image.bak-sg4a-${BACKUP_TS}" || die "Could not back up /boot/Image"
    ok "Backed up current kernel -> /boot/Image.bak-sg4a-${BACKUP_TS}"
  fi
  backup_extlinux
  INSTALL_START="$(date +%s)"
  info "Running install.sh (may ask for your sudo password)..."
  run_in "$PKG" ./install.sh || die "install.sh failed" "Read the output above, fix it, then re-run this script"
  CHANGED_BOOT=1
  step_done "install.sh finished"
fi

# =============================================================================
step_begin 4
# changed_since_install FILE -> 0 if FILE was written during this run's install.sh
# (ctime, because cp -p keeps the old modification time)
changed_since_install() { [ "$INSTALL_START" -gt 0 ] && [ "$(stat -c %Z "$1" 2>/dev/null || echo 0)" -ge "$INSTALL_START" ]; }
# print what we compared, so a mismatch can be diagnosed
show_compare() {   # show_compare TARGET CANDIDATE...
  local t="$1" c; shift
  info "md5 / size / changed:"
  for c in "$t" "$@"; do
    [ -f "$c" ] && info "  $(md5sum "$c" | cut -c1-12)  $(printf '%9s' "$(stat -c %s "$c")") B  $(date -d "@$(stat -c %Z "$c")" '+%F %T')  ${c#"$PKG"/}"
  done
  if [ -r "$PKG/install.sh" ]; then
    info "install.sh lines that copy it:"
    grep -nE "$(basename "$t")|/boot" "$PKG/install.sh" 2>/dev/null | head -n 8 | sed 's/^/           /'
  fi
}
# verify_boot_file TARGET LABEL CANDIDATE... ; result in VERIFY (OK / WARN / FAIL)
VERIFY=""
verify_boot_file() {
  local t="$1" label="$2"; shift 2
  if [ $# -eq 0 ]; then
    if changed_since_install "$t"; then ok "${label} was updated by install.sh"; VERIFY=OK
    else warn "Cannot confirm ${label} is new (no reference copy in the package)"; VERIFY=WARN; fi
    return
  fi
  if same_as_any "$t" "$@"; then ok "${label} matches the package (${MATCHED#"$PKG"/})"; VERIFY=OK; return; fi
  if changed_since_install "$t"; then
    # install.sh wrote it just now, but from a source we do not know (e.g. built/renamed by install.sh)
    warn "${label} was written by install.sh but is not identical to the package copy we compared"
    show_compare "$t" "$@"
    info "install.sh is the reference, so this is accepted. Send this output if the cameras fail later."
    VERIFY=WARN; return
  fi
  fail "${label} differs from the package and was not changed by install.sh in this run"
  show_compare "$t" "$@"
  VERIFY=FAIL
}

if [ "$DRY_RUN" -eq 1 ] && [ "$CHANGED_BOOT" -eq 1 ]; then
  info "(dry run: install.sh was not really run, skipping file checks)"
  step_done "dry run"
else
  [ -f "$BOOT_DTBO" ] || check_fail "$BOOT_DTBO not found" "install.sh did not copy the overlay; check its output"
  ok "Found $BOOT_DTBO"
  verify_boot_file "$BOOT_DTBO" "Overlay $BOOT_DTBO" "${PKG_DTBOS[@]}"; V1="$VERIFY"
  verify_boot_file /boot/Image "/boot/Image" "${PKG_IMAGES[@]}"; V2="$VERIFY"
  if [ "$V1" = FAIL ] || [ "$V2" = FAIL ]; then
    if [ "$REINSTALL" -eq 0 ]; then
      die "Files in /boot do not match the package" "Run once: ./setup.sh step1 --reinstall   (if it still fails, send the md5 lines above)"
    else
      die "Files in /boot still do not match after --reinstall" "install.sh may copy different files than expected - send the md5 / install.sh lines above"
    fi
  elif [ "$V1" = WARN ] || [ "$V2" = WARN ]; then
    step_warn "installed by install.sh, not byte-identical (see above)"
  else
    step_done "dtbo + Image verified"
  fi
fi

# =============================================================================
step_begin 5
show_manual_steps() {
  cat <<EOF

  Select the overlay with the jetson-io menu (works over SSH):
    1) sudo ${JIO_DIR}/jetson-io.py
    2) Choose  "Configure Jetson 24pin CSI Connector"
    3) Choose  "Configure for compatible hardware"
    4) Choose  "${OVERLAY_NAME}"
    5) Choose  "Save pin changes"
    6) Choose  "Save and exit without rebooting"   (NOT "Save and reboot" - this script asks about reboot)
    7) Run this script again to verify:  ./setup.sh step1

  Expected in ${EXTLINUX}:
    DEFAULT JetsonIO
    LABEL JetsonIO
        ...
        OVERLAYS ${BOOT_DTBO}
EOF
}
# find the header number that offers this overlay (no hard-coded header index)
find_header() {
  $SUDO "${JIO_DIR}/config-by-hardware.py" -l 2>/dev/null | awk -v name="$OVERLAY_NAME" '
    /^[[:space:]]*Header[[:space:]]+[0-9]+/ { match($0, /Header[[:space:]]+[0-9]+/); h=substr($0, RSTART, RLENGTH); sub(/Header[[:space:]]+/, "", h) }
    index($0, name) && h!="" { print h; exit }'
}

if extlinux_ok; then
  ok "extlinux.conf already correct (DEFAULT JetsonIO + OVERLAYS ${DTBO_NAME})"
  step_skip "overlay already selected"
else
  ST="$(extlinux_state)"
  info "Current: DEFAULT=${ST% *}, LABEL JetsonIO has overlay=$([ "${ST#* }" = 1 ] && echo yes || echo no)"
  AUTO_DONE=0
  if [ "$MANUAL" -eq 0 ] && [ -x "${JIO_DIR}/config-by-hardware.py" ]; then
    HEADER="$(find_header || true)"
    if [ -n "$HEADER" ]; then
      info "\"${OVERLAY_NAME}\" is offered on header ${HEADER} (config-by-hardware.py)"
      if confirm "Update extlinux.conf with config-by-hardware.py -n ${HEADER}=\"${OVERLAY_NAME}\" (backup first)?"; then
        backup_extlinux
        if run $SUDO "${JIO_DIR}/config-by-hardware.py" -n "${HEADER}=${OVERLAY_NAME}"; then
          AUTO_DONE=1; CHANGED_BOOT=1
        else
          fail "config-by-hardware.py failed, falling back to the jetson-io menu"
        fi
      fi
    else
      warn "config-by-hardware.py -l does not list \"${OVERLAY_NAME}\" (overlay not installed, or different name)"
    fi
  elif [ "$MANUAL" -eq 0 ]; then
    warn "${JIO_DIR}/config-by-hardware.py not found, cannot select automatically"
  fi
  if [ "$AUTO_DONE" -eq 0 ]; then
    show_manual_steps
    if [ -x "${JIO_DIR}/jetson-io.py" ] && confirm "Open the jetson-io.py menu now and follow the steps above (backup first)?"; then
      backup_extlinux
      run $SUDO "${JIO_DIR}/jetson-io.py" || warn "jetson-io.py exited with an error (normal if you chose Exit)"
      CHANGED_BOOT=1
    fi
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "(dry run: extlinux.conf not changed, not verified)"
    step_done "dry run"
  elif extlinux_ok; then
    ok "extlinux.conf: DEFAULT JetsonIO and OVERLAYS ${BOOT_DTBO}"
    step_done "overlay selected"
  else
    ST="$(extlinux_state)"
    die "extlinux.conf is not correct yet (DEFAULT=${ST% *}, JetsonIO overlay=${ST#* })" \
        "Follow the jetson-io menu steps above, then run ./setup.sh step1 again (backups: ${EXTLINUX}.bak*)"
  fi
fi

# =============================================================================
step_begin 6
OVERLAY_ACTIVE=0
[ -e "${SG4A_SYS_I2C:-/sys/bus/i2c/devices}/9-006b" ] && OVERLAY_ACTIVE=1
if [ "$DRY_RUN" -eq 1 ]; then
  step_done "dry run"; sg_finish DONE "dry run"; exit 0
fi
if [ "$CHANGED_BOOT" -eq 0 ] && [ "$OVERLAY_ACTIVE" -eq 1 ]; then
  ok "System already booted with this overlay (i2c 9-006b exists) - no reboot needed"
  state_set step1.reboot NO "overlay active"
  step_done "no reboot needed"
  sg_finish DONE
  printf '\n%sNext:%s ./setup.sh   (runs step 2)\n' "$C_BOLD" "$C_0"
  exit 0
fi
state_set step1.reboot REQUIRED "boot files changed"
printf '\n%sA reboot is required for the new kernel and overlay to take effect.%s\n' "$C_Y" "$C_0"
if confirm "Reboot now?"; then
  step_done "rebooting"
  sg_finish DONE "reboot started"
  info "Rebooting... after boot run:  ./setup.sh"
  run $SUDO reboot
else
  step_warn "reboot pending"
  sg_finish DONE "reboot pending"
  printf '\n%sNext:%s sudo reboot   then   ./setup.sh\n' "$C_BOLD" "$C_0"
fi
