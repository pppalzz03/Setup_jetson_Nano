#!/usr/bin/env bash
# =============================================================================
# step3_test_camera.sh — camera tests (run after step 2 passes)
#
# Commands:
#   all          (default) formats + test + check-frame
#   formats      list resolutions announced by the driver (v4l2-ctl --list-formats-ext);
#                warns if 1600x1300 is missing while --camera DMSBBFAN is set
#   test         capture with v4l2-ctl --stream-mmap (timeout 15 by default) on every port,
#                report fps and check dmesg for uncorr_err
#   check-frame  grab one frame, compute Y/UV min/max/unique with python3,
#                tell blank vs. real image, save /tmp/camN.jpg (copy with scp)
#   live         live view on the monitor attached to the Jetson (works over SSH):
#                one gst-launch-1.0 per camera, started 2 s apart. Stop with Ctrl+C or `stop`
#   stop         pkill gst-launch-1.0
#
# Usage: scripts/step3_test_camera.sh [command] [--ports 0,3] [--mode N] [--camera NAME] [--dry-run] ...
# =============================================================================
set -u
set -o pipefail
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

CMD="all"
PORTS_OPT=""
MODE_OPT=""
CAMERA="${SG4A_CAMERA:-}"
COUNT=100
MIN_FPS=25
FPS=30
OUTDIR="/tmp"
DISPLAY_OPT=""
XAUTH_OPT=""
LIVE_SIZE=""
DETACH=0
TIMEOUT=15
RETRIES=1
SETTLE=2

usage() {
  cat <<EOF
Usage: $0 [command] [options]

Commands: all (default) | formats | test | check-frame | live | stop

Options:
  --ports 0,3        ports to test (default: auto-detect from dmesg "been detected!")
  --mode N           expected sensor_mode 0..4 (default: read from the camera, set in step 2)
  --camera NAME      camera model, e.g. DMSBBFAN (or env SG4A_CAMERA); used for the resolution warning
  --count N          frames for 'test' (default: ${COUNT})
  --min-fps F        minimum fps to pass (default: ${MIN_FPS})
  --timeout SEC      per-capture timeout in test / check-frame (default: ${TIMEOUT})
  --retries N        extra attempts after a timeout, 2 s apart (default: ${RETRIES}); a pass on retry is reported as WARN
  --settle SEC       pause between ports in test (default: ${SETTLE})
  --fps N            framerate in live caps (default: ${FPS})
  --outdir DIR       where check-frame writes camN.uyvy / camN.jpg (default: ${OUTDIR})
  --display :N       X display to use (default: auto-detect)
  --xauth FILE       XAUTHORITY file (default: auto-detect)
  --live-size WxH    live window size (default: half the capture size)
  --detach           live: keep running after SSH closes (stop with: $0 stop)
  --dry-run          print commands, do not run them
EOF
}
bad_arg() { usage >&2; printf '\nInvalid argument: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    all|formats|test|check-frame|live|stop) CMD="$1"; shift ;;
    --ports)     [ $# -ge 2 ] || bad_arg "$1"; PORTS_OPT="$2"; shift 2 ;;
    --ports=*)   PORTS_OPT="${1#*=}"; shift ;;
    --mode)      [ $# -ge 2 ] || bad_arg "$1"; MODE_OPT="$2"; shift 2 ;;
    --mode=*)    MODE_OPT="${1#*=}"; shift ;;
    --camera)    [ $# -ge 2 ] || bad_arg "$1"; CAMERA="$2"; shift 2 ;;
    --camera=*)  CAMERA="${1#*=}"; shift ;;
    --count)     [ $# -ge 2 ] || bad_arg "$1"; COUNT="$2"; shift 2 ;;
    --min-fps)   [ $# -ge 2 ] || bad_arg "$1"; MIN_FPS="$2"; shift 2 ;;
    --timeout)   [ $# -ge 2 ] || bad_arg "$1"; TIMEOUT="$2"; shift 2 ;;
    --retries)   [ $# -ge 2 ] || bad_arg "$1"; RETRIES="$2"; shift 2 ;;
    --settle)    [ $# -ge 2 ] || bad_arg "$1"; SETTLE="$2"; shift 2 ;;
    --fps)       [ $# -ge 2 ] || bad_arg "$1"; FPS="$2"; shift 2 ;;
    --outdir)    [ $# -ge 2 ] || bad_arg "$1"; OUTDIR="$2"; shift 2 ;;
    --display)   [ $# -ge 2 ] || bad_arg "$1"; DISPLAY_OPT="$2"; shift 2 ;;
    --xauth)     [ $# -ge 2 ] || bad_arg "$1"; XAUTH_OPT="$2"; shift 2 ;;
    --live-size) [ $# -ge 2 ] || bad_arg "$1"; LIVE_SIZE="$2"; shift 2 ;;
    --detach)    DETACH=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           bad_arg "$1" ;;
  esac
