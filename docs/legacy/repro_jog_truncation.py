#!/usr/bin/env python3
"""Reproduce the truncated "walk N revs" symptom on real hardware.

Sends exactly what the Flutter app sends when the user presses a walk button:
one single-shot JOG with flags = 0 and no SET_POS refresh while moving. The
_onTick poll loop keeps running as well (QUERY every 200 ms, TMC_QUERY every
1 s) to demonstrate that neither of them refreshes the communication watchdog.

Control group: the same JOG with flags = FF_REQ_LATCH (0x01) runs to completion.

Usage (join the device AP first, SSID FF-XXXXXX, password change-me):
    python test/repro_jog_truncation.py
    python test/repro_jog_truncation.py --reps 5 --host 192.168.4.1

Exit code 0 means every repetition behaved as documented: streaming single-shot
JOGs are cut at ~1 s, latched ones finish. See PROTOCOL.md 7.2 for the app-side
fix and HANDOFF.md 9 for the acceptance suite.
"""

import argparse
import socket
import struct
import sys
import time

MAGIC = 0x46
CMD_SET_POS = 0x01
CMD_JOG = 0x02
CMD_STOP = 0x03
CMD_ENABLE = 0x04
CMD_SET_LIMITS = 0x05
CMD_QUERY = 0x06
CMD_SET_SPEED = 0x07
CMD_TMC_QUERY = 0x08
CMD_HOME = 0x0A
CMD_STATUS = 0x81
CMD_STATUS_V2 = 0x83

REQ_LATCH = 0x01
V2_WATCHDOG_ARMED = 0x0001
RESULT = {0: "idle", 1: "accepted", 2: "completed", 3: "limited",
          4: "rejected", 5: "stopped"}

STEPS_PER_REV = 3200           # 1/16 microstepping over 400 full steps
REVS = 5
TOTAL_STEPS = REVS * STEPS_PER_REV

APP_ACCEL = 96000              # lib/main.dart: 30 rev/s^2 * 3200
# (label, (pulses/s, pulses/s^2), flags)
MODES = [
    ("app 1.2 rev/s (default slider), streaming", (3840, APP_ACCEL), 0),
    ("app 3.0 rev/s, streaming", (9600, APP_ACCEL), 0),
    ("firmware default 2.5 rev/s, streaming", (8000, 20000), 0),
    ("app 1.2 rev/s, latched (flags=0x01)", (3840, APP_ACCEL), REQ_LATCH),
]


class Link:
    def __init__(self, host, port):
        self.dest = (host, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.02)
        self.seq = 0

    def send(self, cmd, a=0, b=0, flags=0):
        self.seq = (self.seq + 1) & 0xFF
        self.sock.sendto(
            struct.pack("<BBBBii", MAGIC, cmd, flags, self.seq, a, b), self.dest)

    def drain(self, window=0.08):
        frames, end = [], time.time() + window
        while time.time() < end:
            try:
                data, _ = self.sock.recvfrom(64)
            except socket.timeout:
                continue
            frames.append(data)
        return frames

    def command(self, cmd, a=0, b=0, flags=0):
        self.send(cmd, a, b, flags)
        return parse(self.drain())


def parse(frames):
    """Return the state from a batch of replies; STATUS wins, V2 adds the bits."""
    status = None
    for data in frames:
        if len(data) < 12 or data[0] != MAGIC:
            continue
        if data[1] == CMD_STATUS:
            _, _, flags, seq, pos, target = struct.unpack("<BBBBii", data[:12])
            status = {
                "seq": seq, "flags": flags, "pos": pos, "target": target,
                "enabled": bool(flags & 1), "moving": bool(flags & 2),
                "uart_ok": bool(flags & 4), "standby": bool(flags & 8),
                "limited": bool(flags & 16),
                "result": RESULT.get(flags >> 5, "?"),
                "trusted": None, "armed": None,
            }
        elif data[1] == CMD_STATUS_V2 and len(data) >= 16:
            _, _, flags, seq, pos, target, trusted, _, reserved = struct.unpack(
                "<BBBBiiBBH", data[:16])
            if status is None:
                status = {
                    "seq": seq, "flags": flags, "pos": pos, "target": target,
                    "enabled": bool(flags & 1), "moving": bool(flags & 2),
                    "uart_ok": bool(flags & 4), "standby": bool(flags & 8),
                    "limited": bool(flags & 16),
                    "result": RESULT.get(flags >> 5, "?"),
                }
            status["trusted"] = bool(trusted)
            status["armed"] = bool(reserved & V2_WATCHDOG_ARMED)
    return status


def wait_idle(link, timeout):
    deadline = time.time() + timeout
    status = None
    while time.time() < deadline:
        status = link.command(CMD_QUERY)
        if status and not status["moving"]:
            return status
        time.sleep(0.05)
    return status


def reset_to_zero(link):
    """Park at pos = 0 and idle.

    The move back must be latched: any travel longer than 1 s would be cut short
    on a streaming command, which is the very bug under test.
    """
    status = link.command(CMD_QUERY)
    if status and status["pos"] != 0:
        link.command(CMD_SET_POS, 0, 0, REQ_LATCH)
        wait_idle(link, 20.0)
    link.command(CMD_HOME)
    return wait_idle(link, 5.0)


