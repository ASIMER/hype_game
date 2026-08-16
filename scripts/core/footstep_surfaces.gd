class_name FootstepSurfaces
extends Node
## D5.3 footsteps & foley + the procedural CLIP BANK the rest of the audio pass draws from
## (D5.4 ambience layers, D5.5 machine vocalizations, loot/craft/door one-shots).
##
## Code-instanced child of AudioManager — the AudioOcclusion / EnemyStatus component
## pattern: the host file only routes, every rule lives here. Purely LOCAL + render-only:
## nothing is replicated, no gameplay code reads a surface, and the node is never built
## headless (AudioManager skips it there), so a dedicated server pays nothing.
##
## SURFACES. What is under the boot is resolved in three cheap steps (surface_at):
##   1. the FROZEN ProceduralTerrain.water_surface_at contract → WATER while wading,
##   2. ONE downward ray on the world layer → a BreakableChunk answers with its
##      material_kind (every floor / roof / container / stair cell is one) → CONCRETE or
##      METAL; indoors with no chunk under us still reads CONCRETE,
##   3. otherwise the biome quadrant (WorldBounds.biome_at) → DIRT / SAND / SNOW.
## The verdict is cached per position+age, so sprinting costs ~4 rays a second — never one
## per frame, and never one per step for a squad standing still.
##
## SYNTHESIS. Every clip is generated in code on FIRST use (AudioStreamWAV, 16-bit mono,
## 22 kHz one-shots / 11 kHz beds) and cached in a static bank, so boot pays nothing and a
## surface you never walk on is never built. The noise source is an inline LCG — NEVER
## randf(): the bank must come out identical on every peer and every boot (and a clip that
## re-rolls per boot makes the mix impossible to tune). Four data-driven builders cover the
## whole bank: _build_step (impact + body + partials), _build_tones (additive blips),
## _build_sweep (glide + noise, both ends of the noise filter animated) and _build_bed
## (crossfade-looped beds).

## What is under the boot. The int doubles as the step-clip bank key suffix.
enum Surface { CONCRETE, DIRT, SAND, SNOW, WATER, METAL }

const _RATE_SFX: int = 22050  # one-shots: plenty for a boot scuff, half the samples of 44k
const _RATE_BED: int = 11025  # beds are wind/hum — nothing above 5 kHz to lose
const _STEP_VARIANTS: int = 3  # per surface; a step picks one deterministically

## Biome quadrant → the ground you walk on out in the open (buildings answer via chunks).
const _BIOME_SURFACE := {
	"urban": Surface.DIRT,
	"snow": Surface.SNOW,
	"desert": Surface.SAND,
	"rain": Surface.DIRT,
}

## Settings.CHUNK_KIND_* → surface. Stone reads as CONCRETE (both are hard mineral); the
## per-step pitch jitter keeps a rock scramble from sounding like a corridor.
const _CHUNK_SURFACE := {
	Settings.CHUNK_KIND_CONCRETE: Surface.CONCRETE,
	Settings.CHUNK_KIND_METAL: Surface.METAL,
	Settings.CHUNK_KIND_STONE: Surface.CONCRETE,
}

## Per-surface voice. `lp`/`hp` are one-pole coefficients on the noise (lp high = bright,
## hp > 0 subtracts a slower pole = thins the low end), `grain` gates the noise at
## `grain_hz` (the snow crunch), `body` is the low thump, p1..p3 are Vector3(hz, amp,
## decay) resonances (the metal clank), `sweep` is Vector3(hz0, amp, hz1) (the water
## bloop). `db` is the playback trim, `lo`/`hi` the pitch-jitter window.
const _STEP_SPECS := {
	Surface.CONCRETE:
	{
		"dur": 0.20,
		"lp": 0.55,
		"hp": 0.04,
		"decay": 0.045,
		"body": 0.25,
		"body_hz": 120.0,
		"p1": Vector3(1900.0, 0.10, 0.02),
		"db": -13.0,
		"lo": 0.94,
		"hi": 1.08,
	},
	Surface.DIRT:
	{
		"dur": 0.26,
		"lp": 0.22,
		"decay": 0.062,
		"grain": 0.18,
		"grain_hz": 128.0,
		"body": 0.30,
		"body_hz": 95.0,
		"db": -14.0,
		"lo": 0.92,
		"hi": 1.10,
	},
	Surface.SAND:
	{
		"dur": 0.30,
		"lp": 0.90,
		"hp": 0.10,
		"decay": 0.085,
		"grain": 0.12,
		"grain_hz": 88.0,
		"body": 0.08,
		"body_hz": 110.0,
		"db": -15.0,
		"lo": 0.95,
		"hi": 1.12,
	},
	Surface.SNOW:
	{
		"dur": 0.26,
		"lp": 0.45,
		"hp": 0.05,
		"decay": 0.070,
		"grain": 0.85,
		"grain_hz": 62.0,
		"body": 0.12,
		"body_hz": 105.0,
		"p1": Vector3(2600.0, 0.05, 0.030),
		"db": -14.0,
		"lo": 0.90,
		"hi": 1.06,
	},
	Surface.WATER:
	{
		"dur": 0.42,
		"lp": 0.35,
		"decay": 0.110,
		"sweep": Vector3(420.0, 0.22, 130.0),
		"db": -12.0,
		"lo": 0.90,
		"hi": 1.14,
	},
	Surface.METAL:
	{
		"dur": 0.34,
		"lp": 0.80,
		"hp": 0.20,
		"decay": 0.030,
		"body": 0.10,
		"body_hz": 150.0,
		"p1": Vector3(690.0, 0.30, 0.140),
		"p2": Vector3(1420.0, 0.18, 0.090),
		"p3": Vector3(2380.0, 0.10, 0.050),
		"db": -13.0,
		"lo": 0.93,
		"hi": 1.09,
	},
}

