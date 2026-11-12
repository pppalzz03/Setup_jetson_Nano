# SG4A GMSL2 camera setup — Jetson Orin Nano

Scripts to bring up SENSING GMSL2 cameras through the **SG4A-NONX-G2Y-A1** (MAX96712) board on a
**Jetson Orin Nano Devkit, JetPack 6.2 / L4T R36.4.3, kernel 5.15.148-tegra**, MIPI cable on **22-pin CAM1**.
Every step shows progress in %, a DONE / SKIP / WARN / FAIL checklist, and remembers what is finished across reboots.

## Repository layout

```
.
├── setup.sh                     # single entry point: runs the next needed step, or `status`
├── scripts/
│   ├── step1_before_reboot.sh   # one time: install driver, select overlay, ask to reboot
│   ├── step2_after_reboot.sh    # every boot: GMSLMODE reload, clocks, sensor_mode
│   ├── step2b_persist.sh        # optional, untested: keep GMSLMODE after reboot
│   ├── step3_test_camera.sh     # tests: formats, capture/fps, frame check, live view
│   └── diag_link.sh             # finds which action makes the camera link disappear
├── lib/common.sh                # shared: progress bar, checklist state, dry-run, prompts
├── driver/                      # SENSING driver package (binaries in Git LFS) - see driver/README.md
├── .gitattributes               # LF endings for scripts, LFS for driver binaries
├── .gitignore
└── .shellcheckrc
```

## 1. Prepare the repo (on your Mac, once)

```bash
cd ~/Documents/Setup_jetson_Nano
brew install git-lfs && git lfs install
git init -b main
# copy the extracted package into driver/ (folder name must match):
#   driver/SG4A_NONX_G2Y_A1_ORIN_NANO_YUV_JP6.2_L4TR36.4.3/
git add .gitattributes && git add .
git update-index --chmod=+x setup.sh scripts/*.sh
git lfs ls-files            # should list Image, *.ko, *.dtbo ... (not the .sh files)
git commit -m "SG4A camera setup scripts + driver package"
git remote add origin git@github.com:<you>/<repo>.git    # use a PRIVATE repo
git push -u origin main
```

## 2. Get it on the Jetson

Prerequisites (one time):

```bash
sudo apt install -y git git-lfs v4l-utils i2c-tools
sudo apt install -y nvidia-l4t-gstreamer     # provides the hardware scaler `nvvidconv` (needed for live view, see below)
sudo apt install -y xdotool                  # optional: tiles the live windows in a grid
rm -f ~/.cache/gstreamer-1.0/registry*.bin   # refresh the GStreamer plugin cache after installing
git lfs install
git clone https://github.com/<you>/<repo>.git ~/sg4a && cd ~/sg4a
./setup.sh status
```

Update later with `git pull` (LFS files come with it). Run as your normal user, without `sudo` — the scripts call `sudo` only where needed.

> **Do not run `sudo apt upgrade` / `dist-upgrade` on the `nvidia-l4t-*` packages.** The kernel and device-tree packages
> can overwrite the `Image` and `.dtbo` that step 1 installed from the SENSING package, and the cameras will disappear.
> Install only what is listed above. (If you must upgrade, hold the kernel packages first: see `dpkg -l | grep nvidia-l4t-kernel`.)
> Note: `nvidia-l4t-gstreamer` installed from the NVIDIA repo may be a newer minor version (e.g. 36.4.7) than the rest of the
> system (36.4.3); no problem was seen with this, but it is a mixed state.

## 3. Run

```bash
./setup.sh            # step 1 -> asks to reboot
sudo reboot
./setup.sh            # step 2 (needed after EVERY boot)
./setup.sh            # step 3 camera tests
./setup.sh live       # live view on the Jetson monitor (Ctrl+C or ./setup.sh stop)
./setup.sh status     # checklist + overall %
```

Add `--dry-run` to any command to see what it would do without changing anything.