done
[ -z "$PORTS_OPT" ] || [[ "$PORTS_OPT" =~ ^[0-9]+(,[0-9]+)*$ ]] || bad_arg "--ports $PORTS_OPT"
[ -z "$MODE_OPT" ]  || [[ "$MODE_OPT" =~ ^[0-4]$ ]] || bad_arg "--mode $MODE_OPT (0-4)"
{ [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; } || bad_arg "--count $COUNT"
[[ "$MIN_FPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || bad_arg "--min-fps $MIN_FPS"
[[ "$FPS" =~ ^[0-9]+$ ]] || bad_arg "--fps $FPS"
{ [[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -gt 0 ]; } || bad_arg "--timeout $TIMEOUT"
[[ "$RETRIES" =~ ^[0-9]+$ ]] || bad_arg "--retries $RETRIES"
[[ "$SETTLE" =~ ^[0-9]+$ ]] || bad_arg "--settle $SETTLE"
[ -z "$LIVE_SIZE" ] || [[ "$LIVE_SIZE" =~ ^[0-9]+x[0-9]+$ ]] || bad_arg "--live-size $LIVE_SIZE (e.g. 960x768)"
[ -z "$DISPLAY_OPT" ] || [[ "$DISPLAY_OPT" =~ ^:[0-9]+(\.[0-9]+)?$ ]] || bad_arg "--display $DISPLAY_OPT (e.g. :1)"

# =============================================================================
PORTS=""
detect_ports() {
  if [ -n "$PORTS_OPT" ]; then PORTS="${PORTS_OPT//,/ }"; ok "Using ports from --ports: ${PORTS}"; return 0; fi
  PORTS="$(detected_ports_from "$(dmesg_all)")"
  if [ -n "$PORTS" ]; then
    ok "Cameras detected (dmesg): port(s) ${PORTS}"
  elif [ "$DRY_RUN" -eq 1 ]; then
    warn "No \"been detected!\" in dmesg (dry run: assuming port 0)"; PORTS="0"
  else
    die "No \"been detected!\" ports in dmesg" "Run ./setup.sh step2 until it passes, or pass --ports"
  fi
}

# read the port's sensor_mode and set W H; returns 1 if it does not match --mode
W=0; H=0
resolve_res() {
  local dev="$1" cur res
  if [ "$DRY_RUN" -eq 1 ] && [ ! -e "$dev" ]; then cur=""; else
    cur="$(v4l2-ctl -d "$dev" --get-ctrl sensor_mode 2>/dev/null | awk -F': *' '{print $2}')"; fi
  if [ -n "$MODE_OPT" ] && [ -n "$cur" ] && [ "$cur" != "$MODE_OPT" ]; then
    fail "${dev}: current sensor_mode=${cur} does not match --mode ${MODE_OPT}"
    info "Fix: ./setup.sh step2 --mode ${MODE_OPT}   (capturing without the right sensor_mode causes uncorr_err timeouts)"
    return 1
  fi
  res="$(mode_res "${MODE_OPT:-${cur:-1}}")"
  [ -z "$cur" ] && [ "$DRY_RUN" -eq 0 ] && warn "${dev}: could not read sensor_mode, assuming ${MODE_OPT:-1}"
  W="${res% *}"; H="${res#* }"
  return 0
}
need_dev() {
  [ -e "$1" ] && return 0
  [ "$DRY_RUN" -eq 1 ] && { warn "$1 not found (dry run: continuing)"; return 0; }
  fail "$1 not found"; info "Available: $(compgen -G '/dev/video*' | tr '\n' ' ')"; return 1
}

# =============================================================================
do_formats() {
  local p dev out has1600=0
  for p in $PORTS; do
    dev="/dev/video${p}"; need_dev "$dev" || continue
    if [ "$DRY_RUN" -eq 1 ] && [ ! -e "$dev" ]; then run v4l2-ctl -d "$dev" --list-formats-ext; continue; fi
    out="$(v4l2-ctl -d "$dev" --list-formats-ext 2>&1)" || { fail "${dev}: cannot list formats"; continue; }
    info "--- ${dev}"
    printf '%s\n' "$out" | grep -E "Size:|\[[0-9]+\]" | sed 's/^[[:space:]]*/           /'
    printf '%s\n' "$out" | grep -q '1600x1300' && has1600=1
  done
  info "Driver sensor_mode: 0=1920x1080 1=1920x1536 2=2880x1860 3=3840x2160 4=1280x720"
  if [ -n "$CAMERA" ] && [[ "${CAMERA^^}" == *DMSBBFAN* ]]; then
    if [ "$has1600" -eq 0 ]; then
      warn "Camera set to DMSBBFAN (OV02311, 1600x1300 mono) but the driver does not offer 1600x1300"
      info "This YUV package may not be the DMSBBFAN build, or the connected camera is another model."
      info "Check the label on the camera and the ..._DMSBBFAN_... folder in SENSING's GitHub."
      step_warn "1600x1300 missing for DMSBBFAN"; return 0
    fi
    ok "Driver offers 1600x1300 (matches DMSBBFAN)"
  elif [ -z "$CAMERA" ]; then
    info "(camera model not set - use --camera DMSBBFAN to check for 1600x1300)"
  fi
  step_done "formats listed"
}

# =============================================================================
# one capture attempt on DEV; sets A_RC A_FPS A_FRAMES A_REASON A_NEWERR A_OUT
A_RC=0; A_FPS=""; A_FRAMES=0; A_REASON=""; A_NEWERR=0; A_OUT=""
capture_attempt() {
  local dev="$1" base after
  base="$(uncorr_count)"
  A_OUT="$(timeout "$TIMEOUT" v4l2-ctl -d "$dev" --set-fmt-video="width=${W},height=${H},pixelformat=UYVY" \
            --stream-mmap --stream-count="$COUNT" 2>&1)"; A_RC=$?
  after="$(uncorr_count)"; A_NEWERR=$((after - base))
  A_FPS="$(printf '%s' "$A_OUT" | tr '\r' '\n' | grep -oE '[0-9]+(\.[0-9]+)? fps' | tail -n1 | awk '{print $1}')"
  A_FRAMES="$(printf '%s' "$A_OUT" | tr -cd '<' | wc -c)"
  A_REASON=""
  [ "$A_RC" -eq 124 ] && A_REASON="timed out after ${TIMEOUT} s (${A_FRAMES}/${COUNT} frames received)"
  [ -z "$A_REASON" ] && [ "$A_RC" -ne 0 ] && A_REASON="v4l2-ctl exited with ${A_RC}: $(printf '%s' "$A_OUT" | grep -iE 'error|busy|fail' | head -n1)"
  [ -z "$A_REASON" ] && [ "$A_FRAMES" -lt "$COUNT" ] && A_REASON="got ${A_FRAMES}/${COUNT} frames"
  [ -z "$A_REASON" ] && [ -n "$A_FPS" ] && awk -v a="$A_FPS" -v b="$MIN_FPS" 'BEGIN{exit !(a<b)}' && A_REASON="fps ${A_FPS} below ${MIN_FPS}"
  [ -z "$A_REASON" ] && [ "$A_NEWERR" -gt 0 ] && A_REASON="${A_NEWERR} new uncorr_err line(s) in dmesg"
  [ -z "$A_REASON" ]
}
show_kernel_hints() {   # recent camera-related kernel messages, to diagnose a failed capture
  local lines
  lines="$(dmesg_all | tail -n 80 | grep -iE 'uncorr|timed out|timeout|csi|camrtc|capture|vi[0-9 ]|sgx|max96712|der-?[0-9]|i2c-w' | tail -n 12)"
  if [ -n "$lines" ]; then info "Recent kernel messages:"; printf '%s\n' "$lines" | sed 's/^/           /'
  else info "No related kernel messages (no uncorr_err): the stream started but no frame arrived"; fi
}
do_test() {
  info "${COUNT} frames per port, timeout ${TIMEOUT} s, pass if fps >= ${MIN_FPS} and no new uncorr_err (${RETRIES} retry after a timeout)"
  local p dev attempt n_pass=0 n_fail=0 n_retry=0 results=() first=1
  for p in $PORTS; do
    dev="/dev/video${p}"
    need_dev "$dev" || { n_fail=$((n_fail + 1)); continue; }
    resolve_res "$dev" || { n_fail=$((n_fail + 1)); continue; }
    if [ "$DRY_RUN" -eq 1 ]; then
      run timeout "$TIMEOUT" v4l2-ctl -d "$dev" --set-fmt-video="width=${W},height=${H},pixelformat=UYVY" --stream-mmap --stream-count="$COUNT"
      continue
    fi
    # let the previous camera's stream shut down completely before the next one starts
    if [ "$first" -eq 0 ] && [ "$SETTLE" -gt 0 ]; then info "(pausing ${SETTLE} s between cameras)"; sleep "$SETTLE"; fi
    first=0
    info "--- ${dev} (${W}x${H} UYVY)"
    attempt=0
    while :; do
      capture_attempt "$dev" && break
      [ "$A_RC" -eq 124 ] && [ "$attempt" -lt "$RETRIES" ] || break
      attempt=$((attempt + 1))
      warn "${dev}: ${A_REASON} - retrying in 2 s (attempt $((attempt + 1))/$((RETRIES + 1)))"
      sleep 2
    done
    if [ -z "$A_REASON" ] && [ "$attempt" -eq 0 ]; then
      ok "${dev}: ${A_FRAMES} frames, ${A_FPS:-?} fps, no uncorr_err"; n_pass=$((n_pass + 1)); results+=("video${p}=${A_FPS:-?}fps")
    elif [ -z "$A_REASON" ]; then
      warn "${dev}: ${A_FRAMES} frames, ${A_FPS:-?} fps - but only on attempt $((attempt + 1)); the first start timed out"
      info "A stream start right after another camera was used can time out (cause not yet known)."
      n_pass=$((n_pass + 1)); n_retry=$((n_retry + 1)); results+=("video${p}=${A_FPS:-?}fps(retry)")
    else
      fail "${dev}: ${A_REASON}"; n_fail=$((n_fail + 1)); results+=("video${p}=FAIL")
      show_kernel_hints
      if [ "$A_NEWERR" -gt 0 ]; then
        info "uncorr_err usually means a skipped step: GMSLMODE, clock_config.sh or sensor_mode"
        info "Fix: ./setup.sh step2 --force-reload, then test again"
      elif [ "$A_RC" -eq 124 ]; then
        info "Timeout without uncorr_err: this camera may not be streaming. Narrow it down:"
        info "  ./setup.sh test --ports ${p}      (this camera alone)"
        info "  ./setup.sh test --ports ${p},$(tr ' ' '\n' <<<"$PORTS" | grep -vx "$p" | head -n1)   (this camera first)"
        info "Also check power/PoC and the coax cable of this camera"
      fi
      printf '%s\n' "$A_OUT" | grep -qi 'busy' && info "Device busy: stop the live view first (./setup.sh stop)"
    fi
  done
  [ "$DRY_RUN" -eq 1 ] && { step_done "dry run"; return 0; }
  info "Capture test: ${n_pass} passed (${n_retry} only after a retry), ${n_fail} failed"
  if [ "$n_fail" -eq 0 ] && [ "$n_pass" -gt 0 ]; then
    if [ "$n_retry" -gt 0 ]; then step_warn "${results[*]}"; else step_done "${results[*]}"; fi
    return 0
  fi
  die "Capture test failed (${results[*]:-no ports})" "See the messages above"
}

# =============================================================================
# analyse a UYVY frame: odd bytes = Y, even bytes = U/V.  exit 0=image 3=blank 4=all-zero(green) 2=error
analyze_frame() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
need = w * h * 2
with open(path, 'rb') as f:
    data = f.read()
if len(data) < need:
    print("         File smaller than one frame: %d/%d bytes" % (len(data), need)); sys.exit(2)
fr = data[-need:]
y, uv = fr[1::2], fr[0::2]
ymin, ymax, yn = min(y), max(y), len(set(y))
cmin, cmax, cn = min(uv), max(uv), len(set(uv))
print("         Y : min=%d max=%d unique=%d" % (ymin, ymax, yn))
print("         UV: min=%d max=%d unique=%d" % (cmin, cmax, cn))
if cmax - cmin <= 4 and 112 <= cmin <= 144:
    print("         UV constant near 128 (~%d) = looks monochrome" % cmin)
elif cmax - cmin <= 4:
    print("         UV constant at ~%d (not 128) = abnormal" % cmin)
else:
    print("         UV varies %d-%d = colour data (not a monochrome sensor)" % (cmin, cmax))
if ymax - ymin <= 4 or yn <= 4:
    if ymax <= 16 and cmax <= 16:
        print("         Result: frame is almost all zeros -> shows as solid green"); sys.exit(4)
    print("         Result: blank frame (single value)"); sys.exit(3)
print("         Result: real image"); sys.exit(0)
PY
}
save_jpg() {   # save_jpg RAW W H JPG
  if command -v gst-launch-1.0 >/dev/null 2>&1 && gst-inspect-1.0 rawvideoparse >/dev/null 2>&1; then
    gst-launch-1.0 -q filesrc location="$1" ! rawvideoparse width="$2" height="$3" format=uyvy framerate=1/1 \
      ! videoconvert ! jpegenc ! filesink location="$4" >/dev/null 2>&1 && return 0
  fi
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -loglevel error -f rawvideo -pix_fmt uyvy422 -s "${2}x${3}" -i "$1" -frames:v 1 "$4" && return 0
  fi
  return 1
}
do_check_frame() {
  command -v python3 >/dev/null 2>&1 || die "python3 not found" "sudo apt install python3"
  local p dev raw jpg rc n_fail=0 results=() ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$OUTDIR" || die "Cannot create $OUTDIR"
  for p in $PORTS; do
    dev="/dev/video${p}"; raw="${OUTDIR}/cam${p}.uyvy"; jpg="${OUTDIR}/cam${p}.jpg"
    need_dev "$dev" || { n_fail=$((n_fail + 1)); continue; }
    resolve_res "$dev" || { n_fail=$((n_fail + 1)); continue; }
    if [ "$DRY_RUN" -eq 1 ]; then
      run timeout "$TIMEOUT" v4l2-ctl -d "$dev" --set-fmt-video="width=${W},height=${H},pixelformat=UYVY" --stream-mmap --stream-skip=4 --stream-count=1 --stream-to="$raw"
      run python3 -I - "$raw" "$W" "$H"
      printf '  [dry-run] convert %s -> %s (gst rawvideoparse/jpegenc or ffmpeg)\n' "$raw" "$jpg"
      continue
    fi
    info "--- ${dev} (${W}x${H})"
    rm -f "$raw"
    # skip 4 frames (may not be stable yet), keep 1
    if ! timeout "$TIMEOUT" v4l2-ctl -d "$dev" --set-fmt-video="width=${W},height=${H},pixelformat=UYVY" \
          --stream-mmap --stream-skip=4 --stream-count=1 --stream-to="$raw" >/dev/null 2>&1; then
      fail "${dev}: frame capture failed (run './setup.sh test' for details, or './setup.sh stop' if live view is open)"
      n_fail=$((n_fail + 1)); results+=("video${p}=capture-failed"); continue
    fi
    analyze_frame "$raw" "$W" "$H"; rc=$?
    case "$rc" in
      0) ok "${dev}: real image"; results+=("video${p}=image") ;;
      3) fail "${dev}: blank frame (single value)"; n_fail=$((n_fail + 1)); results+=("video${p}=blank") ;;
      4) fail "${dev}: all-zero data (solid green) - cause unknown, try ./setup.sh step2 --force-reload"; n_fail=$((n_fail + 1)); results+=("video${p}=green") ;;
      *) fail "${dev}: could not analyse frame"; n_fail=$((n_fail + 1)); results+=("video${p}=error") ;;
    esac
    if save_jpg "$raw" "$W" "$H" "$jpg"; then
      ok "Saved ${jpg}   view from your PC:  scp ${SG4A_USER}@${ip:-<jetson-ip>}:${jpg} ."
    else
      warn "Could not convert to JPEG (no gst rawvideoparse or ffmpeg); raw frame kept at ${raw}"
    fi
  done
  [ "$DRY_RUN" -eq 1 ] && { step_done "dry run"; return 0; }
  if [ "$n_fail" -eq 0 ]; then step_done "${results[*]}"; return 0; fi
  die "Frame check failed (${results[*]:-no ports})" "See the messages above"
}