## Additive tone one-shots — `seq` entries are Vector4(onset_s, hz, amp, decay_s), `grit`
## adds a low-passed noise bed under the whole clip. Machine chirps read "digital" because
## the partials are exact and the envelopes are hard; the loot/craft blips are musical.
const _TONE_SEQS := {
	"robot_alert2":
	{
		"dur": 0.34,
		"grit": 0.16,
		"seq":
		[
			Vector4(0.00, 1180.0, 0.90, 0.035),
			Vector4(0.06, 1560.0, 0.85, 0.035),
			Vector4(0.12, 2040.0, 0.75, 0.055),
		],
	},
	"robot_alert3":
	{
		"dur": 0.30,
		"grit": 0.22,
		"seq":
		[
			Vector4(0.00, 1720.0, 0.85, 0.030),
			Vector4(0.05, 1290.0, 0.80, 0.030),
			Vector4(0.10, 1720.0, 0.70, 0.030),
			Vector4(0.15, 970.0, 0.65, 0.060),
		],
	},
	"gear_jingle0":
	{
		"dur": 0.40,
		"grit": 0.30,
		"seq":
		[
			Vector4(0.000, 1850.0, 0.55, 0.055),
			Vector4(0.045, 2450.0, 0.40, 0.045),
			Vector4(0.090, 3100.0, 0.28, 0.035),
			Vector4(0.130, 1450.0, 0.35, 0.070),
		],
	},
	"gear_jingle1":
	{
		"dur": 0.40,
		"grit": 0.34,
		"seq":
		[
			Vector4(0.000, 2150.0, 0.50, 0.050),
			Vector4(0.055, 1620.0, 0.42, 0.060),
			Vector4(0.100, 2860.0, 0.26, 0.035),
			Vector4(0.150, 1240.0, 0.30, 0.080),
		],
	},
	"loot_pickup":
	{
		"dur": 0.22,
		"grit": 0.06,
		"seq": [Vector4(0.00, 880.0, 0.80, 0.055), Vector4(0.045, 1320.0, 0.70, 0.090)],
	},
	"cache_open":
	{
		"dur": 0.85,
		"grit": 0.28,
		"seq":
		[
			Vector4(0.00, 320.0, 0.70, 0.090),
			Vector4(0.02, 1180.0, 0.30, 0.060),
			Vector4(0.20, 660.0, 0.60, 0.180),
			Vector4(0.32, 880.0, 0.55, 0.200),
			Vector4(0.44, 1320.0, 0.50, 0.320),
		],
	},
	"craft_done":
	{
		"dur": 0.70,
		"grit": 0.20,
		"seq":
		[
			Vector4(0.00, 430.0, 0.85, 0.070),
			Vector4(0.01, 1760.0, 0.35, 0.040),
			Vector4(0.18, 740.0, 0.55, 0.150),
			Vector4(0.30, 1110.0, 0.50, 0.260),
		],
	},
}

