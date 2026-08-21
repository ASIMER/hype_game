"""Reachability — the honest answer to "does a bot actually walk up to the player on floor N?".

Vertical navmesh cannot be checked by eye: a machine that mills around the ground floor and a
machine that is *physically unable* to path to the storey above look identical from the roof.
This drives an ALREADY-RUNNING `--agent` instance: for every probe it parks the player on a
known floor/roof, spawns ONE hunter outside the building, then samples `state.enemies[].dist`
for 35 s while asking `navdbg` what the NavigationServer thinks — and prints PASS/FAIL with a
DIAGNOSIS instead of a bare timeout.

    # launch the game first: ...win64.exe --path "C:\\personal\\hype game" -- --agent
    python tools/agent/reachability.py smoke          # -> showcase/quality2/reach_smoke.json
    python tools/agent/reachability.py e0_baseline 24710

THE THREE OUTCOMES ARE DIFFERENT ANSWERS, NOT DEGREES OF GREEN
  PASS            the machine CLOSED ON ITS OWN FEET: a sample inside `pass_dist` (or ATTACK
                  inside its own attack range, aimed at THIS player) while standing on the
                  player's floor, the CONFIRM_SAMPLES samples after it all still say so — AND
                  not one sample of the probe contained a displacement the machine's own speed
                  cannot produce. `route: "walked"`.
  INCONCLUSIVE    the machine ended up there, but the ROUTE IS NOT PROVEN — the strongest thing
                  that can honestly be said is what the NavigationServer says (reachable /
                  path_len). `route: "teleport-assisted"` for the first kind below.
                  `teleport-assisted`  something relocated the machine on every verdict attempt
                  (see THE TELEPORT RULE). In the verdict phase the stuck-watchdog is switched
                  off, so this should be rare — check `immunised` in the JSON first. Never a
                  PASS, whether the jump happened before or after the closure.
                  `static-at-closure`  it reached the radius on the right level and then sat at
                  a bit-identical position without ever entering ATTACK. That is what a body
                  wedged against a lip looks like from the outside; verify on the position.
                  `unconfirmed-closure`  the sampling window ended mid-confirmation.
  FAIL not-in-navmesh   `navdbg` answered `reachable:false` for this machine in >=3 consecutive
                  polls. Confirmed by `player_snap`: the closest navmesh point to a player
                  standing on a 3 m slab is still down at 0.2 m -> that floor has no navmesh at
                  all, so no amount of AI tuning will ever get a bot up there. This is E2's input.
  FAIL wedge      the path EXISTS (`reachable:true`) but the distance flattened out: the machine
                  is jammed on a stair lip / doorway / ramp edge. The last logged position is the
                  wedge point. Only tested when the window actually ran long enough for the two
                  10 s slices to be DISJOINT (a truncated window makes them the same samples,
                  which "proves" a plateau for a machine that simply died).
  FAIL no-closure the machine kept moving and stayed reachable but never arrived inside the
                  window (slow route, long detour, or it lost the target).
  SKIP            the premise broke: bad stand, no spawn, the player was shoved off the floor
                  mid-probe, or the tracked machine despawned/died. Never a number.

THE TELEPORT RULE — WHY A VERDICT CANNOT FLIP BETWEEN RUNS
  `robot_enemy._update_stuck` judges progress by the DIRECT distance to its target, so a machine
  walking a legitimate detour (around a tower footprint, or to a stairwell on the far side) scores
  no progress, and after STUCK_LIMIT (2.5 s) `_recover_unstuck` RELOCATES it onto navmesh 8-13 m
  from the player — on a tower, straight onto the roof polygon. Everything the body does after
  that is a relocation, not a route.
  The first version of this tool only compared the HORIZONTAL step against a flat 6 m, and the
  relocation's horizontal component is random (`_navmesh_point_near` picks a random angle and
  radius) while its VERTICAL component is the storey height. tower_roof therefore read
  PASS / INCONCLUSIVE / PASS over three identical runs: the watchdog fired every single time
  (t = 7.8-8.6 s in all six archived runs), only its sideways component sometimes stayed under
  the threshold. The flip was in the INSTRUMENT, and the finding it was hiding — "bots do not
  walk the tower, the watchdog carries them" — is the whole point of the E2 (stairs) block.
  So the rule is decisive and one-sided: ANY displacement the machine's own speed cannot produce
  ENDS that attempt, and that attempt can never be scored PASS. PASS means exactly "walked".
  That alone does NOT buy a repeatable verdict, and measuring said so: the watchdog is a RACE.
  Over the archive plus the stabilisation runs it fired on tower_floor2 in 10 of 11 attempts, on
  house_wing in 3 of 11, on yard_deck in 2 of 9 — so "PASS unless relocated" samples a coin on
  every route in between, and no decision rule over a handful of attempts fixes a coin.

TWO PHASES: WHAT THE GAME DOES vs WHAT THE LEVEL DOES
  So each probe runs twice, and the two answers are reported separately.
  PHASE A — the game as it ships. Records ONLY whether the stuck-watchdog carried the machine on
  this route. This is the E2 (stairs) finding and it is printed per probe; it is never a verdict,
  because it is the coin.
  PHASE B — the VERDICT, with the watchdog neutralised through the game's OWN exemption: a
  machine under a cryo SLOW is excused from `_update_stuck` (robot_enemy line ~1236), so a 0.95
  slow parked on the tracked body means `_recover_unstuck` can never fire. No GDScript is touched
  and nothing is hidden — the slow only ever makes the machine's job harder (95% speed, no free
  rescue from a real jam), so a PASS under it is a STRICTLY stronger claim than a PASS without
  it, and a body that wedges on a stair lip now stays wedged and is REPORTED as a wedge instead
  of being airlifted onto the roof. Phase B answers the question E0.2 actually asks — is there a
  walkable route — instead of "did the watchdog win this particular race".
  Both phases also SWEEP foreign machines every other sample: waves and the anti-camp director
  keep adding bodies that stall the tracked one in doorways, and they get denser the longer the
  sweep runs, so leaving them in makes the tool's own runtime a variable.

WHY "ON THE PLAYER'S LEVEL" IS A NARROW WINDOW AND NOT A BLANKET +-1.6 m
  `state.enemies[].dist` is a 3-D distance. A grunt standing on the ground DIRECTLY BELOW a
  player on the 3 m slab measures ~3.2 m — under a naive 3.6 m threshold that scores as
  "arrived" and every stair defect in the game reads green. The window is therefore
  `-LEVEL_DY_BELOW <= dy <= LEVEL_DY_ABOVE` (~0.7/0.9 m, calibrated on measured arrivals — see
  the constants) AND an absolute Y inside the probe's own `land` band, so a machine parked a
  storey down, or 1.2 m under the roof lip on the ramp, is never "on the floor". Closure is
  additionally CONFIRMED over CONFIRM_SAMPLES more samples: a body that reaches the radius and
  then sits at a bit-identical position without ever entering ATTACK is a wedge, not an
  arrival, and gets its own non-green verdict.

HONEST LIMITS OF THIS INSTRUMENT
  * Waves and the anti-camp director keep spawning their own machines; the probe therefore locks
    onto the ONE name that appeared after its own `spawn` and ignores everything else. Foreign
    bodies can still shove the tracked one — a wedge diagnosis is a *pointer*, confirm on the
    logged position.
  * The teleport detector answers "was this step possible on foot?", not "did the watchdog fire?".
    `_recover_unstuck`'s FIRST stage only re-seats the body on the nearest navmesh point in place
    (sub-metre in every archived run) — that is invisible here, and rightly so: it does not carry
    a machine anywhere. Only the second stage, the 8-13 m relocation, moves it further than it
    could walk. A relocation that happens to land the body about where it already stood is
    likewise not flagged, and does not need to be: it did not shorten the route.
  * A relocation DOWNWARD with a small sideways step is indistinguishable from a fall, so falls
    win the tie (the detector only counts the RISE). Every probe here parks the player ABOVE the
    machine, where the watchdog's relocation is a climb — the one direction that is checked.
  * `spawn` snaps its point to `ProceduralTerrain.height_at` — the machine always starts on the
    GROUND, which is exactly the question being asked, but it also means the spawn point drifts
    when the aim direction points off-map (the bridge clamps into the world rect).
  * The player is parked in godmode, which blocks DAMAGE, not displacement: the arriving body can
    shove him off a slab. The stand is therefore re-asserted on EVERY sample, not just once
    before the spawn — a probe whose premise moved reports SKIP, never a distance.
"""