# =============================================================================
# find the X display of the monitor attached to the Jetson (not ssh -X forwarding)
LIVE_DISPLAY=""; LIVE_XAUTH=""
find_display() {
  local user uid home cands=() xauths=() d x s tester=""
  user="${SG4A_USER}"; uid="$(id -u "$user")"; home="${SG4A_HOME}"
  [ -n "$DISPLAY_OPT" ] && cands+=("$DISPLAY_OPT")
  [[ "${DISPLAY:-}" =~ ^:[0-9]+ ]] && cands+=("${DISPLAY}")       # ignore localhost:10.0 from ssh -X
  while read -r d; do [ -n "$d" ] && cands+=("$d"); done < <(who 2>/dev/null | awk -v u="$user" '$1==u { for (i=2;i<=NF;i++) if ($i ~ /^\(?:[0-9]+(\.[0-9]+)?\)?$/) { gsub(/[()]/, "", $i); print $i } }' | sort -u)
  for s in /tmp/.X11-unix/X*; do
    [ -S "$s" ] && [ "$(stat -c %U "$s" 2>/dev/null)" = "$user" ] && cands+=(":${s##*/X}")
  done
  for s in /tmp/.X11-unix/X*; do [ -S "$s" ] && cands+=(":${s##*/X}"); done
  [ -n "$XAUTH_OPT" ] && xauths+=("$XAUTH_OPT")
  xauths+=("/run/user/${uid}/gdm/Xauthority" "${home}/.Xauthority")
  [ -n "${XAUTHORITY:-}" ] && xauths+=("$XAUTHORITY")
  command -v xdpyinfo >/dev/null 2>&1 && tester="xdpyinfo"
  [ -z "$tester" ] && command -v xset >/dev/null 2>&1 && tester="xset q"
  for d in "${cands[@]}"; do
    for x in "${xauths[@]}"; do
      [ -r "$x" ] || continue
      if [ -z "$tester" ]; then LIVE_DISPLAY="$d"; LIVE_XAUTH="$x"; return 0; fi
      # shellcheck disable=SC2086
      if DISPLAY="$d" XAUTHORITY="$x" $tester >/dev/null 2>&1; then LIVE_DISPLAY="$d"; LIVE_XAUTH="$x"; return 0; fi
    done
  done
  return 1
}
LIVE_PIDS=()
# shellcheck disable=SC2329  # called via trap
cleanup_live() {
  [ ${#LIVE_PIDS[@]} -gt 0 ] && kill "${LIVE_PIDS[@]}" 2>/dev/null
  printf '\nLive view closed.\n'
  exit 0
}
do_live() {
  local e p dev lw lh log pid started=0 i=0 total ubase=0 bad=0 cur
  # --- step 2: display
  step_begin 2
  if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
    [ "$DRY_RUN" -eq 1 ] || die "gst-launch-1.0 not found" "sudo apt install gstreamer1.0-tools"
    warn "gst-launch-1.0 not found (dry run: continuing)"
  fi
  for e in v4l2src fpsdisplaysink xvimagesink videoscale videoconvert; do
    [ "$DRY_RUN" -eq 1 ] && ! command -v gst-inspect-1.0 >/dev/null 2>&1 && break
    gst-inspect-1.0 "$e" >/dev/null 2>&1 || die "GStreamer element missing: $e" "Install gstreamer1.0-plugins-base/-good/-bad"
  done
  if find_display; then
    ok "Display: DISPLAY=${LIVE_DISPLAY}  XAUTHORITY=${LIVE_XAUTH}"
  elif [ "$DRY_RUN" -eq 1 ]; then
    warn "No display found (dry run: assuming :1)"; LIVE_DISPLAY=":1"; LIVE_XAUTH="/run/user/$(id -u)/gdm/Xauthority"
  else
    die "No usable X display / XAUTHORITY found" \
        "Log in on the Jetson's own monitor (reach the desktop) and run again, or pass --display :N --xauth FILE (see: who)"
  fi
  step_done "DISPLAY=${LIVE_DISPLAY}"

  # --- step 3: start, one camera at a time, 2 s apart (starting together makes one camera time out)
  step_begin 3
  total=$(wc -w <<<"$PORTS")
  [ "$DETACH" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && trap cleanup_live INT TERM
  [ "$DRY_RUN" -eq 0 ] && ubase="$(uncorr_count)"
  for p in $PORTS; do
    i=$((i + 1)); dev="/dev/video${p}"; log="/tmp/sg4a_live_cam${p}.log"
    need_dev "$dev" || continue
    if pgrep -f "v4l2src device=${dev} " >/dev/null 2>&1; then ok "${dev}: live view already running, skipped"; continue; fi
    resolve_res "$dev" || continue
    if [ -n "$LIVE_SIZE" ]; then lw="${LIVE_SIZE%x*}"; lh="${LIVE_SIZE#*x}"; else lw=$((W / 2)); lh=$((H / 2)); fi
    local gst=(gst-launch-1.0 -v v4l2src "device=${dev}" !
               "video/x-raw,format=UYVY,width=${W},height=${H},framerate=${FPS}/1" !
               videoscale ! "video/x-raw,width=${lw},height=${lh}" ! videoconvert !
               fpsdisplaysink video-sink=xvimagesink text-overlay=true sync=false)
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  [dry-run] DISPLAY=%s XAUTHORITY=%s %s > %s 2>&1 &\n' "$LIVE_DISPLAY" "$LIVE_XAUTH" "$(printf '%q ' "${gst[@]}")" "$log"
    else
      if [ "$DETACH" -eq 1 ]; then
        DISPLAY="$LIVE_DISPLAY" XAUTHORITY="$LIVE_XAUTH" setsid nohup "${gst[@]}" >"$log" 2>&1 < /dev/null &
      else
        DISPLAY="$LIVE_DISPLAY" XAUTHORITY="$LIVE_XAUTH" "${gst[@]}" >"$log" 2>&1 &
      fi
      pid=$!; LIVE_PIDS+=("$pid")
      ok "${dev}: started (pid ${pid}, ${W}x${H} -> window ${lw}x${lh}, log ${log})"
    fi
    started=$((started + 1))
    if [ "$i" -lt "$total" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] sleep 2\n'; else sleep 2; fi
    fi
  done
  step_done "${started} new window(s)"

  # --- step 4: verify
  step_begin 4
  if [ "$DRY_RUN" -eq 1 ]; then step_done "dry run"; sg_finish DONE "dry run"; return 0; fi
  info "Waiting 6 s, then checking each stream..."
  sleep 6
  local results=()
  for p in $PORTS; do
    log="/tmp/sg4a_live_cam${p}.log"; [ -f "$log" ] || continue
    pid="$(pgrep -f "v4l2src device=/dev/video${p} " | head -n1)"
    cur="$(grep -oE 'current: [0-9.]+' "$log" | tail -n1 | awk '{print $2}')"
    if [ -n "$pid" ]; then ok "/dev/video${p}: running, latest fps ${cur:-n/a}"; results+=("video${p}=${cur:-?}fps")
    else fail "/dev/video${p}: process exited - last lines:"; tail -n 5 "$log" | sed 's/^/         /'; bad=1; results+=("video${p}=exited"); fi
  done
  if [ "$(uncorr_count)" -gt "$ubase" ]; then warn "New uncorr_err in dmesg since live view started - a camera may not be receiving frames"; bad=1; fi
  if [ "$bad" -eq 1 ]; then
    info "If not all windows show video: ./setup.sh stop, then start live again"
    step_warn "${results[*]}"; sg_finish WARN "${results[*]}"
  else
    step_done "${results[*]}"; sg_finish DONE "${results[*]}"
  fi
  if [ "$DETACH" -eq 1 ]; then
    printf '\nLive view keeps running. Stop it with:  ./setup.sh stop\n'
  else
    printf '\nPress Ctrl+C to close all windows (or run ./setup.sh stop from another terminal).\n'
    wait
  fi
}

do_stop() {
  if pgrep -x gst-launch-1.0 >/dev/null 2>&1; then
    run pkill -x gst-launch-1.0 && ok "Sent stop signal to gst-launch-1.0"
  else
    ok "No gst-launch-1.0 running"
  fi
}

# =============================================================================
if [ "$CMD" != stop ] && [ "$DRY_RUN" -eq 0 ] && ! command -v v4l2-ctl >/dev/null 2>&1; then
  printf 'v4l2-ctl not found. Install it: sudo apt install v4l-utils\n' >&2; exit 1
fi

case "$CMD" in
  stop)
    do_stop ;;
  live)
    sg_init live "LIVE VIEW - cameras on the Jetson monitor" "${STEP3_LIVE_TITLES[@]}"
    step_begin 1; detect_ports; step_done "port(s) ${PORTS}"
    do_live ;;
  formats|test|check-frame|all)
    sg_init step3 "STEP 3/3 - Camera tests (${CMD})" "${STEP3_TITLES[@]}"
    step_begin 1; detect_ports; step_done "port(s) ${PORTS}"
    if [ "$CMD" = all ] || [ "$CMD" = formats ]; then step_begin 2; do_formats; fi
    if [ "$CMD" = all ] || [ "$CMD" = test ]; then step_begin 3; do_test; fi
    if [ "$CMD" = all ] || [ "$CMD" = check-frame ]; then step_begin 4; do_check_frame; fi
    if [ "$CMD" = all ]; then
      sg_finish DONE
      if [ "$DRY_RUN" -eq 1 ]; then printf '\nDry run finished (nothing was tested).\n'
      else printf '\n%sAll camera tests passed.%s  Next: ./setup.sh live   (live view on the Jetson monitor)\n' "$C_G" "$C_0"; fi
    else
      sg_finish PARTIAL "only '${CMD}' was run"
      printf '\nRun ./setup.sh test-all (or ./setup.sh step3) for the full test.\n'
    fi
    ;;
esac