## Glide one-shots: a sine gliding hz0→hz1 (optionally FM-warbled) plus a noise layer whose
## own filter sweeps lp0→lp1, and an optional low "clunk" partial dropped in late. One
## builder covers the jump grunt, the landing thud, the mantle scrape, the machine
## power-down and the annex door motor.
const _SWEEPS := {
	"foley_jump":
	{
		"dur": 0.28,
		"hz0": 380.0,
		"hz1": 190.0,
		"amp": 0.55,
		"attack": 0.004,
		"decay": 0.070,
		"noise": 0.45,
		"lp0": 0.35,
		"lp1": 0.12,
		"noise_decay": 0.090,
	},
	"foley_land":
	{
		"dur": 0.40,
		"hz0": 98.0,
		"hz1": 62.0,
		"amp": 1.00,
		"attack": 0.003,
		"decay": 0.100,
		"noise": 0.55,
		"lp0": 0.30,
		"lp1": 0.10,
		"noise_decay": 0.070,
	},
	"foley_scrape":
	{
		"dur": 0.55,
		"hz0": 100.0,
		"hz1": 82.0,
		"amp": 0.22,
		"attack": 0.090,
		"decay": 0.220,
		"noise": 1.00,
		"lp0": 0.06,
		"lp1": 0.50,
		"noise_decay": 0.260,
	},
	"robot_death2":
	{
		"dur": 0.80,
		"hz0": 620.0,
		"hz1": 130.0,
		"amp": 0.80,
		"attack": 0.006,
		"decay": 0.320,
		"noise": 0.30,
		"lp0": 0.60,
		"lp1": 0.10,
		"noise_decay": 0.280,
		"clunk_hz": 72.0,
		"clunk_at": 0.60,
	},
	"robot_death3":
	{
		"dur": 0.90,
		"hz0": 840.0,
		"hz1": 96.0,
		"amp": 0.75,
		"attack": 0.004,
		"decay": 0.380,
		"fm_hz": 26.0,
		"fm_amt": 0.22,
		"noise": 0.34,
		"lp0": 0.50,
		"lp1": 0.08,
		"noise_decay": 0.320,
		"clunk_hz": 58.0,
		"clunk_at": 0.68,
	},
	"metal_creak":
	{
		"dur": 1.20,
		"rate": _RATE_BED,
		"hz0": 152.0,
		"hz1": 118.0,
		"amp": 0.65,
		"attack": 0.300,
		"decay": 0.520,
		"fm_hz": 7.5,
		"fm_amt": 0.35,
		"noise": 0.30,
		"lp0": 0.10,
		"lp1": 0.22,
		"noise_decay": 0.600,
	},
	"door_open":
	{
		"dur": 1.10,
		"hz0": 58.0,
		"hz1": 46.0,
		"amp": 0.80,
		"attack": 0.060,
		"decay": 0.520,
		"noise": 0.60,
		"lp0": 0.08,
		"lp1": 0.30,
		"noise_decay": 0.480,
		"clunk_hz": 96.0,
		"clunk_at": 0.86,
	},
}

## Looping beds (D5.4). `mod` entries are Vector3(cycles_per_loop, amount, phase) — the
## cycle count is an INTEGER so the modulation is loop-continuous; `tone` entries are
## Vector3(hz, amp, 0) sines whose hz × dur is likewise a WHOLE number of cycles, so they
## close on themselves. The noise part cannot, so its tail is crossfaded back over the head
## (see _build_bed) — the standard seamless-loop trick.
const _BEDS := {
	"amb_night_wind":
	{
		"dur": 3.4,
		"lp": 0.045,
		"hp": 0.004,
		"noise": 1.00,
		"mod": [Vector3(1.0, 0.55, 0.0), Vector3(3.0, 0.22, 1.7), Vector3(7.0, 0.10, 0.4)],
		"tone": [Vector3(220.0, 0.05, 0.0)],
	},
	"amb_day_air":
	{
		"dur": 3.2,
		"lp": 0.020,
		"hp": 0.002,
		"noise": 0.70,
		"mod": [Vector3(1.0, 0.30, 0.9), Vector3(2.0, 0.14, 0.0)],
		"tone": [Vector3(95.0, 0.04, 0.0), Vector3(1440.0, 0.02, 0.0)],
	},
	"amb_indoor_hum":
	{
		"dur": 3.0,
		"lp": 0.012,
		"noise": 0.22,
		"mod": [Vector3(1.0, 0.14, 0.0)],
		"tone": [Vector3(150.0, 0.55, 0.0), Vector3(300.0, 0.22, 0.0), Vector3(453.0, 0.09, 0.0)],
	},
}

## Playback trim per non-step clip (dB). The component/AudioManager may add its own offset.
const CLIP_DB := {
	"foley_jump": -17.0,
	"foley_land": -11.0,
	"foley_scrape": -14.0,
	"gear_jingle0": -18.0,
	"gear_jingle1": -18.0,
	"robot_alert2": -9.0,
	"robot_alert3": -9.0,
	"robot_death2": -7.0,
	"robot_death3": -7.0,
	"metal_creak": -20.0,
	"loot_pickup": -12.0,
	"cache_open": -8.0,
	"craft_done": -9.0,
	"door_open": -8.0,
}

