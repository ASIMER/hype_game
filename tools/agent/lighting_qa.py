"""Lighting QA suite: screenshots at fixed spots x fixed in-game hours (+ storm).

Usage: python tools/agent/lighting_qa.py <prefix> [port]
Saves <prefix>_h<hour>_<spot>.png via the agent bridge. The day-night hour is a pure
function of the match timer (start 10:00, +12h per match), so we drive it with the
`clock set` debug verb. Hour 22 would end the match (storm) - capped at 21.5.
"""

import json
import socket
import sys
import time

PREFIX = sys.argv[1] if len(sys.argv) > 1 else "lqa"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 24700

SPOTS = [
    ("cross", 80, 80, (0, 6, 0)),
    ("tower", -40, -25, (-40, 8, -45)),
    ("temple", 160, 143, (160, 10, 158)),
    ("beacon", 50, -55, (0, 4, -28)),
]
HOURS = [13.0, 19.5, 21.5]
DAY_START = 10.0
DAY_SPAN = 12.0


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
        time.sleep(2)
    return False


# The idle player may have died (KIA -> RESULTS, not drivable) - restart the match first.
try:
    if not send({"cmd": "state"}).get("drivable"):
        send({"cmd": "restart"})
        time.sleep(6)
except OSError:
    pass
if not wait_drivable():
    sys.exit("not drivable")
send({"cmd": "godmode", "on": True})
total = float(send({"cmd": "state"})["match_timer"]["total"])

for hour in HOURS:
    left = total * (1.0 - (hour - DAY_START) / DAY_SPAN)
    send({"cmd": "clock", "action": "set", "left": left})
    time.sleep(1.5)
    for name, x, z, aim in SPOTS:
        send({"cmd": "tp", "x": x, "z": z})
        time.sleep(0.5)
        send({"cmd": "aim", "target": "point", "x": aim[0], "y": aim[1], "z": aim[2]})
        time.sleep(0.7)
        tag = ("%s_h%s_%s" % (PREFIX, hour, name)).replace(".", "_")
        send({"cmd": "screenshot", "name": tag})
print("suite done:", PREFIX)
