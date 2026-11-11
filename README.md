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
│   └── step3_test_camera.sh     # tests: formats, capture/fps, frame check, live view
├── lib/common.sh                # shared: progress bar, checklist state, dry-run, prompts
├── driver/                      # SENSING driver package (binaries in Git LFS) - see driver/README.md
├── .gitattributes               # LF endings for scripts, LFS for driver binaries
├── .gitignore
└── .shellcheckrc
```


## 1. Get it on the Jetson

```bash
sudo apt install -y git git-lfs v4l-utils
git lfs install
git clone https://github.com/pppalzz03/Setup_jetson_Nano.git ~/sg4a && cd ~/sg4a
./setup.sh status
```

Update later with `git pull` (LFS files come with it). Run as your normal user, without `sudo` — the scripts call `sudo` only where needed.

## 2. Run

```bash
./setup.sh            # step 1 -> asks to reboot
sudo reboot
./setup.sh            # step 2 (needed after EVERY reboot)
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
| `./setup.sh live` / `stop` | start / stop live view |
| `./setup.sh persist [inspect\|enable-modprobe\|enable-service\|status\|revert]` | optional, untested |
| `./setup.sh reset` | forget recorded progress (state file only, system unchanged) |

### Options

| Option | Used by | Meaning |
| --- | --- | --- |
| `--pkg DIR` | step1, step2, persist | driver package (default `driver/SG4A_...`, else `~/SG4A_...`) |
| `--reinstall` | step1 | run `install.sh` again even if `/boot` matches |
| `--manual` | step1 | skip `config-by-hardware.py`, show the jetson-io menu steps |
| `--overlay-name NAME` | step1 | default `Jetson Sensing YUV GMSLx4` |
| `--gmsl A,B,C,D` | step2, persist | 0=GMSL, 1=GMSL2/6G, 2=GMSL2/3G (default `2,2,2,2`) |
| `--mode N` | step2, step3, persist | sensor_mode 0=1920×1080, **1=1920×1536**, 2=2880×1860, 3=3840×2160, 4=1280×720 |
| `--ports 0,3` | step2, step3 | override auto-detected ports |
| `--force-reload` | step2 | reload the module even if GMSLMODE is already right |
| `--wait SEC` | step2 | detection wait after insmod (default 20) |
| `--camera NAME` | step3 | e.g. `DMSBBFAN` → warns if 1600×1300 is missing |
| `--count N`, `--min-fps F` | step3 test | default 100 frames, pass at ≥ 25 fps |
| `--outdir DIR` | step3 check-frame | default `/tmp` (`camN.jpg`, `camN.uyvy`) |
| `--display :N`, `--xauth FILE` | live | default: auto-detect (`who`, `/tmp/.X11-unix`, `/run/user/UID/gdm/Xauthority`) |
| `--live-size WxH`, `--fps N`, `--detach` | live | window size (default half), caps fps (30), keep running after SSH exits |
| `--dry-run` | all | print commands, change nothing, record nothing |

## What you should see

```
[##########----------]  50%  Step 4/6: Check camera detection in dmesg
  [ OK ] dmesg: ###GMSLMODE=2, 2, 2, 2###
  [ OK ] Cameras detected on port(s): 0 3
  DONE   Step 4/6 [#############-------]  66%  port(s): 0 3
```

* **step1** – all DONE; step 5 ends with `extlinux.conf: DEFAULT JetsonIO and OVERLAYS /boot/tegra234-camera-yuv-gmslx4-overlay.dtbo`; asks `Reboot now? [y/N]`.
* **step2** – `###GMSLMODE=2, 2, 2, 2###`, `Cameras detected on port(s): 0 3`, `/dev/video0: bypass_mode=0, sensor_mode=1`.
* **step3** – `/dev/video0: 100 frames, 30.00 fps, no uncorr_err`, `Result: real image`, `Saved /tmp/cam0.jpg  view from your PC: scp ...`.
* **live** – one window per camera, started 2 s apart, then `running, latest fps 30.xx`.

Problems the scripts recognise (from the bring-up notes):

| Message | Cause → fix shown by the script |
| --- | --- |
| `i2c-w, write failed` / `can't find DER adapt broad` | MIPI cable on the wrong connector → move it to 22-pin CAM1 |
| `detect error` on every port with GMSLMODE containing 0 | wrong serializer type → `--gmsl 2,2,2,2` |
| `uncorr_err: request timed out` | skipped GMSLMODE / clock_config.sh / sensor_mode → `./setup.sh step2 --force-reload` |
| `/dev/media0` missing | overlay not active → finish step1 and reboot |
| programs using `/dev/video*` | shown with `fuser -v`, script stops (never `rmmod -f`) |
| `Git LFS pointer files` | `sudo apt install git-lfs && git lfs pull` |

## Safety rules built in

* never `insmod -f` / `rmmod -f`; never writes to MAX96712 with `i2ctransfer`; never interprets MAX96712 registers
* never reboots, edits `extlinux.conf` or runs `jetson-io.py` without asking; backs up `extlinux.conf` (`.bak` + `.bak-<time>`) and the old `/boot/Image` first
* unconfirmed items (persistence after reboot) live in `step2b_persist.sh`, off until you run and confirm them

Progress is stored in `~/.local/state/sg4a/state` (not in the repo).

## Not yet verified on a real Jetson

Tested with `bash -n`, `shellcheck` (clean) and a mock Jetson (stubbed dmesg / lsmod / insmod / v4l2-ctl / gst-launch / jetson-io) covering: full flow with reboot, wrong connector, GMSLMODE 0, busy device, uncorr_err, all-zero frame, re-runs, Ctrl+C. Still to confirm on hardware:

1. `config-by-hardware.py -l` output format and the overlay name (falls back to the jetson-io menu)
2. `install.sh` behaviour, and that `Image` / `.dtbo` sit inside the package (`cmp` against `/boot`)
3. exact dmesg wording (`###GMSLMODE=…###`, `port N camera … been detected!`) — use `--ports` if detection misses
4. port N ↔ `/dev/videoN` (seen only for ports 0 and 3)
5. readability of `/sys/module/sgx_yuv_gmsl2/parameters/GMSLMODE_1` (falls back to dmesg)
6. detection time after insmod (`--wait`)
7. JPEG conversion via GStreamer `rawvideoparse` or `ffmpeg`
8. `fpsdisplaysink` printing `current: …` with `gst-launch-1.0 -v`
9. both persistence methods in `step2b_persist.sh` — run `./setup.sh persist inspect` first
10. never tested in the original bring-up: DMSBBFAN model, solid-green frame cause, sensor modes other than 1, more than 2 cameras, combined single-window view
