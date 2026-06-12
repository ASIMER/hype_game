"""Loot reachability audit: every pickup must SIT on a surface (no floaters), and the
new vertical-access geometry (tower stairs, yard ramp, crate chain) must actually be
climbable by the live player.

Usage: python tools/agent/loot_audit.py [port]
Exit code 0 = all green. Run against a drivable --agent instance.
"""

import json
import socket
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 24700
FAILS: list[str] = []


def send(obj, timeout=40):
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
        time.sleep(2)
    return False


def player_y():
    return float(send({"cmd": "state"})["player"]["pos"][1])


def check(label, y, expect_y):
    ok = y >= expect_y - 0.4
    print("  %-28s y=%.2f (expect >= %.1f) %s" % (label, y, expect_y, "OK" if ok else "FAIL"))
    if not ok:
        FAILS.append(label)


def walk_to(x, z, tol=0.8, max_steps=24):
    """True point-to-point movement: short re-faced hops, stop within tol. A bare
    goto holds forward for its FULL duration (never stops at the target) and overruns
    a near waypoint by metres — on the tower's big open floors that bounced the
    player chaotically off the walls (live QA)."""
    for _ in range(max_steps):
        p = send({"cmd": "state"})["player"]["pos"]
        if ((x - p[0]) ** 2 + (z - p[2]) ** 2) ** 0.5 <= tol:
            return True
        send({"cmd": "goto", "x": x, "z": z, "duration": 0.3})
    return False


def climb_flight(x, z, min_gain, steps=18):
    """Walk toward (x,z) in short telemetry steps until the player has RISEN by
    min_gain (i.e. crested the flight) — never walks blindly past the top."""
    base = player_y()
    for _ in range(steps):
        send({"cmd": "goto", "x": x, "z": z, "duration": 0.4})
        if player_y() >= base + min_gain:
            return True
    return False


def clear_enemies(max_kills=30):
    """Kill every live enemy — they path upstairs now and a chasing body parked in a
    stairwell blocks the climb (waves respawn, so this only buys a clean window)."""
    for _ in range(max_kills):
        if not send({"cmd": "state"}).get("enemies"):
            return
        send({"cmd": "kill", "target": "nearest"})
        time.sleep(0.1)


def mantle_chain(label, tp_xz, face_xz, hops, expect_y):
    """Walk into the chain and mantle hop by hop. NOTE: the goto verb BLOCKS its
    response until its move-hold ends, so the jump pulse lands while the player
    stands pressed+facing the next crate — exactly what the mantle needs (it is
    proximity/facing-based, not motion-based). Jump goes through the HOLD verb:
    the agent-driven player reads AgentBridge.held("jump"), not input actions."""
    send({"cmd": "tp", "x": tp_xz[0], "z": tp_xz[1]})
    time.sleep(0.6)
    send({"cmd": "aim", "target": "point", "x": face_xz[0], "y": 1.0, "z": face_xz[1]})
    time.sleep(0.4)
    for _ in range(hops):
        send({"cmd": "goto", "x": face_xz[0], "z": face_xz[1], "duration": 1.0})  # blocks 1 s
        send({"cmd": "hold", "action": "jump", "on": True})
        time.sleep(0.15)
        send({"cmd": "hold", "action": "jump", "on": False})
        time.sleep(1.2)
    # Walk off the top crate's edge onto the container (a 0.7 m drop). SHORT: the
    # container is only 2.6 m deep and goto never stops at its target — a long hold
    # carries the player off the far edge.
    send({"cmd": "goto", "x": face_xz[0], "z": face_xz[1], "duration": 0.5})
    time.sleep(0.4)
    y = player_y()
    ok = y >= expect_y - 0.3
    print("  %-28s y=%.2f (expect >= %.1f) %s" % (label, y, expect_y, "OK" if ok else "FAIL"))
    if not ok:
        FAILS.append(label)


if not wait_drivable():
    sys.exit("not drivable")
# Fresh match: a long-running session accumulates wave enemies that shove/block the
# climb routes (a roof pass that passed 3x flaked on run 4 from exactly this).
send({"cmd": "restart"})
time.sleep(3)
if not wait_drivable():
    sys.exit("not drivable after restart")
send({"cmd": "godmode", "on": True})

# ---- 1. Floater scan: every pickup within 0.6 m of the surface below it ----------
print("=== floater scan ===")
loot = send({"cmd": "state"}).get("loot", [])
floaters = 0
for item in loot:
    x, y, z = item["pos"]
    hit = send({"cmd": "probe", "x": x, "y": y, "z": z}).get("hit", [x, y, z])
    gap = y - hit[1]
    if gap > 0.6:
        floaters += 1
        print("  FLOATER %s at (%.1f, %.1f, %.1f) gap %.2f" % (item["id"], x, y, z, gap))
if floaters:
    FAILS.append("%d floaters" % floaters)
print("  %d pickups checked, %d floaters" % (len(loot), floaters))

