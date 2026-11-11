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
PKG_IMAGE=""; PKG_DTBO=""
if [ -d "$PKG" ]; then
  PKG_IMAGE="$(find "$PKG" -maxdepth 3 -type f -name Image 2>/dev/null | head -n1)"
  PKG_DTBO="$(find "$PKG" -maxdepth 3 -type f -name "$DTBO_NAME" 2>/dev/null | head -n1)"
fi
if [ -n "$PKG_IMAGE" ]; then info "Package Image:   ${PKG_IMAGE#"$PKG"/}"; else warn "No Image file in package; /boot/Image will be checked by modification time"; fi
if [ -n "$PKG_DTBO" ];  then info "Package overlay: ${PKG_DTBO#"$PKG"/}"; else warn "No ${DTBO_NAME} in package; will only check it exists in /boot"; fi
step_done "${PKG#"${SG4A_REPO_DIR}"/}"

# =============================================================================
step_begin 3
run chmod a+x "$PKG"/*.sh || check_fail "chmod a+x *.sh failed" "Check permissions of $PKG"
ok "chmod a+x *.sh"
boot_matches_pkg() {
  [ -f "$BOOT_DTBO" ] || return 1
  if [ -n "$PKG_DTBO" ]; then cmp -s "$PKG_DTBO" "$BOOT_DTBO" || return 1; fi
  [ -n "$PKG_IMAGE" ] || return 1
  cmp -s "$PKG_IMAGE" /boot/Image
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
if [ "$DRY_RUN" -eq 1 ] && [ "$CHANGED_BOOT" -eq 1 ]; then
  info "(dry run: install.sh was not really run, skipping file checks)"
  step_done "dry run"
else
  if [ -f "$BOOT_DTBO" ]; then ok "Found $BOOT_DTBO"
  else check_fail "$BOOT_DTBO not found" "install.sh did not copy the overlay; check its output"; fi
  if [ -n "$PKG_DTBO" ] && [ -f "$BOOT_DTBO" ]; then
    if cmp -s "$PKG_DTBO" "$BOOT_DTBO"; then ok "Overlay in /boot matches the package"
    else check_fail "Overlay in /boot differs from the package" "Run: $0 --reinstall"; fi
  fi
  if [ -n "$PKG_IMAGE" ]; then
    if cmp -s "$PKG_IMAGE" /boot/Image; then ok "/boot/Image is the new kernel from the package"
    else check_fail "/boot/Image differs from the package Image" "Run: $0 --reinstall"; fi
    step_done "dtbo + Image verified"
  elif [ "$CHANGED_BOOT" -eq 1 ] && [ "$(stat -c %Y /boot/Image 2>/dev/null || echo 0)" -ge "$INSTALL_START" ]; then
    ok "/boot/Image was updated by install.sh"
    step_done "dtbo verified, Image updated"
  else
    warn "Cannot confirm /boot/Image is new (no reference Image in package)"
    step_warn "Image not verified"
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
