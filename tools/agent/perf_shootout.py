"""4-player shootout perf: everyone holds fire at one spot; perf sampled on the HOST."""

import json
import socket
import sys
import time

PORTS = [24704, 24705, 24706, 24707]
HOST = PORTS[0]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "shootout"


def send(port, obj, timeout=30):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(262144)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.decode())


def wait(port, pred, timeout=180, label=""):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if pred(send(port, {"cmd": "state"})):
                return True
        except OSError:
            pass
        time.sleep(2)
    raise SystemExit(f"TIMEOUT {label} on {port}")


for p in PORTS:
    wait(p, lambda s: True, 120, "bridge")
send(HOST, {"cmd": "net", "action": "host"})
time.sleep(4)
for p in PORTS[1:]:
    send(p, {"cmd": "net", "action": "join", "ip": "127.0.0.1"})
    time.sleep(3)
time.sleep(3)
for p in PORTS[1:]:
    send(p, {"cmd": "ready", "on": True})
    time.sleep(0.5)
time.sleep(2)
send(HOST, {"cmd": "deploy"})
for p in PORTS:
    wait(p, lambda s: s.get("drivable"), 180, "drivable")
print("all 4 drivable")

for i, p in enumerate(PORTS):
    send(p, {"cmd": "godmode", "on": True})
    send(p, {"cmd": "tp", "x": 76 + (i % 2) * 6, "z": 76 + (i // 2) * 6})
time.sleep(1.5)
# A few targets so shots also HIT things (impact FX path).
for _ in range(4):
    send(HOST, {"cmd": "spawn", "id": "grunt", "dist": 12, "hunter": True})
time.sleep(1.0)

p_idle = send(HOST, {"cmd": "perf", "window": 2})
print(f"[{LABEL}] idle:  fps={p_idle['fps_avg']:7} p95={p_idle['frame_ms']['p95']:6} max={p_idle['frame_ms']['max']:7} process={p_idle['process_ms_avg']:6} nodes={p_idle['node_count']} orphans={p_idle['orphan_nodes']}")

for p in PORTS:
    send(p, {"cmd": "hold", "action": "fire", "on": True})
time.sleep(1.0)
p_fire = send(HOST, {"cmd": "perf", "window": 4})
n_mid = send(HOST, {"cmd": "perf", "window": 1})["node_count"]
for p in PORTS:
    send(p, {"cmd": "hold", "action": "fire", "on": False})
    send(p, {"cmd": "refill"})
time.sleep(1.5)
p_post = send(HOST, {"cmd": "perf", "window": 1})
print(f"[{LABEL}] FIRE:  fps={p_fire['fps_avg']:7} p95={p_fire['frame_ms']['p95']:6} max={p_fire['frame_ms']['max']:7} process={p_fire['process_ms_avg']:6} nodes={p_fire['node_count']}->{n_mid} orphans={p_fire['orphan_nodes']}")
print(f"[{LABEL}] post:  fps={p_post['fps_avg']:7} p95={p_post['frame_ms']['p95']:6} nodes={p_post['node_count']}")
