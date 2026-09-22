"""Join the board's AP (SSID FF-XXXXXX, pass ffdebug1), then:
  python jog.py selfcheck
  python jog.py status
  python jog.py enable
  python jog.py jog 400
  python jog.py pos 0
  python jog.py stop
  python jog.py disable
"""
import argparse
import socket
import struct
import sys

ADDR = ("192.168.4.1", 4210)
FMT = "<BBBBii"
MAGIC = 0x46
CMD = {
    "set_pos": 0x01,
    "jog": 0x02,
    "stop": 0x03,
    "enable": 0x04,
    "limits": 0x05,
    "query": 0x06,
    "speed": 0x07,
    "status": 0x81,
}
FLAG_ENABLED = 1
FLAG_MOVING = 2
FLAG_UART_OK = 4


def pack(cmd, a=0, b=0, flags=0):
    return struct.pack(FMT, MAGIC, cmd, flags, 0, a, b)


def unpack(data):
    if len(data) < 12:
        return None
    magic, cmd, flags, _pad, a, b = struct.unpack(FMT, data[:12])
    return {"magic": magic, "cmd": cmd, "flags": flags, "a": a, "b": b}


def selfcheck():
    raw = pack(CMD["set_pos"], 1234, -5)
    p = unpack(raw)
    assert p["magic"] == MAGIC and p["cmd"] == 1 and p["a"] == 1234 and p["b"] == -5
    raw2 = pack(CMD["status"], -99, 100, FLAG_ENABLED | FLAG_MOVING)
    p2 = unpack(raw2)
    assert p2["flags"] == 3 and p2["a"] == -99
    print("selfcheck ok  packet=12 bytes")


def send(sock, cmd, a=0, b=0):
    sock.sendto(pack(cmd, a, b), ADDR)
    try:
        data, _ = sock.recvfrom(64)
    except socket.timeout:
        print("timeout (join FF-XXXXXX first)")
        return None
    p = unpack(data)
    if not p or p["magic"] != MAGIC:
        print("unexpected", data)
        return p
    flags = []
    if p["flags"] & FLAG_ENABLED:
        flags.append("en")
    if p["flags"] & FLAG_MOVING:
        flags.append("run")
    if p["flags"] & FLAG_UART_OK:
        flags.append("uart")
    print(f"pos {p['a']}  target {p['b']}  {' '.join(flags) or 'off'}")
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", nargs="?", default="status",
                    choices=["selfcheck", "status", "enable", "disable",
                             "stop", "pos", "jog", "limits", "speed"])
    ap.add_argument("a", nargs="?", type=int, default=0)
    ap.add_argument("b", nargs="?", type=int, default=0)
    args = ap.parse_args()
    if args.cmd == "selfcheck":
        selfcheck()
        return 0
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.0)
    if args.cmd == "status":
        send(sock, CMD["query"])
    elif args.cmd == "enable":
        send(sock, CMD["enable"], 1)
    elif args.cmd == "disable":
        send(sock, CMD["enable"], 0)
    elif args.cmd == "stop":
        send(sock, CMD["stop"])
    elif args.cmd == "pos":
        send(sock, CMD["set_pos"], args.a)
    elif args.cmd == "jog":
        send(sock, CMD["jog"], args.a)
    elif args.cmd == "limits":
        send(sock, CMD["limits"], args.a, args.b)
    elif args.cmd == "speed":
        send(sock, CMD["speed"], args.a or 8000, args.b or 20000)
    return 0


if __name__ == "__main__":
    sys.exit(main())