import json
import re
import socket
import sys
import time
from pathlib import Path
from typing import Any, NamedTuple

HOST = "127.0.0.1"
LABEL = sys.argv[1] if len(sys.argv) > 1 else "reach"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 24700
ROOT = Path(__file__).resolve().parents[2]
OUT_PATH = ROOT / "showcase" / "quality2" / ("reach_%s.json" % LABEL)

# GameState.Phase.IN_MATCH — anything else is a menu / hub / post-raid summary.
PHASE_IN_MATCH = 3
# enemy_state_machine.gd: enum State { PATROL, CHASE, ATTACK, INVESTIGATE }
STATE_ATTACK = 2

SAMPLE_DT = 0.75  # seconds between `state` polls
PROBE_TIME = 35.0  # sampling window per probe
# Sample every Nth poll also asks `navdbg`. Every 2nd (=1.5 s) rather than every 4th, because
# a probe can now END at ~8 s (the abort on a watchdog relocation) and UNREACHABLE_STREAK
# consecutive answers have to fit inside that window — otherwise the strongest verdict this
# tool has ("this floor carries no navmesh at all") could never be reached on a short probe.
NAV_EVERY = 2
SPAWN_SETTLE = 1.4  # assemble tween — the first sample otherwise reads the spawn "point"
SETTLE_MAX = 3.0  # bounded wait for the teleported player to land
SETTLE_POLL = 0.12
# "Same level" (see the docstring). MEASURED on this build, from samples where the machine was
# provably arrived (state ATTACK, `target` = this player, 2.15 m, unchanged for 10+ s): the
# reported Y offset between a machine and the player standing on the SAME surface is +0.01 on
# flat terrain, +0.45 on the SWHouse wing slab and -0.38/-0.39 on the warehouse roof and the
# yard deck. So the offset is a property of the surface, not of "one step short", and any
# window tighter than ~0.5 m turns arrivals into wedges. A whole storey (>=3 m) is still far
# outside it, which is the case the guard exists for; the "parked one step under the roof"
# case (-1.18 m, measured) also stays out.
LEVEL_DY_BELOW = 0.7
LEVEL_DY_ABOVE = 0.9
PASS_DIST = 3.6  # default closure radius (grunt attack_range 2.2 + parking slack)
ATTACK_RANGE_SLACK = 1.0  # an ATTACK sample counts only inside attack_range + this
STAND_DRIFT_MAX = 1.5  # XZ metres the player may drift from the probe point before it is void
UNREACHABLE_STREAK = 3  # consecutive navdbg polls before calling it "not in navmesh"
PLATEAU_WINDOW = 10.0  # first/last N seconds compared for the wedge test
PLATEAU_GAIN = 1.0  # metres the late window must beat the early one by
SNAP_DY_MISS = 1.5  # player_snap this far below the player = the floor has no navmesh
# --- Teleport detector: the budget a WALKED step cannot exceed -------------------------------
# Not a hand-picked distance. The machine's own stat is the bound: it walks at
# `Settings.ENEMY_STATS[<archetype>].speed` m/s (grunt 4.0, read from settings.gd at startup by
# `stat_speed`, never guessed), so between two samples taken `dt` apart it can cover at most
# `speed * dt` of PATH — and the straight-line displacement, climb included, is never longer than
# the path that produced it. Anything past that budget is not locomotion.
#
# The margin is measured, not assumed. Across the 6 archived runs (565 sample intervals,
# dt ~0.78 s, budget ~3.12 m):
#     * 556 intervals <= 3.26 m and the loudest legit step is 3.40 m  -> 1.08x budget
#       (that is the grunt at its 4.0 m/s stat plus sampling jitter)
#     * every interval above that is a watchdog relocation, the SMALLEST being 6.02 m
#       (tower_floor2: 5.19 m sideways + a 3.05 m storey climb)      -> 1.98x budget
# The band 1.08x .. 1.98x is empty, so the threshold goes in the middle of it at 1.5x: 40% of
# headroom above the loudest real walk, 25% below the quietest real teleport. The suggested 2.5x
# was tried against this data and REJECTED — it sits above 1.98x and would miss the two smallest
# relocations, which is precisely the flip this fix exists to remove. Every run re-audits the
# number: `walk_headroom` reports the largest UNFLAGGED step as a fraction of the budget, so a
# build where machines legitimately move faster shows up as a shrinking margin instead of as
# silent false teleports.
TELEPORT_MARGIN = 1.5
# Floor under the budget so a freak short interval (a stalled reply, a hitched frame) cannot make
# the allowance tiny and invent a teleport out of an ordinary step.
TELEPORT_MIN_ALLOW = 2.0
FALLBACK_SPEED = 4.0  # only if settings.gd cannot be read; reported as such in the JSON
CLOCK_LEFT = 400.0  # match seconds re-set before each probe (keeps the 9-min raid out of storm)
CONFIRM_SAMPLES = 3  # samples taken AFTER the first closure; ALL must still read closed
CONFIRM_MOVE_EPS = 0.05  # a confirmation tail this static (m) is a parked body, not an arrival
MIN_ELAPSED_FRAC = 0.6  # a window cut shorter than this fraction of PROBE_TIME diagnoses nothing
# A fresh node this far (metres, HORIZONTAL) off the requested spawn distance is NOT ours.
# Horizontal because `_debug_spawn` places the body at player + facing * dist and then snaps Y
# to the terrain: on a 9 m roof the reported 3-D `dist` is sqrt(14^2 + 9^2) = 16.6 for a 14 m
# request, and a tolerance wide enough to absorb that also lets a foreign body qualify.
SPAWN_MATCH_TOL = 4.0
SPAWN_BEARING_COS = 0.5  # cos(60 deg): the fresh body must lie in the direction we aimed
# An attempt of one of these kinds saw NOTHING about the route (the watchdog carried the body, or
# the probe's own premise broke) — it is voided and repeated rather than scored. See main().
VOID_KINDS = (
    "teleport-assisted",
    "static-at-closure",
    "unconfirmed-closure",
    "target-lost",
    "stand-lost",
    "window-truncated",
    "match-ended",
    "bad-stand",
)
# Attempts per probe before "we never got a clean look" becomes the answer.
MAX_ATTEMPTS = 3
# --- Watchdog neutralisation: how the VERDICT phase is made repeatable --------------------------
# `robot_enemy._update_stuck` has ONE exemption written into the game itself: a machine under a
# cryo SLOW makes slow progress legitimately, so the stuck clock does not accumulate while
# `_status.speed_mult() < 0.99` (line ~1236) and `_recover_unstuck` can never fire. The verdict
# phase therefore parks a 0.95 SLOW on the tracked machine (`chemistry apply`, server-side) and
# refreshes it — the watchdog is switched off THROUGH THE GAME'S OWN RULE, without touching a
# single line of GDScript.
# Why this is not cheating: the slow only ever makes the machine's job HARDER. It walks at 95%
# speed, and it loses its free rescue from any real jam. A PASS measured under it is a STRICTLY
# stronger claim than a PASS without it, and a body that wedges on a stair lip now stays wedged
# and is reported as a wedge instead of being quietly airlifted onto the roof. Removing the
# game's masking mechanism is the opposite of masking the defect.
IMMUNE_SLOW_MULT = 0.95  # >CHEM_FREEZE_THRESHOLD 0.5, so no BRITTLE latch; <0.99, so no watchdog
IMMUNE_SLOW_DUR = 12.0  # seconds per application (refreshed well before it lapses)
IMMUNE_REFRESH_EVERY = 5  # samples between refreshes (~4 s) — 3x the margin on the 12 s duration
# Metres from the PLAYER inside which a foreign machine is removed mid-probe. The tracked body
# spawns at most 20 m out and walks straight in, so nothing beyond this can stand in its way —
# and sweeping wider clears whole waves, which ends the raid (see sweep_foreign).
SWEEP_RADIUS = 26.0
# Restart the match once it reaches this wave. Wave 5 is the boss and a cleared wave 5 ENDS the
# raid; restarting one wave earlier keeps every probe in the same early-wave conditions instead
# of letting probe #6 run in a denser game than probe #1.
WAVE_RESET_AT = 4


