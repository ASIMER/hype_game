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

The shoot RESTARTS the match three times: before the outdoor frames, before the interiors, and
before the readability block (plus once more if an interior fails its confirmation). That is not
hygiene, it is the measurement — an instance that has been up for a while carries accumulated
waves, spent world events and dropped loot, and the interiors additionally LOSE LIGHT with
time-in-match (see INDOOR_CONFIRM_TOL). Anything you set up by hand in the match is discarded.

Frames: urban/snow/desert/rain x day+night (one landmark per biome quadrant), SIX interiors
(NorthTower ground floor day + night + its second storey, the SnowDepot shed, the SWHouse back
wing, the ShrineHouse room), combat_day (3 starter machines in front of the camera) and FOUR
readability A/B pairs shot last, in their own restarted match. The interior
set exists because "there is fog inside buildings" was un-measurable with a single indoor frame:
six of them across three biomes, three storeys and both hours turn it into `range` and `p50`.
The in-game hour is a pure function of the match timer (start 10:00, +12 h per match), so it is
driven with `clock set` exactly like lighting_qa.py — and re-set immediately before every capture
so a long shoot never runs the match out.

WHAT MAKES A FRAME REPEATABLE (all four measured into existence on 2026-08-21; together they
change every number this tool produced before that date, which is the point — the old ones were
taken through the defects):
  * THE POSE IS SETTLED ON THE GROUND, not on `on_floor`. That flag stays TRUE for a frame or
    two after a teleport, so the old shutter aimed from the TELEPORT HEIGHT: outdoor stands drop
    6 m, interiors 1 m, and every committed frame carries that much pitch error. `_settle_grounded`
    waits for two identical heights instead.
  * THE EXPOSURE IS SETTLED ON ITS OWN p50 (`_settle_exposure`). A `clock set` snaps the match
    timer but needs ~1 s to reach the screen (p50 0.31 at t+0.1 s, 0.53 at t+0.57 s, 0.56 from
    t+1.0 s), and volumetric fog re-accumulates for another 2-3 s after a teleport. The old
    shutter fired 0.25 s after the last `clock set`, inside both ramps — which is why two
    committed runs scored urban_day at 0.202 and 0.179 while five others put it at 0.52-0.57,
    and why the NorthTower interior scattered 0.436-0.666 when a settled burst from that same
    pose repeats to 0.0007.
  * INTERIORS ARE SHOT IN FIRST PERSON. In third person the camera sits ~3.5 m behind the player,
    INSIDE the room, and the SpringArm collapses onto anything between the two: a machine, a rack,
    a table. Measured at the SnowDepot — nine shots from ONE frozen pose, seven at p50 0.411-0.413
    and two at 0.304-0.305, the difference being a frosthound that walked behind the player. First
    person has no arm, and it also takes the player's own dark, breathing body out of a tenth of
    the measured area. Outdoor frames stay third person (the body is a few percent of a wide shot,
    and those stands are comparable to every before/after image ever taken from them).
  * INTERIORS ARE CLEARED (`Frame.clear`): the active world event is ended — its banner and its
    beacon land inside the analysed crop, and a supply cache spawns AT a POI, i.e. inside these
    very rooms — and the machines standing in the camera's lap are killed. The clear is small on
    purpose; a big sweep is its own disease (see FRAME_CLEAR_RADIUS). OUTDOOR frames are left
    alone: a distant machine is a few pixels there, and combat_day spawns its trio ON PURPOSE.
  * INTERIORS ARE CONFIRMED. Every one is shot a second time at the end of the block, and if it
    disagrees with itself the match is restarted and the interiors are shot again — because
    roughly one run in three an interior loses its ambient outright and never gets it back
    (INDOOR_CONFIRM_TOL carries the evidence). Both readings go into report.json and the report
    says, in the header and in the verdict, that it happened.

METRICS (all on sRGB screen bytes, i.e. what the player actually sees — NOT linearized):
  luma            = 0.2126R + 0.7152G + 0.0722B, 0..1
  analysis region = the frame minus the top 14% and bottom 16% (HUD/ammo/hotbar bands)
  "sky"           = the top 30% of that region, "world" = the rest (reported separately because
                    a bright sky hides a black ground in any whole-frame average) — OUTDOOR
                    frames only. An INDOOR frame (`Frame.indoor`) is analysed over the FULL
                    crop: that top band is the ceiling and the upper walls, which is exactly
                    where interior haze stratifies, and dropping it as "sky" threw away a third
                    of the evidence the interior set exists to collect. The choice is recorded
                    per row (`stats.region`, `region` column in report.md), so interior numbers
                    are comparable to other INDOOR runs, not to a pre-2026-08 interior row.
  p05..p95        = luma percentiles over "world" — p05 is the shadow floor (our cold grade used
                    to CRUSH it to 0), p50 the overall exposure, p95 the highlight roll-off
  dark_frac       = share of "world" pixels below 0.588 (=150/255) — THE metric: below that the
                    grade turns surfaces into unreadable blue-black
  saturation      = mean HSV S over "world" (chroma left after the cold grade)
  machines        = same luma stats over the alpha>0.5 mask of the isolated 640px hero render
  readability     = the A/B pair (see `analyze_readability`): the same frame shot without and
                    with ONE machine at the crosshair, so the pixel difference IS the machine.
                    contrast = mean |luma of that mask - median luma of the ring around it|.
                    The hero render answers "is this chassis painted light enough"; this
                    answers "does it separate from the ground it is actually standing on".
                    Each probe shoots TWO pairs and reports their mean plus the band and the
                    spread — the DAY gate sits inside this tool's own run-to-run scatter, so a
                    row FAILs only when the whole band is under it. The shutter is gated on the
                    MEASURED range (12 +- 1.5 m), because contrast is compared across probes
                    and a fixed delay put every archetype at a different apparent size.

WHAT THE NUMBERS CANNOT SEPARATE (learned the hard way, twice):
  * SKY STATE. Sky3D's cumulus keeps evolving, so a frame that is mostly sky — rain_day worst
    of all — can move its median by ~0.04 between two runs of IDENTICAL code, purely on cloud
    cover. Trust a light change only when several biomes move TOGETHER; a lone sky-heavy frame
    disagreeing with the others is usually the weather, and the side-by-side images will show it.
    A SEALED interior is immune to this (roof + walls) — a covered veranda is not, which is why
    the temple frame no longer exists: it drifted 0.052 between two runs while the sealed
    interiors moved <=0.017, and four different framings of that same engawa all moved the SAME
    direction in the same minute. See `interior_shrine_day` for what replaced it.
  * FRAME CONTENT. combat_day spawns live machines and the count varies; the street props added
    in D3.4 put dark, saturated objects into every outdoor frame. Both shift the histogram
    without a single light changing. "The world got richer" and "the lighting got worse" look
    the same here — which is why every regression in this file is confirmed on a matched CROP
    or on the paired images before it is believed.
