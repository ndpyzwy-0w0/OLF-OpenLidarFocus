"""List follow-focus boards answering on the current network.

Associate with a board's AP (SSID FF-XXXXXX, pass ffdebug1) first, then:

    python discover.py
    python discover.py --target 192.168.4.1

Boards answer a discover packet with their id, MAC, firmware and UDP port.

The host may have several interfaces (Ethernet, VPN, ...), and a limited
broadcast to 255.255.255.255 follows the *default route*, so it can leave
through the wrong one and never reach the board. To stay route-independent the
packet is sent once unbound and then once per local IPv4 address, with the
socket bound to that address, exactly like SSDP discovery does.
"""
import argparse
import socket

MAGIC = 0x46
CMD_DISCOVER = 0x0B
CMD_DISCOVER_REPLY = 0x84
BROADCAST = "255.255.255.255"
REPLY_SIZE = 32


def parse(data, addr):
    if len(data) < REPLY_SIZE or data[0] != MAGIC or data[1] != CMD_DISCOVER_REPLY:
        return None
    return {
        "device_id": data[15:31].split(b"\0")[0].decode("ascii", "replace"),
        "host": addr[0],
        "port": addr[1],
        "kind": data[2],
        "protocol": data[3],
        "udp_port": int.from_bytes(data[4:6], "little"),
        "fw": "%d.%d.%d" % (data[6], data[7], data[8]),
        "mac": ":".join("%02X" % b for b in data[9:15]),
    }


def local_addresses():
    """IPv4 addresses worth probing, or [] when the host cannot report them."""
    addresses = []
    try:
        infos = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
    except OSError:
        return addresses
    for info in infos:
        ip = info[4][0]
        if ip.startswith("127.") or ip.startswith("169.254.") or ip in addresses:
            continue
        addresses.append(ip)
    return addresses


def probe(sock, sources, target, port, timeout):
    found = {}
    for source in sources:
        if source is not None:
            try:
                sock.bind((source, 0))
            except OSError:
                continue
        sock.sendto(bytes([MAGIC, CMD_DISCOVER]) + bytes(10), (target, port))
        try:
            while True:
                data, addr = sock.recvfrom(1024)
                info = parse(data, addr)
                if info:
                    found[info["device_id"]] = info
        except socket.timeout:
            pass
    return found


def discover(target, port, timeout, tries, bind):
    sources = [bind] if bind else [None] + local_addresses()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(timeout)
    found = {}
    for _ in range(tries):
        found.update(probe(sock, sources, target, port, timeout))
    sock.close()
    return list(found.values())


def main():
    ap = argparse.ArgumentParser(description="Discover follow-focus boards.")
    ap.add_argument("--target", default=BROADCAST, help="broadcast or board IP")
    ap.add_argument("--port", type=int, default=4210)
    ap.add_argument("--timeout", type=float, default=0.6)
    ap.add_argument("--tries", type=int, default=3)
    ap.add_argument("--bind", help="send only from this local IPv4 address")
    args = ap.parse_args()

    boards = discover(args.target, args.port, args.timeout, args.tries, args.bind)
    if not boards:
        print("no board answered on %s:%d" % (args.target, args.port))
        return 1
    for b in boards:
        print(
            "%(device_id)s  fw %(fw)s  udp %(udp_port)d  mac %(mac)s  at %(host)s"
            % b
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