## The bank is STATIC: one copy of every generated clip for the whole process, so a
## re-deploy (a fresh AudioManager child) never re-synthesizes anything.
static var _bank: Dictionary = {}

var _player: Node = null  # the LOCAL player (foley is first-person; teammates get steps)
var _surface: int = Surface.DIRT  # cached verdict for the local player
var _surface_pos: Vector3 = Vector3.ZERO  # where it was taken
var _surface_age: float = 0.0  # s since it was taken
var _step_timer: float = 0.0
var _step_seq: int = 0  # feeds the deterministic variant/pitch pick
var _jingle_timer: float = 0.0
var _weight_ratio: float = 0.0  # haul weight / capacity — drives the gear rattle
var _weight_poll: float = 0.0
var _was_on_floor: bool = true
var _fall_vy: float = 0.0  # deepest downward velocity seen this airtime
var _air_time: float = 0.0
var _remote_step_t: Dictionary = {}  # player instance id → last step time (anti-spam)
var _inv_weight: float = -1.0  # last seen local inventory weight (pickup blip edge)
var _inv_grace: float = 0.0  # suppress the blip while the deploy loadout lands


func _ready() -> void:
	Events.local_player_spawned.connect(_on_local_player_spawned)
	Events.player_mantled.connect(_on_player_mantled)
	Events.player_rolled.connect(_on_player_rolled)
	Events.footstep.connect(_on_footstep)
	Events.inventory_changed.connect(_on_inventory_changed)


# ---------------------------------------------------------------------------
# Local foley tick — steps, jump/land, sprint gear rattle
# ---------------------------------------------------------------------------


func _process(delta: float) -> void:
	if _inv_grace > 0.0:
		_inv_grace -= delta
	if _player == null or not is_instance_valid(_player):
		_player = null
		return
	if GameState.phase != GameState.Phase.IN_MATCH:
		return
	var body := _player as CharacterBody3D
	if body == null:
		return
	_surface_age += delta
	_weight_poll -= delta
	if _weight_poll <= 0.0:
		_weight_poll = 1.0
		_refresh_weight()

	var on_floor: bool = body.is_on_floor()
	var vel: Vector3 = body.velocity
	_tick_air(body, on_floor, vel, delta)
	if not on_floor:
		return

	var speed: float = Vector2(vel.x, vel.z).length()
	if speed < Settings.FOLEY_STEP_MIN_SPEED:
		_step_timer = 0.0
		return
	var sprinting: bool = speed > Settings.PLAYER_SPRINT_SPEED * 0.6
	_step_timer -= delta
	if _step_timer <= 0.0:
		_step_timer = Settings.FOLEY_SPRINT_INTERVAL if sprinting else Settings.FOLEY_WALK_INTERVAL
		_play_step(body.global_position, _resolve_local_surface(body), _weight_ratio * 2.5)
	if sprinting and not _is_downed(body):
		_tick_jingle(body, delta)


## Airtime edge detection (per frame, exact — a 10 Hz poll would land AFTER the body has
## already zeroed its fall speed and the thud would lose its weight).
func _tick_air(body: CharacterBody3D, on_floor: bool, vel: Vector3, delta: float) -> void:
	if not on_floor:
		_air_time += delta
		_fall_vy = minf(_fall_vy, vel.y)
	if _was_on_floor and not on_floor:
		_was_on_floor = false
		_air_time = 0.0
		_fall_vy = 0.0
		if vel.y > Settings.FOLEY_JUMP_MIN_VY:
			_play_clip_at("foley_jump", body.global_position, _jitter(1.0, 0.06), 0.0)
	elif not _was_on_floor and on_floor:
		_was_on_floor = true
		var impact: float = absf(_fall_vy)
		if impact >= Settings.FOLEY_LAND_MIN_SPEED and _air_time > 0.12:
			var hard: float = clampf((impact - Settings.FOLEY_LAND_MIN_SPEED) / 9.0, 0.0, 1.0)
			var surf: int = _resolve_local_surface(body)
			_play_clip_at("foley_land", body.global_position, 1.0 - hard * 0.18, hard * 6.0 - 3.0)
			_play_step(body.global_position, surf, 3.0 + hard * 3.0 + _weight_ratio * 2.5)
		_fall_vy = 0.0