# ---- 2. Reachability smoke (live climbs) ------------------------------------------
print("=== climb checks ===")
clear_enemies()
# NorthTower (-40,-45): stairwell along the west wall, flights run +Z at x=-47.1,
# STACKED (base z -50.6, top z -46.4) - the roof needs a zigzag: up a flight (+Z),
# walk back south on the new floor (-Z), repeat per storey.
# GOTCHA: tp preserves the player's current Y — tp'ing back to the stair base while
# standing on an upper floor restarts the zigzag a storey up (it then walks off the
# roof into the stacked stairwell holes). The tower runs FIRST, from the restart
# spawn at ground level, and storey 0 doubles as the "flight -> floor 2" check.
send({"cmd": "tp", "x": -47.1, "z": -51.0})
time.sleep(0.8)
for _storey in range(3):  # one pass per storey (stacked flights)
    climb_flight(-47.1, -45.8, 2.9)  # up the flight (stops just below the crest)
    walk_to(-47.1, -45.7)  # over the crest onto solid floor past the hole's top end
    if _storey == 0:
        check("tower flight -> floor 2", player_y(), 3.0)
    if _storey == 2:
        break  # on the roof
    # Wrap around the stairwell hole (x [-48.2,-46.0], z [-50.2,-46.4]) back to the
    # next flight base — point-to-point legs that never cross the opening. The west
    # leg hugs the south wall at z -51.3: walking at -50.9 left only 0.26 m of capsule
    # clearance to the hole edge and hop wobble dropped the player through (live QA).
    walk_to(-44.5, -47.6)
    walk_to(-44.5, -51.3)
    walk_to(-47.1, -51.3)
ty = player_y()
ok_roof = ty >= 8.6
print("  %-28s y=%.2f (expect >= 9.0) %s" % ("tower zigzag -> roof", ty, "OK" if ok_roof else "FAIL"))
if not ok_roof:
    FAILS.append("tower roof")
# EastYard (50,42): welded ramp along the south stack, runs -X (EAST approach, base
# world x~56.9) at z~50.8, ending on a flat landing deck at 5.2. Start BEFORE the
# ramp base (tp inside its collider displaces the player). goto holds forward for
# its FULL duration (it does NOT stop at the target — live QA walked the player off
# the bare ramp end), so climb in short telemetry steps, then side-step south onto
# the container stack.
send({"cmd": "tp", "x": 58.5, "z": 50.8})
time.sleep(0.6)
ry = 0.0
for _step in range(16):
    send({"cmd": "goto", "x": 49.0, "z": 50.8, "duration": 0.4})  # blocks 0.4 s
    ry = player_y()
    if ry >= 5.15:  # ramp top OR the landing deck (5.22) — past-the-end is deck-safe
        break
# SHORT side-step onto the stack top: it is only 2.6 m deep and goto moves ~5 m/s
# without stopping at its target — 0.8 s carried the player off the far edge.
send({"cmd": "goto", "x": 49.5, "z": 48.4, "duration": 0.45})
time.sleep(0.3)
ry = player_y()
ok_ramp = ry >= 5.1
print("  %-28s y=%.2f (expect >= 5.2) %s" % ("yard ramp -> 5.2 stack", ry, "OK" if ok_ramp else "FAIL"))
if not ok_ramp:
    FAILS.append("yard ramp")
# EastYard spot-4 crate chain: A(1.15)->B(2.30)->C(3.30)->drop onto the 2.6 top.
# Crate A spans z [52.2, 53.3] — tp at 54.8 stays clear of its collider (+capsule).
mantle_chain("crate chain -> container", (42.5, 54.8), (42.5, 47.5), 3, 2.6)
# EastWarehouse (45,-28) court: 5.0 flight along the back wall (base world x~42,
# lane z~-35.55). Enter over the ramp's BURIED low end from the north (its rising
# side face is a wall past x~42.2), climb east, crest east of the wing-roof hole.
send({"cmd": "tp", "x": 42.0, "z": -31.0})
time.sleep(0.8)
walk_to(41.9, -35.55, tol=0.5)
climb_flight(50.0, -35.55, 4.6)
walk_to(50.0, -35.55)
check("warehouse flight -> roof", player_y(), 5.0)
# SWHouse (-52,30) court: ONE flight under the back wing (base world x~-55.0, lane
# z~23.85) up to the wing floor at 3.0 (the wing roof is decorative by design —
# a same-lane switchback wedges shut and the 3 m strip fits no second lane).
send({"cmd": "tp", "x": -55.0, "z": 27.0})
time.sleep(0.8)
walk_to(-55.1, 23.85, tol=0.5)
climb_flight(-49.0, 23.85, 2.7)
walk_to(-49.5, 23.85)
check("house flight -> wing floor", player_y(), 3.0)

print("RESULT:", "GREEN" if not FAILS else "FAIL: %s" % FAILS)
sys.exit(1 if FAILS else 0)
