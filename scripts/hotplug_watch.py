#!/usr/bin/env python3
"""Hot-plug watcher for GMSL2 cameras behind a MAX96712 (SENSING SG4A).

What it does
------------
* Reads the "link locked" bit of every MAX96712 port once per second (read-only
  ``i2ctransfer``; it never writes a register).
* Logs when a cable is lost / a camera appears.
* When the lock has changed and then stayed stable, it can recover the cameras:
  a signal file asks the applications to release ``/dev/video*``, the camera driver
  is reloaded with ``step2_after_reboot.sh --force-reload`` (which also sets clocks and
  sensor_mode), and the signal file is removed so the applications reopen the cameras.

Why a reload is needed: unplugging a camera powers it off (PoC). The serializer and the
sensor lose what the driver configured when it probed, and the driver does not know. The
GMSL2 link itself locks again by itself.

Safety
------
* Recovery is OFF unless ``--enable-recovery`` is given; without it the watcher only logs
  what it would do (monitor mode). Use that first to confirm that the lock bits really
  follow your cable (unplug / plug one camera and watch the log).
* No process is ever killed and ``rmmod -f`` is never used. If something still holds
  /dev/video* after --release-timeout seconds, the attempt is aborted and retried later.
* The register defaults (bus 9, address 0x6b, lock registers 0x1a/0x0a/0x0b/0x0c, bit 0x08)
  come from a different Jetson with the same chip. They are consistent with the
  ``dser_link_check link:0xc8`` values this board prints, but confirm them with
  ``--once`` while plugging and unplugging a camera.

Usage (run as root: i2c and module loading need it; ``./setup.sh hotplug`` does this)
    hotplug_watch.py --once                 # print the lock state of every port and exit
    hotplug_watch.py                        # monitor only (logs, no changes)
    hotplug_watch.py --enable-recovery      # monitor and recover
"""

from __future__ import annotations

import argparse
import dataclasses
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

DEFAULT_LOCK_REGS = {0: 0x1A, 1: 0x0A, 2: 0x0B, 3: 0x0C}
DEFAULT_FLAG = "/run/sg4a/camera-reload"
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_STEP2 = SCRIPT_DIR / "step2_after_reboot.sh"


class ReadError(Exception):
    """The lock registers could not be read (i2c error, tool missing, bad output)."""


@dataclasses.dataclass
class Config:
    bus: int = 9
    addr: int = 0x6B
    lock_regs: dict[int, int] = dataclasses.field(
        default_factory=lambda: dict(DEFAULT_LOCK_REGS)
    )
    lock_mask: int = 0x08
    poll: float = 1.0  # seconds between reads
    stable: float = 3.0  # lock must stay unchanged this long before a recovery
    retry: float = 15.0  # wait between failed recoveries
    max_retry: int = 3
    release_timeout: float = 20.0  # wait for applications to release /dev/video*
    settle: float = 3.0  # pause after a recovery before the new baseline is read
    step2_timeout: float = 180.0
    enable_recovery: bool = False
    flag_path: str = DEFAULT_FLAG
    step2: str = str(DEFAULT_STEP2)
    step2_args: list[str] = dataclasses.field(default_factory=list)
    step2_log: str = "/tmp/sg4a_hotplug_step2.log"  # noqa: S108 - a diagnostic log


def timestamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def log(level: str, message: str) -> None:
    print(f"{timestamp()} [{level}] {message}", flush=True)


# --------------------------------------------------------------------------- reading
def build_read_command(bus: int, addr: int, regs: dict[int, int]) -> list[str]:
    """One i2ctransfer call that READS the given 8-bit registers (16-bit addressing).

    Every message is ``w2@ADDR hi lo`` (sets the register pointer) followed by ``r1``;
    nothing here can change a register.
    """
    cmd = ["i2ctransfer", "-f", "-y", str(bus)]
    for port in sorted(regs):
        reg = regs[port]
        cmd += [f"w2@0x{addr:02x}", f"0x{reg >> 8:02x}", f"0x{reg & 0xFF:02x}", "r1"]
    assert_read_only(cmd)
    return cmd


