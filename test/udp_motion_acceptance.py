#!/usr/bin/env python3
"""Black-box UDP motion acceptance test for the 12-byte follow-focus protocol.

Example:
    python test/udp_motion_acceptance.py
    python test/udp_motion_acceptance.py --host 192.168.4.1 --port 4210
"""

import argparse
import socket
import struct
import sys
import time


MAGIC = 0x46
PACKET = "<BBBBii"
PACKET_SIZE = struct.calcsize(PACKET)

CMD_SET_POS = 0x01
CMD_JOG = 0x02
CMD_STOP = 0x03
CMD_ENABLE = 0x04
CMD_SET_LIMITS = 0x05
CMD_QUERY = 0x06
CMD_HOME = 0x0A
CMD_STATUS = 0x81
CMD_STATUS_V2 = 0x83

FLAG_ENABLED = 1
FLAG_MOVING = 2
FLAG_STANDBY = 8
FLAG_LIMITED = 16
RESULTS = {
    0: "idle",
    1: "accepted",
    2: "completed",
    3: "limited",
    4: "rejected",
    5: "stopped",
}


class AcceptanceError(RuntimeError):
    pass


class MotionAcceptance:
    def __init__(self, args):
        self.args = args
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(args.timeout)
        self.sock.connect((args.host, args.port))
        self.sequence = 0

    def close(self):
        self.sock.close()

    def _next_sequence(self):
        value = self.sequence
        self.sequence = (self.sequence + 1) & 0xFF
        return value

    def _status(self, data):
        if len(data) >= 16 and data[0] == MAGIC and data[1] == CMD_STATUS_V2:
            _, _, flags, sequence, pos, target, trusted, fault, _ = struct.unpack(
                "<BBBBiiBBH", data[:16]
            )
        elif len(data) >= PACKET_SIZE:
            _, command, flags, sequence, pos, target = struct.unpack(
                PACKET, data[:PACKET_SIZE]
            )
            if command != CMD_STATUS:
                raise AcceptanceError("unexpected reply command 0x%02x" % command)
            trusted, fault = None, None
        else:
            raise AcceptanceError("short reply (%d bytes)" % len(data))
        result_code = (flags >> 5) & 0x07
        result = RESULTS.get(result_code, "unknown(%d)" % result_code)
        status = {
            "sequence": sequence,
            "pos": pos,
            "target": target,
            "moving": bool(flags & FLAG_MOVING),
            "enabled": bool(flags & FLAG_ENABLED),
            "standby": bool(flags & FLAG_STANDBY),
            "limited": bool(flags & FLAG_LIMITED),
            "result": result,
            "flags": flags,
            "trusted": trusted,
            "fault": fault,
        }
        print(
            "seq={sequence:3d} pos={pos:6d} target={target:6d} "
            "moving={moving!s:5s} result={result}".format(**status)
        )
        return status

    def command(self, command, a=0, b=0):
        if command == CMD_HOME:
            return self.home()
        sequence = self._next_sequence()
        self.sock.send(struct.pack(PACKET, MAGIC, command, 0, sequence, a, b))
        deadline = time.monotonic() + self.args.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AcceptanceError("timeout waiting for command 0x%02x" % command)
            self.sock.settimeout(remaining)
            data = self.sock.recv(64)
            if data and data[0] == MAGIC:
                status = self._status(data)
                if status["sequence"] == sequence:
                    return status

    def home(self):
        """Send HOME and consume its legacy 12-byte and V2 16-byte replies."""
        sequence = self._next_sequence()
        self.sock.send(struct.pack(PACKET, MAGIC, CMD_HOME, 0, sequence, 0, 0))
        replies = []
        deadline = time.monotonic() + self.args.timeout
        while len(replies) < 2:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AcceptanceError(
                    "timeout waiting for both HOME status replies "
                    "(received %d/2)" % len(replies)
                )
            self.sock.settimeout(remaining)
            data = self.sock.recv(64)
            if not data or data[0] != MAGIC:
                continue
            status = self._status(data)
            if status["sequence"] != sequence:
                continue
            replies.append(status)
        v2 = [status for status in replies if status["trusted"] is not None]
        self.expect(len(v2) == 1, "HOME did not return exactly one STATUS_V2 reply")
        return v2[0]

    def query(self):
        return self.command(CMD_QUERY)

    def wait_for(self, predicate, description):
        deadline = time.monotonic() + self.args.settle_timeout
        status = self.query()
        while not predicate(status):
            if time.monotonic() >= deadline:
                raise AcceptanceError("timeout waiting for %s" % description)
            time.sleep(self.args.poll_interval)
            status = self.query()
        return status

    def expect(self, condition, message):
        if not condition:
            raise AcceptanceError(message)

    def move_to(self, position):
        self.command(CMD_SET_POS, position)
        return self.wait_for(
            lambda s: s["pos"] == position and s["target"] == position and not s["moving"],
            "position %d" % position,
        )

    def test_enable_and_jogs(self):
        status = self.command(CMD_ENABLE, 1)
        self.expect(status["enabled"], "ENABLE did not enable the motor")
        self.command(CMD_SET_LIMITS, -10000, 10000)
        self.move_to(0)
        for delta in (8, -8, 80, -80):
            status = self.command(CMD_JOG, delta)
            expected = status["pos"] + delta
            self.wait_for(
                lambda s, expected=expected: s["pos"] == expected
                and s["target"] == expected
                and not s["moving"],
                "JOG %+d completion" % delta,
            )

    def test_set_pos(self):
        status = self.command(CMD_SET_POS, 32)
        self.expect(status["target"] == 32, "SET_POS target was not 32")
        self.move_to(32)

    def test_home_status_v2(self):
        status = self.home()
        self.expect(status["trusted"] == 1, "HOME STATUS_V2 trusted was not true")
        self.expect(status["pos"] == 0 and status["target"] == 0,
                    "HOME did not report position and target at zero")
        self.expect(not status["moving"], "HOME STATUS_V2 reported moving")

    def test_stop_and_reverse(self):
        self.command(CMD_SET_POS, 2000)
        time.sleep(self.args.action_delay)
        status = self.command(CMD_STOP)
        self.expect(not status["moving"], "STOP left the motor moving")
        self.expect(status["result"] == "stopped", "STOP result was not stopped")

        self.command(CMD_SET_POS, 2000)
        time.sleep(self.args.action_delay)
        status = self.command(CMD_SET_POS, -2000)
        self.expect(status["target"] == -2000, "reverse command target was not -2000")
        self.move_to(-2000)

    def test_soft_limits(self):
        self.command(CMD_SET_LIMITS, -100, 100)
        status = self.command(CMD_SET_POS, 1000)
        self.expect(status["target"] == 100, "positive soft limit did not clamp to 100")
        self.expect(status["limited"] and status["result"] == "limited",
                    "positive soft limit was not reported")
        self.wait_for(lambda s: s["pos"] == 100 and not s["moving"], "positive soft limit")

        status = self.command(CMD_SET_POS, -1000)
        self.expect(status["target"] == -100, "negative soft limit did not clamp to -100")
        self.expect(status["limited"] and status["result"] == "limited",
                    "negative soft limit was not reported")
        self.wait_for(lambda s: s["pos"] == -100 and not s["moving"], "negative soft limit")
        self.command(CMD_SET_LIMITS, -10000, 10000)

    def test_standby_wakeup(self):
        status = self.wait_for(lambda s: s["standby"], "standby entry")
        self.expect(status["enabled"], "standby lost the enabled state")
        before = status["pos"]
        status = self.command(CMD_JOG, 8)
        self.expect(not status["standby"], "JOG did not wake the driver")
        self.expect(status["target"] == before + 8, "wake JOG target was incorrect")
        self.move_to(before + 8)

    def test_communication_timeout(self):
        """A moving axis must stop after >1 s without another control packet."""
        self.command(CMD_SET_LIMITS, -30000, 30000)
        self.move_to(0)
        status = self.command(CMD_SET_POS, 19000)
        self.expect(status["target"] == 19000, "long SET_POS target was not accepted")
        time.sleep(1.25)
        status = self.query()
        self.expect(not status["moving"], "communication timeout did not stop motion")
        self.expect(status["pos"] != status["target"],
                    "motion reached target despite communication timeout")

    def run(self):
        tests = (
            ("ENABLE and JOG +/-8/+/-80", self.test_enable_and_jogs),
            ("HOME and STATUS_V2 trusted", self.test_home_status_v2),
            ("SET_POS", self.test_set_pos),
            ("STOP and motion reverse", self.test_stop_and_reverse),
            ("soft limits", self.test_soft_limits),
            ("standby wakeup", self.test_standby_wakeup),
            ("communication timeout", self.test_communication_timeout),
        )
        failures = 0
        try:
            for name, test in tests:
                print("\n== %s ==" % name)
                try:
                    test()
                    print("PASS %s" % name)
                except (AcceptanceError, OSError) as exc:
                    failures += 1
                    print("FAIL %s: %s" % (name, exc), file=sys.stderr)
                    try:
                        self.command(CMD_STOP)
                    except (AcceptanceError, OSError):
                        pass
        finally:
            try:
                self.command(CMD_STOP)
                self.command(CMD_ENABLE, 0)
            except (AcceptanceError, OSError):
                pass
            self.close()
        print("\n%d/%d acceptance groups passed" % (len(tests) - failures, len(tests)))
        return 1 if failures else 0


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="192.168.4.1")
    parser.add_argument("--port", type=int, default=4210)
    parser.add_argument("--timeout", type=float, default=1.0,
                        help="UDP reply timeout in seconds (default: 1)")
    parser.add_argument("--settle-timeout", type=float, default=8.0,
                        help="movement/standby timeout in seconds (default: 8)")
    parser.add_argument("--poll-interval", type=float, default=0.10)
    parser.add_argument("--action-delay", type=float, default=0.05,
                        help="delay before STOP/reverse (default: 0.05)")
    return parser.parse_args()


if __name__ == "__main__":
    try:
        sys.exit(MotionAcceptance(parse_args()).run())
    except (OSError, KeyboardInterrupt) as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        sys.exit(2)
