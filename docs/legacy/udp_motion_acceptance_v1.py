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
CMD_SET_SPEED = 0x07
CMD_HOME = 0x0A
CMD_STATUS = 0x81
CMD_STATUS_V2 = 0x83

# 请求包 flags（偏移 2）位 0：单次锁存，本次移动不纳入通信看门狗。
REQ_LATCH = 0x01
# STATUS_V2.reserved 位 0：通信看门狗已武装。
V2_WATCHDOG_ARMED = 0x0001

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
            _, _, flags, sequence, pos, target, trusted, fault, v2_bits = struct.unpack(
                "<BBBBiiBBH", data[:16]
            )
        elif len(data) >= PACKET_SIZE:
            _, command, flags, sequence, pos, target = struct.unpack(
                PACKET, data[:PACKET_SIZE]
            )
            if command != CMD_STATUS:
                raise AcceptanceError("unexpected reply command 0x%02x" % command)
            trusted, fault, v2_bits = None, None, None
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
            "v2_bits": v2_bits,
        }
        print(
            "seq={sequence:3d} pos={pos:6d} target={target:6d} "
            "moving={moving!s:5s} result={result}".format(**status)
        )
        return status

    def command(self, command, a=0, b=0, flags=0):
        if command == CMD_HOME:
            return self.home()
        sequence = self._next_sequence()
        self.sock.send(struct.pack(PACKET, MAGIC, command, flags, sequence, a, b))
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

    def query_v2(self):
        """Send QUERY and return its (legacy, STATUS_V2) replies.

        QUERY answers with two packets, so both must be consumed to keep the
        socket free of stale replies.
        """
        sequence = self._next_sequence()
        self.sock.send(struct.pack(PACKET, MAGIC, CMD_QUERY, 0, sequence, 0, 0))
        legacy = None
        deadline = time.monotonic() + self.args.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AcceptanceError("timeout waiting for QUERY replies")
            self.sock.settimeout(remaining)
            try:
                data = self.sock.recv(64)
            except socket.timeout:
                missing = "STATUS" if legacy is None else "STATUS_V2"
                raise AcceptanceError("timeout waiting for QUERY %s reply" % missing)
            if not data or data[0] != MAGIC:
                continue
            status = self._status(data)
            if status["sequence"] != sequence:
                continue
            if status["trusted"] is not None:
                self.expect(legacy is not None,
                            "QUERY returned STATUS_V2 before STATUS")
                return legacy, status
            legacy = status

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
        legacy, v2 = self.query_v2()
        self.expect(v2["pos"] == legacy["pos"] and v2["target"] == legacy["target"],
                    "STATUS and STATUS_V2 disagreed on position/target")
        self.expect(legacy["result"] == "completed",
                    "STATUS did not report the finished move as completed")
        self.expect(v2["result"] == "completed",
                    "STATUS_V2 did not report the finished move as completed")

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
        """流式命令（flags=0）：运动中静默超过 1 s 必须被刹停。"""
        self.command(CMD_SET_LIMITS, -30000, 30000)
        self.move_to(0)
        status = self.command(CMD_SET_POS, 19000)
        self.expect(status["target"] == 19000, "long SET_POS target was not accepted")
        # QUERY 不刷新看门狗，所以这里必须验证看门狗确实被武装了。
        _, v2 = self.query_v2()
        self.expect(bool(v2["v2_bits"] & V2_WATCHDOG_ARMED),
                    "streaming SET_POS did not arm the communication watchdog")
        time.sleep(1.25)
        status = self.query()
        self.expect(not status["moving"], "communication timeout did not stop motion")
        # motorStop() re-anchors target to the stop position, so pos == target is
        # expected here; what must not happen is reaching the requested 19000.
        self.expect(status["pos"] < 19000,
                    "motion reached the requested target despite timeout")
        self.expect(status["result"] == "stopped",
                    "communication timeout reported result %r" % status["result"])

    def test_latched_single_shot_move(self):
        """单次锁存（flags=REQ_LATCH）：只发一次，静默也必须跑完长行程。

        与 test_communication_timeout 配对：那条验证流式命令会被静默刹停，
        这条验证同一条路径上锁存命令不受影响——App 手动单次移动和一次性
        SET_POS 靠它，否则只要行程超过 1 s 就会被截断。
        """
        self.home()  # 软件置零：把后续行程锚在当前物理位置，不动电机
        self.command(CMD_SET_LIMITS, -30000, 30000)
        _, v2 = self.query_v2()
        self.expect(not (v2["v2_bits"] & V2_WATCHDOG_ARMED),
                    "idle axis reported an armed communication watchdog")

        status = self.command(CMD_SET_POS, 12000, flags=REQ_LATCH)
        self.expect(status["target"] == 12000, "latched SET_POS target was not accepted")
        _, v2 = self.query_v2()
        self.expect(not (v2["v2_bits"] & V2_WATCHDOG_ARMED),
                    "latched SET_POS armed the communication watchdog")

        time.sleep(1.25)  # 远超看门狗阈值，且 QUERY 不会刷新看门狗
        status = self.query()
        self.expect(status["moving"], "latched motion stopped after 1.25 s of silence")
        status = self.wait_for(
            lambda s: s["pos"] == 12000 and not s["moving"], "latched move completion"
        )
        self.expect(status["result"] == "completed",
                    "latched move reported result %r" % status["result"])

    def test_jog_single_shot_modes(self):
        """App「走圈」路径：单发 JOG 16000 步（1/16 细分 = 5 圈）的两种模式对照。

        流式（flags=0）单发必须被通信看门狗截断——这是失联安全的本意；锁存
        （flags=REQ_LATCH）单发必须跑满——App 的一次性长行程靠它。两条合起来就是
        「点一次走圈、中途不保活」的验收：必须显式选一种模式，没有默认的正确值。
        """
        self.command(CMD_SET_LIMITS, -20000, 20000)
        # 固件默认速度（不持久化）：保证 16000 步明显长于 1 s 看门狗阈值。
        self.command(CMD_SET_SPEED, 8000, 20000)
        self.home()
        self.move_to(0)

        status = self.command(CMD_JOG, 16000)
        self.expect(status["target"] == 16000, "streaming JOG target was not 16000")
        _, v2 = self.query_v2()
        self.expect(bool(v2["v2_bits"] & V2_WATCHDOG_ARMED),
                    "streaming JOG did not arm the communication watchdog")
        time.sleep(1.25)
        status = self.query()
        self.expect(not status["moving"], "silent streaming JOG was not stopped")
        self.expect(0 < status["pos"] < 16000,
                    "streaming JOG reached %d steps instead of being truncated"
                    % status["pos"])
        self.expect(status["result"] == "stopped",
                    "truncated streaming JOG reported result %r" % status["result"])

        self.home()
        self.move_to(0)
        status = self.command(CMD_JOG, 16000, flags=REQ_LATCH)
        self.expect(status["target"] == 16000, "latched JOG target was not 16000")
        _, v2 = self.query_v2()
        self.expect(not (v2["v2_bits"] & V2_WATCHDOG_ARMED),
                    "latched JOG armed the communication watchdog")
        time.sleep(1.25)  # 同样静默，且 QUERY 不刷新看门狗
        status = self.query()
        self.expect(status["moving"], "latched JOG stopped after 1.25 s of silence")
        status = self.wait_for(
            lambda s: s["pos"] == 16000 and not s["moving"], "latched JOG completion")
        self.expect(status["result"] == "completed",
                    "latched JOG reported result %r" % status["result"])

    def run(self):
        tests = (
            ("ENABLE and JOG +/-8/+/-80", self.test_enable_and_jogs),
            ("HOME and STATUS_V2 trusted", self.test_home_status_v2),
            ("SET_POS", self.test_set_pos),
            ("STOP and motion reverse", self.test_stop_and_reverse),
            ("soft limits", self.test_soft_limits),
            ("standby wakeup", self.test_standby_wakeup),
            ("communication timeout", self.test_communication_timeout),
            ("latched single-shot move", self.test_latched_single_shot_move),
            ("single-shot JOG: streaming vs latched", self.test_jog_single_shot_modes),
        )
        failures = 0
        try:
            # 先软件置零：所有用例都是相对行程，起始位置不该影响结果。否则上一次
            # 停在离 0 很远的地方时，第一组的 move_to(0) 自己就会被看门狗截断，
            # 报出一个跟被测行为无关的超时。
            start = self.home()
            self.expect(start["pos"] == 0 and not start["moving"],
                        "axis was not idle at suite start (HOME reported pos=%d "
                        "moving=%s)" % (start["pos"], start["moving"]))
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