def assert_read_only(cmd: list[str]) -> None:
    """Refuse any i2ctransfer command that is not made of (w2 pointer, r1) pairs."""
    messages = cmd[4:]  # after: i2ctransfer -f -y BUS
    if cmd[:2] != ["i2ctransfer", "-f"] or len(messages) % 4 != 0 or not messages:
        raise ValueError(f"not a read-only i2ctransfer command: {cmd}")
    for i in range(0, len(messages), 4):
        write, _hi, _lo, read = messages[i : i + 4]
        if not re.fullmatch(r"w2@0x[0-9a-f]{2}", write) or read != "r1":
            raise ValueError(f"not a read-only i2ctransfer command: {cmd}")


def parse_values(output: str, expected: int) -> list[int]:
    values = [int(token, 16) for token in re.findall(r"0x[0-9a-fA-F]{1,2}", output)]
    if len(values) != expected:
        raise ReadError(f"expected {expected} register values, got {output.strip()!r}")
    return values


class I2CLockReader:
    """Reads the lock bit of every port with a single i2ctransfer call."""

    def __init__(
        self, config: Config, runner: Callable[..., Any] = subprocess.run
    ) -> None:
        self.config = config
        self.runner = runner
        self.last_raw: dict[int, int] = {}

    def read(self) -> dict[int, bool]:
        cfg = self.config
        cmd = build_read_command(cfg.bus, cfg.addr, cfg.lock_regs)
        try:
            proc = self.runner(cmd, capture_output=True, text=True, timeout=5)
        except FileNotFoundError as exc:
            raise ReadError("i2ctransfer not found (sudo apt install i2c-tools)") from exc
        except subprocess.TimeoutExpired as exc:
            raise ReadError("i2ctransfer timed out") from exc
        if proc.returncode != 0:
            first = (proc.stderr or "").strip().splitlines()[:1]
            raise ReadError(first[0] if first else f"i2ctransfer exit {proc.returncode}")
        ports = sorted(cfg.lock_regs)
        raw = dict(zip(ports, parse_values(proc.stdout, len(ports)), strict=True))
        self.last_raw = raw
        return {port: bool(value & cfg.lock_mask) for port, value in raw.items()}


# --------------------------------------------------------------------------- helpers
def video_nodes() -> list[str]:
    return sorted(glob.glob("/dev/video*"))


def users_of(nodes: list[str], runner: Callable[..., Any] = subprocess.run) -> str:
    """``fuser -v`` text for the programs holding the nodes ("" when none/unknown)."""
    if not nodes:
        return ""
    try:
        quiet = runner(["fuser", "-s", *nodes], capture_output=True, text=True)
    except FileNotFoundError:
        return ""
    if quiet.returncode != 0:
        return ""
    verbose = runner(["fuser", "-v", *nodes], capture_output=True, text=True)
    return ((verbose.stdout or "") + (verbose.stderr or "")).strip() or "in use"


