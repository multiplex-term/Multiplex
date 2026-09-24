#!/usr/bin/env python3
"""Per-keystroke echo RTT bench for herdr / tmux / plain pty.

Run this ON the host whose multiplexer feels slow (scp it over; stdlib
only, Python ≥3.8) — it isolates the multiplexer's own contribution to
typing latency with the network taken out of the picture:

    python3 echo-bench.py --target plain          # pty baseline (~0.1ms)
    python3 echo-bench.py --target tmux
    python3 echo-bench.py --target herdr
    python3 echo-bench.py --target herdr --load probe   # + app probe cadence
    python3 echo-bench.py --target herdr --busy         # + streaming split pane

A keystroke feels laggy above roughly RTT+50ms; compare p90/p99 across
targets, not p50. Reference on an M-series Mac (herdr 0.8.0 / tmux 3.6a,
2026-08-04): tmux p50 0.3ms p99 2.3ms; herdr p50 3.2ms p90 10-21ms p99
~27ms at every typing cadence — herdr's tail is its own frame scheduling,
unaffected by probe load, and is what stacks visibly on top of remote RTT.

Mechanics: spawns the target in a local pty (answering the terminal
queries a real client answers: DA1/DA2, DSR, OSC 10/11, kitty ?u, DECRQM),
normalizes the pane to `exec cat`, then types marker chars one at a time
and measures until each echo appears in the ESCAPE-STRIPPED output stream.

Optional --load probe replays the Multiplex app's control-connection load
against the same backend (1s pane-current/list-panes + 5s snapshot/pane-read
a.k.a. the deck wall probe) so server contention is a togglable variable.

Isolation: every herdr subprocess strips HERDR_* env (this script may itself
run inside a herdr session) and targets the bench session by name only.
tmux runs on its own -L socket. Nothing touches user sessions.
"""

import argparse
import fcntl
import json
import os
import pty
import re
import select
import shlex
import signal
import statistics
import struct
import subprocess
import sys
import termios
import threading
import time

BENCH_SESSION = "mpx-echo-bench"
TMUX_SOCK = "mpxechobench"
ROWS, COLS = 40, 140

MARKERS = "QXZJVK"

STREAMER_CODE = (
    "import time,sys\n"
    "while True:\n"
    "    sys.stdout.write(('0123456789'*8)+'\\n')\n"
    "    sys.stdout.flush()\n"
    "    time.sleep(0.005)\n"
)


def clean_env():
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("HERDR_") or key.startswith("TMUX"):
            del env[key]
    env["TERM"] = "xterm-256color"
    env["LANG"] = "en_US.UTF-8"
    return env


class Stripper:
    """Incremental ANSI stripper + terminal-query responder."""

    GROUND, ESC, CSI, OSC, OSC_ESC, STR, STR_ESC = range(7)

    def __init__(self, reply):
        self.state = self.GROUND
        self.buf = bytearray()      # params of the current sequence
        self.plain = bytearray()    # stripped plaintext, appended forever
        self.reply = reply          # callable(bytes) -> writes to pty master

    def feed(self, data: bytes):
        for byte in data:
            self._byte(byte)

    def _byte(self, b):
        s = self.state
        if s == self.GROUND:
            if b == 0x1B:
                self.state = self.ESC
            elif b == 0x9B:  # C1 CSI
                self.buf.clear()
                self.state = self.CSI
            else:
                self.plain.append(b)
        elif s == self.ESC:
            if b == ord("["):
                self.buf.clear()
                self.state = self.CSI
            elif b == ord("]"):
                self.buf.clear()
                self.state = self.OSC
            elif b in (ord("P"), ord("X"), ord("^"), ord("_")):
                self.buf.clear()
                self.state = self.STR
            else:
                self.state = self.GROUND
        elif s == self.CSI:
            if 0x40 <= b <= 0x7E:
                self._csi(bytes(self.buf), chr(b))
                self.state = self.GROUND
            else:
                self.buf.append(b)
        elif s == self.OSC:
            if b == 0x07:
                self._osc(bytes(self.buf))
                self.state = self.GROUND
            elif b == 0x1B:
                self.state = self.OSC_ESC
            else:
                self.buf.append(b)
        elif s == self.OSC_ESC:
            if b == ord("\\"):
                self._osc(bytes(self.buf))
                self.state = self.GROUND
            else:  # not ST — treat as data
                self.buf.append(0x1B)
                self.buf.append(b)
                self.state = self.OSC
        elif s == self.STR:
            if b == 0x1B:
                self.state = self.STR_ESC
        elif s == self.STR_ESC:
            self.state = self.GROUND if b == ord("\\") else self.STR

    def _csi(self, params: bytes, final: str):
        if final == "c" and params in (b"", b"0"):
            self.reply(b"\x1b[?62;4;6;18;22c")
        elif final == "c" and params.startswith(b">"):
            self.reply(b"\x1b[>0;276;0c")
        elif final == "n" and params == b"6":
            self.reply(b"\x1b[1;1R")
        elif final == "n" and params == b"5":
            self.reply(b"\x1b[0n")
        elif final == "u" and params == b"?":
            self.reply(b"\x1b[?0u")
        elif final == "p" and params.startswith(b"?") and params.endswith(b"$"):
            mode = params[1:-1]
            self.reply(b"\x1b[?" + mode + b";0$y")

    def _osc(self, payload: bytes):
        if payload.startswith(b"10;?"):
            self.reply(b"\x1b]10;rgb:e5e5/e5e5/e5e5\x1b\\")
        elif payload.startswith(b"11;?"):
            self.reply(b"\x1b]11;rgb:0a0a/0b0b/0c0c\x1b\\")


