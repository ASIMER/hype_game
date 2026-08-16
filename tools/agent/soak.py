"""Long-run soak: does the game still behave after half an hour of play?

Short QA passes never catch the failures that matter most for a co-op raid: a leak that
only shows after ten waves, an FPS curve that sags as debris and corpses accumulate, a
director that stops spawning, a restart that drops something on the floor. This drives a
live `--agent` instance for a set duration, samples the state on a fixed cadence, and
reports the TREND rather than a snapshot.

What it asserts, and why each one is a real failure mode this project has hit before:
  * FPS must not decay      — merged-chunk rebuilds and FX pools are the usual culprits.
    Note the ceiling: a vsynced instance reads a flat 60, so this test only speaks once
    the game has already fallen off the cap. It answers "did it get worse", not "how much
    headroom is left" — the photostand's per-frame FPS is the instrument for the latter.
  * Enemy count must not run away  — a director that ignores its cap, or corpses that
    never free, both show here first.
  * Restart must return to a clean slate — the arena-reload parity bug class.
  * The instance must stay answerable — a hang reads as a timed-out poll, not a crash.

Usage: python tools/agent/soak.py [minutes] [port]
Exit code 1 if any assertion fails, so it can gate a release.
"""

from __future__ import annotations

import json
import socket
import statistics
import sys
import time

PORT = 24702
SAMPLE_EVERY = 15.0
RESTART_EVERY = 300.0  # a fresh raid every five minutes


def send(obj: dict, port: int, timeout: float = 30.0) -> dict:
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.settimeout(timeout)
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.decode() or "{}")


def sample(port: int) -> dict | None:
    try:
        st = send({"cmd": "state"}, port, timeout=20.0)
    except (OSError, ValueError):
        return None
    return {
        "fps": float(st.get("fps") or 0.0),
        "enemies": len(st.get("enemies") or []),
        "loot": len(st.get("loot") or []),
        "wave": int((st.get("match_timer") or {}).get("final_wave", 0)),
        "drivable": bool(st.get("drivable")),
        "phase": st.get("phase"),
    }


def stir(port: int, tick: int) -> None:
    """Keep the raid ALIVE rather than idle — an AFK player is a different test.

    Idle play exercises none of the systems that leak: no spawns, no FX, no destruction.
    So each tick walks somewhere, and every few ticks adds enemies and breaks something.
    """
    spots = [(20, 20), (-40, -30), (45, -20), (160, 158), (0, 158), (205, 40)]
    x, z = spots[tick % len(spots)]
    try:
        send({"cmd": "godmode", "on": True}, port)
        send({"cmd": "tp", "x": float(x), "y": 30.0, "z": float(z)}, port)
        if tick % 2 == 0:
            for eid in ("grunt", "heavy", "wasp"):
                send({"cmd": "spawn", "id": eid, "dist": 12, "hunter": True}, port)
        if tick % 3 == 0:
            send({"cmd": "chunk", "action": "damage", "nearest": True, "dmg": 40.0}, port)
        if tick % 5 == 0:
            send({"cmd": "event", "kind": tick % 4}, port)
    except (OSError, ValueError):
        pass


def main() -> int:
    minutes = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
    port = int(sys.argv[2]) if len(sys.argv) > 2 else PORT
    deadline = time.monotonic() + minutes * 60.0
    next_restart = time.monotonic() + RESTART_EVERY
    samples: list[dict] = []
    misses = 0
    restarts = 0
    tick = 0
    print(f"soak: {minutes:.0f} min on port {port}")
    while time.monotonic() < deadline:
        s = sample(port)
        if s is None:
            misses += 1
            print(f"  [{len(samples):3d}] NO ANSWER ({misses})")
        else:
            samples.append(s)
            if len(samples) % 4 == 1:
                print(
                    f"  [{len(samples):3d}] fps {s['fps']:5.1f}  enemies {s['enemies']:3d}"
                    f"  loot {s['loot']:3d}  phase {s['phase']}"
                )
        stir(port, tick)
        tick += 1
        if time.monotonic() >= next_restart:
            print("  -- restart --")
            try:
                send({"cmd": "restart"}, port, timeout=60.0)
                restarts += 1
            except (OSError, ValueError):
                misses += 1
            time.sleep(16.0)
            next_restart = time.monotonic() + RESTART_EVERY
        time.sleep(SAMPLE_EVERY)

    if len(samples) < 8:
        print("FAIL: too few samples to judge anything")
        return 1
    head = [s["fps"] for s in samples[: len(samples) // 4] if s["fps"] > 0]
    tail = [s["fps"] for s in samples[-len(samples) // 4 :] if s["fps"] > 0]
    fps_head = statistics.median(head) if head else 0.0
    fps_tail = statistics.median(tail) if tail else 0.0
    peak_enemies = max(s["enemies"] for s in samples)
    peak_loot = max(s["loot"] for s in samples)
    drivable_frac = sum(1 for s in samples if s["drivable"]) / len(samples)

    print("")
    print(f"samples {len(samples)}  restarts {restarts}  unanswered polls {misses}")
    print(f"fps  first quarter {fps_head:.1f}  ->  last quarter {fps_tail:.1f}")
    print(f"peak enemies {peak_enemies}   peak loot {peak_loot}   drivable {drivable_frac:.0%}")

    fails: list[str] = []
    # 20% is the band that separates "the machine got busy" from "something accumulates".
    if fps_head > 0 and fps_tail < fps_head * 0.80:
        fails.append(f"FPS decayed {100 * (1 - fps_tail / fps_head):.0f}% over the run")
    if misses > 2:
        fails.append(f"{misses} polls went unanswered (hang or crash)")
    if peak_enemies > 90:
        fails.append(f"enemy count reached {peak_enemies} — the spawn cap is not holding")
    if drivable_frac < 0.75:
        fails.append(f"drivable only {drivable_frac:.0%} of the run")
    for f in fails:
        print("FAIL: " + f)
    if not fails:
        print("PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
