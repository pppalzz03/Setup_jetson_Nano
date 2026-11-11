#!/usr/bin/env bash
# =============================================================================
# step2b_persist.sh — OPTIONAL, UNTESTED: keep GMSLMODE after reboot
# Pick ONE method:
#   inspect          (default, read-only) find out what loads sgx_yuv_gmsl2 at boot
#   enable-modprobe  write /etc/modprobe.d/sgx-yuv-gmsl2.conf
#                    "options sgx_yuv_gmsl2 GMSLMODE_1=..." and (after asking) update-initramfs -u.
#                    Only works if the module is loaded by modprobe/udev from /lib/modules.
#   enable-service   install a systemd service that runs step2_after_reboot.sh at boot
#   status           show what is enabled
#   revert           undo both methods (files are moved to the backup folder, not deleted)
#
# Every change asks first and backs up files to /var/backups/sg4a-persist/.
# Usage: scripts/step2b_persist.sh [inspect|enable-modprobe|enable-service|status|revert]
#                                  [--gmsl A,B,C,D] [--mode N] [--pkg DIR] [--dry-run]
# =============================================================================
set -u
set -o pipefail
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

readonly MOD_CAM="sgx_yuv_gmsl2"
readonly MODPROBE_CONF="/etc/modprobe.d/sgx-yuv-gmsl2.conf"
readonly SERVICE_NAME="sg4a-camera.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly BACKUP_DIR="/var/backups/sg4a-persist"
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"; readonly BACKUP_TS

CMD="inspect"
GMSL="2,2,2,2"
MODE=1
PKG="$(default_pkg_dir)"

usage() {
  cat <<EOF
Usage: $0 [command] [options]

Commands (choose ONE method - both are untested on real hardware):
  inspect          (default) read-only: what loads ${MOD_CAM} at boot
  enable-modprobe  add options to ${MODPROBE_CONF} (+ update-initramfs -u if confirmed)
  enable-service   install ${SERVICE_NAME} that runs step2_after_reboot.sh at boot
  status           show current state
  revert           undo everything this script did

Options:
  --gmsl A,B,C,D   GMSLMODE_1 value (default: ${GMSL})
  --mode N         sensor_mode for enable-service (default: ${MODE})
  --pkg DIR        driver package folder for enable-service (default: ${PKG})
  --dry-run        print commands, do not run them
EOF
}
bad_arg() { usage >&2; printf '\nInvalid argument: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    inspect|enable-modprobe|enable-service|status|revert) CMD="$1"; shift ;;
    --gmsl)    [ $# -ge 2 ] || bad_arg "$1"; GMSL="$2"; shift 2 ;;
    --gmsl=*)  GMSL="${1#*=}"; shift ;;
    --mode)    [ $# -ge 2 ] || bad_arg "$1"; MODE="$2"; shift 2 ;;
    --mode=*)  MODE="${1#*=}"; shift ;;
    --pkg)     [ $# -ge 2 ] || bad_arg "$1"; PKG="$2"; shift 2 ;;
    --pkg=*)   PKG="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         bad_arg "$1" ;;
  esac
done
PKG="${PKG%/}"
GMSL="${GMSL// /}"
[[ "$GMSL" =~ ^[0-2],[0-2],[0-2],[0-2]$ ]] || bad_arg "--gmsl '$GMSL'"
[[ "$MODE" =~ ^[0-4]$ ]] || bad_arg "--mode '$MODE'"
[ "$DRY_RUN" -eq 1 ] && printf '%s*** DRY RUN ***%s\n' "$C_Y" "$C_0"