## Sprint gear rattle — the loot on your back is AUDIBLE. Volume rides the haul-weight
## ratio the HEAT meter and the spawn director already read, so a full pack is loud.
func _tick_jingle(body: CharacterBody3D, delta: float) -> void:
	_jingle_timer -= delta
	if _jingle_timer > 0.0:
		return
	_jingle_timer = Settings.FOLEY_JINGLE_INTERVAL * ProcHash.hrange(_step_seq * 31 + 7, 0.85, 1.2)
	var db: float = lerpf(
		Settings.FOLEY_JINGLE_DB_EMPTY, Settings.FOLEY_JINGLE_DB_FULL, _weight_ratio
	)
	var variant: int = int(ProcHash.h(_step_seq * 17 + 3) % 2)
	var base: float = CLIP_DB.get("gear_jingle0", -18.0)
	_play_clip_at("gear_jingle%d" % variant, body.global_position, _jitter(1.0, 0.09), db - base)


## One surface-typed step at `pos`. `db_extra` carries the caller's trim: the local step
## adds its haul weight (a loaded raider stomps), a landing stomp adds impact, a teammate's
## step adds neither — MY pack must not make YOUR footfalls louder.
func _play_step(pos: Vector3, surface: int, db_extra: float) -> void:
	_step_seq += 1
	var spec: Dictionary = _STEP_SPECS[surface]
	var variant: int = int(ProcHash.h(_step_seq * 97 + surface) % _STEP_VARIANTS)
	var pitch: float = ProcHash.hrange(
		_step_seq * 131 + surface * 7, float(spec["lo"]), float(spec["hi"])
	)
	_play_clip_at("step_%d_%d" % [surface, variant], pos, pitch, float(spec["db"]) + db_extra)


## TEAMMATE steps (co-op): PlayerAnimator emits Events.footstep on EVERY peer for EVERY
## player at the gait's down-beat, so a squadmate running past is audible + occluded for
## free. The local player is skipped — its own cadence is driven above.
func _on_footstep(who: Node, sprinting: bool) -> void:
	if who == null or who == _player or not (who is Node3D):
		return
	if _player == null or GameState.phase != GameState.Phase.IN_MATCH:
		return
	var pos: Vector3 = (who as Node3D).global_position
	var here: Vector3 = (_player as Node3D).global_position
	if pos.distance_to(here) > Settings.FOLEY_STEP_DIST:
		return
	var key: int = who.get_instance_id()
	var now: float = float(Time.get_ticks_msec()) * 0.001
	var last: float = _remote_step_t.get(key, -1.0)
	if last > 0.0 and now - last < Settings.FOLEY_STEP_MIN_INTERVAL:
		return
	_remote_step_t[key] = now
	var surface: int = surface_at(_space_of(who), pos, false)
	_play_step(pos, surface, -3.0 if not sprinting else -1.0)


func _on_player_mantled(who: Node) -> void:
	if who != _player or not (who is Node3D):
		return
	_play_clip_at("foley_scrape", (who as Node3D).global_position, _jitter(1.0, 0.05), 0.0)


func _on_player_rolled(who: Node) -> void:
	if who != _player or not (who is Node3D):
		return
	_play_clip_at("foley_scrape", (who as Node3D).global_position, _jitter(0.82, 0.05), -3.0)


## Loot blip on a WEIGHT INCREASE of the local inventory. Deliberately NOT on
## Events.item_picked_up: pickups resolve server-side, so a co-op CLIENT never sees that
## signal for its own loot — the mirrored inventory_changed is the one path both ends share.
func _on_inventory_changed(inv: Node) -> void:
	if _player == null or inv == null or inv.get_parent() != _player:
		return
	if not inv.has_method("total_weight"):
		return
	var w: float = float(inv.total_weight())
	var prev: float = _inv_weight
	_inv_weight = w
	if prev < 0.0 or _inv_grace > 0.0 or w <= prev + 0.0001:
		return
	if GameState.phase != GameState.Phase.IN_MATCH:
		return
	play_clip("loot_pickup", _jitter(1.0, 0.05), 0.0)


func _on_local_player_spawned(who: Node) -> void:
	_player = who
	_step_timer = 0.0
	_surface_age = 999.0
	_was_on_floor = true
	_inv_weight = -1.0
	_inv_grace = 2.0
	_remote_step_t.clear()


# ---------------------------------------------------------------------------
# Surface resolution
# ---------------------------------------------------------------------------


## Cached surface under the LOCAL player: re-probed only when the cache aged out or the
## player actually moved (standing on a container costs zero rays).
func _resolve_local_surface(body: CharacterBody3D) -> int:
	var pos: Vector3 = body.global_position
	if _surface_age < Settings.FOLEY_SURFACE_TTL and pos.distance_to(_surface_pos) < 1.2:
		return _surface
	_surface_age = 0.0
	_surface_pos = pos
	var indoor: bool = AudioManager.indoor_ratio() > 0.5
	_surface = surface_at(_space_of(body), pos, indoor)
	return _surface


