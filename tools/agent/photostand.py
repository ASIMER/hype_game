"""Photostand — the repeatable acceptance shoot for a VISUAL batch (before/after honesty).

Drives an ALREADY-RUNNING `--agent` instance over its TCP bridge and captures a FIXED set of
frames (same spots, same camera angles, same in-game hours) plus isolated hero renders of the
machines, then scores every image objectively and lays them out on one contact sheet. Run it
once before a visual change and once after with different labels: the two report.json files are
directly comparable because nothing about the shoot is left to chance except the world seed.

    # launch the game first:  ...win64.exe --path "C:\\personal\\hype game" -- --agent
    python tools/agent/photostand.py before          # -> showcase/quality2/before/
    ...make the visual change, restart the instance...
    python tools/agent/photostand.py after 24700     # -> showcase/quality2/after/

Frames: urban/snow/desert/rain x day+night (one landmark per biome quadrant), interior_day
(inside the NorthTower ground floor) and combat_day (3 starter machines in front of the camera).
The in-game hour is a pure function of the match timer (start 10:00, +12 h per match), so it is
driven with `clock set` exactly like lighting_qa.py — and re-set immediately before every capture
so a long shoot never runs the match out.

METRICS (all on sRGB screen bytes, i.e. what the player actually sees — NOT linearized):
  luma            = 0.2126R + 0.7152G + 0.0722B, 0..1
  analysis region = the frame minus the top 14% and bottom 16% (HUD/ammo/hotbar bands)
  "sky"           = the top 30% of that region, "world" = the rest (reported separately because
                    a bright sky hides a black ground in any whole-frame average)
  p05..p95        = luma percentiles over "world" — p05 is the shadow floor (our cold grade used
                    to CRUSH it to 0), p50 the overall exposure, p95 the highlight roll-off
  dark_frac       = share of "world" pixels below 0.588 (=150/255) — THE metric: below that the
                    grade turns surfaces into unreadable blue-black
  saturation      = mean HSV S over "world" (chroma left after the cold grade)
  machines        = same luma stats over the alpha>0.5 mask of the isolated 640px hero render
THRESHOLDS (flagged as FAIL in report.md, they are review triggers, not hard build gates):
  DAY frame   FAIL when dark_frac > 0.50 (world sits under the grade's cold floor)
              or p95-p05 < 0.34 (no tonal range left — the frame is haze, not depth)
  NIGHT frame FAIL when p95 < 0.30 (nothing bright enough to navigate toward)
              or p50 > 0.34 (it stopped reading as night)
              — a night frame is SUPPOSED to be mostly dark, so dark_frac is not a defect there
  machine     FAIL when mean luma < 0.45 (chassis reads as a silhouette, not as painted metal)
A run whose `state.world.mutator` is non-empty is marked CONTAMINATED: fog/night_raid change the
light and make an A/B comparison meaningless (pin it with `{"cmd":"mutator","id":""}` + restart).
"""

import json
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, NamedTuple

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HOST = "127.0.0.1"
LABEL = sys.argv[1] if len(sys.argv) > 1 else "photostand"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 24700
ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "showcase" / "quality2" / LABEL

# Day-night is a pure function of the match timer (see scripts/core/day_night.gd).
DAY_START = 10.0
DAY_SPAN = 12.0
DAY_HOUR = 13.0  # high sun
NIGHT_HOUR = 21.0  # night starts at 19.5; 22.0 would end the match (storm), so stay under it
MIN_LEFT = 6.0  # never let `clock set` drop the timer into the <=2 s storm trigger

# Analysis geometry + thresholds (see the module docstring).
CROP_TOP = 0.14
CROP_BOT = 0.16
SKY_FRAC = 0.30
DARK_T = 0.588
FRAME_FAIL_DARK = 0.50
HERO_FAIL_MEAN = 0.45

# GameState.Phase.IN_MATCH — anything else means a menu, the hub, or a post-raid summary.
PHASE_IN_MATCH = 3

