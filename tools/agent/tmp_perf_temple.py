"""Temple physics-spike isolation: perf with enemies present vs swept."""

import json
import socket
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 24702


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
send({"cmd": "tp", "x": 160, "z": 158})
time.sleep(3.0)

p1 = send({"cmd": "perf", "window": 3})
n1 = len(send({"cmd": "state"}).get("enemies", []))
print(f"WITH {n1:2d} enemies: fps={p1['fps_avg']} physics={p1['physics_ms_avg']} process={p1['process_ms_avg']} p95={p1['frame_ms']['p95']}")

for _ in range(10):
    es = send({"cmd": "state"}).get("enemies", [])
    if not es:
        break
    for e in es:
        send({"cmd": "kill", "target": e.get("name", "")})
    time.sleep(0.3)
time.sleep(2.0)

p2 = send({"cmd": "perf", "window": 3})
n2 = len(send({"cmd": "state"}).get("enemies", []))
print(f"WITH {n2:2d} enemies: fps={p2['fps_avg']} physics={p2['physics_ms_avg']} process={p2['process_ms_avg']} p95={p2['frame_ms']['p95']}")

# Also re-check the open field with whatever enemies respawn (control).
send({"cmd": "tp", "x": 80, "z": 80})
time.sleep(3.0)
p3 = send({"cmd": "perf", "window": 3})
n3 = len(send({"cmd": "state"}).get("enemies", []))
print(f"FIELD {n3:2d} enemies: fps={p3['fps_avg']} physics={p3['physics_ms_avg']} process={p3['process_ms_avg']} p95={p3['frame_ms']['p95']}")