## THE classifier (static — the harness / any future caller can ask about any point).
## `feet` is the body origin (the capsule's base sits at it, so the ray starts just above).
static func surface_at(space: PhysicsDirectSpaceState3D, feet: Vector3, indoor: bool) -> int:
	var wy: float = ProceduralTerrain.water_surface_at(feet.x, feet.z)
	if not is_nan(wy) and feet.y <= wy + 0.35:
		return Surface.WATER
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(
			feet + Vector3.UP * 0.5, feet + Vector3.DOWN * 1.1, 1
		)
		q.collide_with_areas = false
		var hit: Dictionary = space.intersect_ray(q)
		if not hit.is_empty():
			var s: int = _surface_of_collider(hit.get("collider") as Node)
			if s >= 0:
				return s
	if indoor:
		return Surface.CONCRETE  # a floor we could not ray (thin slab / mid-vault) is built
	var biome: String = WorldBounds.biome_at(feet.x, feet.z)
	var out: int = _BIOME_SURFACE.get(biome, Surface.DIRT)
	return out


## -1 when the collider says nothing (terrain / props) — the caller falls back to the biome.
## Walks up two parents because a chunk's collider may be the body itself or a child shape.
static func _surface_of_collider(col: Node) -> int:
	var n: Node = col
	for _i in 3:
		if n == null:
			return -1
		if n is BreakableChunk:
			var out: int = _CHUNK_SURFACE.get((n as BreakableChunk).material_kind, Surface.CONCRETE)
			return out
		n = n.get_parent()
	return -1


static func _space_of(n: Node) -> PhysicsDirectSpaceState3D:
	var n3 := n as Node3D
	if n3 == null or not n3.is_inside_tree():
		return null
	var w := n3.get_world_3d()
	return null if w == null else w.direct_space_state


func _refresh_weight() -> void:
	_weight_ratio = 0.0
	if _player == null:
		return
	var inv: Node = _player.get_node_or_null("Inventory")
	if inv == null or not inv.has_method("total_weight"):
		return
	var cap: float = 1.0
	if inv.has_method("weight_capacity"):
		cap = float(inv.weight_capacity())
	_weight_ratio = clampf(float(inv.total_weight()) / maxf(0.001, cap), 0.0, 1.0)


func _is_downed(body: Node) -> bool:
	return body.has_method("is_downed") and bool(body.is_downed())


## Deterministic pitch wobble off the step counter (no randf anywhere in this file).
func _jitter(base: float, amount: float) -> float:
	_step_seq += 1
	return base + ProcHash.hrange(_step_seq * 61 + 11, -amount, amount)


# ---------------------------------------------------------------------------
# Playback (routes through AudioManager so occlusion + the SFX bus apply)
# ---------------------------------------------------------------------------


## Non-positional bank one-shot (UI / "my own" cues).
func play_clip(id: String, pitch: float, db_extra: float) -> void:
	var s: AudioStream = stream_for(id)
	if s == null:
		return
	AudioManager.play_stream(s, pitch, db_for(id) + db_extra)


## Positional bank one-shot at a world point (steps, foley, machine chirps, doors).
func play_clip_at(id: String, pos: Vector3, pitch: float, db_extra: float) -> void:
	_play_clip_at(id, pos, pitch, db_extra)


func _play_clip_at(id: String, pos: Vector3, pitch: float, db_extra: float) -> void:
	var s: AudioStream = stream_for(id)
	if s == null:
		return
	AudioManager.play_world(s, pos, pitch, db_for(id) + db_extra, Settings.FOLEY_STEP_DIST + 12.0)


## Trim for a bank id (steps carry their own, see _play_step).
static func db_for(id: String) -> float:
	var out: float = CLIP_DB.get(id, 0.0)
	return out


## Deterministic per-INSTANCE pitch: a wave of eight machines must not chirp with one
## voice eight times. Hashing the node NAME (unique + already replicated) means every peer
## hears the same machine at the same pitch, with zero new state.
static func pitch_for_name(node_name: String, lo: float, hi: float) -> float:
	return ProcHash.hrange(node_name.hash(), lo, hi)


## Deterministic variant index for a node name (same hash family, different salt).
static func variant_for_name(node_name: String, count: int) -> int:
	if count <= 1:
		return 0
	return int(ProcHash.h(node_name.hash() * 7 + 13) % count)


# ---------------------------------------------------------------------------
# Synthesis — the bank
# ---------------------------------------------------------------------------