| Command | What it does |
| --- | --- |
| `./setup.sh` | runs the next needed step (step1 → reboot → step2 → step3) |
| `./setup.sh status` | overall progress and per-step checklist (step 2/3 show `REDO` after a reboot) |
| `./setup.sh step1` / `step2` / `step3` | run one step |
| `./setup.sh test` / `check-frame` / `formats` | run one camera test |
| `./setup.sh live` / `stop` | start / stop live view (refuses to start if step 2 has not passed in this boot; `--force` overrides) |
| `./setup.sh diag-link [--rounds N]` | find which action makes the camera link disappear (see Troubleshooting) |
| `./setup.sh persist [inspect\|enable-modprobe\|enable-service\|status\|revert]` | optional, untested |
| `./setup.sh reset` | forget recorded progress (state file only, system unchanged) |

### Options

| Option | Used by | Meaning |
| --- | --- | --- |
| `--pkg DIR` | step1, step2, persist | driver package (default `driver/SG4A_...`, else `~/SG4A_...`) |
| `--reinstall` | step1 | run `install.sh` again even if `/boot` matches |
| `--manual` | step1 | skip `config-by-hardware.py`, show the jetson-io menu steps |
| `--overlay-name NAME` | step1 | default `Jetson Sensing YUV GMSLx4` |
| `--gmsl A,B,C,D` | step2, persist | 0=GMSL, 1=GMSL2/6G, 2=GMSL2/3G (default `2,2,2,2`, which worked on this hardware) |
| `--mode N` | step2, step3, persist | sensor_mode 0=1920×1080, **1=1920×1536**, 2=2880×1860, 3=3840×2160, 4=1280×720 |
| `--ports 2,3` | step2, step3 | override auto-detected ports |
| `--force-reload` | step2 | reload the camera module even if GMSLMODE is already right |
| `--reload-der` | step2 | also reload `max96712.ko` (done automatically when the chip shows `6b` instead of `UU`) |
| `--wait SEC` | step2 | detection wait after insmod (default 20) |
| `--camera NAME` | step3 | e.g. `DMSBBFAN` → warns if 1600×1300 is missing |
| `--count N`, `--min-fps F` | step3 test, live | default 100 frames; pass at ≥ 25 fps |
| `--timeout SEC`, `--retries N`, `--settle SEC` | step3 test | capture timeout (15), retries after a timeout (1), pause between cameras (2) |
| `--expect N` | step3 | number of cameras you expect (env `SG4A_EXPECT_CAMERAS`, default 0 = no check); reports missing ports |
| `--outdir DIR` | step3 check-frame | default `/tmp` (`camN.jpg`, `camN.uyvy`) |
| `--display :N`, `--xauth FILE` | live | default: auto-detect (`who`, `/tmp/.X11-unix`, `/run/user/UID/gdm/Xauthority`) |
| `--scaler auto\|cpu\|nvvidconv` | live | default `auto` = `nvvidconv` if installed, else CPU (slow, see below) |
| `--live-size WxH`, `--fps N`, `--detach`, `--force` | live | window size (default half; one third for 3-4 cameras), caps fps (30), keep running after SSH exits, skip the step-2 check |
| `--rounds N`, `--live-secs SEC` | diag-link | repeat the sequence, live duration per round |
| `--dry-run` | all | print commands, change nothing, record nothing |

## What you should see

```
[##########----------]  50%  Step 4/6: Check camera detection in dmesg
  [ OK ] dmesg: ###GMSLMODE=2, 2, 2, 2###
  [ OK ] Cameras detected on port(s): 2 3
         Link values: port0=0x12 port1=0x00 port2=0xc8 port3=0xc8   (0xc8 = camera linked)
  DONE   Step 4/6 [#############-------]  66%  port(s): 2 3
```

* **step1** – all DONE; step 5 ends with `extlinux.conf: DEFAULT JetsonIO and OVERLAYS /boot/tegra234-camera-yuv-gmslx4-overlay.dtbo`; asks `Reboot now? [y/N]`.
* **step2** – `###GMSLMODE=2, 2, 2, 2###`, `Cameras detected on port(s): …`, `/dev/videoN: bypass_mode=0, sensor_mode=1`. The ports follow where the cameras are plugged (here 2 and 3).
* **step3** – `/dev/videoN: 100 frames, 30.00 fps, no uncorr_err`, `Result: real image`, `Saved /tmp/camN.jpg  view from your PC: scp ...`.
* **live** – one window per camera, started 2 s apart, then `average 30 fps (now 30)` per camera.

