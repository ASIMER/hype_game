"""Visual check of pooled FX: fire at an enemy + at the world, screenshot mid-burst."""

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
send({"cmd": "tp", "x": 20, "z": 20})
time.sleep(1.0)
for _ in range(8):
    es = send({"cmd": "state"}).get("enemies", [])
    if not es:
        break
    for e in es:
        send({"cmd": "kill", "target": e.get("name", "")})
    time.sleep(0.3)

# Enemy-hit burst: spawn a grunt, aim, hold fire, screenshot mid-stream.
send({"cmd": "spawn", "id": "grunt", "dist": 9, "hunter": False})
time.sleep(1.0)
send({"cmd": "aim"})
time.sleep(0.3)
send({"cmd": "hold", "action": "fire", "on": True})
time.sleep(0.5)
print("enemy-fire:", send({"cmd": "screenshot", "name": "fx_pool_enemy"}).get("path"))
send({"cmd": "hold", "action": "fire", "on": False})
send({"cmd": "refill"})
time.sleep(0.6)

# World-hit burst: aim at the ground ahead, fire, screenshot (decal + dust).
st = send({"cmd": "state"})
px, py, pz = st["player"]["pos"]
send({"cmd": "aim", "point": [px + 6, py + 0.1, pz + 6]})
time.sleep(0.3)
send({"cmd": "hold", "action": "fire", "on": True})
time.sleep(0.5)
print("world-fire:", send({"cmd": "screenshot", "name": "fx_pool_world"}).get("path"))
send({"cmd": "hold", "action": "fire", "on": False})
time.sleep(1.0)
print("world-after:", send({"cmd": "screenshot", "name": "fx_pool_decal"}).get("path"))

p = send({"cmd": "perf", "window": 2})
print(f"solo perf: fps={p['fps_avg']} p95={p['frame_ms']['p95']} nodes={p['node_count']}")