def run_jog(link, speed, flags, timeout=12.0):
    """One app-style single-shot JOG; returns (sampled trace, final state)."""
    link.command(CMD_SET_SPEED, speed[0], speed[1])
    link.command(CMD_ENABLE, 1, 0)
    t0 = time.time()
    link.send(CMD_JOG, TOTAL_STEPS, 0, flags)

    trace = []
    last_q = last_tmc = 0.0
    status = None
    while time.time() - t0 < timeout:
        now = time.time() - t0
        if now - last_q >= 0.2:                      # app _onTick, every 200 ms
            last_q = now
            status = link.command(CMD_QUERY)
            if status:
                trace.append((now, status))
        if now - last_tmc >= 1.0:                    # app _onTick, every 1 s
            last_tmc = now
            link.send(CMD_TMC_QUERY)
        if status and not status["moving"] and now > 0.15:
            break
        time.sleep(0.01)
    if status is None:  # no reply at all: the AP probably dropped, do not fake it
        status = link.command(CMD_QUERY)
    return trace, status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.4.1")
    ap.add_argument("--port", type=int, default=4210)
    ap.add_argument("--reps", type=int, default=3)
    args = ap.parse_args()

    link = Link(args.host, args.port)
    if not link.command(CMD_QUERY):
        print("ERROR: no reply - join the device AP (FF-XXXXXX / change-me) first")
        return 2

    link.command(CMD_SET_LIMITS, -20000, 20000)
    print("single-shot JOG of %d steps (%d revs at %d steps/rev)"
          % (TOTAL_STEPS, REVS, STEPS_PER_REV))
    print("watchdog: only SET_POS/JOG refresh it; 1000 ms of silence while moving "
          "stops the axis\n")

    results = []
    for title, speed, flags in MODES:
        print("== %s ==" % title)
        print("   %d pulses/s, %d pulses/s^2, flags = 0x%02X"
              % (speed[0], speed[1], flags))
        reached = []
        for rep in range(1, args.reps + 1):
            reset_to_zero(link)
            trace, end = run_jog(link, speed, flags)
            moving = [t for t, s in trace if s["moving"]]
            still = [t for t, s in trace if not s["moving"]]
            armed = [s["armed"] for _, s in trace if s["armed"] is not None]
            if end is None:
                print("   #%d no reply at all (is the AP still up? ping the host)"
                      % rep)
                reached.append(None)
                continue
            pos = end["pos"]
            reached.append(pos)
            print("   #%d pos=%6d steps (%.2f/%d revs = %5.1f%%)  result=%-9s "
                  "last moving %.2fs / first idle %.2fs  ARMED=%s"
                  % (rep, pos, pos / STEPS_PER_REV, REVS,
                     100.0 * pos / TOTAL_STEPS, end["result"],
                     max(moving) if moving else -1, still[0] if still else -1,
                     "1 then 0" if armed and armed[0] and not armed[-1]
                     else (str(int(armed[0])) if armed else "-")))
            link.command(CMD_STOP)
        mean = sum(reached) / len(reached) if reached and None not in reached else 0
        results.append((title, flags, reached, mean))
        print("   -> mean %d steps = %.2f revs (%.1f%%)\n"
              % (mean, mean / STEPS_PER_REV, 100.0 * mean / TOTAL_STEPS))

    print("== summary (%d runs per mode) ==" % args.reps)
    print("%-40s %10s %9s   %s" % ("mode", "mean steps", "of 5 revs", "verdict"))
    ok = True
    for title, flags, reached, mean in results:
        if None in reached:
            good, verdict = False, "missing replies"
        elif flags & REQ_LATCH:
            good = all(abs(p - TOTAL_STEPS) < STEPS_PER_REV / 10 for p in reached)
            verdict = "full travel" if good else "UNEXPECTED"
        else:
            good = all(0 < p < TOTAL_STEPS for p in reached)
            verdict = "truncated" if good else "UNEXPECTED"
        ok = ok and good
        print("%-40s %10d %8.1f%%   %s"
              % (title, mean, 100.0 * mean / TOTAL_STEPS, verdict))

    print("\n== raw trace of one streaming run (200 ms sampling) ==")
    reset_to_zero(link)
    trace, _ = run_jog(link, MODES[0][1], MODES[0][2])
    for t, s in trace:
        print("   t=%.2fs pos=%6d target=%6d moving=%d result=%-9s armed=%s"
              % (t, s["pos"], s["target"], s["moving"], s["result"], s["armed"]))

    reset_to_zero(link)
    link.command(CMD_ENABLE, 0, 0)
    print("\nleave device: pos = 0, idle, ENABLE(0)  (run HOME after ENABLE(0) if "
          "you want position_trusted back)")
    print("verdict: %s" % ("as documented: streaming single shots are cut at ~1 s, "
                           "latched ones finish" if ok
                           else "at least one mode did not behave as documented"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