### Measured on the Jetson (2 cameras, 1920×1536 UYVY)

| What | Result |
| --- | --- |
| `v4l2-ctl` capture, each camera | 30.00 fps, no `uncorr_err` |
| `check-frame` | real image from both cameras (Y 0–255, UV varies) |
| live view, **CPU scaling** (`videoscale ! videoconvert`) | ~6 fps per camera — too slow, same with 1 or 2 cameras (the limit is per pipeline, not total CPU) |
| live view, **`nvvidconv`** | ~30 fps per camera |

So install `nvidia-l4t-gstreamer`; live uses `nvvidconv` automatically when it exists and warns when it does not.
The fps shown is the `average` printed by `fpsdisplaysink`; the instantaneous `current` value can spike and is shown only for reference.

## Troubleshooting

| Message | Cause → fix shown by the script |
| --- | --- |
| `i2c-w, write failed` / `can't find DER adapt broad` | MIPI cable on the wrong connector → move it to 22-pin CAM1. An *old* line with a chip that answers now is only a warning |
| chip shows `6b` instead of `UU` with `max96712` loaded | the driver is not bound to the chip → step 2 reloads `max96712` automatically (`--reload-der`) |
| `detect error` on every port, GMSLMODE contains 0 | wrong serializer type → `--gmsl 2,2,2,2` |
| `detect error` on every port, GMSLMODE=2,2,2,2 | **the cameras are not linking** (see "Lost camera link" below) |
| `uncorr_err: request timed out` | another camera works → the link of this camera is lost; none works → run `./setup.sh step2` or power-cycle |
| live: `running but NO frames` | same fault as a failed capture test on that port |
| `/dev/media0` missing | overlay not active → finish step1 and reboot |
| programs using `/dev/video*` | shown with `fuser -v`, script stops (never `rmmod -f`) |
| `Git LFS pointer files` | `sudo apt install git-lfs && git lfs pull` |
| `GStreamer element nvvidconv not found` | `sudo apt install nvidia-l4t-gstreamer` (and refresh the plugin cache, see section 2) |

### Lost camera link

What was observed on this hardware, in three separate episodes:

* One camera was detected but delivered **0 frames** (`uncorr_err: request timed out after 2500 ms` repeating), later
  every port showed `detect error`.
* `dser_link_check link:` values in dmesg told the states apart: **`0xc8`** = camera detected and streaming, **`0x00`** =
  nothing linked, `0x02` / `0x12` / `0x16` = no usable link. (The meaning of the register is not documented here;
  this is only what correlated with working and non-working cameras.)
* Reloading the drivers (`--force-reload`, `--reload-der`) and rebooting only the Jetson did **not** bring the link back.
  **Powering off the Jetson and the SG4A board (unplug 12 V for ~10 s), checking the coax connectors, and powering on did.**
* After the full power cycle, test, live (with and without `nvvidconv`), check-frame and `step2 --force-reload` all kept the
  link. What made it disappear earlier is **not known**.

Recovery: power off the Jetson **and** the SG4A board for ~10 s, reseat the coax cables at both ends, power on, `./setup.sh step2`.

To find the trigger, right after such a recovery run:

```bash
./setup.sh step2
./setup.sh diag-link --rounds 3
```

It runs test → live → check-frame, reloads the camera driver after each action and prints a table of detected ports and link
values. The first action after which the cameras vanish is the suspect. Send that table and `sudo dmesg | tail -n 120`.

## Safety rules built in

* never `insmod -f` / `rmmod -f`; never writes to MAX96712 with `i2ctransfer`; never interprets MAX96712 registers
* never reboots, edits `extlinux.conf` or runs `jetson-io.py` without asking; backs up `extlinux.conf` (`.bak` + `.bak-<time>`) and the old `/boot/Image` first
* unconfirmed items (persistence after reboot) live in `step2b_persist.sh`, off until you run and confirm them

Progress is stored in `~/.local/state/sg4a/state` (not in the repo).