THRESHOLDS (flagged as FAIL in report.md, they are review triggers, not hard build gates):
  DAY frame   FAIL when dark_frac > 0.50 (world sits under the grade's cold floor)
              or p95-p05 < 0.34 (no tonal range left — the frame is haze, not depth)
  NIGHT frame FAIL when p95 < 0.30 (nothing bright enough to navigate toward)
              or p50 > 0.34 (it stopped reading as night)
              — a night frame is SUPPOSED to be mostly dark, so dark_frac is not a defect there
  machine     FAIL when mean luma < 0.45 (chassis reads as a silhouette, not as painted metal)
  readability DAY pair FAILs when contrast < 0.10 (the machine melts into its background);
              NIGHT pairs are report-only — there the number is mostly the emissive eye
A run whose `state.world.mutator` is non-empty is marked CONTAMINATED: fog/night_raid change the
light and make an A/B comparison meaningless (pin it with `{"cmd":"mutator","id":""}` + restart).
"""

import json
import math
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

# --- Readability (the A/B pair; see `analyze_readability` for what these mean) ----------------
READ_DIFF_T = 0.055  # |luma_B - luma_A| above which a pixel is called "the machine"
READ_DIFF_T_NIGHT = 0.028  # night frames carry a fraction of the day's luma; so does their noise
READ_RING_PX = 12  # width of the background ring dilated around the mask
READ_FAIL_CONTRAST = 0.10  # DAY fail threshold on the machine-vs-background separation
READ_COVER = (0.002, 0.25)  # sane mask share of the analysis region; outside => SKIP
READ_DESPECKLE_MIN = 5  # of the 9 pixels in a 3x3, this many must be masked to keep one
# RANGE CONTROL. The probe machine is a CHASING hunter: it is spawned FURTHER out than the
# range the pair is shot at, and shutter B waits for it to walk INTO that range. Without this
# the shutter fired at a fixed delay and every probe measured a different apparent size —
# 8.71 m for a grunt, 9.42 for a heavy, 6.56 for a frosthound on the committed runs, none of
# them the "12 m" the docstring claimed — while `contrast` is compared ACROSS probes.
# The SPAWN distances are the ones whose lane is known clear: pushing the urban spawn out to
# 15 m to shoot at 12 m put the body behind something at z -33, where it milled for 4.5 s at
# 14.7 m until the stuck-watchdog relocated it SIDEWAYS out of frame (measured live). The
# shooting range is therefore set to what a machine spawned on a clear lane actually reaches.
READ_SPAWN_DIST = 12.0  # metres ahead the machine is PUT (per-probe override in ReadProbe)
READ_SHOT_DIST = 8.5  # ...and the range shutter B is opened at
READ_DIST_TOL = 1.0  # a shutter outside SHOT_DIST +- this makes the rep invalid (no number)
READ_APPROACH_POLL = 0.25  # how often the closing distance is polled while waiting
READ_APPROACH_MAX = 8.0  # give-up window for the machine to reach the shooting range
# cos(41 deg) — the horizontal half-FOV at 60 deg vertical on 16:9 is ~46 deg, so a target
# under this is off-frame anyway. Shooting one is how a pair ends up measuring bare ground.
READ_AXIS_COS = 0.75
# Earliest the shutter may open after the spawn: the spawn theatre has to be over (assemble
# 0.38 s, drop-pod fall 0.32 s, its dust one-shot lifetime 0.95 s => ~1.3 s).
READ_SPAWN_WAIT = 1.5
# Each probe is shot TWICE in a row. The gate (0.10) sits inside this instrument's own
# run-to-run band — the snow probe measured 0.1364 and 0.1016 on two runs of IDENTICAL code —
# so a single shutter decides FAIL/ok on a coin flip. A pair of shots per probe turns that into
# a measured band: the row FAILs only when the WHOLE band is under the threshold, and the
# spread is printed next to the number so nobody reads a 0.1016 as "comfortably passed".
READ_REPS = 2
READ_LIGHT_SETTLE = 0.7  # per poll of the adaptive settle after a clock jump
READ_SETTLE_DIFF = 0.02  # frame-to-frame diff share under which the light is called settled
READ_SETTLE_TRIES = 6
PIVOT_HEIGHT = 1.5  # Player.tscn CameraPivot y — the first-person eye
TARGET_CENTRE_UP = 0.35  # spawn puts the body origin ~0.5 m over ground; aim at its middle
READ_CLEAR_R = 45.0  # kill foreign machines this far ahead before the shutter
READ_CLEAR_NEAR = 9.0  # ...and this close in ANY direction (3rd-person camera sits behind)
READ_CONE_COS = 0.64  # cos(50 deg) — "ahead" for the clear step
READ_CLEAR_MAX = 8  # kill budget per probe (a runaway loop just completes waves)
READ_GRACE_ELAPSED = 30.0  # match-clock elapsed parked between probes (see readability_block)

# Mirror of scripts/ui/raid_levelup.gd — the in-raid level-up OFFER is a modal that lands in
# the middle of the frame, and the clear step's kills are what open it. There is no state flag
# for it, so the count is mirrored here and the shutter waits out the auto-pick. If those two
# constants ever change in the game, this only over-waits (harmless) or shoots through a card
# stack (visible instantly on the contact sheet).
LEVELUP_KILLS_BASE = 4
LEVELUP_KILLS_PER_LEVEL = 2
LEVELUP_PICK_WAIT = 12.8  # PICK_TIME 12.0 + a frame of slack

# GameState.Phase.IN_MATCH — anything else means a menu, the hub, or a post-raid summary.
PHASE_IN_MATCH = 3

# Pacing (seconds) — kept as short as the engine tolerates.
SETTLE_POLL = 0.12
SETTLE_MAX = 2.5
RENDER_WAIT = 0.6  # climate particles / streaming after a teleport
SPAWN_WAIT = 1.2  # let spawned machines land + play their assemble tween

# --- Interior frame hygiene (`Frame.clear`; see the module docstring) -------------------------
# Radius around the STAND inside which a live machine is cleared before the shutter. It is not
# "what is in shot": the third-person camera sits ~3.5 m BEHIND the player, and the SpringArm
# collapses onto anything that gets between the two — a machine standing on the player's back
# turns the frame into a close-up of his own chassis.
#
# 6 m and FOUR kills, which is far less than "clear the room" — and the small numbers are the
# whole point, because in THIS game a sweep is not free:
#   * every kill drops a Mutant-Harvest limb with a GLOWING drop-billboard, i.e. clearing a
#     room trades machines for light sources, and
#   * the kills are noise, so the AIDirector answers them with reinforcements.
# Together those two make a big sweep a positive-feedback loop. Measured at 18 m: the loop hit
# its budget on every interior (20 kills, never converging) and the litter it left in the
# NorthTower walked interior_night from a rock-steady 0.379 to 0.402 and then 0.436. Repeating
# the pair five times at 12 m showed the ramp outright — 0.386, 0.406, 0.436, 0.445, 0.482,
# monotonic, from an IDENTICAL pose (position, yaw and pitch equal to four decimals), with the
# light gate's residual climbing 0.008 -> 0.087 as the room filled with drops.
# 6 m is the SpringArm's working volume (the camera sits ~3.5 m behind the player): it removes
# the ONE thing that actually wrecks a frame — a machine wedged between the camera and the
# player, which collapses the arm into a close-up of his own back — and nothing else. Machines
# at 8-15 m are a few dozen pixels and cost less than the loot pile that removing them creates.
FRAME_CLEAR_RADIUS = 6.0
FRAME_CLEAR_MAX = 4  # kill budget per frame; more than this and the cure is worse than the bug
# --- Exposure gate (`_settle_exposure`) -------------------------------------------------------
# The shutter waits until the frame's OWN p50 stops moving. Not a pixel-diff gate (that is
# `_settle_light`, for the readability pairs) and not a fixed sleep, because the two things a
# frame has to outlast ramp at completely different speeds:
#   * the clock jump reaches the screen in ~1 s (p50 0.31 -> 0.53 -> 0.56 over the first second),
#   * volumetric fog re-accumulates for 2-3 s after a teleport, and it does so as a slow wash
#     over the WHOLE image — which is invisible to a pixel-diff gate and dominates the median.
# Measured at the NorthTower interior (a dense FogVolume plume): p50 0.440 at t+0.14 s, 0.429 at
# t+1.2 s, then flat at 0.4338 +- 0.0006 from t+2.7 s to t+9 s. The old shutter fired inside
# that, which is why the tower frames scattered 0.436-0.666 while a settled burst at the same
# pose repeats to 0.0007.
FRAME_EXPOSURE_TOL = 0.004  # |dp50| between polls that counts as "stopped"
FRAME_EXPOSURE_POLL = 0.5
FRAME_EXPOSURE_TRIES = 12  # ~6 s ceiling; a frame that needs more says so in `exposure_drift`

# --- Indoor-light collapse: an ENGINE defect this tool has to survive, not hide ----------------
# Roughly one run in three, one interior comes back with its ambient gone: the lamp pool and the
# emissive props stay lit, every surface the sky used to reach goes black. Measured, so that the
# next person does not re-derive it:
#   * it is NOT the shutter — the exposure gate reports drift 0.000 on the dark capture, and a
#     16-exposure burst from the same pose repeats the dark value to 0.007;
#   * it is NOT the clock — driving 13:00 -> 21:00 -> 13:00 moves the dark room by 0.006, i.e.
#     the room stops responding to the day-night cycle entirely;
#   * it is NOT global — the outdoor frames of the same run are normal (sun-dominated), and in
#     one run only ONE of the six interiors was affected while the two shot either side of it
#     were fine;
#   * teleporting far away and back does NOT repair it. A match restart does, every time.
# So the tool RE-MEASURES every interior at the end of the frame block. If a frame disagrees
# with its own first capture by more than this tolerance, the run restarts the match and shoots
# the interiors again, and the report says it did, with both readings. The tolerance sits under
# the 0.05 an interior frame is allowed to move between RUNS and well over the <=0.006 they move
# within one.
INDOOR_CONFIRM_TOL = 0.03


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
    # INDOOR frames are analysed over the FULL crop. The top 30% band is called "sky" and
    # dropped outdoors because a bright sky hides a black ground — but indoors that band is the
    # CEILING and the upper walls, i.e. precisely where fog stratifies and where "there is fog
    # inside buildings" is visible. Dropping it threw away a third of the evidence the interior
    # set exists to collect, under a label that is false indoors.
    indoor: bool = False
    # Clear the stand before the shutter: end the active world event (its banner lands inside
    # the analysed crop) and kill every machine within FRAME_CLEAR_RADIUS. INTERIORS ONLY —
    # see the module docstring for the measurement that put it here. An outdoor frame keeps its
    # machines on purpose (they are a few pixels at that scale, and combat_day spawns its own).
    clear: bool = False


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
    Frame(
        "interior_day", -38.0, -43.0, 1.0, (-46.5, 1.4, -50.5), DAY_HOUR, indoor=True, clear=True
    ),
    # Same spot, same aim, night hour — the pair E1.5 is judged on. `analyze` picks the night
    # ruleset from `state.world.night` at the shutter, not from the frame name, so nothing else
    # has to change. Shot straight after interior_day so the two are pixel-comparable.
    Frame(
        "interior_night",
        -38.0,
        -43.0,
        1.0,
        (-46.5, 1.4, -50.5),
        NIGHT_HOUR,
        indoor=True,
        clear=True,
    ),
    # NorthTower FLOOR 2 (slab at y 3.0; tp 4.2 drops onto it — see loot_audit's "tower flight
    # -> floor 2" check). Stand clear of the west stairwell hole (x [-48.2,-46.0],
    # z [-50.2,-46.4]) and look ~8.7 m at the east window wall: at this range the ceiling, the
    # lamp, the window and the fit-out furniture all survive the haze, which a 13 m diagonal
    # does not (scouted in first person: it comes back as pure milk, p95-p05 0.46 with half the
    # frame over the readable floor — that IS the tower plume, but it is not a measurement).
    # Second storey of the SAME building as interior_day on purpose: the fog plume over the
    # tower is height-dependent and the pair measures that.
    #
    # The stand moved 4 m WEST when the interiors went first person. The aim point is unchanged,
    # and that is the point: in third person the camera sat ~3.5 m behind the player, so the old
    # stand put this same wall ~8 m from the LENS. Keeping the stand would have put it ~1 m from
    # a first-person eye — a frame of blank plaster that repeated to 0.0001 and measured nothing.
    Frame(
        "interior_tower2_day",
        -40.0,
        -42.0,
        4.2,
        (-32.0, 4.3, -38.5),
        DAY_HOUR,
        indoor=True,
        clear=True,
    ),
    # Warehouse interior — the SnowDepot (205,40), NOT the nearer EastWarehouse: that one is
    # `court: true`, i.e. a 3-sided shed whose "interior" is a 4.5 m covered strip open to the
    # south, so the third-person camera always sits outside the roofline and half the frame is
    # sky (verified live: every framing there measures outdoor light). SnowDepot is the same
    # `warehouse` theme built `court: false` — four walls, roller door, roof at 5.0, racking —
    # and it puts one interior in the SNOW quadrant, so the set spans three biomes.
    # `clear=True` here is not cosmetic: this is the frame that exposed the SpringArm collapse
    # (nine shots from one frozen pose, two of them a close-up of the player's own back because
    # a frosthound walked behind him). The snow quadrant's patrols converge on a standing player,
    # so this stand attracts them faster than any other in the set.
    Frame(
        "interior_warehouse_day",
        208.0,
        40.0,
        1.0,
        (198.0, 2.6, 38.0),
        DAY_HOUR,
        indoor=True,
        clear=True,
    ),
    # House interior — SWHouse (-52,30) is `court: true`, so the enclosed part is the back wing
    # (world z [22.5,25.5], ceiling = the wing slab at 3.0) with the ground->wing stair flight at
    # x -55. Stand at the west end and look east along the wing: brick wall left, staircase dead
    # ahead, slab overhead — the one frame in the set with a stair in it.
    Frame(
        "interior_house_day",
        -56.0,
        24.0,
        1.0,
        (-48.0, 1.4, 23.2),
        DAY_HOUR,
        indoor=True,
        clear=True,
    ),
    # RAIN-quadrant interior — the ShrineHouse (205,205): `house` theme, w14 x d14, built
    # `court: false`, so it is a real four-walled room (interior x,z in [198.3,211.7], slab
    # ceiling at 3.0, one lamp at the centre, brick, a stair flight and a fit-out).
    #
    # It REPLACES the old `interior_temple_day` (2026-08-21, lead's call). `build_temple` has no
    # interior at all — the pagoda is three stacked solid plinths — so that frame was shot on the
    # engawa, a 0.9 m covered veranda with an open flank. Being open, it drifted with the rain
    # quadrant's weather like an outdoor frame: 0.052 between two runs against <=0.017 for the
    # sealed interiors, and re-aiming it four ways moved all four the same direction. The set
    # still needs a rain-quadrant interior, and this is the only sealed one in that quadrant.
    # WHEN E9.1 GIVES THE TEMPLE A REAL INTERIOR, the temple frame comes back as its own item —
    # this shrine frame is not a stand-in for the temple's LOOK, only for its quadrant's AIR.
    #
    # Stand in the north-west quarter and look 12.4 m down the SE diagonal — the longest sight
    # line the room has. Chosen against two shorter framings that were just as repeatable and
    # said far less: a 6.4 m shot at the east wall came back as flat brick plus the gun
    # (p95-p05 0.52), the NE corner came back nearly black (p50 0.10). The diagonal carries
    # floor, both walls, the ceiling, the lamp and the far corner at once, and measures 0.65 of
    # tonal range — an interior frame is only worth shooting if the room is IN it. The stand sits
    # just south of the NW stairwell hole (x [199,203.2], z [198.35,200.35]), which is open to
    # the sky through the roof opening above it, so its daylight shaft stays behind the camera.
    Frame(
        "interior_shrine_day",
        201.8,
        201.8,
        1.0,
        (210.6, 1.3, 210.2),
        DAY_HOUR,
        indoor=True,
        clear=True,
    ),
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


class ReadProbe(NamedTuple):
    """One readability A/B pair: the same camera, shot without and then with one machine."""

    name: str
    x: float
    z: float
    y: float
    aim: tuple[float, float, float]
    hour: float
    spawn_id: str  # harness spawn id (AgentBridge._debug_spawn scene_map)
    # Where the machine is PUT. Tuned per archetype so that, once the spawn theatre has burned
    # out, the body is still OUTSIDE the shooting range and walks into it (a frosthound covers
    # 4.5 m/s, a heavy far less) — the shutter itself is gated on the measured distance.
    dist: float = READ_SPAWN_DIST


# The urban probes look down combat_day's axis at the same tower, but from 7 m further back:
# combat_day stands 20 m off the NorthTower and the machine has to be PUT somewhere, and the
# tower footprint starts at z -37.5 — a 12 m spawn from z -25 lands against the wall, where a
# heavy ends up half inside the masonry and invisible (measured: an empty mask twice running).
# From z -18 a 15 m spawn still lands 4.5 m clear of the wall, on open ground with the tower as
# the far backdrop, and the machine walks into the 12 m shooting range from there.
# The snow probe is the deliberate worst case: a pale chassis on lit snow. Its stand sits 6 m
# further back than the frames' snow spot because the SnowLodge footprint reaches z -1 and a
# 15 m spawn from z 14 would drop the machine INTO the south wall.
# The rain quadrant is left out of v1 — its climate particles repaint the WHOLE frame between
# two shutters.
READ_PROBES: tuple[ReadProbe, ...] = (
    ReadProbe("urban_grunt", -40.0, -18.0, 6.0, (-40.0, 2.5, -45.0), DAY_HOUR, "grunt"),
    ReadProbe("urban_heavy", -40.0, -18.0, 6.0, (-40.0, 2.5, -45.0), DAY_HOUR, "heavy"),
    # A frosthound crosses ~3.6 m/s, so from 12 m it is already INSIDE the shooting range when
    # the spawn theatre ends; it gets 15 m instead. That in turn is why this stand sits 6 m
    # further back than the snow FRAME spot: the SnowLodge footprint reaches z -1, and a 15 m
    # spawn from z 14 would drop the machine into its south wall.
    ReadProbe(
        "snow_frosthound", 160.0, 20.0, 6.0, (160.0, 2.5, -10.0), DAY_HOUR, "frosthound", 15.0
    ),
    # Report-only: at night the contrast is carried by the emissive eye, which is a different
    # question from "does the chassis separate from the ground". No threshold in v1.
    ReadProbe("urban_grunt_night", -40.0, -18.0, 6.0, (-40.0, 2.5, -45.0), NIGHT_HOUR, "grunt"),
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


def png_path(reply: dict[str, Any]) -> str:
    """`screenshot` answers with `path`, chemistry/preview with `png`."""
    return str(reply.get("path") or reply.get("png") or "")


# ------------------------------------------------------------------------------- capture verbs
def _end_world_event() -> int:
    """End whatever world event is running; returns the kind that was ended (-1 = none).

    A live event is not just machines: SURGE/siege/contested-POI paint a banner and a countdown
    across the middle of the screen, i.e. INSIDE the analysed crop, and a supply cache adds an
    "Open Power Cache" prompt over whatever is behind it. Those are HUD pixels scored as world
    luma, and whether one is running at the moment a given frame comes up is pure timer luck.
    """
    kind = int(send({"cmd": "state"}).get("active_event_kind", -1) or -1)
    if kind < 0:
        return -1
    send({"cmd": "event", "end": True})
    return kind


def _clear_frame(radius: float = FRAME_CLEAR_RADIUS) -> int:
    """Kill every machine within `radius` of the player; returns the body count.

    Deliberately a RADIUS and not a view cone (which is what `_clear_view` uses for the
    readability pairs): the point here is the third-person SpringArm, and the thing that
    collapses it stands BEHIND the camera, where no cone would look. Bounded by
    FRAME_CLEAR_MAX because a map-wide sweep completes the wave and summons the next one.
    Kills are booked into `_KILL_TRACK` so the shutter can wait out the level-up card stack
    they open — that modal lands dead centre and would otherwise be photographed.
    """
    killed = 0
    for _ in range(FRAME_CLEAR_MAX):
        near = [
            e
            for e in (send({"cmd": "state"}).get("enemies") or [])
            if float(e.get("dist") or 1e9) <= radius
        ]
        if not near:
            break
        near.sort(key=lambda e: float(e.get("dist") or 0.0))
        send({"cmd": "kill", "target": str(near[0].get("name") or "nearest")})
        killed += 1
        time.sleep(0.08)
    _note_kills(killed)
    return killed


def _settle_exposure(frame: Frame, label: str) -> float:
    """Hold the shutter until this frame's own p50 stops moving; returns the last |dp50|.

    Throwaway captures are analysed EXACTLY as the real one will be (same crop, same
    indoor/night ruleset) and read straight out of the game's user:// folder — the gate has to
    watch the published statistic, or it is gating on something else. Two consecutive polls
    within FRAME_EXPOSURE_TOL end it; running out of tries does NOT fail the frame, it just
    returns the drift, which the report prints. A row whose drift is large is a sample of a
    moving scene and must be read as one.
    """
    prev: float | None = None
    drift = 1.0
    for i in range(FRAME_EXPOSURE_TRIES):
        time.sleep(FRAME_EXPOSURE_POLL)
        rep = send({"cmd": "screenshot", "name": "%s_expose%d" % (label, i % 2)}, timeout=60.0)
        path = png_path(rep)
        if path == "":
            return drift
        stats = analyze(
            Path(path), night=bool(frame.hour >= 19.5), indoor=frame.indoor
        )
        if not stats.get("ok"):
            return drift
        cur = float((stats.get("world") or {}).get("p50") or 0.0)
        if prev is not None:
            drift = abs(cur - prev)
            if drift <= FRAME_EXPOSURE_TOL:
                return round(drift, 4)
        prev = cur
    return round(drift, 4)


def shot(frame: Frame, label: str, total: float) -> dict[str, Any]:
    """Capture one fixed frame. Never raises: a dead verb becomes a `skipped` entry.

    THE SHUTTER IS GATED TWICE, and both gates moved every number this function produced
    before 2026-08-21 (see the module docstring for the measurements):
      * the pose is settled with `_settle_grounded`, not on `on_floor` — that flag survives a
        teleport for a frame or two, so the old code aimed from the TP HEIGHT instead of from
        the ground and every frame carried a few degrees of pitch error;
      * the light is settled by looking at the image (`_settle_light`) instead of sleeping
        0.25 s, because a `clock set` needs ~1 s to reach the screen.
    """
    out: dict[str, Any] = {"frame": frame.name, "pos": [frame.x, frame.z], "indoor": frame.indoor}
    tp = send({"cmd": "tp", "x": frame.x, "y": frame.y, "z": frame.z})
    if not tp.get("ok"):
        out["skipped"] = "tp failed: %s" % tp.get("error", tp)
        return out
    set_hour(frame.hour, total)
    _settle_grounded()
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
    if frame.clear:
        # Order matters: end the event FIRST (its guards are machines too, and ending it can
        # despawn some of them), then sweep. The kills' death FX, loot drops and XP popups are
        # then waited out by the light gate below, which needs two agreeing frames.
        out["event_ended"] = _end_world_event()
        out["cleared"] = _clear_frame()
    for eid, dist in frame.spawn:
        rep = send({"cmd": "spawn", "id": eid, "dist": dist, "hunter": False})
        if not rep.get("ok"):
            out.setdefault("warnings", []).append("spawn %s failed" % eid)
    if frame.spawn:
        time.sleep(SPAWN_WAIT)
    # Re-pin the hour right before the shutter: the match clock kept running through the setup.
    set_hour(frame.hour, total)
    out["levelup_wait"] = _wait_levelup_clear()
    out["exposure_drift"] = _settle_exposure(frame, label)
    if frame.clear:
        # SECOND event check, and it is not belt-and-braces. WorldEventDirector fires on a
        # timer and puts a supply cache AT A POI — the same POIs this set stands inside. One
        # materialised in the NorthTower between the clear step and the shutter and turned
        # interior_night into a frame-filling yellow beacon plus two banners: p50 0.491 against
        # 0.388 on the pass where it did not. The clear step cannot see an event that has not
        # started yet, so the check is repeated once the setup is over, and the light is
        # re-settled if it fired (ending an event despawns its beacon and its HUD).
        late = _end_world_event()
        if late >= 0:
            out["event_ended_late"] = late
            out["exposure_drift"] = _settle_exposure(frame, label)
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


# ------------------------------------------------------------------------------ readability A/B
# Mirrored level-up bookkeeping (see LEVELUP_* above): kills made by the clear step.
_KILL_TRACK: dict[str, float] = {"bank": 0.0, "level": 1.0, "offer_until": 0.0}


def _note_kills(n: int) -> None:
    for _ in range(n):
        _KILL_TRACK["bank"] += 1.0
        need = LEVELUP_KILLS_BASE + LEVELUP_KILLS_PER_LEVEL * _KILL_TRACK["level"]
        if _KILL_TRACK["bank"] >= need:
            _KILL_TRACK["bank"] -= need
            _KILL_TRACK["level"] += 1.0
            _KILL_TRACK["offer_until"] = time.time() + LEVELUP_PICK_WAIT


def _wait_levelup_clear() -> float:
    """Block until any level-up card stack has auto-picked itself off the middle of the frame."""
    wait = _KILL_TRACK["offer_until"] - time.time()
    if wait <= 0.0:
        return 0.0
    time.sleep(wait)
    return round(wait, 1)


def _view_step(presses: int) -> None:
    """Cycle the V zoom step. There is no state key for it, but there IS a fixed starting
    point: player.gd resets `_view_step` to Settings.DEFAULT_VIEW_STEP (1, third-person
    medium) in `_ready`, i.e. on every deploy. The block restarts the match first, so from
    there +2 is Settings.VIEW_STEP_FIRST_PERSON (3) and +2 again wraps back to 1 (count 4).
    """
    for _ in range(presses):
        send({"cmd": "act", "action": "toggle_view"})
        time.sleep(0.35)
    time.sleep(0.5)  # the view step folds into the camera-length lerp


def _in_frame_enemies(st: dict[str, Any], probe: ReadProbe) -> list[dict[str, Any]]:
    """Machines that could plausibly be in this probe's frame: ahead in a cone, or very close.

    "Very close in any direction" is not paranoia — the third-person camera sits several metres
    BEHIND the player, so a machine standing on the player's back is in shot.
    """
    pos = (st.get("player") or {}).get("pos") or [probe.x, 0.0, probe.z]
    fx, fz = probe.aim[0] - float(pos[0]), probe.aim[2] - float(pos[2])
    flen = math.hypot(fx, fz) or 1.0
    fx, fz = fx / flen, fz / flen
    out: list[dict[str, Any]] = []
    for e in st.get("enemies") or []:
        dist = float(e.get("dist") or 0.0)
        if dist <= READ_CLEAR_NEAR:
            out.append(e)
            continue
        if dist > READ_CLEAR_R:
            continue
        ep = e.get("pos") or [0.0, 0.0, 0.0]
        dx, dz = float(ep[0]) - float(pos[0]), float(ep[2]) - float(pos[2])
        dlen = math.hypot(dx, dz) or 1.0
        if (dx / dlen) * fx + (dz / dlen) * fz >= READ_CONE_COS:
            out.append(e)
    return out


def _clear_view(probe: ReadProbe) -> int:
    """Kill only what could be in shot. A blanket sweep of the whole map would COMPLETE the
    wave and immediately summon the next one (live QA: 60 kills never converged)."""
    killed = 0
    for _ in range(READ_CLEAR_MAX):
        near = _in_frame_enemies(send({"cmd": "state"}), probe)
        if not near:
            break
        near.sort(key=lambda e: float(e.get("dist") or 0.0))
        send({"cmd": "kill", "target": str(near[0].get("name") or "nearest")})
        killed += 1
        time.sleep(0.08)
    _note_kills(killed)
    return killed


def _settle_grounded() -> dict[str, Any]:
    """Wait until the teleported player has actually LANDED (position stopped changing).

    The obvious version of this polls `on_floor`, and for a frame or two after a teleport that
    is still TRUE from where the player used to stand — so it returns before the fall even
    starts. Aiming then computes the pitch from the tp height, not the ground: a probe tp'd to
    y=6 over ground at y=0.04 aimed 14 deg too far DOWN, which put the machine above the
    analysed area and produced an off-frame SKIP that looked like a spawn failure. This waits
    for two identical heights instead.

    It is the ONLY settle in the file: `shot()` used the `on_floor` version until 2026-08-21,
    so every committed frame before that date was aimed from its teleport height (the outdoor
    stands drop 6 m, the interiors 1 m) and carries a pitch error of a few degrees. Frame
    numbers from an older report are therefore not directly comparable to a newer one — the
    framing itself changed, not just the light.
    """
    t0 = time.time()
    st: dict[str, Any] = {}
    last = 1e9
    while time.time() - t0 < SETTLE_MAX * 2.0:
        st = send({"cmd": "state"})
        pl = st.get("player") or {}
        y = float(((pl.get("pos") or [0.0, 1e9, 0.0])[1]))
        if pl.get("on_floor") and abs(y - last) < 0.01:
            return st
        last = y
        time.sleep(SETTLE_POLL)
    return st


def _settle_light(label: str) -> float:
    """Shoot throwaway frames until two in a row agree — THEN open the shutter.

    `clock set` teleports the sun (parked ~10:40 between probes, then jumped to 13:00 or
    21:00 for the pair), and the frame does not follow instantly: the sky, the fill light and
    the tonemap all chase it. A fixed sleep guessed wrong at night, where a pair shot too
    early differed over HALF its pixels — the whole world re-lighting, not a machine. This
    measures the thing that matters (has the image stopped moving) and reports the residual.

    This is the READABILITY gate, and its metric — the share of pixels that moved by more than
    READ_DIFF_T — is the right one there, because a readability pair IS a pixel difference.
    It is the WRONG one for a frame capture: a slow, whole-image ramp (volumetric fog
    re-accumulating after a teleport) moves every pixel a little and almost none of them past
    the threshold, so this gate calls "settled" while the median is still climbing. Frames use
    `_settle_exposure` instead, which watches the statistic the report actually publishes.
    """
    prev: Path | None = None
    residual = 1.0
    for i in range(READ_SETTLE_TRIES):
        time.sleep(READ_LIGHT_SETTLE)
        rep = send({"cmd": "screenshot", "name": "%s_settle%d" % (label, i % 2)}, timeout=60.0)
        cur = Path(png_path(rep)) if png_path(rep) else None
        if cur is None or not cur.exists():
            return residual
        if prev is not None:
            ra, rb = _read_region(prev), _read_region(cur)
            if ra is not None and rb is not None and ra[0].shape == rb[0].shape:
                residual = float((np.abs(_luma(rb[0]) - _luma(ra[0])) > READ_DIFF_T).mean())
                if residual < READ_SETTLE_DIFF:
                    return round(residual, 4)
        prev = cur
    return round(residual, 4)


def _near_map(st: dict[str, Any], radius: float = 80.0) -> dict[str, list[float]]:
    return {
        str(e.get("name")): [float(v) for v in (e.get("pos") or [0, 0, 0])]
        for e in (st.get("enemies") or [])
        if float(e.get("dist") or 0.0) <= radius
    }


def _camera_yaw(st: dict[str, Any]) -> float:
    """The camera's WORLD yaw — which lives on the player BODY, not on the camera pivot.

    `state.player.cam_yaw` is `cam_pivot.rotation.y` (AgentBridge), and that field is
    STRUCTURALLY zero: player.gd zeroes it every physics tick ("the body yaw IS the look yaw"),
    and `aim point` zeroes it again on the way in. The real heading is `rot_y`, the body yaw —
    the same value `_debug_spawn` uses via `-basis.z` to place a spawn. Reading cam_yaw happened
    to work only because every probe here aims along -Z, where the true yaw is 0.0; the first
    probe aimed anywhere else would have seeded the mask on a random patch of frame and the
    flood would have measured whatever diff blob sat there. Warn if the assumption ever breaks.
    """
    pl = st.get("player") or {}
    pivot_yaw = float(pl.get("cam_yaw") or 0.0)
    if abs(pivot_yaw) > 1e-6:
        print(
            "  WARN cam_yaw is no longer zero (%.4f) — camera model changed, re-check" % pivot_yaw
        )
    return float(pl.get("rot_y") or 0.0)


def _identify_target(before: dict[str, list[float]], probe: ReadProbe, dist: float) -> str:
    """Name the machine the probe just spawned: the new one nearest the point it was put at.

    AgentBridge places a debug spawn at `player + flattened camera-forward * dist`, so that
    point is known exactly — and matching on it survives the wave manager dropping its own
    machines into the same second.
    """
    st = send({"cmd": "state"})
    pos = (st.get("player") or {}).get("pos") or [probe.x, 0.0, probe.z]
    yaw = _camera_yaw(st)
    want = (
        float(pos[0]) - math.sin(yaw) * dist,
        float(pos[2]) - math.cos(yaw) * dist,
    )
    best, best_d = "", 1e9
    for e in st.get("enemies") or []:
        name = str(e.get("name"))
        if name in before:
            continue
        ep = e.get("pos") or [0.0, 0.0, 0.0]
        d = math.hypot(float(ep[0]) - want[0], float(ep[2]) - want[1])
        if d < best_d:
            best, best_d = name, d
    return best if best_d < 6.0 else ""


def _await_shot_range(target: str, probe: ReadProbe) -> dict[str, Any]:
    """Hold the shutter until the spawned machine has walked INTO the declared shooting range.

    Returns the state snapshot to shoot on plus the measured distance. `ok:false` means the
    machine never crossed into the band (or shot past it) — the rep then carries no number
    instead of a plausible one taken at whatever range it happened to be.
    """
    lo, hi = READ_SHOT_DIST - READ_DIST_TOL, READ_SHOT_DIST + READ_DIST_TOL
    time.sleep(READ_SPAWN_WAIT)  # spawn theatre first — an assembling body is a dot
    t0 = time.time()
    last = -1.0
    bearing = 1.0
    while time.time() - t0 < READ_APPROACH_MAX:
        st = send({"cmd": "state"})
        pos = (st.get("player") or {}).get("pos") or [probe.x, 0.0, probe.z]
        ax, az = probe.aim[0] - float(pos[0]), probe.aim[2] - float(pos[2])
        alen = math.hypot(ax, az) or 1.0
        for e in st.get("enemies") or []:
            if str(e.get("name")) != target:
                continue
            last = float(e.get("dist") or 0.0)
            ep = e.get("pos") or [0.0, 0.0, 0.0]
            dx, dz = float(ep[0]) - float(pos[0]), float(ep[2]) - float(pos[2])
            bearing = (dx * ax + dz * az) / (alen * (math.hypot(dx, dz) or 1.0))
            break
        if last < 0.0:
            return {"ok": False, "error": "target vanished before the shutter"}
        # A machine that walked off the view axis is not what this pair is about — usually it
        # was relocated by the stuck-watchdog. Keep waiting rather than shooting an empty lane.
        if last <= hi and bearing >= READ_AXIS_COS:
            if last < lo:
                return {
                    "ok": False,
                    "error": "closed past the band: %.2f m outside %.1f-%.1f m" % (last, lo, hi),
                    "dist": round(last, 2),
                }
            return {"ok": True, "state": st, "dist": round(last, 2), "bearing": round(bearing, 3)}
        time.sleep(READ_APPROACH_POLL)
    if bearing < READ_AXIS_COS:
        return {
            "ok": False,
            "error": "target left the view axis (cos %.2f < %.2f at %.2f m) — relocated?"
            % (bearing, READ_AXIS_COS, last),
            "dist": round(last, 2),
        }
    return {
        "ok": False,
        "error": "never reached %.1f m in %.0fs (stopped at %.2f m)"
        % (hi, READ_APPROACH_MAX, last),
        "dist": round(last, 2),
    }


def _readability_shot(probe: ReadProbe, label: str, total: float, rep_i: int) -> dict[str, Any]:
    """One A/B pair at the probe's already-aimed camera. Never raises; failures set `skipped`.

    The camera is NEVER touched between the two shutters — no `look`, no `aim`, no movement —
    because the whole metric is a pixel-aligned difference.
    """
    out: dict[str, Any] = {"rep": rep_i}
    tag = "%s_r%d" % (probe.name, rep_i)
    out["cleared"] = _clear_view(probe)
    out["levelup_wait"] = _wait_levelup_clear()

    set_hour(probe.hour, total)
    out["settle_residual"] = _settle_light(label)
    st = send({"cmd": "state"})
    before = _near_map(st)
    out["hour"] = (st.get("world") or {}).get("hour")
    out["night"] = bool((st.get("world") or {}).get("night"))
    out["player_pos"] = (st.get("player") or {}).get("pos")
    shot_a = send({"cmd": "screenshot", "name": "%s_read_%s_a" % (label, tag)}, timeout=60.0)
    if not shot_a.get("ok") or png_path(shot_a) == "":
        out["skipped"] = "shot A failed: %s" % shot_a.get("error", shot_a)
        return out
    out["src_a"] = png_path(shot_a)

    # `hunter` forces CHASE, which is the ONLY way this lands where it is aimed: a patrol
    # wanders (live QA had one 39 deg off-axis after 2 s, another straight into the tower)
    # and every run then measures a different background. A hunter walks the view axis.
    spawned = send({"cmd": "spawn", "id": probe.spawn_id, "dist": probe.dist, "hunter": True})
    if not spawned.get("ok"):
        out["skipped"] = "spawn %s failed" % probe.spawn_id
        return out
    # Name the target IMMEDIATELY (waves keep adding machines, and picking "the first new
    # name" once picked a wave grunt 75 m away — the pair then measured empty wall).
    target = _identify_target(before, probe, probe.dist)
    out["target_name"] = target
    if target == "":
        out["skipped"] = "target machine not found after spawn"
        return out
    gate = _await_shot_range(target, probe)
    out["shutter_dist"] = gate.get("dist")
    if not gate.get("ok"):
        send({"cmd": "kill", "target": target})
        _note_kills(1)
        out["skipped"] = "range gate: %s" % gate.get("error")
        return out
    st2 = dict(gate["state"])
    after = _near_map(st2)
    # How far the machines that were ALREADY there moved between the shutters — the honest
    # readout of how much of the mask is somebody else's motion rather than the probe target.
    moved = 0.0
    for name, p in after.items():
        q = before.get(name)
        if q is None:
            continue
        moved = max(moved, math.dist(p, q))
    out["foreign_move"] = round(moved, 2)
    pl2 = (st2.get("player") or {}).get("pos") or [probe.x, 0.0, probe.z]
    for e in st2.get("enemies") or []:
        if str(e.get("name")) != target:
            continue
        ep = [float(v) for v in (e.get("pos") or [0, 0, 0])]
        out["target_dist"] = round(float(e.get("dist") or 0.0), 2)
        out["target_pos"] = [round(v, 2) for v in ep]
        out["cam"] = {
            "pos": [float(pl2[0]), float(pl2[1]) + PIVOT_HEIGHT, float(pl2[2])],
            # The camera's world yaw is the BODY yaw: `cam_yaw` (the pivot) is zeroed every
            # physics tick and by `aim point` itself — see `_camera_yaw`.
            "yaw": _camera_yaw(st2),
            "pitch": float((st2.get("player") or {}).get("cam_pitch") or 0.0),
            "fov": float((st2.get("player") or {}).get("fov") or 60.0),
            "target": [ep[0], ep[1] + TARGET_CENTRE_UP, ep[2]],
        }
    if "cam" not in out:
        out["skipped"] = "target machine lost between the range gate and the shutter"
        return out
    shot_b = send({"cmd": "screenshot", "name": "%s_read_%s_b" % (label, tag)}, timeout=60.0)
    if not shot_b.get("ok") or png_path(shot_b) == "":
        out["skipped"] = "shot B failed: %s" % shot_b.get("error", shot_b)
        return out
    out["src_b"] = png_path(shot_b)
    # How far it closed WHILE the shutter was open — the honest slack on `shutter_dist`.
    for e in send({"cmd": "state"}).get("enemies") or []:
        if str(e.get("name")) == target:
            out["dist_after"] = round(float(e.get("dist") or 0.0), 2)
    send({"cmd": "kill", "target": target})
    _note_kills(1)
    return out


def readability_probe(probe: ReadProbe, label: str, total: float) -> dict[str, Any]:
    """Stand, aim, then shoot READ_REPS A/B pairs from that ONE camera pose.

    Two pairs, not one: the DAY gate (0.10) sits inside this instrument's own reproducibility
    band, so a single shutter decides FAIL/ok on weather and framing noise. Both reps share the
    same stand and aim, so they are comparable to each other as well as across runs.

    The clock is parked back in the match's opening-grace window between reps: `wave_manager`
    gates both its near-player spawn bias and the anti-camp flank punish on
    `match_duration - match_time_left`, so a long shoot at a pinned "13:00" (= 135 s elapsed)
    is what buries the spot in machines.
    """
    out: dict[str, Any] = {"probe": probe.name, "id": probe.spawn_id, "pos": [probe.x, probe.z]}
    park = max(MIN_LEFT, total - READ_GRACE_ELAPSED)
    send({"cmd": "clock", "action": "set", "left": park})
    tp = send({"cmd": "tp", "x": probe.x, "y": probe.y, "z": probe.z})
    if not tp.get("ok"):
        out["skipped"] = "tp failed: %s" % tp.get("error", tp)
        return out
    _settle_grounded()
    aim = send(
        {"cmd": "aim", "target": "point", "x": probe.aim[0], "y": probe.aim[1], "z": probe.aim[2]}
    )
    if not aim.get("ok"):
        out["skipped"] = "aim failed"
        return out
    time.sleep(RENDER_WAIT)

    reps: list[dict[str, Any]] = []
    for i in range(READ_REPS):
        reps.append(_readability_shot(probe, label, total, i))
        send({"cmd": "clock", "action": "set", "left": park})
    out["reps"] = reps
    # Surface the first usable rep's context at the top level so the report/JSON keep the same
    # shape they had when a probe was a single pair.
    first = next((r for r in reps if "skipped" not in r), reps[0])
    for key in ("hour", "night", "player_pos", "target_name", "target_dist", "foreign_move"):
        if key in first:
            out[key] = first[key]
    if all("skipped" in r for r in reps):
        out["skipped"] = "; ".join(str(r.get("skipped")) for r in reps)
    return out


def readability_block(label: str, total: float) -> list[dict[str, Any]]:
    """Run the four A/B pairs in ONE freshly restarted match.

    The restart is load-bearing, not hygiene: after a few minutes of shooting, the spot in
    front of the tower holds a dozen machines pressed against the player, and clearing them
    fast enough for a 2-second pair is impossible (killing a wave just spawns the next).
    A fresh match plus the parked clock keeps the field empty for the whole block. The raid
    mutator is pinned empty first because a restart RE-ROLLS it, and Night Raid would silently
    turn every DAY probe into a night one.
    """
    send({"cmd": "mutator", "id": ""})
    send({"cmd": "restart"})
    time.sleep(6.0)
    if not wait_drivable(90.0):
        return [{"probe": p.name, "skipped": "not drivable after restart"} for p in READ_PROBES]
    send({"cmd": "godmode", "on": True})
    # The restart resets the game's own level-up counters, so the mirror has to reset with it —
    # the frame shoot that just ran killed machines too (Frame.clear), and a stale bank would
    # make the block wait for an offer that already auto-picked, or miss one that has not.
    _KILL_TRACK.update({"bank": 0.0, "level": 1.0, "offer_until": 0.0})
    _wait_contract_clear()
    st = send({"cmd": "state"})
    total = float((st.get("match_timer") or {}).get("total") or total)
    _view_step(2)  # -> first person
    out: list[dict[str, Any]] = []
    for probe in READ_PROBES:
        entry = readability_probe(probe, label, total)
        out.append(entry)
        print("  read %-18s %s" % (probe.name, entry.get("skipped", "ok")))
    _view_step(2)  # 3 + 2 == 1 (mod VIEW_STEP_COUNT) -> back to the default third person
    send({"cmd": "mutator", "clear": True})
    return out


# ------------------------------------------------------------------------------------ analysis
def _luma(rgb: np.ndarray) -> np.ndarray:
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def _saturation(rgb: np.ndarray) -> float:
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    sat = np.where(mx > 1e-6, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    return float(sat.mean())


def analyze(
    path: Path, is_hero: bool = False, night: bool = False, indoor: bool = False
) -> dict[str, Any]:
    """Objective luma/saturation stats. World frames split sky vs world; heroes mask on alpha.

    `indoor` keeps the WHOLE crop as "world": there is no sky in a sealed room, and the band
    that would be dropped is the ceiling and the upper walls — where interior haze actually
    stratifies. Outdoor frames keep the split byte-for-byte, so old before/after captures stay
    comparable; the interior rows are marked with `"region": "full"` in report.json (and their
    numbers are NOT comparable to a pre-fix interior row, which measured the lower two thirds).
    """
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
    world_rgb = core if indoor else core[split:]
    world_l = _luma(world_rgb)
    pcts = np.percentile(world_l, [5, 25, 50, 75, 95])
    return {
        "ok": True,
        "size": [img.width, img.height],
        "region": "full" if indoor else "below-sky",
        "indoor": bool(indoor),
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


# --------------------------------------------------------------------------------- readability
def _shift(a: np.ndarray, dy: int, dx: int) -> np.ndarray:
    """Translate a boolean image by (dy,dx) with ZERO fill (np.roll would wrap the edges in)."""
    out = np.zeros_like(a)
    h, w = a.shape
    out[max(dy, 0) : h + min(dy, 0), max(dx, 0) : w + min(dx, 0)] = a[
        max(-dy, 0) : h + min(-dy, 0), max(-dx, 0) : w + min(-dx, 0)
    ]
    return out


def _despeckle(mask: np.ndarray) -> np.ndarray:
    """Drop isolated diff pixels: keep only those with >= READ_DESPECKLE_MIN of their 3x3 set.

    Wind in the grass, a swaying antenna and sensor-grade noise all produce single-pixel diffs
    scattered over the whole frame; a real machine is a solid blob. Done with shifted adds so
    the tool needs no scipy (numpy + Pillow are the only deps the harness already carries).
    """
    count = np.zeros(mask.shape, dtype=np.int16)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            count += _shift(mask, dy, dx).astype(np.int16)
    return mask & (count >= READ_DESPECKLE_MIN)


def _fill_silhouette(mask: np.ndarray) -> np.ndarray:
    """Fill each row of the blob between its outermost pixels — the machine, not just its edges.

    A |diff| > threshold mask only keeps the parts of a machine that ALREADY stand out, so
    taking a median over it is circular: it answers "how bright are the bright bits" and it
    moved 0.14 apart between two archetypes on the identical wall purely by which half of
    each chassis cleared the threshold. Filling the silhouette puts the low-contrast pixels
    back in, which is exactly what "does this machine read against the background" needs.
    """
    out = mask.copy()
    rows = np.nonzero(mask.any(axis=1))[0]
    if rows.size == 0:
        return out
    cols = np.nonzero(mask)
    order = np.argsort(cols[0])
    ys, xs = cols[0][order], cols[1][order]
    starts = np.searchsorted(ys, rows, side="left")
    ends = np.searchsorted(ys, rows, side="right")
    for i, y in enumerate(rows):
        seg = xs[starts[i] : ends[i]]
        out[y, seg.min() : seg.max() + 1] = True
    return out


def _dilate(mask: np.ndarray, radius: int) -> np.ndarray:
    """Grow a mask by `radius` pixels (4-neighbour steps => a diamond, good enough for a ring)."""
    out = mask.copy()
    for _ in range(radius):
        out = out | _shift(out, 1, 0) | _shift(out, -1, 0) | _shift(out, 0, 1) | _shift(out, 0, -1)
    return out


def _read_region_rows(h: int) -> tuple[int, int]:
    """First and last+1 FULL-FRAME row of the readability analysis region (HUD + sky dropped)."""
    top = int(round(h * CROP_TOP))
    bot = h - int(round(h * CROP_BOT))
    sky = max(1, int(round((bot - top) * SKY_FRAC)))
    return top + sky, bot


def _read_region(path: Path) -> tuple[np.ndarray, int] | None:
    """Analysis region of one capture + the full-frame row its first row came from.

    Same crop as `analyze` (HUD bands off, sky band dropped) — the sky matters most here,
    because Sky3D's cumulus is the single largest source of false difference in a pair.
    """
    try:
        img = Image.open(path)
        img.load()
    except OSError:
        return None
    arr = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
    h = arr.shape[0]
    top = int(round(h * CROP_TOP))
    core = arr[top : h - int(round(h * CROP_BOT))]
    if core.shape[0] < 16:
        return None
    sky = max(1, int(round(core.shape[0] * SKY_FRAC)))
    return core[sky:], top + sky


def project_to_frame(
    cam: tuple[float, float, float],
    yaw: float,
    pitch: float,
    fov_deg: float,
    target: tuple[float, float, float],
    w: int,
    h: int,
) -> tuple[float, float] | None:
    """Where a world point lands on screen, in full-frame pixels (None = behind the camera).

    Needed because the probe machine does NOT stay where it was spawned: it is a live patrol
    that starts walking the moment it assembles, and the pair cannot be shot until the spawn
    drop-pod FX has burned out (~2.5 s), by which time it has moved metres. Seeding the mask
    on the crosshair alone then finds nothing. Godot camera basis = Ry(yaw) * Rx(pitch), the
    camera looks down its own -Z, and Camera3D.fov is VERTICAL under KEEP_HEIGHT.
    """
    dx, dy, dz = target[0] - cam[0], target[1] - cam[1], target[2] - cam[2]
    cy, sy = math.cos(yaw), math.sin(yaw)
    cp, sp = math.cos(pitch), math.sin(pitch)
    bx = dx * cy - dz * sy  # . X = (cy, 0, -sy)
    by = dx * sy * sp + dy * cp + dz * cy * sp  # . Y = (sy*sp, cp, cy*sp)
    bz = dx * sy * cp - dy * sp + dz * cy * cp  # . Z = (sy*cp, -sp, cy*cp)
    if bz >= -0.05:
        return None
    tan_v = math.tan(math.radians(fov_deg) * 0.5)
    tan_h = tan_v * (float(w) / float(h))
    return (
        w * 0.5 * (1.0 + (bx / -bz) / tan_h),
        h * 0.5 * (1.0 - (by / -bz) / tan_v),
    )


TARGET_BODY_R = 1.6  # m — generous half-width of any machine in the probe roster
TARGET_BODY_LOW = 1.2  # m below the reported body origin (feet + shadow slack)
TARGET_BODY_HIGH = 2.4  # m above it (the boss/oni class of silhouette)


def _target_box(cam: dict[str, Any], w: int, h: int) -> tuple[float, float, float, float] | None:
    """Screen rectangle the target machine's body can possibly cover (full-frame pixels)."""
    tx, ty, tz = cam["target"]
    xs: list[float] = []
    ys: list[float] = []
    for dx in (-TARGET_BODY_R, TARGET_BODY_R):
        for dz in (-TARGET_BODY_R, TARGET_BODY_R):
            for dy in (-TARGET_BODY_LOW, TARGET_BODY_HIGH):
                p = project_to_frame(
                    tuple(cam["pos"]),
                    cam["yaw"],
                    cam["pitch"],
                    cam["fov"],
                    (tx + dx, ty + dy, tz + dz),
                    w,
                    h,
                )
                if p is None:
                    return None
                xs.append(p[0])
                ys.append(p[1])
    return (min(xs), min(ys), max(xs), max(ys))


def _blob_at(mask: np.ndarray, cy: int, cx: int) -> np.ndarray:
    """The one connected component of `mask` that covers (cy,cx) — the machine's screen spot.

    THE reason this exists: the diff is never only the machine. Snowfall over the whole snow
    quadrant, the drop-pod dust at the spawn point, another machine walking through frame,
    HUD text ticking over — all of it is "something changed", and on the very first live run
    the biggest blob in the snow pair was a patch of falling snow while the machine itself
    never made the mask at all. Naming the target by WHERE IT IS (projected from its live
    world position) instead of hoping it wins on area is what makes the number the machine's.
    An empty result is a diagnosis, not something to explain away.
    """
    h, w = mask.shape
    cy = int(np.clip(cy, 0, h - 1))
    cx = int(np.clip(cx, 0, w - 1))
    seed = np.zeros_like(mask)
    for radius in (14, 40):
        yy, xx = np.ogrid[:h, :w]
        seed = mask & (((yy - cy) ** 2 + (xx - cx) ** 2) <= radius * radius)
        if bool(seed.any()):
            break
    if not bool(seed.any()):
        return seed
    # Flood the seed through the mask (4-neighbour growth until it stops changing).
    grown = seed
    for _ in range(max(h, w)):
        nxt = (
            grown
            | _shift(grown, 1, 0)
            | _shift(grown, -1, 0)
            | _shift(grown, 0, 1)
            | _shift(grown, 0, -1)
        ) & mask
        if int(nxt.sum()) == int(grown.sum()):
            break
        grown = nxt
    return grown


def analyze_readability(
    path_a: Path,
    path_b: Path,
    mask_png: Path | None = None,
    seed_xy: tuple[float, float] | None = None,
    night: bool = False,
    box: tuple[float, float, float, float] | None = None,
) -> dict[str, Any]:
    """Score how far ONE machine separates from the exact background it is standing on.

    A is the empty frame, B the identical frame with one machine spawned at the crosshair,
    both shot in FIRST PERSON (the third-person body sits dead centre and swallows anything
    put on the view axis — live QA: the machine was invisible in every third-person pair).
    Nothing moves the camera between the two, so |luma_B - luma_A| over READ_DIFF_T is what
    appeared; despeckled and reduced to the blob touching the crosshair (`_blob_at`), that is
    the machine. Dilating it by READ_RING_PX gives the background RING it is actually seen
    against, and the answer is how far the machine's pixels sit from that background level,
    measured on B (what the player looks at). The isolated hero render already answers "is
    this chassis painted light enough"; this answers "does it come off THIS ground".

    WHICH SEPARATION — and why not the obvious one. The first cut of this was the textbook
    |median(machine) - median(ring)|, and it is WRONG for this roster: the D2 palette is
    deliberately two-tone (a light plate over a near-black frame), so a perfectly visible
    machine can have its median land exactly ON the background while both of its tones are
    far from it. Worse, which tone dominates the mask is decided by things that have nothing
    to do with readability — which half of the chassis cleared the diff threshold, and which
    HUD banner happened to be covering the other half. Measured: the same heavy at the same
    9.3 m scored 0.172 and 0.034 on two runs of identical code. `contrast` is therefore the
    MEAN ABSOLUTE separation of the machine's pixels from the background level, which is the
    same number for a single-tone machine, counts both tones for a two-tone one, and moved
    <=0.036 across those same two runs. The literal median difference is still reported as
    `p50_delta` so the older, more naive reading is never hidden.

    HONEST LIMITS — this is a RELATIVE A/B instrument, exactly like the rest of photostand:
      * FALSE DIFF. Anything that moves between the two shutters lands in the raw diff: Sky3D
        clouds (why the sky band is dropped), wind in the grass, snowfall and rain particles
        (why the rain quadrant has no probe in v1), and any foreign machine that walked into
        frame (hence the clear step and the `foreign_move` field). The crosshair-blob rule
        keeps them out of the TARGET, and the ring drops every other diff pixel, but a
        particle that lands ON the machine is still counted. Trust a shift when several probes
        move together, not a single one.
      * THE MACHINE MAY DRIFT. A patrol spawned for the pair keeps walking, so part of its
        silhouette can leave the frame; the blob stays valid (it exists only in B) and only
        `coverage` drops — and if it walks off the crosshair entirely the pair SKIPs rather
        than measuring something else. It is deliberately NOT frozen with a shock: the
        chemistry FX aura would light the machine up and inflate the very number measured.
      * ONE ANGLE, ONE RANGE BAND. The shutter is held until the machine walks into
        READ_SHOT_DIST +- READ_DIST_TOL (12 +- 1.5 m) and the rep is void outside it, so the
        probes really are compared at the same apparent size — but it is still one angle, one
        distance band, one biome light each and one machine per probe. It is not a universal
        "readability" score and says nothing about 60 m, backlight, a moving target, or a
        machine seen against a wall instead of the ground.
      * ONE SHUTTER IS NOISE. The gate (0.10) is inside the tool's own reproducibility spread:
        the snow probe measured 0.1364 and then 0.1016 on two runs of IDENTICAL code. Hence
        READ_REPS pairs per probe and a verdict on the whole band; a single `contrast` value,
        from here or from an old report, must be read next to its `spread`.
      * THE EMISSIVE EYE COUNTS, on purpose. A glowing eye is the one signal channel the D2
        palette work left the machines; it is part of how a player finds them, so it belongs
        in the number rather than being masked out.
    """
    ra = _read_region(path_a)
    rb = _read_region(path_b)
    if ra is None or rb is None:
        return {"ok": False, "error": "open/crop failed"}
    a, _ = ra
    b, row0 = rb
    if a.shape != b.shape:
        return {"ok": False, "error": "A/B size mismatch %s vs %s" % (a.shape, b.shape)}
    lum_a = _luma(a)
    lum_b = _luma(b)
    thresh = READ_DIFF_T_NIGHT if night else READ_DIFF_T
    raw = _despeckle(np.abs(lum_b - lum_a) > thresh)
    if seed_xy is None:  # no live position for the target: fall back to the crosshair
        seed_x, seed_y = b.shape[1] * 0.5, b.shape[0] * 0.5
    else:
        seed_x, seed_y = seed_xy[0], seed_xy[1] - row0
    if not (0.0 <= seed_x < b.shape[1] and 0.0 <= seed_y < b.shape[0]):
        # Clamping here would silently measure whatever sits on the frame edge. The honest
        # answer is that the machine walked out of the analysed area before the shutter.
        return {
            "ok": False,
            "error": "target off analysis area (%.0f,%.0f)" % (seed_x, seed_y),
            "seed": [round(seed_x, 1), round(seed_y, 1)],
        }
    # Clip the flood to the box the machine's own body can possibly occupy on screen. Without
    # it a windy pair (grass and foliage moving between the shutters) lets the blob leak
    # through a one-pixel bridge into the whole speckled ground: the same heavy at the same
    # 9.3 m measured 0.172 on a calm pair and 0.034 on a noisy one, purely from swallowed
    # background. The box is generous (a 3.2 m wide, 3.6 m tall cylinder) — it bounds the
    # damage, it does not decide the answer.
    reach = raw
    if box is not None:
        yy, xx = np.ogrid[: b.shape[0], : b.shape[1]]
        reach = raw & (
            (xx >= box[0]) & (xx <= box[2]) & (yy >= box[1] - row0) & (yy <= box[3] - row0)
        )
    mask = _fill_silhouette(_blob_at(reach, int(round(seed_y)), int(round(seed_x))))
    coverage = float(mask.mean())
    out: dict[str, Any] = {
        "ok": True,
        "coverage": round(coverage, 5),
        "diff_frac": round(float(raw.mean()), 5),
        "diff_t": thresh,
        "seed": [round(seed_x, 1), round(seed_y, 1)],
    }
    if not (READ_COVER[0] <= coverage <= READ_COVER[1]):
        out["ok"] = False
        out["error"] = "mask implausible (crosshair blob %.3f%% outside %.1f-%.1f%%)" % (
            coverage * 100.0,
            READ_COVER[0] * 100.0,
            READ_COVER[1] * 100.0,
        )
        if mask_png is not None:
            _write_mask_png(b, mask, raw & ~mask, mask_png)
        return out
    # The ring must not contain the OTHER diff pixels (a passing machine, snowfall): it is
    # the background, and background is what did NOT change between the two shutters.
    ring = _dilate(mask, READ_RING_PX) & ~_dilate(raw, 2)
    if not bool(ring.any()):
        out["ok"] = False
        out["error"] = "empty background ring"
        return out
    tgt_p50 = float(np.percentile(lum_b[mask], 50))
    bg_p50 = float(np.percentile(lum_b[ring], 50))
    out.update(
        {
            "target_p50": round(tgt_p50, 4),
            "bg_p50": round(bg_p50, 4),
            "p50_delta": round(abs(tgt_p50 - bg_p50), 4),
            "contrast": round(float(np.abs(lum_b[mask] - bg_p50).mean()), 4),
            "target_sat": round(_saturation(b[mask]), 4),
            "bg_sat": round(_saturation(b[ring]), 4),
            "sat_delta": round(_saturation(b[mask]) - _saturation(b[ring]), 4),
            "ring_px": int(ring.sum()),
            "mask_px": int(mask.sum()),
        }
    )
    if mask_png is not None:
        _write_mask_png(b, mask, ring, mask_png, raw & ~mask)
    return out


def _write_mask_png(
    b: np.ndarray,
    mask: np.ndarray,
    ring: np.ndarray,
    dst: Path,
    rejected: np.ndarray | None = None,
) -> None:
    """Evidence image: B dimmed, target magenta, ring teal, other (rejected) diff dull olive.

    Look at this before believing any contrast number: the magenta has to be a MACHINE.
    """
    vis = (b * 0.35 * 255.0).astype(np.uint8)
    if rejected is not None:
        vis[rejected] = np.array([90, 90, 40], dtype=np.uint8)
    vis[ring] = np.array([40, 180, 180], dtype=np.uint8)
    vis[mask] = np.array([245, 60, 200], dtype=np.uint8)
    try:
        Image.fromarray(vis).save(dst)
    except OSError:
        pass


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


def _read_flag(entry: dict[str, Any]) -> str:
    """SKIP / FAIL / ok for one readability probe (night pairs are report-only in v1).

    FAIL needs the WHOLE measured band under the gate. The threshold sits inside this
    instrument's own reproducibility spread (0.1364 vs 0.1016 on two runs of identical code),
    so calling FAIL on the lower shutter of a pair would be calling a coin flip.
    """
    if "skipped" in entry:
        return "SKIP"
    stats = entry.get("stats") or {}
    if not stats.get("ok"):
        return "SKIP"
    if entry.get("night"):
        return "n/a"
    best = float(stats.get("contrast_max", stats.get("contrast", 1.0)))
    return "FAIL" if best < READ_FAIL_CONTRAST else "ok"


def report(
    meta: dict[str, Any],
    frames: list[dict[str, Any]],
    machines: list[dict[str, Any]],
    readability: list[dict[str, Any]] | None = None,
) -> int:
    """Write report.json + report.md (the human table + verdict). Returns the SKIP count.

    That count is the process exit code's only input: a FAIL is a measured defect and is the
    expected state of a "before" baseline, but a SKIP means the shoot did not happen, and a
    scripted baseline run must not pass silently on frames that never rendered.
    """
    readability = readability or []
    doc = {"meta": meta, "frames": frames, "machines": machines, "readability": readability}
    (OUT_DIR / "report.json").write_text(json.dumps(doc, indent=2), encoding="utf-8")

    bad_frames = [f["frame"] for f in frames if _flag(f) == "FAIL"]
    bad_machines = [m["id"] for m in machines if _flag(m) == "FAIL"]
    bad_read = [r["probe"] for r in readability if _read_flag(r) == "FAIL"]
    # Build the SKIP list from the FLAG, not from the "skipped" key: `_flag` also returns SKIP
    # for an entry whose `analyze` failed (open failed / image too small / empty alpha mask).
    # Keyed on "skipped" alone, such a row printed SKIP in the table and then vanished from the
    # verdict, which could read "0/15 frames FAIL, 0/17 machines FAIL" for a shoot where
    # nothing rendered at all.
    skipped = [str(e.get("frame") or e.get("id")) for e in frames + machines if _flag(e) == "SKIP"]
    skipped += [r["probe"] for r in readability if _read_flag(r) == "SKIP"]

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
    if meta.get("indoor_reshot"):
        lines.append("")
        lines.append(
            "> **AN INTERIOR FAILED ITS CONFIRMATION** — %s did not reproduce when shot a second "
            "time in the same match. That is the known engine defect where a room loses its "
            "ambient and stops responding to the day-night cycle until the match is restarted, "
            "so the match WAS restarted and the WHOLE interior block was shot again (as a block, "
            "because they have to share one match age to stay comparable). The numbers below are "
            "the re-shot ones; the discarded pass was: %s."
            % (
                ", ".join(
                    "`%s` (%s vs %s)" % (d["frame"], d["first"], d["second"])
                    for d in (meta.get("indoor_drifted") or [])
                )
                or "an interior",
                ", ".join(
                    "%s %s->%s" % (r["frame"], r["discarded"], r["kept"])
                    for r in meta["indoor_reshot"]
                ),
            )
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
    lines.append(
        "`prep` is the shutter hygiene, and it is how a suspicious row is triaged: `cN` = "
        "machines cleared around the stand before the shutter (INTERIORS only — an outdoor "
        "frame keeps its machines, and combat_day spawns its own), `evK` = a world event of "
        "kind K was running and was ended, `dX` = how far p50 still moved between the last two "
        "throwaway exposures when the shutter opened (gate: %.3f). A `d` at or under the gate "
        "means the scene had stopped; a larger one means the shoot ran out of patience and the "
        "row is a sample of a moving scene, not a measurement." % FRAME_EXPOSURE_TOL
    )
    lines.append("")
    lines.append(
        "| frame | hour | region | p05 | p50 | p95 | range | %%<%.3f | sat | prep | status |"
        % DARK_T
    )
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for f in frames:
        flag = _flag(f)
        if flag == "SKIP":
            lines.append(
                "| %s | - | - | - | - | - | - | - | - | - | SKIP (%s) |"
                % (f["frame"], f.get("skipped", (f.get("stats") or {}).get("error", "?")))
            )
            continue
        w = f["stats"]["world"]
        why = f["stats"].get("fail_why") or ""
        prep = "d%.3f" % float(f.get("exposure_drift") or 0.0)
        if "cleared" in f:
            prep = "c%d %s" % (int(f["cleared"]), prep)
        ended = max(int(f.get("event_ended", -1)), int(f.get("event_ended_late", -1)))
        if ended >= 0:
            prep = "ev%d %s" % (ended, prep)
        lines.append(
            "| %s | %.1f | %s | %.3f | %.3f | %.3f | %.3f | %.1f%% | %.3f | %s | %s |"
            % (
                f["frame"],
                float(f.get("hour") or 0.0),
                "FULL (indoor)" if f["stats"].get("indoor") else "below-sky",
                w["p05"],
                w["p50"],
                w["p95"],
                f["stats"].get("range", w["p95"] - w["p05"]),
                w["dark_frac"] * 100.0,
                w["saturation"],
                prep,
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
    if readability:
        lines.append("")
        lines.append("## Readability (A/B pair: same frame without / with ONE machine)")
        lines.append("")
        lines.append(
            "The pixels that differ between the two shots ARE the machine. `contrast` = mean "
            "|luma of those pixels - median luma of the %d px background ring around them|, on "
            "the B frame, averaged over the %d pairs each probe shoots. DAY fails only when the "
            "WHOLE measured band (`band`, min..max of those pairs) is under %.2f — the gate sits "
            "inside this tool's own run-to-run spread, so one shutter cannot decide it; read "
            "`spread` before trusting any single number. Night pairs are report-only (there the "
            "number is mostly the emissive eye). `range` is the measured distance at the shutter "
            "(gated to %.1f+-%.1f m so probes are compared at the same apparent size). `dp50` is "
            "the naive median-vs-median reading, kept for reference — it collapses on a two-tone "
            "chassis (see `analyze_readability`). `cover` = mask share of the analysed region, "
            "`noise` = share of that region which changed for reasons OTHER than the machine "
            "(wind, particles, other machines): a pair with high `noise` is weather, not a "
            "measurement."
            % (READ_RING_PX, READ_REPS, READ_FAIL_CONTRAST, READ_SHOT_DIST, READ_DIST_TOL)
        )
        lines.append("")
        lines.append(
            "| probe | machine | hour | range | target | bg | contrast | band | spread | dp50 "
            "| dsat | cover | noise | status |"
        )
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in readability:
            flag = _read_flag(r)
            st = r.get("stats") or {}
            if flag == "SKIP":
                lines.append(
                    "| %s | %s | - | - | - | - | - | - | - | - | - | - | - | SKIP (%s) |"
                    % (r["probe"], r.get("id", "?"), r.get("skipped", st.get("error", "?")))
                )
                continue
            lines.append(
                "| %s | %s | %.1f | %.1fm | %.3f | %.3f | **%.3f** | %.3f-%.3f | %.3f | %.3f "
                "| %+.3f | %.2f%% | %.1f%% | %s |"
                % (
                    r["probe"],
                    r.get("id", "?"),
                    float(r.get("hour") or 0.0),
                    float(st.get("shot_dist_mean") or r.get("target_dist") or 0.0),
                    st["target_p50"],
                    st["bg_p50"],
                    st["contrast"],
                    st.get("contrast_min", st["contrast"]),
                    st.get("contrast_max", st["contrast"]),
                    st.get("contrast_spread", 0.0),
                    st["p50_delta"],
                    st["sat_delta"],
                    st["coverage"] * 100.0,
                    st.get("diff_frac", 0.0) * 100.0,
                    "%s (%d/%d pairs)" % (flag, st.get("reps_ok", 1), st.get("reps", 1)),
                )
            )
    lines.append("")
    verdict = "VERDICT: %d/%d frames FAIL, %d/%d machines FAIL" % (
        len(bad_frames),
        len(frames),
        len(bad_machines),
        len(machines),
    )
    if readability:
        verdict += ", %d/%d readability FAIL" % (len(bad_read), len(readability))
    # ASCII only: this line is also printed to a Windows console (cp1251 there would raise
    # UnicodeEncodeError on an em-dash and kill the run right at the finish line).
    if bad_frames:
        verdict += " | dark frames: %s" % ", ".join(bad_frames)
    if bad_machines:
        verdict += " | dark machines: %s" % ", ".join(bad_machines)
    if bad_read:
        verdict += " | unreadable vs background: %s" % ", ".join(bad_read)
    if skipped:
        verdict += " | skipped: %s" % ", ".join(str(s) for s in skipped)
    if meta["contaminated"]:
        verdict += " | CONTAMINATED (mutator %s)" % meta["mutator"]
    if meta.get("indoor_reshot"):
        verdict += " | interior confirmation failed on %s, whole interior block re-shot" % (
            ", ".join(str(d["frame"]) for d in (meta.get("indoor_drifted") or [])) or "an interior"
        )
    lines.append("**%s**" % verdict)
    lines.append("")
    lines.append("Contact sheet: `contact.jpg` (montage via %s)." % meta["contact"])
    lines.append("")
    (OUT_DIR / "report.md").write_text("\n".join(lines), encoding="utf-8")
    print(verdict)
    return len(skipped)


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
    entry["stats"] = analyze(
        dst,
        is_hero=is_hero,
        night=bool(entry.get("night")),
        indoor=bool(entry.get("indoor")),
    )
    return dst


def _collect_rep(probe_name: str, rep: dict[str, Any], idx: int) -> Path | None:
    """Copy BOTH halves of ONE A/B pair out of user://, then diff them."""
    if "skipped" in rep:
        return None
    dsts: list[Path] = []
    for key, suffix in (("src_a", "a"), ("src_b", "b")):
        src = rep.get(key)
        if not src:
            rep["skipped"] = "missing %s" % key
            return None
        dst = OUT_DIR / ("read_%s_r%d_%s.png" % (probe_name, idx, suffix))
        try:
            shutil.copy2(src, dst)
        except OSError as exc:
            rep["skipped"] = "copy failed: %s" % exc
            return None
        dsts.append(dst)
    rep["png"] = dsts[1].name
    mask_png = OUT_DIR / ("read_%s_r%d_mask.png" % (probe_name, idx))
    seed = None
    box = None
    cam = rep.get("cam")
    if isinstance(cam, dict):
        try:
            with Image.open(dsts[1]) as img:
                w, h = img.width, img.height
        except OSError:
            w, h = 0, 0
        if w and h:
            seed = project_to_frame(
                tuple(cam["pos"]), cam["yaw"], cam["pitch"], cam["fov"], tuple(cam["target"]), w, h
            )
            rep["seed_px"] = [round(v, 1) for v in seed] if seed else None
            box = _target_box(cam, w, h)
            rep["box_px"] = [round(v, 1) for v in box] if box else None
            # How much of the body the ANALYSED region can even see. The crop drops the top 14%
            # and bottom 16% for HUD, so a close machine has its legs outside the measured area
            # — which is fine as long as the reader knows (a fully framed body and a half-framed
            # one are not the same measurement).
            if box:
                row0, row1 = _read_region_rows(h)
                inside = max(0.0, min(box[3], row1) - max(box[1], row0))
                rep["box_in_region"] = round(inside / max(1e-6, box[3] - box[1]), 3)
    rep["stats"] = analyze_readability(
        dsts[0], dsts[1], mask_png, seed, bool(rep.get("night")), box
    )
    if (rep["stats"] or {}).get("ok"):
        rep["mask_png"] = mask_png.name
    return dsts[1]


# Fields averaged over the reps of one probe so the report row is a pair-MEAN, not a coin flip.
_READ_MEAN_KEYS = (
    "target_p50",
    "bg_p50",
    "p50_delta",
    "contrast",
    "sat_delta",
    "coverage",
    "diff_frac",
)


def _collect_read(entry: dict[str, Any]) -> list[tuple[Path | None, str]]:
    """Diff every rep of one probe, fold them into one row, return the contact-sheet tiles.

    The row carries the MEAN of the reps plus the measured BAND (min..max) and spread: the
    gate is a decision about the whole band, and a reader has to see how wide it was.
    """
    tiles: list[tuple[Path | None, str]] = []
    reps: list[dict[str, Any]] = entry.get("reps") or []
    for i, rep in enumerate(reps):
        dst = _collect_rep(str(entry["probe"]), rep, i)
        stats = rep.get("stats") or {}
        cap = "read %s r%d" % (entry["probe"], i)
        if stats.get("ok"):
            cap = "read %s r%d  c %.3f @%.1fm" % (
                entry["probe"],
                i,
                stats["contrast"],
                float(rep.get("target_dist") or 0.0),
            )
        elif "skipped" in rep:
            cap = "read %s r%d  SKIP" % (entry["probe"], i)
        tiles.append((dst, cap))
    oks = [r for r in reps if (r.get("stats") or {}).get("ok")]
    if not oks:
        entry.setdefault(
            "skipped",
            "; ".join(
                str(r.get("skipped") or (r.get("stats") or {}).get("error", "?")) for r in reps
            )
            or "no reps",
        )
        return tiles
    agg: dict[str, Any] = {"ok": True, "reps_ok": len(oks), "reps": len(reps)}
    for key in _READ_MEAN_KEYS:
        vals = [float(r["stats"][key]) for r in oks if key in r["stats"]]
        if vals:
            agg[key] = round(sum(vals) / len(vals), 4)
    cs = [float(r["stats"]["contrast"]) for r in oks]
    agg["contrast_reps"] = [round(c, 4) for c in cs]
    agg["contrast_min"] = round(min(cs), 4)
    agg["contrast_max"] = round(max(cs), 4)
    agg["contrast_spread"] = round(max(cs) - min(cs), 4)
    dists = [float(r.get("target_dist") or 0.0) for r in oks]
    agg["shot_dist_mean"] = round(sum(dists) / len(dists), 2)
    entry["stats"] = agg
    entry["png"] = oks[0].get("png")
    return tiles


def _fresh_match(total: float) -> float:
    """Restart the match and hand back a world in a known state; returns the match duration.

    Used three times: before the outdoor frames, before the interiors, and as the repair when
    an interior fails its confirmation. The mutator is pinned empty FIRST because a restart
    RE-ROLLS it and Night Raid would silently relight the whole set.
    """
    send({"cmd": "mutator", "id": ""})
    send({"cmd": "restart"})
    time.sleep(6.0)
    if not wait_drivable(120.0):
        return 0.0
    send({"cmd": "godmode", "on": True})
    _KILL_TRACK.update({"bank": 0.0, "level": 1.0, "offer_until": 0.0})
    # The raid-contract offer pops a full-width modal a few seconds into a fresh match and
    # auto-dismisses at ~15 s. Shooting through it puts a card stack over half the frame.
    _wait_contract_clear()
    st = send({"cmd": "state"})
    return float((st.get("match_timer") or {}).get("total") or total)


def _capture(frame: Frame, label: str, total: float) -> tuple[dict[str, Any], tuple[Any, str]]:
    """Shoot one frame, copy + score it, and build its contact-sheet tile. Also prints the row.

    Factored out of the main loop because the indoor block can be shot TWICE — once normally and
    once after a repair restart (see INDOOR_CONFIRM_TOL) — and both passes have to produce
    byte-identical bookkeeping.
    """
    entry = shot(frame, label, total)
    dst = _collect(entry, is_hero=False)
    caption = frame.name + (" [indoor]" if frame.indoor else "")
    stats = entry.get("stats") or {}
    if stats.get("ok"):
        caption = "%s%s  p50 %.2f  dark %.0f%%" % (
            frame.name,
            " [indoor]" if frame.indoor else "",
            stats["world"]["p50"],
            stats["world"]["dark_frac"] * 100.0,
        )
    prep = " (drift %.3f)" % float(entry.get("exposure_drift") or 0.0)
    if frame.clear:
        prep = " (cleared %d,%s" % (int(entry.get("cleared") or 0), prep[2:])
    print("  %-22s %s%s" % (frame.name, entry.get("skipped", "ok"), prep))
    return entry, (dst, caption)


def _confirm_indoor(
    indoor_idx: list[int], frames: list[dict[str, Any]], label: str, total: float
) -> list[dict[str, Any]]:
    """Shoot every interior a SECOND time and report how far each moved from its first capture.

    The confirmation frames are analysed straight out of the game's user:// folder and thrown
    away — only the number matters. The camera has to be put back into first person for them,
    because that is how the interiors were shot.
    """
    out: list[dict[str, Any]] = []
    if not indoor_idx:
        return out
    _view_step(2)
    for i in indoor_idx:
        frame = FRAMES[i]
        first = ((frames[i].get("stats") or {}).get("world") or {}).get("p50")
        entry = shot(frame, "%s_confirm" % label, total)
        second: float | None = None
        src = entry.get("src")
        if src:
            stats = analyze(Path(src), night=bool(entry.get("night")), indoor=frame.indoor)
            if stats.get("ok"):
                second = round(float(stats["world"]["p50"]), 4)
        delta = None if (first is None or second is None) else round(abs(float(first) - second), 4)
        out.append(
            {"frame": frame.name, "first": first, "second": second, "delta": delta}
        )
        print("  confirm %-18s %s vs %s (d %s)" % (frame.name, first, second, delta))
    _view_step(2)
    return out


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
    if not wait_drivable(120.0):
        print("not drivable — launch the game with `-- --agent` first (port %d)" % PORT)
        return 1
    # THE SHOOT RUNS IN TWO RESTARTED MATCHES, outdoors first and the interiors in a match of
    # their own. Both halves need a fresh world for the ordinary reason — an instance that has
    # been up for a while has accumulated waves (18 -> 21 -> 24 machines over three passes,
    # measured), spent world events and a floor full of dropped loot, all of which walk the
    # histogram with no light change behind them. The interiors need it for a second, sharper
    # reason: their light DEGRADES with time-in-match. The SnowDepot reads ~0.31 when shot into
    # a fresh arena and ~0.257 when the same capture comes after the eight outdoor frames, and
    # both values are self-consistent — a confirmation shot taken next to it agrees to 0.0004,
    # so no amount of re-measuring inside one match can catch it. Shooting every interior at the
    # same age of the match is what makes them comparable between runs.
    total = _fresh_match(300.0)
    if total <= 0.0:
        print("not drivable after the opening restart (port %d)" % PORT)
        return 1
    st = send({"cmd": "state"})
    mutator = str((st.get("world") or {}).get("mutator") or "")
    contaminated = mutator != ""
    print(
        "mutator=%r total=%.0fs -> %s"
        % (mutator, total, "CONTAMINATED" if contaminated else "clean")
    )

    outdoor_idx = [i for i, f in enumerate(FRAMES) if not f.clear]
    indoor_idx = [i for i, f in enumerate(FRAMES) if f.clear]
    # Pre-seeded so a frame that never gets captured (the interior block failing to become
    # drivable, say) reports as an honest SKIP row instead of crashing the table builder.
    frames: list[dict[str, Any]] = [
        {"frame": f.name, "skipped": "not captured"} for f in FRAMES
    ]
    tiles: list[tuple[Path | None, str]] = [(None, "") for _ in FRAMES]
    for i in outdoor_idx:
        frames[i], tiles[i] = _capture(FRAMES[i], LABEL, total)

    # INDOOR frames are shot in FIRST PERSON, for the two reasons the readability pairs are (and
    # they are the one part of this tool that always repeated):
    #   * there is no SpringArm, so nothing can collapse it. In third person the camera sits
    #     ~3.5 m behind the player, INSIDE the room, and it snaps onto whatever gets between
    #     the two — a machine, a rack, a table. That produced the garbage frames in the tower
    #     (a washed-out close-up of a slab edge scoring p50 0.67 where the settled room reads
    #     0.43) and the warehouse dips (0.411 vs 0.305 from a frozen pose).
    #   * the player's own body stops being a tenth of the measured area. It is dark, it is
    #     centred, and it breathes — a moving 0.1-luma object inside the crop, moving the
    #     median for no reason connected to the room's light.
    # Outdoor frames stay third person: the body is a few percent of a wide shot, and those
    # captures are comparable to every lighting_qa/before-after image ever taken from them.
    # The restart is what makes the toggling safe: player.gd resets `_view_step` to
    # Settings.DEFAULT_VIEW_STEP (1) on every deploy, so +2 lands on VIEW_STEP_FIRST_PERSON
    # and +2 again wraps back (VIEW_STEP_COUNT 4). A mis-step is not silent — the player's
    # chassis reappears in the middle of every interior tile on the contact sheet.
    confirm: list[dict[str, Any]] = []
    reshot: list[dict[str, Any]] = []
    drifted: list[dict[str, Any]] = []
    for attempt in range(2):
        total = _fresh_match(total)
        if total <= 0.0:
            print("not drivable for the interior block (port %d)" % PORT)
            break
        _view_step(2)
        for i in indoor_idx:
            before = ((frames[i].get("stats") or {}).get("world") or {}).get("p50")
            frames[i], tiles[i] = _capture(FRAMES[i], LABEL, total)
            if attempt > 0:
                frames[i]["reshot_after_collapse"] = True
                frames[i]["discarded_p50"] = before
                reshot.append(
                    {
                        "frame": FRAMES[i].name,
                        "discarded": before,
                        "kept": ((frames[i].get("stats") or {}).get("world") or {}).get("p50"),
                    }
                )
        _view_step(2)
        # Re-measure every interior. See INDOOR_CONFIRM_TOL for the defect and its evidence:
        # this is the part of the tool that refuses to publish a number it has just failed to
        # reproduce. One repair attempt, then the run ships what it has and says so.
        confirm = _confirm_indoor(indoor_idx, frames, LABEL, total)
        fails = [c for c in confirm if c["delta"] is not None and c["delta"] > INDOOR_CONFIRM_TOL]
        if attempt == 0:
            drifted = fails
        if not fails:
            break
        if attempt > 0:
            print("  still drifting after the repair — shipping it, flagged")
            break
        print(
            "  CONFIRMATION FAILED: %s — restarting and re-shooting the whole interior block"
            % ", ".join("%s (%.3f vs %.3f)" % (c["frame"], c["first"], c["second"]) for c in fails)
        )

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

    # Readability LAST: it restarts the match (see readability_block), so it must not disturb
    # the fixed frames — and it needs a field that the frame shoot has just finished heating up.
    readability = readability_block(LABEL, total)
    for entry in readability:
        tiles.extend(_collect_read(entry))

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
            "read_diff_t": READ_DIFF_T,
            "read_ring_px": READ_RING_PX,
            "read_fail_contrast": READ_FAIL_CONTRAST,
            "read_shot_dist": READ_SHOT_DIST,
            "read_dist_tol": READ_DIST_TOL,
            "read_reps": READ_REPS,
            "indoor_confirm_tol": INDOOR_CONFIRM_TOL,
            "frame_exposure_tol": FRAME_EXPOSURE_TOL,
        },
        # Evidence for the interiors: every one was shot twice, and if the two disagreed the
        # match was restarted and they were shot again. Both readings stay in the file.
        "indoor_confirm": confirm,
        "indoor_reshot": reshot,
        "indoor_drifted": drifted,
        # `sky_frac` applies to OUTDOOR frames only — an indoor frame is analysed over the
        # full crop and says so per row (`stats.region`).
        "crop": {"top": CROP_TOP, "bottom": CROP_BOT, "sky_frac": SKY_FRAC},
        "contact": how,
    }
    skipped = report(meta, frames, machines, readability)
    print("out: %s" % OUT_DIR)
    # A FAIL is a measurement (and the expected state of a "before" baseline); a SKIP means the
    # shoot did not happen. Only the latter fails the process, so a scripted baseline run cannot
    # pass silently on frames or heroes that never rendered.
    return 1 if skipped else 0


if __name__ == "__main__":
    sys.exit(main())