## Fetch (building on first use). Returns null for an unknown id; the null is CACHED so a
## typo can never turn into a per-shot rebuild.
static func stream_for(id: String) -> AudioStream:
	if _bank.has(id):
		var cached: AudioStream = _bank[id]
		return cached
	var s: AudioStream = null
	if id.begins_with("step_"):
		var parts := id.split("_")
		if parts.size() == 3:
			s = _build_step(int(parts[1]), int(parts[2]))
	elif _TONE_SEQS.has(id):
		s = _build_tones(_TONE_SEQS[id])
	elif _SWEEPS.has(id):
		s = _build_sweep(_SWEEPS[id])
	elif _BEDS.has(id):
		s = _build_bed(_BEDS[id])
	_bank[id] = s
	return s


## Deterministic 30-bit LCG step — the ONE noise source in this file.
static func _lcg(s: int) -> int:
	return (s * 1103515245 + 12345) & 0x3FFFFFFF


## White noise in [-1,1] from an LCG state.
static func _white(s: int) -> float:
	return float(s % 20001) / 10000.0 - 1.0


## Pack a float buffer into a normalized 16-bit mono AudioStreamWAV.
static func _make(buf: PackedFloat32Array, rate: int, loop: bool) -> AudioStreamWAV:
	var n: int = buf.size()
	var peak: float = 0.0
	for i in n:
		peak = maxf(peak, absf(buf[i]))
	var gain: float = 0.92 / maxf(peak, 0.0001)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(buf[i] * gain, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	return w


## One boot impact: filtered noise (+ optional grain gate) × a fast decay, a low body
## thump, up to three resonances and an optional pitch-glide bloop (water).
static func _build_step(surface: int, variant: int) -> AudioStreamWAV:
	var spec: Dictionary = _STEP_SPECS.get(surface, _STEP_SPECS[Surface.DIRT])
	var dur: float = float(spec["dur"])
	var n: int = int(_RATE_SFX * dur)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var st: int = 7919 * (surface + 1) + 104729 * (variant + 1) + 17
	var lp_a: float = float(spec["lp"])
	var hp_a: float = spec.get("hp", 0.0)
	var decay: float = float(spec["decay"])
	var grain: float = spec.get("grain", 0.0)
	var grain_hz: float = float(spec.get("grain_hz", 100.0)) * (1.0 + 0.17 * float(variant))
	var body: float = spec.get("body", 0.0)
	var body_hz: float = float(spec.get("body_hz", 100.0)) * (1.0 - 0.06 * float(variant))
	var p1: Vector3 = spec.get("p1", Vector3.ZERO)
	var p2: Vector3 = spec.get("p2", Vector3.ZERO)
	var p3: Vector3 = spec.get("p3", Vector3.ZERO)
	var sweep: Vector3 = spec.get("sweep", Vector3.ZERO)
	var inv: float = 1.0 / float(_RATE_SFX)
	var lo: float = 0.0
	var lo2: float = 0.0
	var sw_ph: float = 0.0
	for i in n:
		var t: float = float(i) * inv
		st = _lcg(st)
		lo += lp_a * (_white(st) - lo)
		var nz: float = lo
		if hp_a > 0.0:
			lo2 += hp_a * (lo - lo2)
			nz = lo - lo2
		if grain > 0.0:
			nz *= lerpf(1.0, maxf(sin(TAU * grain_hz * t + float(variant)), 0.0), grain)
		var env: float = exp(-t / decay) * minf(t * 320.0, 1.0)
		var s: float = nz * env
		if body > 0.0:
			s += body * sin(TAU * body_hz * t) * exp(-t / (decay * 0.6))
		if p1.y > 0.0:
			s += p1.y * sin(TAU * p1.x * t) * exp(-t / p1.z)
		if p2.y > 0.0:
			s += p2.y * sin(TAU * p2.x * t) * exp(-t / p2.z)
		if p3.y > 0.0:
			s += p3.y * sin(TAU * p3.x * t) * exp(-t / p3.z)
		if sweep.y > 0.0:
			sw_ph += TAU * lerpf(sweep.x, sweep.z, minf(t / dur, 1.0)) * inv
			s += sweep.y * sin(sw_ph) * exp(-t / (decay * 1.6))
		buf[i] = s
	return _make(buf, _RATE_SFX, false)


## Additive blip/chirp: a list of onset-scheduled decaying partials over a noise bed.
static func _build_tones(spec: Dictionary) -> AudioStreamWAV:
	var dur: float = float(spec["dur"])
	var rate: int = spec.get("rate", _RATE_SFX)
	var n: int = int(rate * dur)
	var seq: Array = spec["seq"]
	var grit: float = spec.get("grit", 0.0)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var st: int = 20261
	var inv: float = 1.0 / float(rate)
	var lo: float = 0.0
	for i in n:
		var t: float = float(i) * inv
		var s: float = 0.0
		for e in seq:
			var v: Vector4 = e
			var dt: float = t - v.x
			if dt < 0.0:
				continue
			s += v.z * sin(TAU * v.y * dt) * exp(-dt / v.w)
		if grit > 0.0:
			st = _lcg(st)
			lo += 0.5 * (_white(st) - lo)
			s += grit * lo * exp(-t / (dur * 0.35))
		buf[i] = s
	return _make(buf, rate, false)


## Gliding tone + a noise layer whose own one-pole sweeps lp0→lp1, plus an optional late
## clunk. Covers jump / land / scrape / power-down / creak / door motor.
static func _build_sweep(spec: Dictionary) -> AudioStreamWAV:
	var dur: float = float(spec["dur"])
	var rate: int = spec.get("rate", _RATE_SFX)
	var n: int = int(rate * dur)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var hz0: float = float(spec["hz0"])
	var hz1: float = float(spec["hz1"])
	var amp: float = float(spec["amp"])
	var attack: float = float(spec["attack"])
	var decay: float = float(spec["decay"])
	var fm_hz: float = spec.get("fm_hz", 0.0)
	var fm_amt: float = spec.get("fm_amt", 0.0)
	var noise: float = spec.get("noise", 0.0)
	var lp0: float = spec.get("lp0", 0.3)
	var lp1: float = spec.get("lp1", 0.3)
	var nd: float = float(spec.get("noise_decay", decay))
	var clunk_hz: float = spec.get("clunk_hz", 0.0)
	var clunk_at: float = float(spec.get("clunk_at", 0.0)) * dur
	var inv: float = 1.0 / float(rate)
	var st: int = 611953
	var lo: float = 0.0
	var ph: float = 0.0
	for i in n:
		var t: float = float(i) * inv
		var k: float = minf(t / dur, 1.0)
		var f: float = lerpf(hz0, hz1, k)
		if fm_amt > 0.0:
			f *= 1.0 + fm_amt * sin(TAU * fm_hz * t)
		ph += TAU * f * inv
		var env: float = minf(t / maxf(attack, 0.0005), 1.0) * exp(-t / decay)
		var s: float = amp * sin(ph) * env
		if noise > 0.0:
			st = _lcg(st)
			lo += lerpf(lp0, lp1, k) * (_white(st) - lo)
			s += noise * lo * minf(t / maxf(attack, 0.0005), 1.0) * exp(-t / nd)
		if clunk_hz > 0.0 and t >= clunk_at:
			var ct: float = t - clunk_at
			s += 0.7 * sin(TAU * clunk_hz * ct) * exp(-ct / 0.06)
		buf[i] = s
	return _make(buf, rate, false)


## Looping bed: slowly modulated filtered noise + loop-exact sines. The noise cannot loop
## on its own, so the TAIL is crossfaded back over the HEAD (the standard seamless-loop
## trick) — the sines use integer cycles-per-loop and stay continuous by construction.
static func _build_bed(spec: Dictionary) -> AudioStreamWAV:
	var dur: float = float(spec["dur"])
	var n: int = int(_RATE_BED * dur)
	var xf: int = int(_RATE_BED * 0.35)
	var total: int = n + xf
	var raw := PackedFloat32Array()
	raw.resize(total)
	var lp_a: float = float(spec["lp"])
	var hp_a: float = spec.get("hp", 0.0)
	var noise: float = float(spec["noise"])
	var mods: Array = spec.get("mod", [])
	var tones: Array = spec.get("tone", [])
	var inv: float = 1.0 / float(_RATE_BED)
	var st: int = 8675309
	var lo: float = 0.0
	var lo2: float = 0.0
	for i in total:
		var t: float = float(i) * inv
		st = _lcg(st)
		lo += lp_a * (_white(st) - lo)
		var nz: float = lo
		if hp_a > 0.0:
			lo2 += hp_a * (lo - lo2)
			nz = lo - lo2
		var m: float = 1.0
		for e in mods:
			var mv: Vector3 = e
			m *= 1.0 - mv.y + mv.y * (0.5 + 0.5 * sin(TAU * mv.x * t / dur + mv.z))
		var s: float = noise * nz * m * 6.0
		for e2 in tones:
			var tv: Vector3 = e2
			s += tv.y * sin(TAU * tv.x * t)
		raw[i] = s
	var buf := PackedFloat32Array()
	buf.resize(n)
	for i in n:
		if i < xf:
			var w: float = float(i) / float(xf)
			buf[i] = raw[i] * w + raw[n + i] * (1.0 - w)
		else:
			buf[i] = raw[i]
	return _make(buf, _RATE_BED, true)
