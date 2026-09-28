#!/usr/bin/env python3
"""只读抓板子的串口日志（默认 115200 8N1），带时间戳。

用途：App 那边报错时，对照固件在同一时刻打印的原因（`cal request ... error=N`、
`cal DIAG run=... phase=...`）。固件对这些事件都有 Serial.printf，比在 App 侧猜快得多。

    python3 tool/serial_tap.py                    # 抓到 Ctrl-C
    python3 tool/serial_tap.py --seconds 20       # 抓 20 秒
    python3 tool/serial_tap.py --port /dev/cu.usbmodem14A01

注意：只监听，不写、不改配置；但**打开串口本身**可能让部分板子复位，
所以不要在标定/运动过程中才第一次打开。
"""

import argparse
import os
import select
import sys
import termios
import time
from typing import Optional


def open_serial(port: str, baud: int) -> int:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    iflag, oflag, cflag, lflag, _ispeed, _ospeed, cc = termios.tcgetattr(fd)
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(
        fd,
        termios.TCSANOW,
        [0, 0, cflag, 0, baud, baud, cc],
    )
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/cu.usbmodem14A01")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=0, help="0 = 一直抓")
    args = ap.parse_args()

    if not os.path.exists(args.port):
        print(f"没有这个串口：{args.port}", file=sys.stderr)
        return 2

    fd = open_serial(args.port, args.baud)
    print(f"# 开始监听 {args.port} @ {args.baud}", flush=True)
    start = time.time()
    buf = b""
    try:
        while True:
            if args.seconds and time.time() - start > args.seconds:
                break
            try:
                if not select.select([fd], [], [], 0.2)[0]:
                    continue
                chunk = os.read(fd, 4096)
            except OSError as e:
                # ESP32-S3 的 USB CDC 偶尔会重新枚举（Errno 6 Device not configured）。
                # 重开继续抓，否则一次掉线就把整段录制丢在这里。
                fd = reopen(fd, args, start)
                if fd is None:
                    return 1
                continue
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                stamp = time.strftime("%H:%M:%S")
                print(f"[{stamp}] {line.decode('utf-8', 'replace').rstrip()}", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        # 掉线重连失败时 fd 已经是 None（板子被拔了），别再 close 一次 ——
        # 之前这里会抛 TypeError，把"重连失败"这个有用信息盖掉。
        if fd is not None:
            os.close(fd)
    if buf:
        print(f"[!] 半行（未换行）：{buf.decode('utf-8', 'replace')}", flush=True)
    return 0


def reopen(fd: int, args, start: float) -> "Optional[int]":
    """串口掉线后重连。最多试 30 次；每次都失败就放弃（板子被拔了）。"""
    print("[!] 串口掉线，1 秒后重连", flush=True)
    try:
        os.close(fd)
    except OSError:
        pass
    for _ in range(30):
        if args.seconds and time.time() - start > args.seconds:
            return None
        time.sleep(1.0)
        try:
            fd = open_serial(args.port, args.baud)
        except OSError:
            continue
        # 字符串拼接避免把时间戳前缀也画到重连消息上
        print("# 已重连 " + args.port, flush=True)
        return fd
    print("[!] 重连失败，退出", flush=True)
    return None



if __name__ == "__main__":
    raise SystemExit(main())
