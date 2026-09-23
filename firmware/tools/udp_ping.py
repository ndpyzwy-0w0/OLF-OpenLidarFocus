"""Join the board's AP (SSID FF-XXXXXX, pass change-me), then: python udp_ping.py"""
import socket
import time

addr = ("192.168.4.1", 4210)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1.0)
times = []
for i in range(20):
    payload = f"ping{i}".encode()
    t0 = time.perf_counter()
    s.sendto(payload, addr)
    try:
        data, _ = s.recvfrom(64)
        ms = (time.perf_counter() - t0) * 1000
        times.append(ms)
        print(f"{ms:6.1f} ms  {data!r}")
    except socket.timeout:
        print("timeout")
if times:
    times.sort()
    print(f"avg {sum(times)/len(times):.1f} ms  min {times[0]:.1f} ms")
