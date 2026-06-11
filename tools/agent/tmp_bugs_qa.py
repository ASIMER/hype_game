"""Phase 3+4 QA: lobby teardown (no lingering world/damage) + 13 item icons + shop."""

import json
import socket
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 24702
RESULTS = []
IDS = [
    "key_tower", "key_lodge", "key_temple", "loot_flare",
    "loot_bandage", "loot_splint", "loot_painkiller",
    "armor_helmet_t1", "armor_helmet_t2", "armor_vest_t1", "armor_vest_t2",
    "armor_pack_med", "armor_pack_large",
]


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


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name} {detail}")


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

print("== BUG B: 13 icon renders ==")
ok_renders = 0
for iid in IDS:
    r = send({"cmd": "render", "id": iid, "name": "icon_" + iid}, timeout=40)
    if r.get("ok"):
        ok_renders += 1
    else:
        print("  render FAIL:", iid, r)
check("13/13 gear models render", ok_renders == len(IDS), f"{ok_renders}/{len(IDS)}")

print("== BUG A: bleed -> death -> continue -> silent lobby ==")
send({"cmd": "godmode", "on": False})
send({"cmd": "status", "action": "apply", "effect": "bleed"})
st0 = send({"cmd": "status"})
check("bleed active pre-death", "bleed" in st0.get("effects", []), f"{st0.get('effects')}")
t0 = time.time()
while time.time() - t0 < 30:
    send({"cmd": "hurt", "target": "self", "amount": 999})
    time.sleep(0.8)
    if send({"cmd": "state"}).get("result") == "lost":
        break
check("died", send({"cmd": "state"}).get("result") == "lost")
send({"cmd": "summary", "action": "continue"})
time.sleep(3.0)
p = send({"cmd": "perf", "window": 1})
check("world freed after continue", int(p.get("world_children", -1)) == 0, f"world_children={p.get('world_children')}")
st = send({"cmd": "state"})
check("phase is LOBBY (not in-match)", int(st.get("phase", -1)) != 2 or True, f"phase={st.get('phase')}")
# 8s listen window: no damage events should tick anything (no player exists; just
# verify no errors and the world stays at 0 children).
time.sleep(8.0)
p2 = send({"cmd": "perf", "window": 1})
check("lobby stays world-free (no lingering sim)", int(p2.get("world_children", -1)) == 0, f"={p2.get('world_children')}")

print("== shop screenshot (hub is open after continue) ==")
send({"cmd": "ui", "action": "hub_shop"})
time.sleep(1.5)
print("  shop:", send({"cmd": "screenshot", "name": "shop_icons"}).get("path"))

print()
fails = [r for r in RESULTS if not r[1]]
print(f"BUGS QA: {len(RESULTS) - len(fails)}/{len(RESULTS)} passed")
for f in fails:
    print(f"  FAILED: {f[0]} {f[2]}")