class PtyTarget:
    def __init__(self, argv, env):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.proc = subprocess.Popen(
            argv, stdin=slave, stdout=slave, stderr=slave,
            env=env, start_new_session=True,
            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
        )
        os.close(slave)
        self.stripper = Stripper(self._write)

    def _write(self, data: bytes):
        try:
            os.write(self.master, data)
        except OSError:
            pass

    raw_bytes = 0

    def pump(self, timeout: float) -> bool:
        """Read whatever is available within timeout. True if bytes arrived."""
        ready, _, _ = select.select([self.master], [], [], timeout)
        if not ready:
            return False
        try:
            data = os.read(self.master, 65536)
        except OSError:
            return False
        if not data:
            return False
        self.raw_bytes += len(data)
        self.stripper.feed(data)
        return True

    def drain_until_quiet(self, quiet: float, cap: float):
        deadline = time.monotonic() + cap
        while time.monotonic() < deadline:
            if not self.pump(quiet):
                return

    def send(self, data: bytes):
        os.write(self.master, data)

    def close(self):
        try:
            os.killpg(self.proc.pid, signal.SIGHUP)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        os.close(self.master)


def run_quiet(argv, env, timeout=10):
    return subprocess.run(argv, env=env, capture_output=True,
                          timeout=timeout, text=True)


class ProbeLoad:
    """Replays the app's control-connection cadence in a background thread."""

    def __init__(self, target, env):
        self.target = target
        self.env = env
        self.stop_event = threading.Event()
        self.pane_id = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        if self.target == "herdr":
            out = run_quiet(["herdr", "--session", BENCH_SESSION, "api",
                             "snapshot"], self.env).stdout
            match = re.search(r'"id"\s*:\s*"(w\d+:p\d+)"', out)
            self.pane_id = match.group(1) if match else None
        self.thread.start()

    def _run(self):
        tick = 0
        while not self.stop_event.is_set():
            start = time.monotonic()
            try:
                if self.target == "herdr":
                    run_quiet(["herdr", "--session", BENCH_SESSION,
                               "pane", "current"], self.env)
                    if tick % 5 == 0:
                        run_quiet(["herdr", "status", "--json"], self.env)
                        run_quiet(["herdr", "session", "list", "--json"],
                                  self.env)
                        run_quiet(["herdr", "--session", BENCH_SESSION,
                                   "api", "snapshot"], self.env)
                        if self.pane_id:
                            run_quiet(["herdr", "--session", BENCH_SESSION,
                                       "pane", "read", self.pane_id,
                                       "--source", "visible"], self.env)
                elif self.target == "tmux":
                    run_quiet(["tmux", "-L", TMUX_SOCK, "list-panes", "-t",
                               BENCH_SESSION, "-F",
                               "#{pane_id} #{pane_pid} #{pane_tty} "
                               "#{pane_current_command} #{pane_title}"],
                              self.env)
                    if tick % 5 == 0:
                        run_quiet(["tmux", "-L", TMUX_SOCK, "list-sessions"],
                                  self.env)
                        run_quiet(["tmux", "-L", TMUX_SOCK, "capture-pane",
                                   "-p", "-t", BENCH_SESSION], self.env)
            except subprocess.TimeoutExpired:
                pass
            tick += 1
            remaining = 1.0 - (time.monotonic() - start)
            if remaining > 0:
                self.stop_event.wait(remaining)

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=3)


def herdr_cleanup(env):
    run_quiet(["herdr", "session", "stop", BENCH_SESSION, "--json"], env)
    run_quiet(["herdr", "session", "delete", BENCH_SESSION, "--json"], env)


def tmux_cleanup(env):
    run_quiet(["tmux", "-L", TMUX_SOCK, "kill-server"], env)