hdr() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
stop_here() { fail "$1"; [ $# -gt 1 ] && printf '  %sFix:%s %s\n' "$C_Y" "$C_0" "$2" >&2; exit 1; }
backup() {   # copy FILE (if it exists) into BACKUP_DIR
  [ -e "$1" ] || return 0
  run $SUDO mkdir -p "$BACKUP_DIR" || stop_here "Cannot create $BACKUP_DIR"
  run $SUDO cp -p "$1" "${BACKUP_DIR}/$(basename "$1").${BACKUP_TS}" || stop_here "Backup of $1 failed"
  ok "Backed up $1 -> ${BACKUP_DIR}/$(basename "$1").${BACKUP_TS}"
}
initrd_files() { compgen -G '/boot/initrd*' || true; }

do_inspect() {
  hdr "What loads ${MOD_CAM} at boot? (read-only)"
  info "--- grep -rn sgx /etc/modules-load.d/ /etc/modprobe.d/ /etc/modules"
  grep -rn sgx /etc/modules-load.d/ /etc/modprobe.d/ /etc/modules 2>/dev/null | sed 's/^/         /' || info "(none)"
  info "--- systemd units matching sg4a|sgx|sensing|camera"
  systemctl list-units --all --no-pager 2>/dev/null | grep -iE 'sg4a|sgx|sensing|camera' | sed 's/^/         /' || info "(none)"
  info "--- modinfo -n ${MOD_CAM}"
  local mi f; mi="$(modinfo -n "$MOD_CAM" 2>/dev/null || true)"
  if [ -n "$mi" ]; then info "Found: $mi"; info "=> module is in /lib/modules, udev/modprobe can autoload it: enable-modprobe may work"
  else info "Not in /lib/modules/$(uname -r) => loaded some other way; enable-modprobe may NOT work, prefer enable-service"; fi
  if command -v lsinitramfs >/dev/null 2>&1; then
    for f in $(initrd_files); do
      info "--- lsinitramfs $f | grep sgx"
      lsinitramfs "$f" 2>/dev/null | grep -i sgx | sed 's/^/         /' || info "(no sgx in initrd)"
    done
  fi
  info "--- scripts mentioning the module in /etc/systemd /etc/rc.local /etc/init.d"
  grep -rln 'sgx-yuv-gmsl2\|sgx_yuv_gmsl2' /etc/systemd /etc/rc.local /etc/init.d 2>/dev/null | sed 's/^/         /' || info "(none)"
  if [ -r "/sys/module/${MOD_CAM}/parameters/GMSLMODE_1" ]; then
    info "Current GMSLMODE_1 = $(cat "/sys/module/${MOD_CAM}/parameters/GMSLMODE_1")"
  else
    info "Cannot read /sys/module/${MOD_CAM}/parameters/GMSLMODE_1 (not loaded or not exported)"
  fi
  printf '\nNext: ./setup.sh persist enable-modprobe   OR   ./setup.sh persist enable-service   (choose one)\n'
}

do_status() {
  hdr "Persistence status"
  if [ -f "$MODPROBE_CONF" ]; then ok "${MODPROBE_CONF}: $(grep -v '^#' "$MODPROBE_CONF" | tr '\n' ' ')"
  else info "${MODPROBE_CONF}: not present"; fi
  if [ -f "$SERVICE_FILE" ]; then
    ok "${SERVICE_FILE} (enabled: $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo no))"
    info "Last run: journalctl -u ${SERVICE_NAME} -b"
  else info "${SERVICE_FILE}: not present"; fi
  [ -d "$BACKUP_DIR" ] && info "Backups: $(find "$BACKUP_DIR" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
  return 0
}

do_enable_modprobe() {
  hdr "Method 1: ${MODPROBE_CONF} (untested)"
  local content="# created by step2b_persist.sh ${BACKUP_TS} - undo with: ./setup.sh persist revert
options ${MOD_CAM} GMSLMODE_1=${GMSL}" f
  if [ -f "$MODPROBE_CONF" ] && grep -q "^options ${MOD_CAM} GMSLMODE_1=${GMSL}\$" "$MODPROBE_CONF"; then
    ok "${MODPROBE_CONF} already has this value"
  else
    confirm "Write ${MODPROBE_CONF} with GMSLMODE_1=${GMSL}?" || { info "Cancelled"; return 0; }
    backup "$MODPROBE_CONF"
    write_root "$MODPROBE_CONF" "$content" || stop_here "Writing ${MODPROBE_CONF} failed"
    ok "Wrote ${MODPROBE_CONF}"
  fi
  if ! command -v update-initramfs >/dev/null 2>&1; then
    warn "update-initramfs not found, initrd step skipped"
  elif confirm "Run update-initramfs -u (initrd is backed up first)? Needed if the module loads from initrd"; then
    for f in $(initrd_files); do backup "$f"; done
    run $SUDO update-initramfs -u || stop_here "update-initramfs -u failed" "Restore initrd from ${BACKUP_DIR}, then: ./setup.sh persist revert"
    ok "update-initramfs -u done"
  fi
  printf '\nNext: sudo reboot, then check: sudo dmesg | grep GMSLMODE   (expect %s)\n' "${GMSL//,/, }"
  info "If it still shows 0, 0, 0, 0 this method does not work: ./setup.sh persist revert, then use enable-service"
}

do_enable_service() {
  hdr "Method 2: systemd ${SERVICE_NAME} (untested)"
  local s2="${SG4A_SCRIPTS_DIR}/step2_after_reboot.sh"
  [ -f "$s2" ] || stop_here "Not found: $s2"
  [ -d "$PKG" ] || stop_here "Driver package not found: $PKG" "Pass --pkg DIR"
  local content="# created by step2b_persist.sh ${BACKUP_TS} - undo with: ./setup.sh persist revert
[Unit]
Description=SENSING SG4A camera bring-up (GMSLMODE_1=${GMSL}, sensor_mode=${MODE})
After=multi-user.target systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=SG4A_STATE_DIR=${SG4A_STATE_DIR}
Environment=SG4A_STATE_OWNER=${SG4A_USER}
ExecStart=/bin/bash \"${s2}\" --pkg \"${PKG}\" --gmsl ${GMSL} --mode ${MODE} --force-reload
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target"
  if [ -f "$SERVICE_FILE" ] && [ "$(tail -n +2 "$SERVICE_FILE")" = "$(printf '%s\n' "$content" | tail -n +2)" ]; then
    ok "${SERVICE_FILE} already up to date"
  else
    warn "The service points to ${s2} - do not move or delete the repo after installing"
    confirm "Install ${SERVICE_FILE}?" || { info "Cancelled"; return 0; }
    backup "$SERVICE_FILE"
    write_root "$SERVICE_FILE" "$content" || stop_here "Writing ${SERVICE_FILE} failed"
    run $SUDO systemctl daemon-reload || stop_here "systemctl daemon-reload failed"
  fi
  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    ok "${SERVICE_NAME} already enabled"
  else
    confirm "Enable ${SERVICE_NAME} at boot (systemctl enable)?" || { info "Not enabled"; return 0; }
    run $SUDO systemctl enable "$SERVICE_NAME" || stop_here "systemctl enable failed"
    ok "Enabled ${SERVICE_NAME}"
  fi
  printf '\nNext: sudo reboot, then check: ./setup.sh status ; journalctl -u %s -b\n' "$SERVICE_NAME"
}

do_revert() {
  hdr "Revert"
  local did=0 f
  if [ -f "$SERVICE_FILE" ] && confirm "Disable and remove ${SERVICE_NAME} (moved to ${BACKUP_DIR})?"; then
    run $SUDO systemctl disable "$SERVICE_NAME" || warn "systemctl disable failed (maybe not enabled)"
    run $SUDO mkdir -p "$BACKUP_DIR" || stop_here "Cannot create $BACKUP_DIR"
    run $SUDO mv "$SERVICE_FILE" "${BACKUP_DIR}/${SERVICE_NAME}.removed-${BACKUP_TS}" || stop_here "Moving ${SERVICE_FILE} failed"
    run $SUDO systemctl daemon-reload || warn "daemon-reload failed"
    ok "Removed ${SERVICE_NAME}"; did=1
  fi
  if [ -f "$MODPROBE_CONF" ] && confirm "Remove ${MODPROBE_CONF} (moved to ${BACKUP_DIR})?"; then
    run $SUDO mkdir -p "$BACKUP_DIR" || stop_here "Cannot create $BACKUP_DIR"
    run $SUDO mv "$MODPROBE_CONF" "${BACKUP_DIR}/$(basename "$MODPROBE_CONF").removed-${BACKUP_TS}" || stop_here "Moving file failed"
    ok "Removed ${MODPROBE_CONF}"; did=1
    if command -v update-initramfs >/dev/null 2>&1 && confirm "Run update-initramfs -u to drop the option from initrd too?"; then
      for f in $(initrd_files); do backup "$f"; done
      run $SUDO update-initramfs -u || warn "update-initramfs -u failed - restore initrd from ${BACKUP_DIR}"
    fi
  fi
  [ "$did" -eq 0 ] && info "Nothing reverted (nothing installed, or not confirmed)"
  info "initrd backups (if any) are in ${BACKUP_DIR}; restore with: sudo cp -p ${BACKUP_DIR}/initrd.<time> /boot/initrd"
}

case "$CMD" in
  inspect)         do_inspect ;;
  status)          do_status ;;
  enable-modprobe) do_enable_modprobe ;;
  enable-service)  do_enable_service ;;
  revert)          do_revert ;;
esac
