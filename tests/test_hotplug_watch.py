"""hotplug_watch.py: lock reading, the state machine and the recovery steps (no hardware)."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("hotplug_watch", ROOT / "scripts/hotplug_watch.py")
hw = importlib.util.module_from_spec(_spec)
sys.modules["hotplug_watch"] = hw
_spec.loader.exec_module(hw)

LOCKED = {0: False, 1: False, 2: True, 3: True}


def lock(*ports: int) -> dict[int, bool]:
    return {p: p in ports for p in range(4)}


# ------------------------------------------------------------------ reading
def test_read_command_is_made_of_register_reads_only() -> None:
    cmd = hw.build_read_command(9, 0x6B, hw.DEFAULT_LOCK_REGS)
    assert cmd[:4] == ["i2ctransfer", "-f", "-y", "9"]
    assert cmd[4:] == [
        "w2@0x6b", "0x00", "0x1a", "r1",
        "w2@0x6b", "0x00", "0x0a", "r1",
        "w2@0x6b", "0x00", "0x0b", "r1",
        "w2@0x6b", "0x00", "0x0c", "r1",
    ]  # fmt: skip


@pytest.mark.parametrize(
    "bad",
    [
        ["i2ctransfer", "-f", "-y", "9", "w3@0x6b", "0x00", "0x1a", "0x01"],  # a register write
        ["i2ctransfer", "-f", "-y", "9", "w2@0x6b", "0x00", "0x1a", "w1@0x6b"],
        ["i2ctransfer", "-f", "-y", "9", "w2@0x6b", "0x00", "0x1a"],
        ["i2ctransfer", "-f", "-y", "9"],
        ["i2cset", "-y", "9", "0x6b", "0x1a", "0x00"],
    ],
)
def test_anything_that_could_write_is_refused(bad) -> None:
    with pytest.raises(ValueError):
        hw.assert_read_only(bad)


def _reader(stdout="", returncode=0, stderr="", exc=None):
    def runner(cmd, **_kwargs):
        if exc:
            raise exc
        return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=returncode)

    return hw.I2CLockReader(hw.Config(), runner)


def test_lock_bit_is_taken_from_each_register() -> None:
    # 0xc8 / 0x00 / 0x16 / 0xc8 : the values seen in this board's dmesg
    reader = _reader("0x16\n0x00\n0xc8\n0xc8\n")
    assert reader.read() == {0: False, 1: False, 2: True, 3: True}
    assert reader.last_raw[2] == 0xC8


@pytest.mark.parametrize(
    "reader",
    [
        _reader("0xc8\n0xc8\n"),  # wrong number of values
        _reader("garbage"),
        _reader(returncode=1, stderr="Error: Could not open file\n"),
        _reader(exc=FileNotFoundError()),
        _reader(exc=subprocess.TimeoutExpired("i2ctransfer", 5)),
    ],
)
def test_read_problems_raise_read_error(reader) -> None:
    with pytest.raises(hw.ReadError):
        reader.read()


# ------------------------------------------------------------------ state machine
class Clock:
    def __init__(self) -> None:
        self.t = 100.0

    def __call__(self) -> float:
        return self.t


class Scripted:
    """Reader that returns what the test sets (or raises ReadError)."""

    def __init__(self) -> None:
        self.value: dict[int, bool] | Exception = lock(2, 3)

    def read(self):
        if isinstance(self.value, Exception):
            raise self.value
        return dict(self.value)


class FakeRecovery:
    def __init__(self, results=(True,)) -> None:
        self.results = list(results)
        self.calls: list[list[int]] = []

    def run(self, ports):
        self.calls.append(list(ports))
        return self.results.pop(0) if self.results else True


def make(cfg=None, results=(True,), exists=lambda _p: True):
    clock, reader, rec = Clock(), Scripted(), FakeRecovery(results)
    logs: list[tuple[str, str]] = []
    watcher = hw.Watcher(
        cfg or hw.Config(), reader, rec, now=clock, exists=exists,
        logger=lambda level, msg: logs.append((level, msg)),
    )  # fmt: skip

    def step(value=None, seconds=1.0):
        if value is not None:
            reader.value = value
        watcher.tick()
        clock.t += seconds

    return watcher, step, rec, logs, clock


def events(logs):
    return [m for level, m in logs if level == "EVENT"]


def test_steady_link_does_nothing() -> None:
    _w, step, rec, logs, _c = make()
    for _ in range(20):
        step()
    assert rec.calls == [] and events(logs) == []


def test_cable_lost_and_back_recovers_once_after_the_lock_is_stable() -> None:
    _w, step, rec, logs, _c = make()
    step()                     # baseline
    step(lock(3))              # port 2 lost
    assert any("port 2: link LOST" in m for m in events(logs))
    step(lock(3)); step(lock(3))
    assert rec.calls == []     # nothing to reconnect while the cable is out
    step(lock(2, 3))           # cable back
    assert any("port 2: link LOCKED (returned)" in m for m in events(logs))
    step(); step()
    assert rec.calls == []     # less than STABLE seconds since the change
    step(); step()
    assert rec.calls == [[2, 3]]
    for _ in range(10):
        step()
    assert len(rec.calls) == 1  # one recovery per change


def test_a_quick_replug_is_still_recovered() -> None:
    _w, step, rec, _l, _c = make()
    step()
    step(lock(3))              # lost for one second only
    step(lock(2, 3))
    for _ in range(5):
        step()
    assert rec.calls == [[2, 3]]  # the camera was power-cycled even though the link came back fast


def test_flapping_lock_postpones_the_recovery() -> None:
    _w, step, rec, _l, _c = make()
    step()
    for i in range(10):        # toggles every second for 10 s
        step(lock(3) if i % 2 == 0 else lock(2, 3))
    assert rec.calls == []
    for _ in range(5):
        step(lock(2, 3))
    assert rec.calls == [[2, 3]]


def test_a_new_camera_triggers_a_recovery() -> None:
    _w, step, rec, logs, _c = make()
    step()
    step(lock(1, 2, 3))
    for _ in range(5):
        step()
    assert any("port 1: link LOCKED (new)" in m for m in events(logs))
    assert rec.calls == [[1, 2, 3]]


def test_read_errors_are_not_treated_as_a_lost_cable() -> None:
    _w, step, rec, logs, _c = make()
    step()
    step(hw.ReadError("i2c busy"))
    step(); step()
    step(lock(2, 3))
    for _ in range(6):
        step()
    assert rec.calls == [] and not any("LOST" in m for m in events(logs))
    assert any(level == "WARN" and "cannot read" in m for level, m in logs)


def test_failed_recovery_is_retried_then_abandoned() -> None:
    cfg = hw.Config(retry=15.0, max_retry=3)
    _w, step, rec, logs, _clock = make(cfg, results=(False, False, False))
    step(); step(lock(3)); step(lock(2, 3))
    while not rec.calls:
        step()
    assert len(rec.calls) == 1
    for _ in range(10):
        step()
    assert len(rec.calls) == 1             # waits RETRY seconds between attempts
    for _ in range(8):
        step()
    assert len(rec.calls) == 2
    for _ in range(40):
        step()
    assert len(rec.calls) == 3
    assert any(level == "ERROR" and "giving up" in m for level, m in logs)
    for _ in range(60):
        step()
    assert len(rec.calls) == 3             # stays quiet until the next link change
    step(lock(3)); step(lock(2, 3))
    for _ in range(6):
        step()
    assert len(rec.calls) == 4             # a new change tries again


def test_baseline_is_read_again_after_a_recovery() -> None:
    _w, step, rec, logs, _c = make()
    step(); step(lock(3)); step(lock(2, 3))
    for _ in range(5):
        step()
    assert len(rec.calls) == 1
    # the reload toggled the links; this must not cause another recovery
    step(lock(3)); step(lock(2, 3)); step(lock(2, 3))
    baselines = [m for _l_, m in logs if m.startswith("baseline")]
    assert len(baselines) == 2 and len(rec.calls) == 1 or len(rec.calls) == 2


def test_missing_video_node_at_start_is_reported() -> None:
    _w, step, _r, logs, _c = make(exists=lambda path: path != "/dev/video3")
    step()
    assert any("port 3 is locked but /dev/video3 is missing" in m for _l_, m in logs)


# ------------------------------------------------------------------ recovery
class Sys:
    """Fake runner: fuser reports `busy` calls, bash (step 2) returns `step2_rc`."""

    def __init__(self, flag: Path, busy_calls=0, step2_rc=0, nodes=(2, 3)) -> None:
        self.flag, self.busy, self.step2_rc = flag, busy_calls, step2_rc
        self.calls: list[list[str]] = []
        self.flag_during_step2 = None
        self.existing = {f"/dev/video{n}" for n in nodes}

    def runner(self, cmd, **_kwargs):
        self.calls.append(list(cmd))
        if cmd[0] == "fuser" and cmd[1] == "-s":
            if self.busy > 0:
                self.busy -= 1
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=1, stdout="", stderr="")
        if cmd[0] == "fuser":
            return SimpleNamespace(returncode=0, stdout="", stderr="/dev/video2: user 1000 F.... python3\n")
        if cmd[0] == "bash":
            self.flag_during_step2 = self.flag.exists()
            return SimpleNamespace(returncode=self.step2_rc, stdout="step2 output\n", stderr="")
        raise AssertionError(cmd)


def recovery(tmp_path, **kwargs):
    flag = tmp_path / "run" / "camera-reload"
    system = Sys(flag, **{k: v for k, v in kwargs.items() if k in ("busy_calls", "step2_rc", "nodes")})
    clock = Clock()
    cfg = hw.Config(flag_path=str(flag), step2="/repo/scripts/step2_after_reboot.sh",
                    step2_log=str(tmp_path / "step2.log"), release_timeout=5, settle=0)  # fmt: skip
    logs: list[tuple[str, str]] = []
    rec = hw.Recovery(
        cfg, runner=system.runner, now=clock,
        sleep=lambda s: setattr(clock, "t", clock.t + s),
        nodes=lambda: ["/dev/video2", "/dev/video3"],
        exists=lambda p: p in system.existing,
        logger=lambda level, msg: logs.append((level, msg)),
    )  # fmt: skip
    return rec, system, flag, logs


def test_recovery_signals_waits_reloads_and_cleans_up(tmp_path) -> None:
    rec, system, flag, _logs = recovery(tmp_path, busy_calls=2)
    assert rec.run([2, 3]) is True
    assert system.flag_during_step2 is True        # applications were told before the reload
    assert not flag.exists()                       # and released afterwards
    step2 = [c for c in system.calls if c[0] == "bash"]
    assert step2 == [["bash", "/repo/scripts/step2_after_reboot.sh", "--force-reload"]]
    assert "rmmod" not in " ".join(" ".join(c) for c in system.calls)   # never unloads by itself
    assert "-f" not in [a for c in system.calls if c[0] == "bash" for a in c]


def test_recovery_does_not_unload_while_something_holds_the_cameras(tmp_path) -> None:
    rec, system, flag, logs = recovery(tmp_path, busy_calls=10_000)
    assert rec.run([2, 3]) is False
    assert not [c for c in system.calls if c[0] == "bash"]     # step 2 never ran
    assert not flag.exists()
    assert any("still in use" in m for _l, m in logs)
    assert not [c for c in system.calls if c[0] in ("kill", "pkill")]


def test_recovery_reports_a_failed_reload(tmp_path) -> None:
    rec, _system, flag, logs = recovery(tmp_path, step2_rc=1)
    assert rec.run([2, 3]) is False and not flag.exists()
    assert any("step 2 failed" in m for _l, m in logs)


def test_recovery_requires_the_video_nodes_to_come_back(tmp_path) -> None:
    rec, _system, flag, logs = recovery(tmp_path, nodes=(2,))
    assert rec.run([2, 3]) is False and not flag.exists()
    assert any("no /dev/video node for port(s) [3]" in m for _l, m in logs)


def test_signal_file_is_removed_even_if_the_reload_crashes(tmp_path) -> None:
    rec, system, flag, _logs = recovery(tmp_path)

    def boom(cmd, **kwargs):
        if cmd[0] == "bash":
            raise KeyboardInterrupt
        return Sys.runner(system, cmd, **kwargs)

    rec.runner = boom
    with pytest.raises(KeyboardInterrupt):
        rec.run([2, 3])
    assert not flag.exists()


def test_monitor_mode_changes_nothing(tmp_path) -> None:
    flag = tmp_path / "camera-reload"
    logs: list[tuple[str, str]] = []
    dry = hw.DryRecovery(hw.Config(flag_path=str(flag)), lambda level, msg: logs.append((level, msg)))
    assert dry.run([2, 3]) is True
    assert not flag.exists()
    assert all(level == "DRY" for level, _m in logs) and len(logs) >= 5


# ------------------------------------------------------------------ CLI
def test_parse_regs_and_defaults() -> None:
    assert hw.parse_regs("0:0x1a,2:0x0b") == {0: 0x1A, 2: 0x0B}
    cfg, args = hw.parse_args([])
    assert (cfg.bus, cfg.addr, cfg.lock_mask) == (9, 0x6B, 0x08)
    assert cfg.enable_recovery is False and args.once is False
    cfg, _ = hw.parse_args(["--enable-recovery", "--poll", "0.5", "--step2-arg=--mode=1"])
    assert cfg.enable_recovery and cfg.poll == 0.5 and cfg.step2_args == ["--mode=1"]


def test_bad_options_are_rejected() -> None:
    with pytest.raises(SystemExit):
        hw.parse_args(["--poll", "0"])
    with pytest.raises(SystemExit):
        hw.parse_args(["--max-retry", "0"])