# Pacing (seconds) — kept as short as the engine tolerates.
SETTLE_POLL = 0.12
SETTLE_MAX = 2.5
RENDER_WAIT = 0.6  # climate particles / streaming after a teleport
SPAWN_WAIT = 1.2  # let spawned machines land + play their assemble tween


class Frame(NamedTuple):
    """One deterministic capture: where to stand, where to look, and at what hour."""

    name: str
    x: float
    z: float
    y: float  # tp height; the player then falls to the ground (interior needs a low value)
    aim: tuple[float, float, float]  # exact world point the camera is pinned to
    hour: float
    look: tuple[float, float] = (0.0, 0.0)  # extra fixed camera delta, radians (yaw+, pitch down+)
    spawn: tuple[tuple[str, float], ...] = ()  # (harness spawn id, distance ahead)


# Coordinates are verified against scripts/core/world_bounds.gd (X,Z in [-80,240], centre 80,80;
# biome_at: x<80 & z<80 urban / x>=80 & z<80 snow / x<80 & z>=80 desert / x>=80 & z>=80 rain)
# and the arena `_POI_DEFS` landmarks, so each shot frames its quadrant's themed building.
FRAMES: tuple[Frame, ...] = (
    # NW urban — the tier-3 NorthTower POI (-40,-45) seen from 20 m south. Proven spot: the
    # same pair lighting_qa.py uses, so old lighting captures stay comparable.
    Frame("urban_day", -40.0, -25.0, 6.0, (-40.0, 8.0, -45.0), DAY_HOUR),
    Frame("urban_night", -40.0, -25.0, 6.0, (-40.0, 8.0, -45.0), NIGHT_HOUR),
    # NE snow — the alpine SnowLodge POI (160,-10) + its snow climate zone, from 24 m south.
    Frame("snow_day", 160.0, 14.0, 6.0, (160.0, 7.0, -10.0), DAY_HOUR),
    Frame("snow_night", 160.0, 14.0, 6.0, (160.0, 7.0, -10.0), NIGHT_HOUR),
    # SW desert — the sandstone DesertRuins POI (0,158) + desert zone, from 24 m south.
    Frame("desert_day", 0.0, 182.0, 6.0, (0.0, 6.0, 158.0), DAY_HOUR),
    Frame("desert_night", 0.0, 182.0, 6.0, (0.0, 6.0, 158.0), NIGHT_HOUR),
    # SE rain — the Japanese Temple POI (160,158) + rain zone, from 15 m south (lighting_qa spot).
    Frame("rain_day", 160.0, 143.0, 6.0, (160.0, 10.0, 158.0), DAY_HOUR),
    Frame("rain_night", 160.0, 143.0, 6.0, (160.0, 10.0, 158.0), NIGHT_HOUR),
    # Interior — NorthTower ground floor (w17 x d15, unrotated => x in [-48.5,-31.5],
    # z in [-52.5,-37.5], ceiling 3.0 m). Stand off-centre (clear of the west stairwell) and
    # look 10 m across the room at the stair/window wall. tp y=1.0 keeps the head under the slab.
    Frame("interior_day", -38.0, -43.0, 1.0, (-46.5, 1.4, -50.5), DAY_HOUR),
    # Combat — the urban spot again (directly comparable luma) with the starter trio lined up
    # between the camera and the tower; aim lowered so the machines, not the roof, are centred.
    Frame(
        "combat_day",
        -40.0,
        -25.0,
        6.0,
        (-40.0, 2.5, -45.0),
        DAY_HOUR,
        spawn=(("grunt", 7.0), ("heavy", 10.5), ("elite", 14.0)),
    ),
)