def write_flag(path: str, ports: list[int], reason: str) -> None:
    """Create the signal file atomically; applications release the cameras while it exists."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(target.parent, 0o755)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(
        json.dumps(
            {"ports": ports, "reason": reason, "pid": os.getpid(), "started": time.time()}
        )
    )
    os.chmod(tmp, 0o644)
    os.replace(tmp, target)


def remove_flag(path: str) -> None:
    try:
        Path(path).unlink()
    except FileNotFoundError:
        pass


# --------------------------------------------------------------------------- recovery
class DryRecovery:
    """Monitor mode: say what a recovery would do, change nothing."""

    def __init__(self, config: Config, logger: Callable[[str, str], None] = log) -> None:
        self.config = config
        self.log = logger

    def run(self, ports: list[int]) -> bool:
        cfg = self.config
        self.log("DRY", "recovery is OFF (monitor mode); a real recovery would:")
        self.log("DRY", f"  1. create {cfg.flag_path} so applications release the cameras")
        self.log("DRY", f"  2. wait up to {cfg.release_timeout:.0f}s until nothing holds /dev/video*")
        self.log("DRY", f"  3. run: bash {cfg.step2} --force-reload {' '.join(cfg.step2_args)}".rstrip())
        self.log("DRY", f"  4. check /dev/video nodes for ports {ports}")
        self.log("DRY", "  5. remove the signal file so applications reopen the cameras")
        self.log("DRY", "start with --enable-recovery (or ./setup.sh hotplug install --enable-recovery)")
        return True


class Recovery:
    def __init__(
        self,
        config: Config,
        runner: Callable[..., Any] = subprocess.run,
        sleep: Callable[[float], None] = time.sleep,
        now: Callable[[], float] = time.monotonic,
        nodes: Callable[[], list[str]] = video_nodes,
        exists: Callable[[str], bool] = os.path.exists,
        logger: Callable[[str, str], None] = log,
    ) -> None:
        self.config = config
        self.runner, self.sleep, self.now = runner, sleep, now
        self.nodes, self.exists, self.log = nodes, exists, logger

    def run(self, ports: list[int]) -> bool:
        cfg = self.config
        write_flag(cfg.flag_path, ports, "hotplug recovery")
        self.log("INFO", f"signal file created: {cfg.flag_path}")
        try:
            if not self._wait_until_free():
                return False
            if not self._reload():
                return False
            missing = [p for p in ports if not self.exists(f"/dev/video{p}")]
            if missing:
                self.log("ERROR", f"driver reloaded but no /dev/video node for port(s) {missing}")
                return False
            self.log("INFO", f"cameras ready on port(s) {ports}")
            return True
        finally:
            remove_flag(cfg.flag_path)
            self.log("INFO", "signal file removed (applications may reopen the cameras)")
            self.sleep(cfg.settle)

    def _wait_until_free(self) -> bool:
        deadline = self.now() + self.config.release_timeout
        while True:
            users = users_of(self.nodes(), self.runner)
            if not users:
                return True
            if self.now() >= deadline:
                self.log("ERROR", "/dev/video* is still in use, not unloading the driver:")
                for line in users.splitlines():
                    self.log("ERROR", f"    {line}")
                return False
            self.sleep(0.5)

    def _reload(self) -> bool:
        cfg = self.config
        cmd = ["bash", cfg.step2, "--force-reload", *cfg.step2_args]
        self.log("INFO", f"reloading the camera driver: {' '.join(cmd)}")
        try:
            proc = self.runner(
                cmd, capture_output=True, text=True, timeout=cfg.step2_timeout
            )
        except subprocess.TimeoutExpired:
            self.log("ERROR", f"step 2 did not finish in {cfg.step2_timeout:.0f}s")
            return False
        output = (proc.stdout or "") + (proc.stderr or "")
        try:
            Path(cfg.step2_log).write_text(output)
        except OSError:
            pass
        if proc.returncode != 0:
            self.log("ERROR", f"step 2 failed (exit {proc.returncode}); last lines (full log: {cfg.step2_log}):")
            for line in output.strip().splitlines()[-8:]:
                self.log("ERROR", f"    {line}")
            return False
        return True


# --------------------------------------------------------------------------- watcher
def describe(lock: dict[int, bool]) -> str:
    return " ".join(f"port{p}={'LOCK' if v else '----'}" for p, v in sorted(lock.items()))


class Watcher:
    def __init__(
        self,
        config: Config,
        reader: Any,
        recovery: Any,
        now: Callable[[], float] = time.monotonic,
        exists: Callable[[str], bool] = os.path.exists,
        logger: Callable[[str, str], None] = log,
    ) -> None:
        self.config, self.reader, self.recovery = config, reader, recovery
        self.now, self.exists, self.log = now, exists, logger
        self.prev: dict[int, bool] | None = None
        self.last_change = 0.0
        self.pending = False  # a port gained lock since the last recovery
        self.waiting_logged = False
        self.attempts = 0
        self.next_try = 0.0
        self.read_errors = 0
        self.dropped: set[int] = set()

    def tick(self) -> None:
        cfg, t = self.config, self.now()
        try:
            lock = self.reader.read()
        except ReadError as exc:
            self.read_errors += 1
            if self.read_errors == 1 or self.read_errors % 30 == 0:
                self.log("WARN", f"cannot read the lock registers ({self.read_errors}x): {exc}")
            return
        if self.read_errors:
            self.log("INFO", "lock registers readable again")
            self.read_errors = 0

        if self.prev is None:
            self.prev, self.last_change = lock, t
            self.log("INFO", f"baseline: {describe(lock)}")
            for port, locked in sorted(lock.items()):
                if locked and not self.exists(f"/dev/video{port}"):
                    self.log("WARN", f"port {port} is locked but /dev/video{port} is missing - run ./setup.sh step2")
            return

        for port in sorted(lock):
            was, now_locked = self.prev.get(port, False), lock[port]
            if was and not now_locked:
                self.dropped.add(port)
                self.log("EVENT", f"port {port}: link LOST (cable removed or camera off)")
            elif now_locked and not was:
                returned = " (returned)" if port in self.dropped else " (new)"
                self.log("EVENT", f"port {port}: link LOCKED{returned}")
                self.pending = True
        if lock != self.prev:
            self.last_change = t
            self.waiting_logged = False
            self.log("INFO", describe(lock))
        self.prev = lock

        if not self.pending:
            return
        if t - self.last_change < cfg.stable:
            if not self.waiting_logged:
                self.log("INFO", f"waiting {cfg.stable:.0f}s for the lock to stay stable")
                self.waiting_logged = True
            return
        if t < self.next_try:
            return
        self._recover(lock, t)

    def _recover(self, lock: dict[int, bool], t: float) -> None:
        cfg = self.config
        ports = sorted(p for p, locked in lock.items() if locked)
        self.attempts += 1
        self.log("EVENT", f"link change is stable -> recovery attempt {self.attempts}/{cfg.max_retry} for port(s) {ports}")
        if self.recovery.run(ports):
            self.log("EVENT", "recovery finished")
            self.pending, self.attempts, self.waiting_logged = False, 0, False
            self.dropped.clear()
            self.prev = None  # read a fresh baseline: reloading the driver toggles the links
            return
        if self.attempts >= cfg.max_retry:
            self.log("ERROR", f"recovery failed {self.attempts} times; giving up until the next link change")
            self.pending, self.attempts = False, 0
            return
        self.next_try = self.now() + cfg.retry
        self.log("WARN", f"recovery failed; trying again in {cfg.retry:.0f}s")


# --------------------------------------------------------------------------- CLI
def parse_regs(text: str) -> dict[int, int]:
    regs: dict[int, int] = {}
    for part in text.split(","):
        port, _, reg = part.partition(":")
        regs[int(port, 0)] = int(reg, 0)
    if not regs:
        raise ValueError("no registers given")
    return regs


def parse_args(argv: list[str] | None = None) -> tuple[Config, argparse.Namespace]:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--bus", type=int, default=9, help="i2c bus of the MAX96712 (default 9)")
    parser.add_argument("--addr", type=lambda v: int(v, 0), default=0x6B, help="MAX96712 i2c address (default 0x6b)")
    parser.add_argument("--lock-regs", default=",".join(f"{p}:0x{r:02x}" for p, r in DEFAULT_LOCK_REGS.items()),
                        help="port:register list (default 0:0x1a,1:0x0a,2:0x0b,3:0x0c)")
    parser.add_argument("--lock-mask", type=lambda v: int(v, 0), default=0x08, help="lock bit (default 0x08)")
    parser.add_argument("--poll", type=float, default=1.0, help="seconds between reads (default 1)")
    parser.add_argument("--stable", type=float, default=3.0, help="lock must be unchanged this long (default 3)")
    parser.add_argument("--retry", type=float, default=15.0, help="seconds between failed recoveries (default 15)")
    parser.add_argument("--max-retry", type=int, default=3, help="recovery attempts per link change (default 3)")
    parser.add_argument("--release-timeout", type=float, default=20.0, help="wait for apps to release the cameras (default 20)")
    parser.add_argument("--settle", type=float, default=3.0, help="pause after a recovery (default 3)")
    parser.add_argument("--enable-recovery", action="store_true", help="really reload the driver (default: monitor only)")
    parser.add_argument("--flag", default=os.getenv("SG4A_HOTPLUG_FLAG", DEFAULT_FLAG), help=f"signal file (default {DEFAULT_FLAG})")
    parser.add_argument("--step2", default=str(DEFAULT_STEP2), help="step 2 script used to reload the driver")
    parser.add_argument("--step2-arg", action="append", default=[], help="extra argument for step 2 (repeatable), e.g. --step2-arg=--mode=1")
    parser.add_argument("--once", action="store_true", help="print the state of every port once and exit")
    parser.add_argument("--duration", type=float, default=0.0, help="stop after N seconds (0 = run until stopped)")
    args = parser.parse_args(argv)
    cfg = Config(
        bus=args.bus, addr=args.addr, lock_regs=parse_regs(args.lock_regs), lock_mask=args.lock_mask,
        poll=args.poll, stable=args.stable, retry=args.retry, max_retry=args.max_retry,
        release_timeout=args.release_timeout, settle=args.settle, enable_recovery=args.enable_recovery,
        flag_path=args.flag, step2=args.step2, step2_args=list(args.step2_arg),
    )
    for name in ("poll", "stable", "retry", "release_timeout", "settle"):
        if getattr(cfg, name) < 0:
            parser.error(f"--{name.replace('_', '-')} must not be negative")
    if cfg.poll <= 0 or cfg.max_retry < 1:
        parser.error("--poll must be positive and --max-retry at least 1")
    return cfg, args


def show_once(cfg: Config, reader: I2CLockReader) -> int:
    try:
        lock = reader.read()
    except ReadError as exc:
        log("ERROR", f"cannot read the lock registers: {exc}")
        return 1
    print(f"MAX96712 on i2c-{cfg.bus} @ 0x{cfg.addr:02x}, lock bit 0x{cfg.lock_mask:02x}")
    print("  port  register  value  lock  node          in use by")
    for port in sorted(lock):
        node = f"/dev/video{port}"
        users = users_of([node]) if os.path.exists(node) else ""
        print(
            f"  {port:<5} 0x{cfg.lock_regs[port]:02x}      0x{reader.last_raw[port]:02x}   "
            f"{'YES' if lock[port] else 'no ':<4}  {node if os.path.exists(node) else '-':<13} "
            f"{' '.join(users.split()) if users else '-'}"
        )
    print(f"  signal file {cfg.flag_path}: {'PRESENT' if os.path.exists(cfg.flag_path) else 'absent'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    cfg, args = parse_args(argv)
    reader = I2CLockReader(cfg)
    if args.once:
        return show_once(cfg, reader)
    recovery: Any = Recovery(cfg) if cfg.enable_recovery else DryRecovery(cfg)
    if cfg.enable_recovery and os.geteuid() != 0:
        log("ERROR", "--enable-recovery needs root (rmmod/insmod): use ./setup.sh hotplug watch --enable-recovery")
        return 2
    watcher = Watcher(cfg, reader, recovery)

    def stop(_signum: int, _frame: Any) -> None:
        raise SystemExit(0)  # lets Recovery.run() remove the signal file in its finally

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log("INFO", f"watching ports {sorted(cfg.lock_regs)} every {cfg.poll:g}s; recovery {'ON' if cfg.enable_recovery else 'OFF (monitor only)'}")
    started = time.monotonic()
    try:
        while args.duration <= 0 or time.monotonic() - started < args.duration:
            watcher.tick()
            time.sleep(cfg.poll)
    finally:
        if cfg.enable_recovery:
            remove_flag(cfg.flag_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