def stat_speed(spawn_id: str) -> tuple[float, str]:
    """(m/s, provenance) for a spawn id, read out of `Settings.ENEMY_STATS` in settings.gd.

    The teleport threshold is only honest if the speed it is derived from is the speed the game
    actually gives the machine, so it is READ, not typed in here — a balance pass that makes
    grunts faster must move this instrument's threshold with it. The block is found by key and
    cut at the next archetype, and a COMMENT is tolerated between the key and its brace
    (`robot_specter` has one, and a naive `"key": {` regex drops exactly that line —
    balance_matrix.py learned this the hard way).
    """
    key = spawn_id if spawn_id.startswith("robot_") else "robot_%s" % spawn_id
    path = ROOT / "autoload" / "settings.gd"
    try:
        src = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return FALLBACK_SPEED, "fallback %.1f (settings.gd unreadable: %s)" % (FALLBACK_SPEED, exc)
    start = src.find("ENEMY_STATS")
    at = src.find('"%s"' % key, start if start >= 0 else 0)
    if at < 0:
        return FALLBACK_SPEED, "fallback %.1f (%s not in ENEMY_STATS)" % (FALLBACK_SPEED, key)
    block = src[at + len(key) + 2 :]
    nxt = block.find('"robot_')
    if nxt > 0:
        block = block[:nxt]
    m = re.search(r'"speed"\s*:\s*([0-9]+(?:\.[0-9]+)?)', block)
    if not m:
        return FALLBACK_SPEED, "fallback %.1f (no speed in %s block)" % (FALLBACK_SPEED, key)
    return float(m.group(1)), "Settings.ENEMY_STATS[%s].speed" % key


class Probe(NamedTuple):
    """One vertical question: stand HERE, spawn a hunter THERE, does it arrive?"""

    name: str
    tp: tuple[float, float, float]  # explicit y ALWAYS — the bridge defaults tp to y=1.5
    land: tuple[float, float]  # accepted landing-Y band (verified live, see below)
    aim: tuple[float, float, float]  # world point the player faces; `spawn` uses this direction
    spawn_id: str = "grunt"
    spawn_dist: float = 16.0
    pass_dist: float = PASS_DIST
    # Settings.ENEMY_STATS attack_range of `spawn_id` (grunt 2.2). The ATTACK clause is bounded
    # by it: a ranged/large body (cryomortar, raiju, oni) can sit in ATTACK from the NEXT
    # structure at the same height, and an unbounded clause would score that as an arrival.
    attack_range: float = 2.2
    expect_fail: bool = False


# Landing bands and stand points are LIVE-VERIFIED against this build (tp -> settle -> state):
#   yard 30,30 -> -0.36 | tower slab -> 3.00 | tower roof -> 9.00 | warehouse roof -> 5.00
#   house wing -> 3.00  | yard deck  -> 5.20 | crate-chain top C -> 3.30
PROBES: tuple[Probe, ...] = (
    # Positive control. Flat courtyard, nothing between the two bodies: if this ever fails the
    # instrument (or the navmesh commit) is broken, not the level geometry.
    Probe("ground_control", (30.0, 1.5, 30.0), (-1.2, 0.4), (14.0, 1.0, 30.0), spawn_dist=14.0),
    # NorthTower (-40,-45), footprint x[-48.5,-31.5] z[-52.5,-37.5]. Stand away from the
    # stairwell hole (x[-48.2,-46.0] z[-50.2,-46.4]); the hunter lands ~8 m south of the wall.
    Probe("tower_floor2", (-38.0, 4.2, -43.0), (2.6, 3.6), (-40.0, 1.0, -25.0), spawn_dist=14.0),
    Probe("tower_roof", (-38.0, 11.0, -43.0), (8.6, 9.4), (-40.0, 1.0, -25.0), spawn_dist=14.0),
    # EastWarehouse (45,-28) court, roof 5.0; hunter spawns 14 m east of the wall.
    Probe("warehouse_roof", (50.0, 6.5, -34.0), (4.6, 5.4), (70.0, 1.0, -34.0), spawn_dist=20.0),
    # SWHouse (-52,30) court, wing floor 3.0 (the wing roof is decorative by design).
    Probe("house_wing", (-49.5, 4.2, 23.85), (2.6, 3.4), (-30.0, 1.0, 30.0), spawn_dist=20.0),
    # EastYard (50,42): the welded ramp's landing deck at 5.2 — the one elevated spot in the
    # game that was BUILT to be walkable, so it is the sharpest test of "ramp is in the bake".
    Probe("yard_deck", (49.5, 6.4, 48.4), (4.9, 5.5), (30.0, 1.0, 42.0), spawn_dist=20.0),
    # NEGATIVE CONTROL — top crate of the mantle chain (1.1 m cube at 3.30, reachable only by
    # the player's mantle). A bot must NOT get here; a PASS would mean the instrument lies.
    # NOTE the roadmap's literal coordinate (49.5, 3.4, 48.4) is unusable: that XZ is the 5.2
    # container stack and y=3.4 lands the player INSIDE its collider (measured: no on_floor,
    # 0.2 m depenetration drift, player_snap 2 m ABOVE the body). The crate-chain top is the
    # same question with a clean stand.
    Probe(
        "crate_top_negctl",
        (42.5, 3.6, 50.0),
        (3.0, 3.6),
        (25.0, 1.0, 55.0),
        spawn_dist=16.0,
        expect_fail=True,
    ),
)