## Verification status

Tested with `bash -n`, `shellcheck` (clean) and a mock Jetson (stubbed dmesg / lsmod / insmod / v4l2-ctl / gst-launch / gst-inspect / jetson-io).

**Confirmed on a real Jetson Orin Nano (JetPack 6.2):** step 1 (including the `/boot` verification), step 2 detection and
`sensor_mode`, port N ↔ `/dev/videoN` for ports 0, 2 and 3, 30 fps capture at 1920×1536 UYVY from two cameras, real images from
`check-frame`, live view at ~30 fps per camera with `nvvidconv` (~6 fps with CPU scaling), recovery by a full power cycle.

**Not yet verified:**

1. more than 2 cameras at once (the 4-camera window grid and fps with `nvvidconv` for 4 streams)
2. whether the cameras stay detected after rebooting only the Jetson (step 2 is needed after every boot anyway)
3. the cause of the lost link, and long-running (soak) stability — use `./setup.sh diag-link`
4. both persistence methods in `step2b_persist.sh` — run `./setup.sh persist inspect` first
5. the new automatic `max96712` reload when the chip shows `6b` (tested only with stubs)
6. the DMSBBFAN model, the cause of a solid-green frame, sensor modes other than 1, and a combined single-window view
7. window tiling with `xdotool` (only a stub was tested)

## Hot-plug reconnect (GMSL2)

Unplugging a coax cable powers the camera off (PoC). The GMSL2 link relocks by itself when it is
plugged back in, but the serializer/sensor configuration done at driver probe is lost, so video
stays frozen until the camera driver (`sgx_yuv_gmsl2`) is reloaded. `scripts/hotplug_watch.py`
automates this: it polls the MAX96712 lock bits (read-only I2C reads), and after a link change that
has been stable for a few seconds it releases the cameras, runs `step2 --force-reload`, verifies
`/dev/videoN` and lets the application reopen them.

**1. Verify the register map on your board first** (values below are from the SG4A/Orin Nano setup:
I2C bus 9, address 0x6b, lock regs port0..3 = 0x1a, 0x0a, 0x0b, 0x0c, bit 0x08):

    ./setup.sh hotplug once        # run while plugging / unplugging each camera; the "lock" column must follow

Another board (Orin NX, Nano 4-camera, other carrier) may differ: use `--bus`, `--addr`,
`--lock-regs 0:0x1a,1:0x0a,2:0x0b,3:0x0c` and `--lock-mask`.

**2. Monitor mode (default, changes nothing)**:

    ./setup.sh hotplug watch       # logs LOST / LOCKED events and what recovery would do

**3. Enable recovery** once the events match reality:

    ./setup.sh hotplug watch --enable-recovery        # foreground test
    ./setup.sh hotplug install --enable-recovery      # systemd service (sg4a-hotplug), starts at boot
    ./setup.sh hotplug status | uninstall

**Coordination protocol.** The watcher creates the signal file `/run/sg4a/camera-reload`
(override: env `SG4A_HOTPLUG_FLAG`) containing JSON `{ports, reason, pid, started}`. Applications
must close their GMSL pipelines while it exists and reopen them after it is removed (BlackBox's
`GMSLCameraDriver` does this). The watcher never kills processes: if `/dev/video*` is still in use
after 20 s it aborts, removes the file and retries later (up to 3 times, 15 s apart).

**Tested on the SG4A / Orin Nano board** (cameras moved between ports 0-3 while the watcher ran): a link
loss is detected within 1 s, and 3 s after the lock is stable the cameras are released, step 2 reloads the
driver (~5 s) and the application reopens them. A locked link does not prove the camera streams: port 1
once showed lock (0xc8) but delivered 0 frames and `uncorr_err` every 2.5 s; check with `./setup.sh test --ports N`.
If a link is lost for unknown reasons only a full power cycle of the Jetson and the SG4A board restores it.

**Limits.** All GMSL cameras are released together (the driver probe rewrites link settings for
every port, so per-port reconnect is not possible), so every camera pauses for ~5 s during a reload.
The recovery only checks that the lock and /dev/videoN come back, not that frames flow.