# Isolated hero renders (chemistry/preview bypasses the 256px icon pre-warm cache).
MACHINES: tuple[str, ...] = (
    # One per silhouette FAMILY plus the tier siblings, because the roster is judged on
    # whether these read as different SHAPES (see silhouette_sheet) and not just on luma.
    "robot_grunt",
    "robot_heavy",
    "robot_elite",
    "robot_tick",
    "robot_wasp",
    "robot_specter",
    "robot_caller",
    "robot_bastion",
    "robot_frosthound",
    "robot_kappa",
    "robot_scarab",
    "robot_cryomortar",
    "robot_avalanche",
    "robot_sandworm",
    "robot_oni",
    "robot_boss",
    "player",
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


def wait_drivable(timeout: float = 90.0) -> bool:
    """`drivable` is a TOP-LEVEL state key; refs are briefly null right after a deploy.

    IN_MATCH is checked too, and that check is load-bearing: a finished raid parks the
    instance on the EXTRACTED / KIA summary with the world dimmed BEHIND a modal, and
    `drivable` can still read true there. A whole shoot was once captured through that modal
    and scored every frame at p50 0.08 — a result that looks like a catastrophic rendering
    regression and is really just the wrong screen.
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = send({"cmd": "state"})
        if st.get("drivable") and int(st.get("phase") or 0) == PHASE_IN_MATCH:
            return True
        time.sleep(2.0)
    return False


def set_hour(hour: float, total: float) -> float:
    """Drive the match clock so DayNight lands on `hour`; returns the requested time-left."""
    left = total * (1.0 - (hour - DAY_START) / DAY_SPAN)
    left = max(MIN_LEFT, min(total, left))
    send({"cmd": "clock", "action": "set", "left": left})
    return left


def settle() -> dict[str, Any]:
    """Poll until the teleported player is back on the floor (bounded, no fixed sleep)."""
    t0 = time.time()
    st: dict[str, Any] = {}
    while time.time() - t0 < SETTLE_MAX:
        st = send({"cmd": "state"})
        pl = st.get("player") or {}
        if pl.get("on_floor"):
            return st
        time.sleep(SETTLE_POLL)
    return st


def png_path(reply: dict[str, Any]) -> str:
    """`screenshot` answers with `path`, chemistry/preview with `png`."""
    return str(reply.get("path") or reply.get("png") or "")


# ------------------------------------------------------------------------------- capture verbs
def shot(frame: Frame, label: str, total: float) -> dict[str, Any]:
    """Capture one fixed frame. Never raises: a dead verb becomes a `skipped` entry."""
    out: dict[str, Any] = {"frame": frame.name, "pos": [frame.x, frame.z]}
    tp = send({"cmd": "tp", "x": frame.x, "y": frame.y, "z": frame.z})
    if not tp.get("ok"):
        out["skipped"] = "tp failed: %s" % tp.get("error", tp)
        return out
    set_hour(frame.hour, total)
    settle()
    # `look` only ACCUMULATES a delta (AgentBridge._pending_look), so the absolute framing has
    # to come from `aim point` first — then the per-frame look delta is repeatable on top of it.
    aim = send(
        {
            "cmd": "aim",
            "target": "point",
            "x": frame.aim[0],
            "y": frame.aim[1],
            "z": frame.aim[2],
        }
    )
    if not aim.get("ok"):
        out["skipped"] = "aim failed"
        return out
    if frame.look != (0.0, 0.0):
        send({"cmd": "look", "dx": frame.look[0], "dy": frame.look[1]})
    time.sleep(RENDER_WAIT)
    for eid, dist in frame.spawn:
        rep = send({"cmd": "spawn", "id": eid, "dist": dist, "hunter": False})
        if not rep.get("ok"):
            out.setdefault("warnings", []).append("spawn %s failed" % eid)
    if frame.spawn:
        time.sleep(SPAWN_WAIT)
    # Re-pin the hour right before the shutter: the match clock kept running through the setup.
    set_hour(frame.hour, total)
    time.sleep(0.25)
    st = send({"cmd": "state"})
    world = st.get("world") or {}
    player = st.get("player") or {}
    out["hour"] = world.get("hour")
    out["night"] = world.get("night")
    out["player_pos"] = player.get("pos")
    out["enemies_visible"] = len(st.get("enemies") or [])
    rep = send({"cmd": "screenshot", "name": "%s_%s" % (label, frame.name)}, timeout=60.0)
    if not rep.get("ok") or png_path(rep) == "":
        out["skipped"] = "screenshot failed: %s" % rep.get("error", rep)
        return out
    out["src"] = png_path(rep)
    return out


def hero(model_id: str, label: str) -> dict[str, Any]:
    """Isolated 640px render on a transparent background (fresh — bypasses the icon cache)."""
    out: dict[str, Any] = {"id": model_id}
    rep = send(
        {
            "cmd": "chemistry",
            "action": "preview",
            "id": model_id,
            "name": "%s_hero_%s" % (label, model_id),
            "px": 640,
        },
        timeout=90.0,
    )
    if not rep.get("ok") or png_path(rep) == "":
        out["skipped"] = "preview failed: %s" % rep.get("error", rep)
        return out
    out["src"] = png_path(rep)
    # The render rig FRAMES each model to fill the canvas, so a hero shot says nothing about
    # how big the thing actually is. The verb hands back the model's world AABB — keep it, or
    # the silhouette board will show a 2.4 m siege walker and a 0.7 m crawler as the same
    # size and quietly hide the one axis (mass) the tiers are supposed to differ on.
    aabb = rep.get("aabb")
    if isinstance(aabb, list) and len(aabb) == 3:
        out["aabb"] = [round(float(v), 3) for v in aabb]
    return out


# ------------------------------------------------------------------------------------ analysis
def _luma(rgb: np.ndarray) -> np.ndarray:
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def _saturation(rgb: np.ndarray) -> float:
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    sat = np.where(mx > 1e-6, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    return float(sat.mean())


def analyze(path: Path, is_hero: bool = False, night: bool = False) -> dict[str, Any]:
    """Objective luma/saturation stats. World frames split sky vs world; heroes mask on alpha."""
    try:
        img = Image.open(path)
        img.load()
    except OSError as exc:
        return {"ok": False, "error": "open failed: %s" % exc}
    if is_hero:
        arr = np.asarray(img.convert("RGBA"), dtype=np.float32) / 255.0
        mask = arr[..., 3] > 0.5
        if not bool(mask.any()):
            return {"ok": False, "error": "empty alpha mask (nothing rendered)"}
        lum = _luma(arr[..., :3])[mask]
        return {
            "ok": True,
            "size": [img.width, img.height],
            "coverage": round(float(mask.mean()), 4),
            "mean": round(float(lum.mean()), 4),
            "p50": round(float(np.percentile(lum, 50)), 4),
            "dark_frac": round(float((lum < DARK_T).mean()), 4),
            "saturation": round(_saturation(arr[..., :3][mask]), 4),
            "fail": bool(lum.mean() < HERO_FAIL_MEAN),
        }
    arr = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
    h = arr.shape[0]
    core = arr[int(round(h * CROP_TOP)) : h - int(round(h * CROP_BOT))]
    if core.shape[0] < 8:
        return {"ok": False, "error": "image too small to crop"}
    split = max(1, int(round(core.shape[0] * SKY_FRAC)))
    sky_l = _luma(core[:split])
    world_rgb = core[split:]
    world_l = _luma(world_rgb)
    pcts = np.percentile(world_l, [5, 25, 50, 75, 95])
    return {
        "ok": True,
        "size": [img.width, img.height],
        "world": {
            "p05": round(float(pcts[0]), 4),
            "p25": round(float(pcts[1]), 4),
            "p50": round(float(pcts[2]), 4),
            "p75": round(float(pcts[3]), 4),
            "p95": round(float(pcts[4]), 4),
            "mean": round(float(world_l.mean()), 4),
            "dark_frac": round(float((world_l < DARK_T).mean()), 4),
            "saturation": round(_saturation(world_rgb), 4),
        },
        "sky": {
            "p50": round(float(np.percentile(sky_l, 50)), 4),
            "mean": round(float(sky_l.mean()), 4),
        },
        "range": round(float(pcts[4] - pcts[0]), 4),
        "fail": _frame_fail(pcts, float((world_l < DARK_T).mean()), night),
        "fail_why": _frame_fail_why(pcts, float((world_l < DARK_T).mean()), night),
    }


# A NIGHT frame is supposed to be mostly under the readable floor — judging it by
# `dark_frac` only ever says "it is night", which is not a defect. What a night frame owes
# the player is ANCHORS (pools of light, a moonlit surface) and a floor that is not pitch
# black; what a DAY frame owes is that the world is not sitting under the grade's cold floor
# and not flattened into haze. Hence two different rules over the same percentiles.
NIGHT_MIN_P95 = 0.30  # at least some readable highlight to navigate toward
NIGHT_MAX_P50 = 0.34  # past this it stopped reading as night
DAY_MIN_RANGE = 0.34  # p95-p05: below this the frame is milk, not depth


def _frame_fail(pcts: Any, dark_frac: float, night: bool) -> bool:
    if night:
        return bool(pcts[4] < NIGHT_MIN_P95 or pcts[2] > NIGHT_MAX_P50)
    return bool(dark_frac > FRAME_FAIL_DARK or (pcts[4] - pcts[0]) < DAY_MIN_RANGE)


def _frame_fail_why(pcts: Any, dark_frac: float, night: bool) -> str:
    if night:
        if pcts[4] < NIGHT_MIN_P95:
            return "no anchors (p95 %.2f < %.2f)" % (pcts[4], NIGHT_MIN_P95)
        if pcts[2] > NIGHT_MAX_P50:
            return "not night (p50 %.2f > %.2f)" % (pcts[2], NIGHT_MAX_P50)
        return ""
    if dark_frac > FRAME_FAIL_DARK:
        return "under floor (%.0f%% > %.0f%%)" % (dark_frac * 100, FRAME_FAIL_DARK * 100)
    if (pcts[4] - pcts[0]) < DAY_MIN_RANGE:
        return "flat/milky (range %.2f < %.2f)" % (pcts[4] - pcts[0], DAY_MIN_RANGE)
    return ""


# ------------------------------------------------------------------------------- contact sheet
TILE_W = 420
TILE_H = 280
BAR_H = 22


def _font(size: int) -> Any:
    try:
        return ImageFont.load_default(size=size)
    except (OSError, TypeError):
        return ImageFont.load_default()


def _tile(src: Path | None, caption: str) -> Image.Image:
    tile = Image.new("RGB", (TILE_W, TILE_H + BAR_H), (16, 18, 20))
    if src is not None and src.exists():
        try:
            thumb = Image.open(src).convert("RGB")
            thumb.thumbnail((TILE_W, TILE_H))
            tile.paste(thumb, ((TILE_W - thumb.width) // 2, (TILE_H - thumb.height) // 2))
        except OSError:
            pass
    draw = ImageDraw.Draw(tile)
    draw.rectangle([0, TILE_H, TILE_W, TILE_H + BAR_H], fill=(30, 33, 36))
    draw.text((6, TILE_H + 4), caption[:64], fill=(235, 200, 120), font=_font(15))
    return tile


def silhouette_sheet(machines: list[dict[str, Any]], out_path: Path) -> str:
    """Black-on-white outline board — the honest test of "do these read as DIFFERENT machines".

    The owner's complaint that started this work was that every enemy looked humanoid and
    shared one signature. Colour, paint and glow all hide that: a roster can be beautifully
    varied in material and still be one shape in seven costumes. Stripping every render to
    its alpha mask removes everything except the outline, which is also all a player gets at
    100 m (a machine is 15-31 px tall there). If two families are hard to tell apart on this
    board, they are indistinguishable in play.
    """
    shots = [m for m in machines if m.get("png")]
    if not shots:
        return "no machines"
    cell = 190
    cols = min(6, len(shots))
    rows = -(-len(shots) // cols)
    sheet = Image.new("RGB", (cell * cols, (cell + 20) * rows), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    font = _font(13)
    # Put every machine on ONE world scale: the tallest gets the full cell, the rest shrink
    # in proportion to their real height. Without this the board is actively misleading —
    # each hero render is auto-framed, so a squat bunker and a lean scout look the same size
    # and "tier reads as mass, not height" becomes impossible to judge.
    heights = [float(m.get("aabb", [0, 0, 0])[1]) for m in shots]
    tallest = max(heights) if max(heights) > 0.01 else 1.0
    for i, m in enumerate(shots):
        src = OUT_DIR / str(m["png"])
        if not src.exists():
            continue
        h_world = float(m.get("aabb", [0, 0, 0])[1])
        rel = clamp01(h_world / tallest) if h_world > 0.01 else 1.0
        side = max(24, int(round(cell * (0.34 + 0.66 * rel))))
        img = Image.open(src).convert("RGBA").resize((side, side), Image.LANCZOS)
        alpha = np.asarray(img)[..., 3]
        mask = np.where(alpha > 128, 0, 255).astype(np.uint8)
        tile = Image.fromarray(np.dstack([mask] * 3))
        x, y = (i % cols) * cell, (i // cols) * (cell + 20)
        # Bottom-aligned inside the cell so every machine stands on a common floor line.
        sheet.paste(tile, (x + (cell - side) // 2, y + (cell - side)))
        label = "%s  %.1fm" % (m.get("id", ""), h_world) if h_world > 0.01 else str(m.get("id", ""))
        draw.text((x + 5, y + cell + 3), label, fill=(40, 40, 40), font=font)
    sheet.save(out_path, quality=92)
    return "pil"


def clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def contact_sheet(tiles: list[tuple[Path | None, str]], out_path: Path) -> str:
    """Labeled grid of every capture. ffmpeg does the montage; PIL is the no-ffmpeg fallback."""
    if not tiles:
        return "no tiles"
    cols = min(4, len(tiles))
    rows = -(-len(tiles) // cols)
    tmp = out_path.parent / "_tiles"
    tmp.mkdir(parents=True, exist_ok=True)
    for i in range(cols * rows):
        src, caption = tiles[i] if i < len(tiles) else (None, "")
        _tile(src, caption).save(tmp / ("t%03d.png" % i))
    cmd = [
        "ffmpeg",
        "-y",
        "-loglevel",
        "error",
        "-framerate",
        "1",
        "-start_number",
        "0",
        "-i",
        str(tmp / "t%03d.png"),
        "-vf",
        "tile=%dx%d" % (cols, rows),
        "-frames:v",
        "1",
        "-q:v",
        "3",
        str(out_path),
    ]
    how = "ffmpeg"
    try:
        res = subprocess.run(cmd, capture_output=True, check=False, timeout=180)
        if res.returncode != 0 or not out_path.exists():
            how = "pil (ffmpeg rc=%d)" % res.returncode
    except (OSError, subprocess.SubprocessError) as exc:
        how = "pil (%s)" % type(exc).__name__
    if how != "ffmpeg":
        sheet = Image.new("RGB", (cols * TILE_W, rows * (TILE_H + BAR_H)), (16, 18, 20))
        for i in range(cols * rows):
            src, caption = tiles[i] if i < len(tiles) else (None, "")
            sheet.paste(_tile(src, caption), ((i % cols) * TILE_W, (i // cols) * (TILE_H + BAR_H)))
        sheet.convert("RGB").save(out_path, quality=88)
    shutil.rmtree(tmp, ignore_errors=True)
    return how


# ------------------------------------------------------------------------------------ reporting
def _flag(entry: dict[str, Any]) -> str:
    if "skipped" in entry:
        return "SKIP"
    stats = entry.get("stats") or {}
    if not stats.get("ok"):
        return "SKIP"
    return "FAIL" if stats.get("fail") else "ok"


def report(
    meta: dict[str, Any], frames: list[dict[str, Any]], machines: list[dict[str, Any]]
) -> None:
    """Write report.json (machine-readable) + report.md (the human table + verdict)."""
    doc = {"meta": meta, "frames": frames, "machines": machines}
    (OUT_DIR / "report.json").write_text(json.dumps(doc, indent=2), encoding="utf-8")

    bad_frames = [f["frame"] for f in frames if _flag(f) == "FAIL"]
    bad_machines = [m["id"] for m in machines if _flag(m) == "FAIL"]
    skipped = [f.get("frame") or f.get("id") for f in frames + machines if "skipped" in f]

    lines: list[str] = []
    lines.append("# Photostand — `%s`" % meta["label"])
    lines.append("")
    lines.append(
        "captured %s | port %d | mutator `%s` | %s"
        % (meta["captured"], meta["port"], meta["mutator"] or "-", meta["status"])
    )
    if meta["contaminated"]:
        lines.append("")
        lines.append(
            "> **CONTAMINATED** — raid mutator `%s` was active; light/particles are not the "
            "baseline, so this run is NOT comparable to a clean one." % meta["mutator"]
        )
    lines.append("")
    lines.append(
        "Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top %d%% / "
        "bottom %d%% (HUD). `%%<%.3f` = share of WORLD pixels under the readable floor."
        % (int(CROP_TOP * 100), int(CROP_BOT * 100), DARK_T)
    )
    lines.append("")
    lines.append("## Frames")
    lines.append("")
    lines.append("| frame | hour | p05 | p50 | p95 | range | %%<%.3f | sat | status |" % DARK_T)
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for f in frames:
        flag = _flag(f)
        if flag == "SKIP":
            lines.append(
                "| %s | - | - | - | - | - | - | - | SKIP (%s) |"
                % (f["frame"], f.get("skipped", (f.get("stats") or {}).get("error", "?")))
            )
            continue
        w = f["stats"]["world"]
        why = f["stats"].get("fail_why") or ""
        lines.append(
            "| %s | %.1f | %.3f | %.3f | %.3f | %.3f | %.1f%% | %.3f | %s |"
            % (
                f["frame"],
                float(f.get("hour") or 0.0),
                w["p05"],
                w["p50"],
                w["p95"],
                f["stats"].get("range", w["p95"] - w["p05"]),
                w["dark_frac"] * 100.0,
                w["saturation"],
                flag if not why else "%s — %s" % (flag, why),
            )
        )
    lines.append("")
    lines.append("## Machines (isolated 640px renders, alpha>0.5 mask)")
    lines.append("")
    lines.append("| model | mean | p50 | %%<%.3f | sat | coverage | status |" % DARK_T)
    lines.append("|---|---|---|---|---|---|---|")
    for m in machines:
        flag = _flag(m)
        if flag == "SKIP":
            lines.append(
                "| %s | - | - | - | - | - | SKIP (%s) |"
                % (m["id"], m.get("skipped", (m.get("stats") or {}).get("error", "?")))
            )
            continue
        s = m["stats"]
        lines.append(
            "| %s | %.3f | %.3f | %.1f%% | %.3f | %.1f%% | %s |"
            % (
                m["id"],
                s["mean"],
                s["p50"],
                s["dark_frac"] * 100.0,
                s["saturation"],
                s["coverage"] * 100.0,
                flag,
            )
        )
    lines.append("")
    verdict = "VERDICT: %d/%d frames FAIL, %d/%d machines FAIL" % (
        len(bad_frames),
        len(frames),
        len(bad_machines),
        len(machines),
    )
    # ASCII only: this line is also printed to a Windows console (cp1251 there would raise
    # UnicodeEncodeError on an em-dash and kill the run right at the finish line).
    if bad_frames:
        verdict += " | dark frames: %s" % ", ".join(bad_frames)
    if bad_machines:
        verdict += " | dark machines: %s" % ", ".join(bad_machines)
    if skipped:
        verdict += " | skipped: %s" % ", ".join(str(s) for s in skipped)
    if meta["contaminated"]:
        verdict += " | CONTAMINATED (mutator %s)" % meta["mutator"]
    lines.append("**%s**" % verdict)
    lines.append("")
    lines.append("Contact sheet: `contact.jpg` (montage via %s)." % meta["contact"])
    lines.append("")
    (OUT_DIR / "report.md").write_text("\n".join(lines), encoding="utf-8")
    print(verdict)


# ----------------------------------------------------------------------------------------- main
def _collect(entry: dict[str, Any], is_hero: bool) -> Path | None:
    """Copy a capture out of the game's user:// folder into the report dir + analyze it."""
    src = entry.get("src")
    if not src:
        return None
    name = ("%s.png" % entry.get("frame")) if not is_hero else ("hero_%s.png" % entry.get("id"))
    dst = OUT_DIR / name
    try:
        shutil.copy2(src, dst)
    except OSError as exc:
        entry["skipped"] = "copy failed: %s" % exc
        return None
    entry["png"] = name
    entry["stats"] = analyze(dst, is_hero=is_hero, night=bool(entry.get("night")))
    return dst


def _wait_contract_clear(timeout: float = 22.0) -> None:
    """Sleep until the deploy raid-contract modal has auto-dismissed (best effort).

    There is no state flag for the offer, so this waits out its known lifetime measured
    from match start: `match_timer.left` counting down from `total` tells us how far in we
    are, and the offer is gone by ~20 s.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        timer = send({"cmd": "state"}).get("match_timer") or {}
        total = float(timer.get("total") or 0.0)
        left = float(timer.get("left") or 0.0)
        if total <= 0.0 or (total - left) > 20.0:
            return
        time.sleep(1.5)


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    st0 = send({"cmd": "state"})
    if not st0.get("drivable") or int(st0.get("phase") or 0) != PHASE_IN_MATCH:
        # A KIA, an idle bleed-out or an accidental extraction parks the instance on the
        # post-raid summary — one restart, then wait it out.
        send({"cmd": "restart"})
        time.sleep(6.0)
    if not wait_drivable(90.0):
        print("not drivable — launch the game with `-- --agent` first (port %d)" % PORT)
        return 1
    send({"cmd": "godmode", "on": True})
    st = send({"cmd": "state"})
    mutator = str((st.get("world") or {}).get("mutator") or "")
    total = float((st.get("match_timer") or {}).get("total") or 300.0)
    contaminated = mutator != ""
    print(
        "mutator=%r total=%.0fs -> %s"
        % (mutator, total, "CONTAMINATED" if contaminated else "clean")
    )

    # The raid-contract offer pops a full-width modal a few seconds into a fresh match and
    # auto-dismisses at ~15 s. Shooting through it puts a card stack over half the frame and
    # skews the histogram, so wait it out once before the first shutter.
    _wait_contract_clear()

    frames: list[dict[str, Any]] = []
    tiles: list[tuple[Path | None, str]] = []
    for frame in FRAMES:
        entry = shot(frame, LABEL, total)
        dst = _collect(entry, is_hero=False)
        frames.append(entry)
        caption = frame.name
        stats = entry.get("stats") or {}
        if stats.get("ok"):
            caption = "%s  p50 %.2f  dark %.0f%%" % (
                frame.name,
                stats["world"]["p50"],
                stats["world"]["dark_frac"] * 100.0,
            )
        tiles.append((dst, caption))
        print("  %-14s %s" % (frame.name, entry.get("skipped", "ok")))

    machines: list[dict[str, Any]] = []
    for model_id in MACHINES:
        entry = hero(model_id, LABEL)
        dst = _collect(entry, is_hero=True)
        machines.append(entry)
        caption = model_id
        stats = entry.get("stats") or {}
        if stats.get("ok"):
            caption = "%s  mean %.2f" % (model_id, stats["mean"])
        tiles.append((dst, caption))
        print("  %-18s %s" % (model_id, entry.get("skipped", "ok")))

    how = contact_sheet(tiles, OUT_DIR / "contact.jpg")
    silhouette_sheet(machines, OUT_DIR / "silhouettes.jpg")
    meta = {
        "label": LABEL,
        "port": PORT,
        "captured": time.strftime("%Y-%m-%d %H:%M:%S"),
        "mutator": mutator,
        "contaminated": contaminated,
        "status": "CONTAMINATED" if contaminated else "clean",
        "match_total": total,
        "day_hour": DAY_HOUR,
        "night_hour": NIGHT_HOUR,
        "thresholds": {
            "dark_luma": DARK_T,
            "frame_fail_dark_frac": FRAME_FAIL_DARK,
            "hero_fail_mean": HERO_FAIL_MEAN,
        },
        "crop": {"top": CROP_TOP, "bottom": CROP_BOT, "sky_frac": SKY_FRAC},
        "contact": how,
    }
    report(meta, frames, machines)
    print("out: %s" % OUT_DIR)
    return 0


if __name__ == "__main__":
    sys.exit(main())
