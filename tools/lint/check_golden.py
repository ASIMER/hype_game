"""Golden determinism snapshot — capture + compare (docs/AUDIT.md, refactor phase 2).

The AgentBridge `golden` command returns the deterministic slice of the built world:
terrain height/water probes on a fixed grid, extraction-zone positions + pad heights,
and a placement checksum per procedural container. Two runs of the same build must
byte-match; a mismatch after a refactor of the procedural pipeline means behaviour
changed (ProcHash / WorldBounds / pads / POI defs drifted).

Usage (with a `--agent` instance running and in-match):
    python tools/lint/check_golden.py --capture   # write tools/lint/golden_world.json
    python tools/lint/check_golden.py             # compare live world vs golden, exit 1 on drift

NOTE: capture and check must run on the SAME instance settings (the grass/terrain
density settings are per-instance; the default port-24700 profile is the reference).
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "agent"))
from play import DEFAULT_PORT, send  # noqa: E402

GOLDEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden_world.json")


def canonical(d):
    return json.dumps(d, sort_keys=True, indent=1)


def wait_drivable(port, timeout=90.0):
    """The golden data is only valid in-match (pads cached, arena built)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            st = send({"cmd": "state"}, port=port)
            if st.get("drivable"):
                return True
        except Exception:
            pass
        time.sleep(1.0)
    return False


def diff_report(old, new):
    """Human-oriented drift report: name WHAT moved, not just 'mismatch'."""
    lines = []
    for key in ("version", "ok"):
        if old.get(key) != new.get(key):
            lines.append(f"  {key}: {old.get(key)!r} -> {new.get(key)!r}")
    for key in ("heights", "water"):
        o, n = old.get(key, []), new.get(key, [])
        if len(o) != len(n):
            lines.append(f"  {key}: probe count {len(o)} -> {len(n)}")
        shown = 0
        for a, b in zip(o, n):
            if a != b and shown < 8:
                lines.append(f"  {key} @({a[0]},{a[1]}): {a[2]} -> {b[2]}")
                shown += 1
        if shown == 8:
            lines.append(f"  {key}: ... (more probes differ)")
    oz = {z["name"]: z for z in old.get("zones", [])}
    nz = {z["name"]: z for z in new.get("zones", [])}
    for name in sorted(set(oz) | set(nz)):
        if oz.get(name) != nz.get(name):
            lines.append(f"  zone {name}: {oz.get(name)} -> {nz.get(name)}")
    oc, nc = old.get("containers", {}), new.get("containers", {})
    for name in sorted(set(oc) | set(nc)):
        if oc.get(name) != nc.get(name):
            lines.append(f"  container {name}: {oc.get(name)} -> {nc.get(name)}")
    return lines


def main():
    capture = "--capture" in sys.argv
    port = int(os.environ.get("AGENT_PORT", str(DEFAULT_PORT)))
    if not wait_drivable(port):
        print("[golden] no drivable --agent instance on port %d" % port)
        return 2
    reply = send({"cmd": "golden"}, port=port)
    if not reply.get("ok"):
        print("[golden] capture failed (arena not built?): %s" % reply)
        return 2

    if capture:
        with open(GOLDEN, "w", encoding="utf-8") as f:
            f.write(canonical(reply))
        print("[golden] captured -> %s (%d height probes, %d zones, containers: %s)" % (
            GOLDEN, len(reply.get("heights", [])), len(reply.get("zones", [])),
            ", ".join(sorted(reply.get("containers", {}).keys()))))
        return 0

    if not os.path.isfile(GOLDEN):
        print("[golden] %s missing — run with --capture first" % GOLDEN)
        return 2
    with open(GOLDEN, encoding="utf-8") as f:
        golden_text = f.read()
    live_text = canonical(reply)
    if live_text == golden_text:
        print("[golden] MATCH — world is byte-identical to the snapshot")
        return 0
    print("[golden] DRIFT — the deterministic world changed:")
    for line in diff_report(json.loads(golden_text), reply):
        print(line)
    return 1


if __name__ == "__main__":
    sys.exit(main())