# --------------------------------------------------------------------------- bridge transport
def send(obj: dict[str, Any], timeout: float = 30.0) -> dict[str, Any]:
    """One command, one connection (the AgentBridge protocol: one JSON line in, one out)."""
    try:
        s = socket.create_connection((HOST, PORT), timeout=timeout)
    except OSError as exc:
        return {"ok": False, "error": "connect: %s" % exc}
    try:
        s.sendall((json.dumps(obj) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(262144)
            if not chunk:
                break
            buf += chunk
    except OSError as exc:
        return {"ok": False, "error": "io: %s" % exc}
    finally:
        s.close()
    try:
        return json.loads(buf.decode())
    except ValueError as exc:
        return {"ok": False, "error": "bad reply: %s" % exc}


def wait_drivable(timeout: float = 180.0) -> bool:
    """`drivable` is a TOP-LEVEL state key; IN_MATCH is checked too.

    A finished raid parks the instance on the EXTRACTED/KIA summary with the world dimmed behind
    a modal and `drivable` can still read true there — probes run through that screen measure
    nothing (photostand learned this the expensive way).
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = send({"cmd": "state"})
        if st.get("drivable") and int(st.get("phase") or 0) == PHASE_IN_MATCH:
            return True
        time.sleep(2.0)
    return False


def settle() -> dict[str, Any]:
    """Poll until the teleported player is back on a floor (bounded, no blind sleep)."""
    t0 = time.time()
    st: dict[str, Any] = {}
    while time.time() - t0 < SETTLE_MAX:
        st = send({"cmd": "state"})
        if (st.get("player") or {}).get("on_floor"):
            return st
        time.sleep(SETTLE_POLL)
    return st


def clear_enemies(max_kills: int = 40) -> int:
    """Kill every live machine so the probe starts from a clean field.

    Waves keep respawning, so this only buys a window — the probe still tracks its own spawn
    by name. It matters anyway: a chasing body parked in a stairwell blocks the route under test
    and would be diagnosed as a geometry wedge that does not exist.
    """
    killed = 0
    for _ in range(max_kills):
        if not send({"cmd": "state"}).get("enemies"):
            break
        send({"cmd": "kill", "target": "nearest"})
        killed += 1
        time.sleep(0.1)
    return killed


def enemy_names() -> set[str]:
    return {str(e.get("name")) for e in (send({"cmd": "state"}).get("enemies") or [])}


def local_player_name() -> str:
    """Node name of THIS peer's player (AgentBridge names it after the peer id).

    `state.enemies[].target` is a node NAME, so honouring an ATTACK sample requires knowing
    which name is ours — in co-op a machine can be attacking somebody else entirely. Empty
    string = could not tell (the ATTACK clause then accepts any non-empty target and says so).
    """
    players = send({"cmd": "state"}).get("players") or []
    for pl in players:
        if pl.get("authority"):
            return str(pl.get("name"))
    return str(players[0].get("name")) if len(players) == 1 else ""


# ------------------------------------------------------------------------------- navmesh gate
def nav_gate() -> tuple[bool, dict[str, Any]]:
    """The arena's navmesh must exist AND be committed before any probe means anything.

    A per-boot lost map commit is a known failure of the threaded 320x320 bake (arena.gd
    `_verify_navmesh_commit`): every ground machine then freezes at spawn and EVERY probe would
    fail for a reason that has nothing to do with stairs. `player_snap == [0,0,0]` is its tell.
    """
    nav = send({"cmd": "navdbg"})
    reg = dict(nav.get("region") or {})
    snap = list(nav.get("player_snap") or [0.0, 0.0, 0.0])
    ok = (
        bool(reg.get("map_valid"))
        and int(reg.get("polygons") or 0) > 0
        and [round(v, 3) for v in snap] != [0.0, 0.0, 0.0]
    )
    return ok, {"region": reg, "player_snap": snap}


def nav_for(name: str) -> dict[str, Any]:
    """This machine's agent verdict + the closest navmesh point to the player, in one call."""
    nav = send({"cmd": "navdbg"})
    rec: dict[str, Any] = {}
    for e in nav.get("enemies") or []:
        if str(e.get("name")) == name:
            rec = dict(e)
            break
    rec["player_snap"] = list(nav.get("player_snap") or [0.0, 0.0, 0.0])
    return rec


# ------------------------------------------------------------------------------------- probe
def spawn_tracked(p: Probe, timeout: float = 6.0) -> str:
    """Spawn the hunter and return the name of THAT node, or "" if it never appeared.

    `hunter:true` forces CHASE and exempts it from the leash, so the machine commits to the
    player instead of wandering home; the name diff keeps wave spawns out of the sample.

    A plain name-diff is NOT enough, and this cost a probe: while the yard_deck probe spawned its
    grunt, the WorldEventDirector started a roaming-miniboss event and a `RobotDuneWarden`
    appeared in the desert quadrant in the same window. Taking the first fresh name tracked THAT
    body 103 m away and reported a FAIL that had nothing to do with the yard ramp. The spawn
    geometry is known exactly (the bridge puts the body at player + flattened facing * dist,
    then snaps Y to the terrain), so the tracked node is the fresh one whose HORIZONTAL offset
    matches the request in both length AND bearing. Matching the reported 3-D `dist` instead
    would have to absorb the whole vertical drop — 9 m on a tower roof — and a tolerance that
    wide is exactly what lets a foreign body qualify.
    """
    before = enemy_names()
    if not send({"cmd": "spawn", "id": p.spawn_id, "dist": p.spawn_dist, "hunter": True}).get("ok"):
        return ""
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(0.35)
        st = send({"cmd": "state"})
        ppos = list((st.get("player") or {}).get("pos") or [p.tp[0], p.tp[1], p.tp[2]])
        ax, az = p.aim[0] - float(ppos[0]), p.aim[2] - float(ppos[2])
        alen = (ax * ax + az * az) ** 0.5 or 1.0
        best, best_err = "", 1e9
        for e in st.get("enemies") or []:
            nm = str(e.get("name"))
            if nm in before:
                continue
            ep = [float(v) for v in (e.get("pos") or [0.0, 0.0, 0.0])]
            dx, dz = ep[0] - float(ppos[0]), ep[2] - float(ppos[2])
            horiz = (dx * dx + dz * dz) ** 0.5
            bearing = ((dx * ax) + (dz * az)) / (alen * (horiz or 1.0))
            if bearing < SPAWN_BEARING_COS:
                continue
            err = abs(horiz - p.spawn_dist)
            if err < best_err:
                best, best_err = nm, err
        if best and best_err <= SPAWN_MATCH_TOL:
            return best
    return ""


def immunise(name: str) -> bool:
    """Park a light SLOW on the tracked machine — the game's own stuck-watchdog exemption.

    Returns whether the bridge says it landed; a probe that could not immunise says so in its
    report rather than pretending the verdict phase was watchdog-free.
    """
    rep = send(
        {
            "cmd": "chemistry",
            "action": "apply",
            "target": name,
            "kind": "slow",
            "dur": IMMUNE_SLOW_DUR,
            "mag": IMMUNE_SLOW_MULT,
        }
    )
    return bool(rep.get("ok")) and bool(rep.get("applied"))


def sweep_foreign(tracked: str, enemies: list[dict[str, Any]]) -> int:
    """Kill foreign machines NEAR the experiment, mid-probe.

    The field is cleared before each attempt, but waves and the anti-camp director keep adding
    bodies for the whole 35 s window, and they get denser the longer a sweep runs. A foreign body
    parked in a doorway stalls the tracked machine on a route that is perfectly walkable, which
    is measurement noise that grows with the tool's own runtime — the thing most likely to make
    two runs disagree. Both phases sweep, so the only difference between them stays the immunity.

    NEAR, not map-wide, and this cost a whole run: sweeping every machine on a 320x320 map clears
    waves so fast that the raid reaches wave 5, the boss dies to the sweep, the match is WON and
    the world PAUSES on the summary — after which the player no longer falls onto his stand and
    four probes in a row reported "bad stand" for a reason that had nothing to do with the level.
    Only bodies inside SWEEP_RADIUS can stand between the spawn point and the player, so only
    those are removed; the rest of the map is left to play the game (see also `ensure_match`).
    """
    killed = 0
    for e in enemies:
        nm = str(e.get("name"))
        if nm and nm != tracked and float(e.get("dist") or 1e9) <= SWEEP_RADIUS:
            send({"cmd": "kill", "target": nm})
            killed += 1
    return killed


def ensure_match(reason: str = "") -> bool:
    """Guarantee an IN_MATCH, UNPAUSED, early-wave, godmoded instance before a probe runs.

    Two different accidents put the sweep's probes on a dead world, and both are silent: a raid
    that ENDS (all waves cleared, or the timer) parks the instance on the summary with the tree
    paused — `drivable` still reads true there, positions stop changing, and the tool would
    happily diagnose a "wedge" from a frozen machine. And a late-wave match is simply a different
    experiment from an early-wave one (more bodies, denser interference), so probe #6 would not
    be measuring what probe #1 measured. Restarting on either condition makes every probe of
    every run start from the same place, which is what "two runs agree" actually requires.
    """
    st = send({"cmd": "state"})
    wave = int(st.get("wave") or 0)
    live = int(st.get("phase") or 0) == PHASE_IN_MATCH and not st.get("paused")
    if live and wave < WAVE_RESET_AT and not reason:
        return True
    why = reason or ("phase=%s paused=%s wave=%d" % (st.get("phase"), st.get("paused"), wave))
    print("    [restart] %s" % why)
    send({"cmd": "mutator", "id": ""})  # a restart re-rolls it; pin "none" again first
    send({"cmd": "restart"})
    time.sleep(3.0)
    ok = wait_drivable()
    send({"cmd": "godmode", "on": True})
    return ok


def on_level(p: Probe, ey: float, py: float) -> bool:
    """Is the machine standing on the SAME floor as the player? (see the module docstring)."""
    if not (-LEVEL_DY_BELOW <= ey - py <= LEVEL_DY_ABOVE):
        return False
    return p.land[0] - LEVEL_DY_BELOW <= ey <= p.land[1] + LEVEL_DY_ABOVE


def is_closed(p: Probe, rec: dict[str, Any], ppos: list[float], local_name: str) -> bool:
    """One sample's closure test: on the player's floor AND either inside `pass_dist` or
    genuinely attacking HIM from inside its own attack range."""
    epos = [float(v) for v in (rec.get("pos") or [0.0, 0.0, 0.0])]
    if not on_level(p, epos[1], float(ppos[1])):
        return False
    dist = float(rec.get("dist") or 0.0)
    if dist <= p.pass_dist:
        return True
    est = int(rec.get("state") if rec.get("state") is not None else -1)
    if est != STATE_ATTACK or dist > max(p.pass_dist, p.attack_range + ATTACK_RANGE_SLACK):
        return False
    target = str(rec.get("target") or "")
    return target == local_name if local_name else target != ""


def run_probe(p: Probe, local_name: str = "", immune: bool = False) -> dict[str, Any]:
    """Park the player, spawn one hunter outside, sample for PROBE_TIME, diagnose.

    `immune` runs the VERDICT phase: the machine carries a light SLOW so the game's stuck-watchdog
    cannot relocate it (see IMMUNE_SLOW_MULT). Without it, the phase measures what the game
    actually does to a chasing machine on this route — which is the E2 finding, not the verdict.
    """
    out: dict[str, Any] = {"probe": p.name, "expect_fail": p.expect_fail, "immune": immune}
    if not ensure_match():
        out["verdict"] = "SKIP"
        out["kind"] = "match-ended"
        out["diagnosis"] = "instance is not IN_MATCH and a restart did not recover it"
        return out
    # Wind the match clock back before every probe. A full sweep costs ~6 min of the 9-minute
    # raid; without this the last probes run inside the final storm wave, which floods the map
    # with hunters and turns "did MY machine arrive" into a crowd-shoving experiment.
    send({"cmd": "clock", "action": "set", "left": CLOCK_LEFT})
    # End any live world event. A roaming-miniboss / contested-POI event keeps re-spawning its
    # own guards for the whole probe (and once put a DuneWarden into the name diff, see
    # spawn_tracked). Answers ok:false when nothing is active — harmless.
    send({"cmd": "event", "end": True})
    clear_enemies()
    send({"cmd": "tp", "x": p.tp[0], "y": p.tp[1], "z": p.tp[2]})
    st = settle()
    ppos = list((st.get("player") or {}).get("pos") or [0.0, 0.0, 0.0])
    out["player_pos"] = [round(v, 2) for v in ppos]
    drift = ((ppos[0] - p.tp[0]) ** 2 + (ppos[2] - p.tp[2]) ** 2) ** 0.5
    out["stand_drift_xz"] = round(drift, 2)
    if not (p.land[0] <= ppos[1] <= p.land[1]) or drift > STAND_DRIFT_MAX:
        # The stand is the experiment's premise. A player pushed out of a prop collider or
        # dropped a storey measures a DIFFERENT question, so refuse rather than report a number.
        out["verdict"] = "SKIP"
        out["kind"] = "bad-stand"
        frozen = abs(ppos[1] - p.tp[1]) < 0.01 and drift < 0.01
        out["diagnosis"] = "bad stand: y=%.2f not in %s (drift %.2f m) — %s" % (
            ppos[1],
            list(p.land),
            drift,
            (
                "the player is sitting EXACTLY on the teleport point without falling, which is "
                "what a PAUSED world looks like (raid ended behind the summary), not a bad probe "
                "point — the retry restarts the match"
                if frozen
                else "probe point needs a fix"
            ),
        )
        return out

    send({"cmd": "aim", "target": "point", "x": p.aim[0], "y": p.aim[1], "z": p.aim[2]})
    time.sleep(0.35)
    name = spawn_tracked(p) or spawn_tracked(p)  # one retry: a spawn can lose the name race
    if not name:
        out["verdict"] = "SKIP"
        out["diagnosis"] = (
            "spawn produced no new enemy node (bridge said not-ok or nothing appeared)"
        )
        return out
    out["enemy"] = name
    time.sleep(SPAWN_SETTLE)

    speed, speed_src = stat_speed(p.spawn_id)
    if immune:
        out["immunised"] = immunise(name)
        # The slow is what makes this phase repeatable, so a failed application is reported, not
        # silently tolerated — the numbers below would then be a watchdog measurement wearing a
        # verdict's clothes.
        if not out["immunised"]:
            out["immune_warning"] = (
                "chemistry slow did NOT land — this attempt is NOT watchdog-free"
            )
        speed *= IMMUNE_SLOW_MULT  # the budget must shrink with the handicap, or it stops binding
    out["walk_speed"] = speed
    out["walk_speed_source"] = speed_src + (" x %.2f slow" % IMMUNE_SLOW_MULT if immune else "")
    samples: list[dict[str, Any]] = []
    nav_polls: list[dict[str, Any]] = []
    unreachable_streak = 0
    max_unreachable_streak = 0
    teleports = 0
    first_teleport_t: float | None = None
    teleport_detail: dict[str, Any] | None = None
    walk_headroom = 0.0  # largest UNFLAGGED step as a fraction of its own budget
    swept = 0  # foreign bodies removed mid-probe (interference, not signal)
    arrived_at: float | None = None
    tail: list[dict[str, Any]] = []
    stopped = ""  # why the loop broke early: "teleport" / "gone" / "stand"
    last_pos: list[float] | None = None
    last_clock: float | None = None
    t0 = time.time()
    i = 0
    while time.time() - t0 < PROBE_TIME:
        st = send({"cmd": "state"})
        now = time.time()
        ppos = list((st.get("player") or {}).get("pos") or ppos)
        t = round(now - t0, 2)
        if int(st.get("phase") or 0) != PHASE_IN_MATCH or st.get("paused"):
            # The raid ended under the probe (a cleared final wave, the timer, a boss death).
            # The world is now FROZEN behind the summary: every position repeats, which reads as
            # a textbook "wedge". Stop before inventing that diagnosis.
            samples.append({"t": t, "match_ended": True, "phase": st.get("phase")})
            stopped = "ended"
            break
        # The STAND is the premise, and it is re-checked every sample, not once before the
        # spawn: godmode blocks damage, not displacement, and the probe deliberately walks a
        # CharacterBody3D into a parked one (CLAUDE.md: two of them in one spot get shot into
        # the air by the solver). If the player leaves the floor, both bodies end up on the
        # ground, |dy| collapses to 0 and the tool would report "closed on the player's level"
        # for a floor that was never reached.
        drift_live = ((ppos[0] - p.tp[0]) ** 2 + (ppos[2] - p.tp[2]) ** 2) ** 0.5
        if not (p.land[0] <= ppos[1] <= p.land[1]) or drift_live > STAND_DRIFT_MAX:
            samples.append({"t": t, "stand_lost": [round(v, 2) for v in ppos]})
            stopped = "stand"
            break
        rec = None
        for e in st.get("enemies") or []:
            if str(e.get("name")) == name:
                rec = e
                break
        if rec is None:
            samples.append({"t": t, "gone": True})
            stopped = "gone"
            break
        epos = [float(v) for v in rec.get("pos") or [0.0, 0.0, 0.0]]
        dist = float(rec.get("dist") or 0.0)
        dy = epos[1] - float(ppos[1])
        est = int(rec.get("state") if rec.get("state") is not None else -1)
        # Was this step possible on foot? `gain` is the displacement a WALK would have had to
        # cover: sideways plus the RISE (a drop is free — gravity does it, and a fall off a roof
        # covers ~5.6 m down in one sample). `dt` is wall-clock between the two `state` replies,
        # which is never shorter than the game time that elapsed, so the budget it buys is if
        # anything generous. See TELEPORT_MARGIN for where the 1.5 comes from.
        gain = 0.0
        allow = 0.0
        jump_xz = 0.0
        climb = 0.0
        step_dt = 0.0
        if last_pos is not None and last_clock is not None:
            jump_xz = ((epos[0] - last_pos[0]) ** 2 + (epos[2] - last_pos[2]) ** 2) ** 0.5
            climb = epos[1] - last_pos[1]
            gain = (jump_xz**2 + max(0.0, climb) ** 2) ** 0.5
            step_dt = max(1e-3, now - last_clock)
            allow = max(TELEPORT_MIN_ALLOW, speed * step_dt * TELEPORT_MARGIN)
        last_pos = epos
        last_clock = now
        samples.append(
            {
                "t": t,
                "dist": round(dist, 2),
                "dy": round(dy, 2),
                "pos": [round(v, 2) for v in epos],
                "state": est,
                "target": str(rec.get("target") or ""),
            }
        )
        if allow > 0.0 and gain > allow:
            # A displacement its own speed cannot produce. There is exactly ONE such mechanism in
            # this game (robot_enemy._recover_unstuck), and everything the body does afterwards is
            # a relocation rather than a route — so the probe ENDS here whether or not it had
            # already closed, and the verdict can never be PASS.
            teleports += 1
            if first_teleport_t is None:
                first_teleport_t = t
            teleport_detail = {
                "t": t,
                "gain_m": round(gain, 2),
                "horiz_m": round(jump_xz, 2),
                "climb_m": round(climb, 2),
                "dt_s": round(step_dt, 2),
                "allowed_m": round(allow, 2),
                "budget_x": round(gain / max(1e-6, speed * step_dt), 2),
                "after_closure": arrived_at is not None,
                "from": samples[-2]["pos"] if len(samples) > 1 else None,
                "to": [round(v, 2) for v in epos],
            }
            samples[-1]["teleport"] = teleport_detail
            stopped = "teleport"
            break
        if allow > 0.0:
            # Headroom bookkeeping: the loudest step this instrument accepted as walking, in
            # units of the machine's own budget. It is printed so the 1.5x threshold stays
            # auditable from live data instead of from the archive it was calibrated on.
            walk_headroom = max(walk_headroom, gain / max(1e-6, speed * step_dt))
        if immune and i > 0 and i % IMMUNE_REFRESH_EVERY == 0:
            immunise(name)
        if i % NAV_EVERY == 0:
            swept += sweep_foreign(name, st.get("enemies") or [])
        if i % NAV_EVERY == 0 or arrived_at is not None:
            nr = nav_for(name)
            nr["t"] = t
            nav_polls.append(nr)
            if nr.get("reachable") is False:
                unreachable_streak += 1
                max_unreachable_streak = max(max_unreachable_streak, unreachable_streak)
            elif "reachable" in nr:
                unreachable_streak = 0
        closed = is_closed(p, rec, ppos, local_name)
        if arrived_at is None:
            if closed:
                arrived_at = t
                tail = []
        else:
            # Confirmation tail: the first "closed" sample can catch the machine mid-flight
            # (dy -1.1 on a stair run, or mid-fall). EVERY sample of the tail has to still
            # read closed — one transient sample deciding the verdict is what let a body
            # parked 1.18 m under the warehouse roof score PASS.
            tail.append({"t": t, "closed": closed, "pos": epos, "state": est})
            if not closed:
                arrived_at = None
                tail = []
            elif len(tail) >= CONFIRM_SAMPLES:
                break
        i += 1
        time.sleep(SAMPLE_DT)

    live = [s for s in samples if "dist" in s]
    out["samples"] = samples
    out["nav"] = nav_polls
    out["teleports"] = teleports
    out["teleport_detected"] = bool(teleports)
    out["teleport"] = teleport_detail
    out["first_teleport_s"] = first_teleport_t
    out["walk_headroom"] = round(walk_headroom, 2)
    out["foreign_swept"] = swept
    out["max_unreachable_streak"] = max_unreachable_streak
    out["local_player"] = local_name
    if not live:
        out["verdict"] = "SKIP"
        out["diagnosis"] = "the tracked machine vanished before the first sample"
        return out
    d0 = live[0]["dist"]
    dmin = min(s["dist"] for s in live)
    elapsed = float(live[-1]["t"])
    out["dist0"] = d0
    out["dist_min"] = dmin
    out["closed_m"] = round(d0 - dmin, 2)
    out["last_pos"] = live[-1]["pos"]
    out["arrived_s"] = arrived_at
    out["elapsed_s"] = elapsed
    out["best_dy"] = min((abs(s["dy"]) for s in live), default=None)
    reach_vals = [n.get("reachable") for n in nav_polls if "reachable" in n]
    out["reachable_last"] = reach_vals[-1] if reach_vals else None
    out["path_len_first"] = next((n.get("path_len") for n in nav_polls if "path_len" in n), None)
    out["path_len_last"] = next(
        (n.get("path_len") for n in reversed(nav_polls) if "path_len" in n), None
    )
    snap = (nav_polls[-1].get("player_snap") if nav_polls else None) or [0.0, 0.0, 0.0]
    out["player_snap"] = [round(float(v), 2) for v in snap]
    snap_dy = float(ppos[1]) - float(snap[1])

    if stopped == "ended":
        out["verdict"] = "SKIP"
        out["route"] = "none"
        out["kind"] = "match-ended"
        out["diagnosis"] = (
            "the raid ended at t=%.1fs and the world is paused behind the summary — nothing after "
            "that sample is a measurement; the next attempt restarts the match" % elapsed
        )
        return out

    if stopped == "stand":
        out["verdict"] = "SKIP"
        out["route"] = "none"
        out["kind"] = "stand-lost"
        out["diagnosis"] = (
            "the player left the stand at t=%.1fs (y=%.2f, %.2f m off the probe point) — "
            "godmode stops damage, not shoving; re-run" % (elapsed, ppos[1], drift_live)
        )
        return out

    if stopped == "teleport" and max_unreachable_streak >= UNREACHABLE_STREAK:
        # The NavigationServer had already answered "this target is not reachable" often enough
        # before the body was relocated. That verdict is about the MESH, not about the machine,
        # so the teleport does not weaken it — report the stronger, geometric answer.
        out["verdict"] = "FAIL"
        out["route"] = "none"
        out["kind"] = "not-in-navmesh"
        out["diagnosis"] = (
            "floor not in navmesh: is_target_reachable() = false in %d consecutive polls before "
            "the stuck-watchdog relocated the body at t=%.1fs; closest navmesh point to the "
            "player is (%.2f, %.2f, %.2f), %.2f m below him (player y=%.2f)"
            % (
                max_unreachable_streak,
                first_teleport_t or elapsed,
                snap[0],
                snap[1],
                snap[2],
                snap_dy,
                ppos[1],
            )
        )
        return out

    if stopped == "teleport":
        # `_recover_unstuck` relocates a jammed machine onto navmesh 8-13 m from its TARGET,
        # which on a tower is the roof polygon. Anything it does after that is not a route, so
        # this is its own verdict and not a footnote on a PASS — including when the jump landed
        # it INSIDE the closure radius, which is the shape the old horizontal-only detector kept
        # scoring green.
        out["verdict"] = "INCONCLUSIVE"
        out["route"] = "teleport-assisted"
        out["kind"] = "teleport-assisted"
        # WHY this keeps happening is worth printing, because it is a finding about the GAME:
        # `_update_stuck` measures the DIRECT distance to the target, so a machine walking a
        # legitimate detour (around a footprint, or up a stairwell on the far side) makes no
        # "progress" by that measure and gets relocated after 2.5 s — even while its NAVMESH
        # path is shortening every poll. When path_len was falling at the moment of the jump,
        # say so: the route was being walked and the watchdog misjudged it.
        pl0, pl1 = out["path_len_first"], out["path_len_last"]
        progressing = (
            isinstance(pl0, (int, float))
            and isinstance(pl1, (int, float))
            and float(pl1) < float(pl0) - 2.0
        )
        out["path_was_progressing"] = bool(progressing)
        det = teleport_detail or {}
        out["diagnosis"] = (
            "stuck-watchdog RELOCATED the machine at t=%.1fs: %s -> %s in %.2fs = %.1f m "
            "(%.1f sideways + %.1f climb) where its own %.1f m/s allows %.1f m — %.1fx the walk "
            "budget, so the route was NOT walked%s. Only the navmesh verdict stands "
            "(reachable=%s, path_len %s->%s); dist %.2f->%.2f m%s"
            % (
                first_teleport_t or elapsed,
                det.get("from"),
                det.get("to"),
                float(det.get("dt_s") or 0.0),
                float(det.get("gain_m") or 0.0),
                float(det.get("horiz_m") or 0.0),
                float(det.get("climb_m") or 0.0),
                speed,
                float(det.get("allowed_m") or 0.0),
                float(det.get("budget_x") or 0.0),
                " (the jump happened AFTER it had already closed — a relocation into the "
                "closure radius is not an arrival)"
                if det.get("after_closure")
                else "",
                out["reachable_last"],
                pl0,
                pl1,
                d0,
                dmin,
                (
                    " — NOTE its navmesh path was still SHRINKING when the watchdog fired: "
                    "robot_enemy._update_stuck judges progress by DIRECT distance, which any "
                    "detour around a footprint trips by design"
                    if progressing
                    else ""
                ),
            )
        )
        return out

    if stopped == "gone":
        out["verdict"] = "SKIP"
        out["route"] = "none"
        out["kind"] = "target-lost"
        out["diagnosis"] = (
            "tracked machine despawned/died at t=%.1fs (killed by a fall, an AoE or a world-event "
            "cleanup, or `state` briefly answered with no enemies) — re-run" % elapsed
        )
        return out

    if arrived_at is not None and len(tail) >= CONFIRM_SAMPLES:
        moved = 0.0
        for a, b in zip(tail, tail[1:], strict=False):
            moved = max(
                moved,
                ((b["pos"][0] - a["pos"][0]) ** 2 + (b["pos"][2] - a["pos"][2]) ** 2) ** 0.5,
            )
        attacked = any(s["state"] == STATE_ATTACK for s in tail)
        out["confirm_move"] = round(moved, 3)
        out["confirm_attack"] = attacked
        out["route"] = "walked"
        if moved < CONFIRM_MOVE_EPS and not attacked:
            # An arrived machine either attacks or keeps shuffling. A bit-identical position
            # for the whole tail with no ATTACK is what a body wedged against a lip looks like.
            out["verdict"] = "INCONCLUSIVE"
            out["kind"] = "static-at-closure"
            out["diagnosis"] = (
                "reached %.2f m on the player's level at t=%.1fs but then sat at the IDENTICAL "
                "position %s for the whole %d-sample tail without ever entering ATTACK — "
                "verify on the position before calling this an arrival"
                % (dmin, arrived_at, out["last_pos"], CONFIRM_SAMPLES)
            )
            return out
        out["verdict"] = "PASS"
        out["kind"] = "walked"
        # `teleports` is 0 here BY CONSTRUCTION — the sampling loop ends at the first impossible
        # displacement, so a PASS cannot contain one. The headroom says how close the loudest
        # accepted step came to the threshold, which is what makes that claim auditable.
        out["diagnosis"] = (
            "WALKED to %.2f m on the player's level at t=%.1fs, confirmed by %d more samples "
            "(tail moved %.2f m, attack=%s); every step was inside the %.1f m/s walk budget "
            "(loudest %.2fx of it, threshold %.1fx) — no watchdog relocation anywhere in the probe"
            % (
                dmin,
                arrived_at,
                CONFIRM_SAMPLES,
                moved,
                attacked,
                speed,
                walk_headroom,
                TELEPORT_MARGIN,
            )
        )
        return out

    if arrived_at is not None:
        out["verdict"] = "INCONCLUSIVE"
        out["route"] = "walked"
        out["kind"] = "unconfirmed-closure"
        out["diagnosis"] = (
            "closed to %.2f m at t=%.1fs but the %.0fs window ended after only %d/%d "
            "confirmation samples — re-run"
            % (dmin, arrived_at, elapsed, len(tail), CONFIRM_SAMPLES)
        )
        return out

    if elapsed < MIN_ELAPSED_FRAC * PROBE_TIME:
        # Belt and braces: every early break above has its own verdict, so reaching this means
        # the window died for a reason nobody modelled. A FAIL diagnosis off a stub of samples
        # would be fiction either way.
        out["verdict"] = "SKIP"
        out["route"] = "none"
        out["kind"] = "window-truncated"
        out["diagnosis"] = (
            "only %.1fs of the %.0fs window was sampled (%d samples) — nothing to diagnose, re-run"
            % (elapsed, PROBE_TIME, len(live))
        )
        return out

    out["verdict"] = "FAIL"
    out["route"] = "none"
    if max_unreachable_streak >= UNREACHABLE_STREAK:
        why = (
            "floor not in navmesh: NavigationAgent3D.is_target_reachable() = false in %d consecutive polls; "
            "closest navmesh point to the player is (%.2f, %.2f, %.2f), %.2f m below him (player y=%.2f)"
            % (max_unreachable_streak, snap[0], snap[1], snap[2], snap_dy, ppos[1])
        )
        if snap_dy > SNAP_DY_MISS:
            why += " — a whole storey down, so this floor carries NO navmesh polygon at all"
        out["kind"] = "not-in-navmesh"
        out["diagnosis"] = why
        return out

    # The wedge test compares the first and last PLATEAU_WINDOW seconds — which is only a test
    # while those two slices are DISJOINT. In a window cut short, `late` is a subset of `early`
    # (identical below 10 s), min(late) == min(early) by construction, and the tool would print
    # a confident "geometric wedge" for a machine that never got a chance to move.
    early = [s["dist"] for s in live if s["t"] <= PLATEAU_WINDOW]
    late = [s["dist"] for s in live if s["t"] >= max(0.0, elapsed - PLATEAU_WINDOW)]
    disjoint = elapsed >= 2.0 * PLATEAU_WINDOW
    plateau = bool(disjoint and early and late and min(late) >= min(early) - PLATEAU_GAIN)
    if out["reachable_last"] and plateau:
        out["kind"] = "wedge"
        out["diagnosis"] = (
            "geometric wedge: path exists (reachable=true) but distance flattened "
            "(min %.2f m in the first %.0fs -> %.2f m in the last %.0fs of a %.1fs window); "
            "machine stuck at %s, player at %s"
            % (
                min(early),
                PLATEAU_WINDOW,
                min(late),
                PLATEAU_WINDOW,
                elapsed,
                out["last_pos"],
                out["player_pos"],
            )
        )
        return out
    out["kind"] = "no-closure"
    out["diagnosis"] = (
        "no closure in %.1fs sampled: %.2f -> %.2f m (reachable=%s, %d teleports%s); machine "
        "ended at %s"
        % (
            elapsed,
            d0,
            dmin,
            out["reachable_last"],
            teleports,
            "" if disjoint else ", window too short for the wedge test",
            out["last_pos"],
        )
    )
    return out


# --------------------------------------------------------------------------------------- main
def main() -> int:
    print("reachability | port %d | label %s" % (PORT, LABEL))
    # The restart below RE-ROLLS the raid mutator (35% chance of one), so an instance that was
    # clean when the operator checked it can still start the sweep on `elite_patrols` — which
    # floods the probes with modified bodies — or `night_raid`, which cuts enemy detect range by
    # NIGHT_DETECT_MULT and changes how fast a hunter locks on. Two runs of this tool would then
    # be measuring two different games. `forced_mutator = ""` pins "no mutator" for every deploy
    # of this process, so it must be set BEFORE the restart, not after it.
    send({"cmd": "mutator", "id": ""})
    # A previous session may have left the instance on the post-raid summary (phase 4): the
    # probes park the player in godmode, but ANY earlier run — or a wave that caught him before
    # godmode was on — ends the raid, and `restart` is the only way back into IN_MATCH. Try it
    # unconditionally first, so the tool is re-runnable without babysitting the instance.
    send({"cmd": "restart"})
    time.sleep(3.0)
    if not wait_drivable():
        print("FATAL: instance not drivable / not IN_MATCH after restart")
        return 2
    send({"cmd": "godmode", "on": True})  # JSON bool — the string "on" silently enables it
    st = send({"cmd": "state"})
    mutator = str((st.get("world") or {}).get("mutator") or "")
    if mutator:
        # The force did not take (an older build, or a deploy path that skipped the roll). Say so
        # loudly instead of quietly measuring a different game than the previous run did.
        print(
            "WARN: raid mutator %r is STILL active after forcing none — this run is NOT "
            "comparable with a clean one (elite_patrols/night_raid change what the probes see)"
            % mutator
        )
    else:
        print("mutator: none (forced) — runs are comparable")

    ok, gate = nav_gate()
    if not ok:
        send({"cmd": "restart"})
        time.sleep(3.0)
        wait_drivable()
        ok, gate = nav_gate()
    print(
        "navmesh gate: map_valid=%s polygons=%s player_snap=%s -> %s"
        % (
            gate["region"].get("map_valid"),
            gate["region"].get("polygons"),
            [round(v, 2) for v in gate["player_snap"]],
            "OK" if ok else "BROKEN",
        )
    )
    if not ok:
        print("FATAL: navmesh not committed (known per-boot bake failure) — probes would be noise")
        return 2

    local_name = local_player_name()
    print("local player node: %s" % (local_name or "<unknown — ATTACK samples unattributed>"))
    speed, speed_src = stat_speed(PROBES[0].spawn_id)
    print(
        "teleport gate: %.1f m/s (%s) x sample dt x %.1f, floor %.1f m — any step above that is "
        "a stuck-watchdog relocation and forbids PASS"
        % (speed, speed_src, TELEPORT_MARGIN, TELEPORT_MIN_ALLOW)
    )

    results = []
    for p in PROBES:
        print("--- %s" % p.name)
        # PHASE A — the game as it ships. No immunity: this is the one that answers "does the
        # stuck-watchdog carry a machine on this route?", which is the E2 finding. It is NEVER
        # the verdict, precisely because its outcome is a race the tool cannot control.
        native = run_probe(p, local_name, immune=False)
        if native.get("kind") in ("match-ended", "bad-stand", "target-lost", "stand-lost"):
            # The premise broke, so phase A saw nothing either way — repeat it once (run_probe
            # restarts a dead match on entry). A teleport is NOT retried here: it is the signal.
            print("    native : premise broke (%s) — repeating" % native.get("kind"))
            native = run_probe(p, local_name, immune=False)
        print(
            "    native : %-12s %s"
            % (
                native["verdict"],
                (
                    "WATCHDOG RELOCATED it at t=%ss (%.1f m, %.1fx budget)"
                    % (
                        (native.get("teleport") or {}).get("t", "?"),
                        float((native.get("teleport") or {}).get("gain_m") or 0.0),
                        float((native.get("teleport") or {}).get("budget_x") or 0.0),
                    )
                    if native.get("teleport_detected")
                    else "walked, no relocation"
                ),
            )
        )
        # PHASE B — the VERDICT, with the watchdog switched off through the game's own slow
        # exemption. An attempt whose kind is in VOID_KINDS OBSERVED NOTHING about the route, so
        # it is voided and repeated on a fresh machine up to MAX_ATTEMPTS.
        voided: list[dict[str, Any]] = []
        r = run_probe(p, local_name, immune=True)
        while r.get("kind") in VOID_KINDS and len(voided) + 1 < MAX_ATTEMPTS:
            print(
                "    attempt %d VOID (%s: %s) — repeating on a fresh machine"
                % (len(voided) + 1, r["verdict"], r.get("kind"))
            )
            voided.append(
                {
                    "attempt": len(voided) + 1,
                    "verdict": r["verdict"],
                    "kind": r.get("kind"),
                    "teleport": r.get("teleport"),
                    "diagnosis": r.get("diagnosis"),
                }
            )
            r = run_probe(p, local_name, immune=True)
        r["attempt"] = len(voided) + 1
        r["attempts_voided"] = len(voided)
        r["void_attempts"] = voided
        r["native"] = {
            "verdict": native["verdict"],
            "kind": native.get("kind"),
            "route": native.get("route"),
            "teleport": native.get("teleport"),
            "watchdog_relocated": bool(native.get("teleport_detected")),
            "arrived_s": native.get("arrived_s"),
            "reachable_last": native.get("reachable_last"),
            "path_len_first": native.get("path_len_first"),
            "path_len_last": native.get("path_len_last"),
            "path_was_progressing": native.get("path_was_progressing"),
            "diagnosis": native.get("diagnosis"),
        }
        r["watchdog_relocated_native"] = bool(native.get("teleport_detected"))
        results.append(r)
        print("    verdict: %s | %s" % (r["verdict"], r.get("diagnosis", "")))

    print("")
    hdr = "%-18s %7s %7s %7s %6s %6s %-18s %12s  %s"
    print(hdr % ("probe", "dist0", "min", "closed", "reach", "|dy|", "route", "verdict", "note"))
    bad = []
    warn = []
    for r in results:
        v = r["verdict"]
        expect_fail = r.get("expect_fail")
        if v == "SKIP":
            status = "SKIP"
            bad.append(r["probe"])
        elif v == "INCONCLUSIVE":
            # NOT green: an unproven route is exactly the lie this instrument exists to stop.
            status = "INCONCLUSIVE"
            bad.append(r["probe"])
        elif expect_fail:
            status = "PASS(neg)" if v == "FAIL" else "FALSE-PASS"
            if v != "FAIL":
                bad.append(r["probe"])
        else:
            status = v
            if v != "PASS":
                bad.append(r["probe"])
            elif r.get("teleports"):
                # Unreachable by construction (the sampling loop ends at the first impossible
                # step). If it ever prints, the detector and the verdict chain have drifted apart
                # and the PASS is not trustworthy — treat it as an instrument bug, not a result.
                warn.append(r["probe"])
        print(
            hdr
            % (
                r["probe"],
                r.get("dist0", "-"),
                r.get("dist_min", "-"),
                r.get("closed_m", "-"),
                r.get("reachable_last", "-"),
                ("%.2f" % r["best_dy"]) if r.get("best_dy") is not None else "-",
                r.get("route", "-"),
                status,
                (r.get("kind") or r.get("diagnosis", ""))[:68],
            )
        )
    if warn:
        print(
            "BUG: PASS carrying a detected teleport (%s) — detector and verdict chain disagree"
            % ", ".join(warn)
        )
    tele = [r for r in results if r.get("watchdog_relocated_native")]
    if tele:
        # ONE EXPLICIT LINE PER PROBE, whatever the verdict ended up being. This list is the
        # hand-off into E2 (stairs): every entry is a place where, IN THE SHIPPING GAME, a chasing
        # machine does not walk the route — the stuck-watchdog picks it up and puts it down on the
        # target's floor. An E2 fix has to be verified by these lines DISAPPEARING, not by a bot
        # being seen on the roof.
        print("")
        print(
            "WATCHDOG-CARRIED (phase A, game as it ships) — %d of %d probes, E2 input:"
            % (len(tele), len(results))
        )
        for r in tele:
            nat = r.get("native") or {}
            det = nat.get("teleport") or {}
            print(
                "  WARN %-17s relocated at t=%ss: %s -> %s, %.1f m in %.2fs (%.1fx its walk "
                "budget) — navmesh: reachable=%s path_len %s->%s; with the watchdog neutralised "
                "the same route verdicts %s"
                % (
                    r["probe"],
                    det.get("t", "?"),
                    det.get("from"),
                    det.get("to"),
                    float(det.get("gain_m") or 0.0),
                    float(det.get("dt_s") or 0.0),
                    float(det.get("budget_x") or 0.0),
                    nat.get("reachable_last"),
                    nat.get("path_len_first"),
                    nat.get("path_len_last"),
                    r["verdict"],
                )
            )
            if nat.get("path_was_progressing"):
                print(
                    "       ^ its navmesh path was still SHRINKING when the watchdog fired — the "
                    "route was BEING walked and the watchdog cut it short"
                )
        print(
            "  robot_enemy._update_stuck judges progress by DIRECT distance, so a detour around a"
            " footprint reads as 'stuck' and _recover_unstuck lifts the body onto the target's"
            " floor. Until E2, 'bots reach that floor' is the WATCHDOG's doing, not the level's."
        )
    unproven = [r for r in results if r.get("kind") == "teleport-assisted"]
    if unproven:
        print(
            "  NOTE %d probe(s) were relocated even WITH the watchdog neutralised (%s) — check "
            "`immunised` in the JSON before reading anything else into it."
            % (len(unproven), ", ".join(r["probe"] for r in unproven))
        )
    walked = [r for r in results if r["verdict"] == "PASS"]
    if walked:
        head = max((float(r.get("walk_headroom") or 0.0) for r in walked), default=0.0)
        print(
            "walk-budget headroom on the PASS probes: loudest accepted step %.2fx of the "
            "%.1f m/s budget vs the %.1fx threshold%s"
            % (
                head,
                speed,
                TELEPORT_MARGIN,
                "" if head < TELEPORT_MARGIN * 0.8 else "  <-- MARGIN SHRINKING, re-calibrate",
            )
        )
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    # `verdicts` is the run's fingerprint: the three outcomes and their routes, one line per
    # probe, so "two runs give the same verdicts" is a diff of this block instead of an eyeball
    # pass over the samples.
    # NOTE what is deliberately NOT in here: the phase-A watchdog flag / attempt counts. Those are
    # observations of a RACE (a route that stalls sometimes), so they may legitimately differ
    # between two runs of an unchanged build — putting them in the fingerprint would make
    # "identical verdicts" un-provable for a reason that is not a verdict.
    verdicts = {
        r["probe"]: {
            "verdict": r["verdict"],
            "kind": r.get("kind"),
            "route": r.get("route"),
            "expect_fail": bool(r.get("expect_fail")),
        }
        for r in results
    }
    OUT_PATH.write_text(
        json.dumps(
            {
                "label": LABEL,
                "port": PORT,
                "captured": time.strftime("%Y-%m-%d %H:%M:%S"),
                "mutator": mutator,
                "local_player": local_name,
                "teleport_gate": {
                    "speed_m_s": speed,
                    "speed_source": speed_src,
                    "margin_x": TELEPORT_MARGIN,
                    "min_allow_m": TELEPORT_MIN_ALLOW,
                    "rule": "gain = hypot(horizontal, RISE) per sample; gain > speed*dt*margin "
                    "is a stuck-watchdog relocation -> verdict can never be PASS",
                },
                "verdicts": verdicts,
                "watchdog_carried_native": [
                    {
                        "probe": r["probe"],
                        "verdict_watchdog_free": r["verdict"],
                        "teleport": (r.get("native") or {}).get("teleport"),
                        "path_was_progressing": (r.get("native") or {}).get("path_was_progressing"),
                    }
                    for r in tele
                ],
                "nav_gate": gate,
                "probes": results,
            },
            indent=1,
        ),
        encoding="utf-8",
    )
    print("\nreport: %s" % OUT_PATH)
    print("RESULT:", "GREEN" if not bad else "FAIL: %s" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
