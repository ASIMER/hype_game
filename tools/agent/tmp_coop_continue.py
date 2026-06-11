"""Bug A co-op QA: match end -> continue (host-first, then client-first round) ->
worlds freed on both peers, no errors, re-deploy works."""

import json
import socket
import time

HOST = 24704
CLIENT = 24705
RESULTS = []


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


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name} {detail}")


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


def deploy_and_wait():
    send(HOST, {"cmd": "deploy"})
    wait(HOST, lambda s: s.get("drivable"), 180, "host drivable")
    wait(CLIENT, lambda s: s.get("drivable"), 180, "client drivable")


def wipe_both():
    for p in (HOST, CLIENT):
        send(p, {"cmd": "godmode", "on": False})
    t0 = time.time()
    while time.time() - t0 < 40:
        for p in (HOST, CLIENT):
            send(p, {"cmd": "hurt", "target": "self", "amount": 999})
        time.sleep(1.0)
        if send(HOST, {"cmd": "state"}).get("result") == "lost":
            return True
    return False


def world_children(port):
    return int(send(port, {"cmd": "perf", "window": 0.3}, timeout=20).get("world_children", -1))


wait(HOST, lambda s: True, 120, "host bridge")
wait(CLIENT, lambda s: True, 120, "client bridge")
send(HOST, {"cmd": "net", "action": "host"})
time.sleep(3)
send(CLIENT, {"cmd": "net", "action": "join", "ip": "127.0.0.1"})
time.sleep(3)
send(CLIENT, {"cmd": "ready", "on": True})
time.sleep(2)
deploy_and_wait()
print("round 1 deployed")

check("round1: wiped (match lost)", wipe_both())
time.sleep(2.0)
# HOST continues FIRST, then the client.
send(HOST, {"cmd": "summary", "action": "continue"})
time.sleep(3.0)
check("round1: host world freed", world_children(HOST) == 0, f"={world_children(HOST)}")
send(CLIENT, {"cmd": "summary", "action": "continue"})
time.sleep(3.0)
check("round1: client world freed", world_children(CLIENT) == 0, f"={world_children(CLIENT)}")

# Re-deploy from the hub-lobby.
send(CLIENT, {"cmd": "ready", "on": True})
time.sleep(1.5)
deploy_and_wait()
check("round1: re-deploy works (both drivable)", True)

check("round2: wiped", wipe_both())
time.sleep(2.0)
# CLIENT continues FIRST this time.
send(CLIENT, {"cmd": "summary", "action": "continue"})
time.sleep(3.0)
check("round2: client world freed (client-first)", world_children(CLIENT) == 0, f"={world_children(CLIENT)}")
send(HOST, {"cmd": "summary", "action": "continue"})
time.sleep(3.0)
check("round2: host world freed", world_children(HOST) == 0, f"={world_children(HOST)}")
send(CLIENT, {"cmd": "ready", "on": True})
time.sleep(1.5)
deploy_and_wait()
check("round2: re-deploy works", True)

print()
fails = [r for r in RESULTS if not r[1]]
print(f"CO-OP CONTINUE QA: {len(RESULTS) - len(fails)}/{len(RESULTS)} passed")
for f in fails:
    print(f"  FAILED: {f[0]} {f[2]}")
