"""Perf baseline/AB: capture perf at 3 solo spots (open field, beacon, Temple)."""

import json
import socket
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 24702
LABEL = sys.argv[2] if len(sys.argv) > 2 else "baseline"


def send(obj, timeout=20):
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


def wait_drivable(timeout=150):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if send({"cmd": "state"}).get("drivable"):
                return True
        except OSError:
            pass
        time.sleep(3)
    return False


if not wait_drivable():
    sys.exit("not drivable")
send({"cmd": "godmode", "on": True})

SPOTS = [("open_field", 80, 80), ("beacon", 50, -55), ("temple", 160, 158)]
print(f"=== PERF {LABEL} ===")
for name, x, z in SPOTS:
    send({"cmd": "tp", "x": x, "z": z})
    time.sleep(5.0)
    p = send({"cmd": "perf", "window": 3}, timeout=30)
    print(
        f"{name:11} fps={p['fps_avg']:7} frame_avg={p['frame_ms']['avg']:6} "
        f"p95={p['frame_ms']['p95']:6} max={p['frame_ms']['max']:7} "
        f"process={p['process_ms_avg']:6} physics={p['physics_ms_avg']:5} "
        f"draws={p['draw_calls_avg']:7} nodes={p['node_count']}"
    )
