"""StallGuard calibration client. Default is read-only; --smoke never enables motion."""
import argparse
import json
import random
import socket
import struct
import time

PACKET = struct.Struct('<BBBBii')
CAL = struct.Struct('<8B4i2HI')
FIELDS = ('magic', 'cmd', 'state', 'sequence', 'error', 'run_id', 'threshold',
          'valid', 'pos', 'travel', 'safe_min', 'safe_max', 'sg', 'microsteps', 'elapsed_ms')
STATES = ('idle', 'seek_negative', 'backoff_negative', 'seek_positive',
          'backoff_positive', 'completed', 'cancelled', 'failed')


class Client:
    def __init__(self, host, port):
        self.address = (socket.gethostbyname(host), port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.4)
        self.sequence = 0

    def request(self, cmd, a=0, b=0, sequence=None, expected=0x85):
        self.sequence = self.sequence % 255 + 1
        seq = self.sequence if sequence is None else sequence
        self.sock.sendto(PACKET.pack(0x46, cmd, 0, seq, a, b), self.address)
        deadline = time.monotonic() + 0.6
        while time.monotonic() < deadline:
            data, source = self.sock.recvfrom(128)
            if source != self.address or len(data) < 4 or data[:2] != bytes((0x46, expected)):
                continue
            if expected in (0x81, 0x83, 0x85) and data[3] != seq:
                continue
            if expected == 0x85:
                if len(data) != CAL.size:
                    raise ValueError(f'CAL_STATUS expected 32 bytes, got {len(data)}')
                result = dict(zip(FIELDS, CAL.unpack(data)))
                return result
            return data
        raise TimeoutError('No matching reply')


def show(s):
    print(json.dumps(dict(s, state_name=STATES[s['state']]), ensure_ascii=False), flush=True)


def smoke(c):
    """Only disable, read, cancel and deliberately rejected starts. No ENABLE(1)."""
    stopped = c.request(0x04, 0, expected=0x81)
    assert len(stopped) == 12 and not (stopped[2] & 3)
    status = c.request(0x06, expected=0x83)
    assert len(status) == 16 and not (status[2] & 3)
    old = c.request(0x0D)
    show(old)
    assert old['state'] not in (1, 2, 3, 4)
    fw = c.request(0x0B, expected=0x84)
    assert len(fw) == 32 and tuple(fw[6:9]) >= (1, 1, 0)
    print('firmware:', '.'.join(str(n) for n in fw[6:9]))
    invalid = c.request(0x0C, 60, 0, sequence=0)
    assert invalid['error'] == 1
    token = old['run_id'] % 255 + 1
    disabled = c.request(0x0C, 60, 0, sequence=token)
    assert disabled['error'] == 2 and disabled['run_id'] == old['run_id']
    c.request(0x0E)
    end = c.request(0x0D)
    assert end['pos'] == old['pos'] and end['state'] == old['state']
    tmc = c.request(0x08, expected=0x82)
    assert len(tmc) == 22
    print('TMC UART:', tmc[2], 'chip:', hex(tmc[11]))
    assert tmc[2] == 1 and tmc[11] == 0x21, 'TMC2209 UART unavailable'
    print('PASS: version, 32-byte status, sequence, invalid/disabled start, cancel; no movement')


def run(c, threshold, max_steps):
    before = c.request(0x0D)
    if before['state'] in (1, 2, 3, 4):
        raise RuntimeError('Calibration already active; query or cancel it first')
    token = random.choice([n for n in range(1, 256) if n != before['run_id']])
    completed = False
    try:
        c.request(0x04, 1, expected=0x81)
        s = c.request(0x0C, threshold, max_steps, sequence=token)
        deadline = time.monotonic() + 180
        while True:
            show(s)
            if s['error'] or s['run_id'] != token:
                raise RuntimeError('Calibration rejected/failed')
            if s['state'] == 5 and s['valid']:
                completed = True
                return
            if time.monotonic() >= deadline:
                raise TimeoutError('Calibration timeout')
            time.sleep(0.2)
            s = c.request(0x0D, token)
    finally:
        if not completed:
            # Firmware also stops autonomously if these packets cannot arrive.
            try:
                c.request(0x0E)
                c.request(0x04, 0, expected=0x81)
            except (OSError, TimeoutError):
                pass


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host', default='192.168.4.1')
    p.add_argument('--port', type=int, default=4210)
    group = p.add_mutually_exclusive_group()
    group.add_argument('--smoke', action='store_true', help='Non-moving hardware checks; disables motor')
    group.add_argument('--start', action='store_true', help='MOVES MOTOR: requires a lens with mechanical stops')
    group.add_argument('--cancel', action='store_true')
    p.add_argument('--threshold', type=int, default=60)
    p.add_argument('--max-steps', type=int, default=0)
    args = p.parse_args()
    c = Client(args.host, args.port)
    try:
        if args.smoke:
            smoke(c)
        elif args.start:
            run(c, args.threshold, args.max_steps)
        else:
            show(c.request(0x0E if args.cancel else 0x0D))
    finally:
        c.sock.close()


if __name__ == '__main__':
    main()