def bench(args):
    env = clean_env()
    if args.target == "plain":
        target = PtyTarget(["/bin/cat"], env)
    elif args.target == "tmux":
        tmux_cleanup(env)
        target = PtyTarget(
            ["tmux", "-L", TMUX_SOCK, "-u", "new-session", "-A", "-s",
             BENCH_SESSION, "/bin/cat"], env)
    elif args.target == "herdr":
        herdr_cleanup(env)
        target = PtyTarget(
            ["herdr", "session", "attach", BENCH_SESSION], env)
    else:
        raise SystemExit(f"unknown target {args.target}")

    try:
        target.drain_until_quiet(quiet=0.7, cap=12.0)

        if args.target == "herdr":
            new_pane = None
            if args.busy:
                # Visible split streaming beside the typing pane. The split
                # response's JSON envelope names the new (unfocused) pane.
                split_out = run_quiet(
                    ["herdr", "--session", BENCH_SESSION, "pane", "split",
                     "--current", "--direction", "right"], env).stdout
                match = re.search(r'"pane_id"\s*:\s*"(w\d+:p\d+)"', split_out)
                if not match:
                    raise SystemExit(f"busy: split gave no pane: {split_out[:200]}")
                new_pane = match.group(1)
                time.sleep(1.0)
                target.drain_until_quiet(quiet=0.5, cap=5.0)
            # Normalize the focused pane's shell to a bare echo surface.
            target.send(b" exec cat\r")
            target.drain_until_quiet(quiet=0.7, cap=8.0)
            if args.busy:
                run_quiet(["herdr", "--session", BENCH_SESSION, "pane",
                           "run", new_pane,
                           "python3", "-u", "-c", STREAMER_CODE], env)
                time.sleep(1.0)
        elif args.target == "tmux" and args.busy:
            streamer = "python3 -u -c " + shlex.quote(STREAMER_CODE)
            run_quiet(["tmux", "-L", TMUX_SOCK, "split-window", "-d", "-h",
                       "-t", BENCH_SESSION, streamer], env)
            time.sleep(1.0)

        load = None
        if args.load == "probe":
            load = ProbeLoad(args.target, env)
            load.start()
            time.sleep(1.0)

        # Idle watch: does the client stream bytes with nobody typing?
        idle_start_bytes = target.raw_bytes
        idle_until = time.monotonic() + args.idle_watch
        idle_chunks = 0
        while time.monotonic() < idle_until:
            if target.pump(0.05):
                idle_chunks += 1
        idle_bytes = target.raw_bytes - idle_start_bytes

        samples = []
        key_bytes = []
        timeouts = 0
        search_from = len(target.stripper.plain)
        for i in range(args.keys):
            marker = MARKERS[i % len(MARKERS)].encode()
            search_from = len(target.stripper.plain)
            bytes_before = target.raw_bytes
            t0 = time.monotonic_ns()
            target.send(marker)
            deadline = time.monotonic() + 2.0
            hit = None
            while time.monotonic() < deadline:
                target.pump(0.05)
                idx = target.stripper.plain.find(marker, search_from)
                if idx != -1:
                    hit = time.monotonic_ns()
                    break
            if hit is None:
                timeouts += 1
            else:
                samples.append((hit - t0) / 1e6)
                # settle briefly so the echo's full redraw is attributed
                target.drain_until_quiet(quiet=0.03, cap=0.3)
                key_bytes.append(target.raw_bytes - bytes_before)
            time.sleep(args.gap)

        if load:
            load.stop()

        label = f"{args.target}/load={args.load}/busy={int(args.busy)}"
        if samples:
            samples_sorted = sorted(samples)
            def pct(p):
                k = min(len(samples_sorted) - 1,
                        max(0, round(p / 100 * (len(samples_sorted) - 1))))
                return samples_sorted[k]
            print(json.dumps({
                "target": label,
                "keys": len(samples),
                "timeouts": timeouts,
                "p50_ms": round(pct(50), 2),
                "p90_ms": round(pct(90), 2),
                "p99_ms": round(pct(99), 2),
                "max_ms": round(max(samples), 2),
                "mean_ms": round(statistics.fmean(samples), 2),
                "idle_bytes_per_s": round(idle_bytes / max(args.idle_watch, 0.001)),
                "idle_chunks": idle_chunks,
                "bytes_per_key_p50": int(statistics.median(key_bytes)) if key_bytes else 0,
                "bytes_per_key_max": max(key_bytes) if key_bytes else 0,
            }))
        else:
            print(json.dumps({"target": label, "keys": 0,
                              "timeouts": timeouts}))
    finally:
        target.close()
        if args.target == "herdr":
            herdr_cleanup(env)
        elif args.target == "tmux":
            tmux_cleanup(env)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True,
                        choices=["plain", "tmux", "herdr"])
    parser.add_argument("--keys", type=int, default=50)
    parser.add_argument("--gap", type=float, default=0.05)
    parser.add_argument("--load", default="none", choices=["none", "probe"])
    parser.add_argument("--idle-watch", type=float, default=5.0)
    parser.add_argument("--busy", action="store_true",
                        help="visible neighbor pane streams ~16KB/s")
    bench(parser.parse_args())
