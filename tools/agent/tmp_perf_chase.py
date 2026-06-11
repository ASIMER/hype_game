"""Controlled chase-cost test: exactly N hunter grunts chasing, measure physics."""

import json
import socket
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 24702
N = int(sys.argv[2]) if len(sys.argv) > 2 else 12


def send(obj, timeout=30):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(262144)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.decode())


send({"cmd": "godmode", "on": True})
send({"cmd": "tp", "x": 80, "z": 80})
time.sleep(2.0)
for _ in range(10):
    es = send({"cmd": "state"}).get("enemies", [])
    if not es:
        break
    for e in es:
        send({"cmd": "kill", "target": e.get("name", "")})
    time.sleep(0.3)
time.sleep(1.0)
p0 = send({"cmd": "perf", "window": 2})
print(f"0 enemies:  fps={p0['fps_avg']:7} physics={p0['physics_ms_avg']:6} process={p0['process_ms_avg']:6}")

for i in range(N):
    send({"cmd": "spawn", "id": "grunt", "dist": 14, "hunter": True})
time.sleep(3.0)
n = len(send({"cmd": "state"}).get("enemies", []))
p1 = send({"cmd": "perf", "window": 3})
print(f"{n} chasers: fps={p1['fps_avg']:7} physics={p1['physics_ms_avg']:6} process={p1['process_ms_avg']:6} p95={p1['frame_ms']['p95']}")
