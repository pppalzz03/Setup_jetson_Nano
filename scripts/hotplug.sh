#!/usr/bin/env bash
# =============================================================================
# hotplug.sh — GMSL2 hot-plug watcher (monitor first, recovery optional)
#
#   scripts/hotplug.sh once                 read the lock bits once (verify register map: plug/unplug a cable)
#   scripts/hotplug.sh watch [--enable-recovery]   run the watcher in the foreground (default = monitor only)
#   scripts/hotplug.sh install [--enable-recovery] install + start the systemd service (sg4a-hotplug)
#   scripts/hotplug.sh uninstall            stop and remove the service
#   scripts/hotplug.sh status               service state + last log lines
#
# Monitor mode only logs what it WOULD do. --enable-recovery makes it release the cameras (signal
# file), run `step2 --force-reload` and verify /dev/videoN. Extra options go to hotplug_watch.py.
# =============================================================================
set -u
set -o pipefail
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

WATCHER="${SG4A_SCRIPTS_DIR}/hotplug_watch.py"
UNIT_NAME="sg4a-hotplug"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}.service"

usage() {
  sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  printf '\nOptions: --dry-run, --enable-recovery, and any hotplug_watch.py option (see: python3 %s --help)\n' "$WATCHER"
}

CMD="${1:-}"; [ $# -gt 0 ] && shift
EXTRA=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    *) EXTRA+=("$a") ;;
  esac
done
ENABLE=0
for a in "${EXTRA[@]+"${EXTRA[@]}"}"; do [ "$a" = "--enable-recovery" ] && ENABLE=1; done

need_tools() {
  command -v python3 >/dev/null || die "python3 not found"
  command -v i2ctransfer >/dev/null || check_fail "i2ctransfer not found" "sudo apt install i2c-tools"
  [ -f "$WATCHER" ] || die "missing $WATCHER"
}

watcher() {   # run as root, keep state in the user's dir
  run $SUDO env "SUDO_USER=${SG4A_USER}" python3 "$WATCHER" "$@"
}

case "$CMD" in
  once)
    need_tools
    watcher --once "${EXTRA[@]+"${EXTRA[@]}"}" ;;
  watch)
    need_tools
    if [ "$ENABLE" -eq 1 ]; then warn "Recovery ENABLED: cameras will be released and drivers reloaded on a link change"
    else info "Monitor mode: only logging (add --enable-recovery to act)"; fi
    watcher "${EXTRA[@]+"${EXTRA[@]}"}" ;;
  install)
    need_tools
    command -v systemctl >/dev/null || die "systemctl not found"
    exec_line="/usr/bin/python3 ${WATCHER}"
    for a in "${EXTRA[@]+"${EXTRA[@]}"}"; do exec_line+=" $(printf '%q' "$a")"; done
    unit="[Unit]
Description=SG4A GMSL2 camera hot-plug watcher
After=multi-user.target

[Service]
Type=simple
Environment=SUDO_USER=${SG4A_USER}
ExecStart=${exec_line}
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target"
    write_root "$UNIT_FILE" "$unit"
    run $SUDO systemctl daemon-reload
    run $SUDO systemctl enable --now "$UNIT_NAME"
    if [ "$ENABLE" -eq 1 ]; then ok "Installed with recovery ENABLED"; else ok "Installed in monitor mode (reinstall with --enable-recovery to act)"; fi
    info "Logs: journalctl -u ${UNIT_NAME} -f" ;;
  uninstall)
    command -v systemctl >/dev/null || die "systemctl not found"
    run $SUDO systemctl disable --now "$UNIT_NAME" || true
    run $SUDO rm -f "$UNIT_FILE"
    run $SUDO systemctl daemon-reload
    ok "Removed ${UNIT_NAME}" ;;
  status)
    systemctl is-active "$UNIT_NAME" 2>/dev/null || true
    systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true
    journalctl -u "$UNIT_NAME" -n 20 --no-pager 2>/dev/null || true
    [ -e /run/sg4a/camera-reload ] && warn "signal file present: $(cat /run/sg4a/camera-reload)" || info "no signal file (cameras not being reloaded)" ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
