extends CharacterBody3D
class_name RobotEnemy
## Server-authoritative robot enemy. Patrols, chases the nearest player on
## detection + line-of-sight, and melees within range. ALL AI runs only on the
## node's multiplayer authority (the spawner/server); clients are purely visual
## and read transform + Health.current + the replicated state enum from the
## MultiplayerSynchronizer.
##
## PARAMETRIZED BY `enemy_id`: stats come from Settings.ENEMY_STATS[enemy_id]
## (health/speed/damage/detect/attack_range/cooldown) and the visual model from
## AssetRegistry.get_model(enemy_id). This one script serves grunt / heavy / tick;
## flying + ranged archetypes (wasp / bastion / boss) extend it (see
## robot_flyer.gd, robot_gunner.gd) and override the hooks marked "# OVERRIDE".
##
## Contracts consumed:
##   Settings.ENEMY_STATS        — per-archetype tuning (fallback ENEMY_* for grunt)
##   AssetRegistry.get_model()   — art per enemy_id
##   Health (child)              — damage/death; we listen to died + health_changed
##   Hurtbox (child)             — weapon raycasts apply damage through it
##   Events.enemy_spawned        — emitted in _ready
##
## Loot hook on death: if res://scenes/items/LootPickup.tscn exists it is
## instantiated under the sibling Net/Loot container (falls back to our own
## parent) at our position with a random loot id; otherwise we just print.

const LOOT_SCENE := "res://scenes/items/LootPickup.tscn"
const LOOT_IDS := ["loot_scrap", "loot_cell"]
# Throttle for the "body-part dropped" toast so a wave of kills doesn't spam the feed (UI-only).
static var _last_part_toast_ms: int = 0
const HP_BAR_SCENE := "res://scenes/enemies/EnemyHealthBar.tscn"
const DEBRIS_SCENE := "res://scenes/fx/RobotDebris.tscn"
const IMPACT_SCENE := "res://scenes/fx/Impact.tscn"

# Death scale-pop: the model snaps up then collapses over this window before freeing.
const DEATH_POP_TIME: float = 0.32

# How long the corpse lingers (death anim + SFX) before it is freed.
const DEATH_LINGER: float = 1.0
# Separation: nearby enemies within this radius push us apart so they don't blob.
const SEPARATION_RADIUS: float = 1.6
const SEPARATION_STRENGTH: float = 1.5
# Hard ceiling on the separation steer's magnitude (vs the unit-length pursuit dir) so a
# dense crowd can never repel itself outside attack range — body collision still resolves
# the final hard overlaps. See _apply_movement.
const SEPARATION_MAX: float = 0.6

# Mirror of EnemyStateMachine.State so the synchronizer replicates a plain int
# and clients can map it to animation without the helper class.
enum State { PATROL, CHASE, ATTACK, INVESTIGATE }

@export var enemy_id: String = "robot_grunt"
@export var patrol_radius: float = 10.0

@onready var _agent: NavigationAgent3D = $NavigationAgent3D
@onready var _health: Health = $Health
@onready var _los_ray: RayCast3D = $LineOfSight
@onready var _model_root: Node3D = $ModelRoot

var _fsm: EnemyStateMachine
var _target: Node3D = null
var _attack_cooldown: float = 0.0
var _home: Vector3 = Vector3.ZERO
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 20.0)
var _retarget_timer: float = 0.0
var _dying: bool = false
# Death scale-pop progress (counts UP from 0 to DEATH_POP_TIME while dying).
var _death_pop_t: float = 0.0
# Visual death FX (burst + scale-pop) run on ALL peers off the replicated is_dead,
# so every client sees the juice even though _on_died (gameplay) is authority-only.
var _death_fx_started: bool = false

# --- Stuck detection / recovery --------------------------------------------
# A chasing enemy that spawns inside a building or jams on geometry yields a zero
# nav direction and freezes — which deadlocks the wave (a wave only clears when
# every spawned enemy is dead). We watch planar progress while chasing and, after
# STUCK_LIMIT seconds without moving STUCK_PROGRESS metres, re-seat on the navmesh
# and (if still unreachable) relocate to open navmesh near the target.
var _stuck_dist: float = INF  # best (smallest) distance-to-target seen while chasing
var _stuck_time: float = 0.0
var _recover_count: int = 0
# PERF: last goal actually submitted to the NavigationAgent — chase/investigate only
# re-issue a path when the goal MOVED (the agent's setter repaths unconditionally;
# per-frame live-position writes cost a full navmesh A* per enemy per tick).
var _last_nav_goal: Vector3 = Vector3(INF, INF, INF)
# PERF: per-enemy noise-handling cooldown (see _on_noise_emitted).
var _noise_ignore_until_ms: int = 0
const STUCK_PROGRESS: float = 1.0  # metres the gap must close to count as progress
const STUCK_LIMIT: float = 2.5  # seconds chasing without closing the gap -> recover

# --- Stats (resolved from Settings.ENEMY_STATS in _ready) -------------------
var _stat_health: float = Settings.ENEMY_MAX_HEALTH
var _stat_speed: float = Settings.ENEMY_MOVE_SPEED
var _stat_damage: float = Settings.ENEMY_DAMAGE
var _stat_detect: float = Settings.ENEMY_DETECT_RADIUS
var _stat_attack_range: float = Settings.ENEMY_ATTACK_RANGE
var _stat_cooldown: float = Settings.ENEMY_ATTACK_COOLDOWN

# --- Animation (visual only) ------------------------------------------------
# The GLB (three.js RobotExpressive) ships an AnimationPlayer with these clips:
#   Idle, Walking, Running, Punch, Death (plus emotes we don't use). We locate it
#   under ModelRoot after the model is added and drive it from `current_state`.
# Everything is guarded so the primitive fallback (no AnimationPlayer) is fine.
var _anim_player: AnimationPlayer = null
var _current_anim: String = ""
var _anim_idle := ""
var _anim_walk := ""
var _anim_run := ""
var _anim_attack := ""
var _anim_death := ""
var _death_anim_played := false

# --- Hit flash --------------------------------------------------------------
# Collected StandardMaterial3D from the model so a hit briefly pushes emission.
var _flash_mats: Array[StandardMaterial3D] = []
var _flash_base_emission: Array = []  # parallel: original emission colors
var _flash_t: float = 0.0
const FLASH_TIME: float = 0.14  # longer so hits read clearly

# --- Hit stagger (visual flinch + small knockback) --------------------------
# On taking damage we kick a brief model-local flinch (recoil scale + dip) that
# decays over STAGGER_TIME, plus a tiny server-driven knockback nudge away from
# the hit so the body reacts. Both are small to avoid net desync; the flinch is
# purely on ModelRoot (replicated transform unaffected). Authority computes the
# knockback so clients see it through the synchronizer.
var _stagger_t: float = 0.0
const STAGGER_TIME: float = 0.16
var _model_rest_pos: Vector3 = Vector3.ZERO
var _model_rest_scale: Vector3 = Vector3.ONE
# Pending knockback velocity applied (and decayed) by the authority's movement.
var _knockback: Vector3 = Vector3.ZERO
const KNOCKBACK_SPEED: float = 2.2  # m/s initial nudge (small)
const KNOCKBACK_DECAY: float = 12.0  # how fast the nudge bleeds off
# Last attacker position (for knockback direction); set by Health via apply_hit
# chain isn't available, so we derive direction from the nearest threat instead.
var _last_hit_health: float = -1.0

var _hp_bar: EnemyHealthBar = null

# --- Procedural idle animation (visual only, runs on ALL peers) --------------
# Only the primitive/procedural models (NO AnimationPlayer) get scripted idle
# motion; the .glb grunt/heavy drive their own AnimationPlayer instead. Parts are
# cached ONCE in _ready (by stable name set in ProceduralModels) and animated each
# _process. We rotate/scale/emit on CHILD nodes of ModelRoot only — never the
# replicated body transform/velocity/state — so co-op stays in sync.
var _has_proc_anim: bool = false
var _anim_time: float = 0.0
# PERF gate: idle animation only runs when the camera is within 60m (2 Hz check).
var _idle_gate_accum: float = 1.0  # start past the threshold → first frame evaluates
var _idle_anim_on: bool = true
# Tick parts.
var _proc_eye: MeshInstance3D = null
var _proc_legs: Array[Node3D] = []
var _proc_leg_rest: Array[Vector3] = []
# Emission-pulse bookkeeping: a glowing part + its authored base energy. We scale
# this base by a sine each frame, but ONLY while the hit-flash is idle (the flash
# owns emission_energy_multiplier during its window, then restores it to 1.0).
var _pulse_part: MeshInstance3D = null
var _pulse_base_energy: float = 6.0

# Replicated to clients by the MultiplayerSynchronizer (see .tscn). Authority
# writes it each tick; clients read it for animation/state-driven visuals.
var current_state: int = State.PATROL
# Alert-chirp bookkeeping (visual/_process side; see the calm→CHASE watcher).
var _sfx_state_prev: int = State.PATROL
var _sfx_age: float = 0.0
var _sfx_alert_last_ms: int = -10000

# Hunter mode: wave-spawned enemies actively seek the nearest player (ignoring the
# detect radius / line-of-sight gate) so survival waves stay aggressive on the big
# map instead of idling at their nest. Set by the wave manager on spawn.
var hunter: bool = false

# --- Perception / INVESTIGATE state -----------------------------------------
# Last-heard world position the enemy is walking toward while investigating.
var _investigate_point: Vector3 = Vector3.ZERO
var _investigate_timer: float = 0.0  # counts DOWN from INVESTIGATE_GIVEUP
var _leash_calm_ms: int = 0  # M3: after a leash break, ignore re-acquire until this tick
var _investigate_arrived: bool = false  # true once within INVESTIGATE_ARRIVE

# Cascading alert refractory: monotonic counter decremented each physics tick.
# Guards alert_to() from ping-ponging (each enemy fires once per ALERT_REFRACTORY s).
var _last_alert_time: float = 0.0

# --- EMP stun (server-side only, NOT replicated) ----------------------------
# An EMP grenade calls apply_stun() on the SERVER; we freeze movement/AI until this
# ms deadline. NOT in the sync config — movement + position are already server-driven
# and replicate via the body transform, so a frozen authority replicates a frozen
# body automatically (clients need no extra state). 0 = not stunned.
var _stunned_until_ms: int = 0

# Track whether we were chasing last tick so we detect the edge PATROL→CHASE
# for cascading alerts.
var _was_chasing: bool = false

# --- Elite modifiers (rare wave-rolled prefixes, parsed from the node name) ---
# Full modifier names (e.g. ["armored", "volatile"]); empty for a normal enemy. Parsed on
# EVERY peer from str(name) at the top of _ready (the name replicates via the auto-spawn).
# Stats (armored/swift) are applied server-side onto _stat_*; volatile fires a death blast;
# regenerating heals over time; the PRIMARY mod tints the model + adds a feet glow ring.
# Exposed for the harness (AgentBridge reads e.get("modifiers")).
var modifiers: Array[String] = []
# Cached HP/s for the regenerating mod (0 = not regenerating); read each physics tick.
var _regen_rate: float = 0.0

# --- Machine Nemesis (signature) — parsed from the _NEM name token on EVERY peer, so a
# returning rival rebuilds the IDENTICAL scarred/buffed body everywhere. is_nemesis gates the
# tier health scalar, the learned-counter resists (emp_hard in apply_stun), and the scars.
var is_nemesis: bool = false
var nemesis_tier: int = 0
var nemesis_traits: Array[String] = []
var scar_seed: int = 0

# --- Machine Chemistry (Phase 5) — the per-enemy status component (code-instantiated,
# authority-local logic; brittle hooks Health.damage_filter, slow scales _apply_movement).
# _status_flags_visual is the last flag set received via sync_chemistry_flags (every peer)
# and drives the per-status FX nodes in _chem_fx (render-only).
var _status: EnemyStatus = null
var _status_flags_visual: int = 0
var _chem_fx: Dictionary = {}


func _ready() -> void:
	# Parse elite modifiers FIRST (every peer) — wave_manager name-encoded them before
	# add_child, so the name is already correct here and replicates to clients.
	_parse_modifiers_from_name()
	# Machine Nemesis: parse the _NEM token (every peer) right after the elite mods so the
	# rival's tier/traits/scars are known before stats + visuals are built.
	_parse_nemesis_from_name()
	add_to_group(Groups.ENEMIES)
	if is_nemesis:
		add_to_group(Groups.NEMESIS)  # map marker + kill-payoff lookup (server + clients)
	_home = global_position
	_load_stats()
	# Apply modifier stat multipliers onto the resolved _stat_* BEFORE the health refill
	# + collision/avoidance setup, so armored reaches max_health and swift reaches max_speed.
	_apply_modifier_stats()
	# Nemesis tier/trait stat counters layer on top of the elite mults (same pre-refill window).
	_apply_nemesis_stats()

	# Populate the visual model from the registry (CC0 art or primitive).
	var model := AssetRegistry.get_model(enemy_id)
	if model:
		_model_root.add_child(model)
		_setup_animation()
		_collect_flash_materials(model)
		# Procedural idle motion only when the model has NO AnimationPlayer (the .glb
		# grunt/heavy animate themselves). Subclasses override _cache_proc_parts.
		if _anim_player == null:
			_cache_proc_parts()
	# Rest transform for the flinch — capture BEFORE assemble (rest at 0.05 shrank enemies).
	if _model_root:
		_model_rest_pos = _model_root.position
		_model_rest_scale = _model_root.scale
	if model:
		LimbBurst.assemble(_model_root, self)  # M1: spawn-assembly (scale-up + ring)

	# Elite modifier visuals (tint + feet glow ring). Runs on every peer; tints the
	# already-duplicated _flash_mats so it never bleeds onto other instances. Headless-guarded.
	_apply_modifier_visuals()
	# Nemesis scars (deterministic in scar_seed → identical on every peer; render-only).
	_apply_nemesis_scars()

	# Health is configured via the scene export; ensure max matches stats even if
	# the scene drifts, then refill. Only the authority should own its state.
	_health.max_health = _stat_health
	_health.current = _health.max_health
	if not _health.died.is_connected(_on_died):
		_health.died.connect(_on_died)
	if not _health.health_changed.is_connected(_on_health_changed):
		_health.health_changed.connect(_on_health_changed)

	# Machine Chemistry (Phase 5): the status component (no scene edit — built here). The
	# brittle status amplifies incoming damage via Health.damage_filter, which enemies
	# otherwise leave unset; the burn tick exempts itself via _status.is_dot_tick().
	_status = EnemyStatus.new()
	add_child(_status)
	_status.setup(self)
	_health.damage_filter = _chemistry_damage_filter

	_setup_health_bar()
	_setup_collision_and_avoidance()

	_fsm = EnemyStateMachine.new()
	_fsm.setup(self)

	# M2 boss fight: the staged-encounter brain (added on EVERY peer — its FX rpcs
	# need the same node path everywhere; logic self-gates to the server inside).
	if enemy_id == "robot_boss":
		var brain := BossBrain.new()
		brain.name = "BossBrain"
		add_child(brain)

	_agent.path_desired_distance = 0.6
	_agent.target_desired_distance = maxf(1.0, _stat_attack_range * 0.6)

	# Connect to loud noise events (gunfire/grenades). Only the authority runs
	# AI, so we gate the connection to the server — enemies are server-spawned
	# so is_multiplayer_authority() is valid in _ready here.
	if is_multiplayer_authority():
		if not Events.noise_emitted.is_connected(_on_noise_emitted):
			Events.noise_emitted.connect(_on_noise_emitted)

	# Visual weak-point indicator (render-only; runs on all peers, skipped headless).
	_setup_weakpoint_marker()
	# Armored elites get a bigger/brighter weak-point marker (must run AFTER the marker exists).
	_boost_weakpoint_for_armored()

	Events.enemy_spawned.emit(self)


## Add a small glowing marker at this enemy's WeakPoint so players can SEE where the
## bonus-damage spot is (the Hurtbox itself is invisible). Render-only: a tiny emissive
## sphere parented under the WeakPoint Area (inherits its position); no gameplay/collision
## change. No-op if the enemy has no WeakPoint or we're on a headless server.
func _setup_weakpoint_marker() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var wp := get_node_or_null(Groups.NODE_WEAKPOINT)
	if wp == null:
		return
	var shape := wp.get_node_or_null("CollisionShape3D")
	var radius := 0.18
	if shape is CollisionShape3D and (shape as CollisionShape3D).shape is SphereShape3D:
		radius = ((shape as CollisionShape3D).shape as SphereShape3D).radius * 0.85
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 10
	mesh.rings = 6
	var mat := StandardMaterial3D.new()
	var accent := AssetRegistry.get_color(enemy_id).lerp(Color(1.0, 0.85, 0.2), 0.6)
	mat.albedo_color = accent
	mat.emission_enabled = true
	mat.emission = accent
	mat.emission_energy_multiplier = 2.2
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.85
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	if shape is CollisionShape3D:
		mi.position = (shape as CollisionShape3D).position  # sit exactly on the weak point
	wp.add_child(mi)


## Pull archetype stats from Settings.ENEMY_STATS. Falls back to legacy ENEMY_*
## (already the defaults above) so a missing/unknown id still behaves like a grunt.
func _load_stats() -> void:
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	if stats.is_empty():
		return
	_stat_health = stats.get("health", _stat_health)
	_stat_speed = stats.get("speed", _stat_speed)
	_stat_damage = stats.get("damage", _stat_damage)
	_stat_detect = stats.get("detect", _stat_detect)
	_stat_attack_range = stats.get("attack_range", _stat_attack_range)
	_stat_cooldown = stats.get("cooldown", _stat_cooldown)
	# Difficulty scaling: Easy softens enemies, Hard makes them tankier + hit harder.
	var mods: Dictionary = Settings.difficulty_mods()
	_stat_health *= float(mods.get("enemy_health", 1.0))
	_stat_damage *= float(mods.get("enemy_damage", 1.0))


## Make enemy bodies block each other AND the player (so move_and_slide resolves
## overlaps), and enable NavigationAgent avoidance so paths fan out instead of
## stacking. Layer stays 4 (enemy); mask gains 2 (player) + 4 (enemy) on top of
## 1 (world). Overridable by flyers that don't want body-on-body shoving.
func _setup_collision_and_avoidance() -> void:
	collision_mask = 1 | 2 | 4
	if _agent:
		_agent.avoidance_enabled = true
		_agent.radius = 0.55
		_agent.max_speed = _stat_speed
		_agent.neighbor_distance = 4.0
		# We don't use the velocity_computed signal (we blend a manual separation
		# steer in _apply_movement instead, which is cheaper and works for the
		# flyers too); avoidance_enabled still makes the agent fan paths apart.


func _physics_process(delta: float) -> void:
	# SERVER-AUTHORITATIVE: clients never run AI; they just display replicated state.
	if not is_multiplayer_authority():
		return
	if _dying or _health.is_dead:
		return

	# EMP stun: frozen in place (grounded keep gravity, flyers hover — _apply_movement
	# handles ZERO for both). Subclasses inheriting _physics_process get this for free;
	# those that OVERRIDE it must replicate this gate (see robot_worm etc.).
	if Time.get_ticks_msec() < _stunned_until_ms:
		_apply_movement(Vector3.ZERO, delta)
		return

	# Regenerating elites slowly heal back (server-side; heal() is drop-only so it never
	# triggers the hit-flash — see _on_health_changed's took_damage guard).
	if (
		_regen_rate > 0.0
		and _health != null
		and not _health.is_dead
		and _health.current < _health.max_health
	):
		_health.heal(_regen_rate * delta)

	if _attack_cooldown > 0.0:
		_attack_cooldown -= delta

	# Decay the cascading-alert refractory timer.
	if _last_alert_time > 0.0:
		_last_alert_time -= delta
		if _last_alert_time < 0.0:
			_last_alert_time = 0.0

	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = 0.4
		_target = _find_nearest_player()
		# Non-hunter footstep perception (piggyback on the 0.4s retarget cadence).
		if not hunter:
			_check_footstep_perception()

	var dist := INF
	var has_los := false
	if _target != null and is_instance_valid(_target):
		dist = global_position.distance_to(_target.global_position)
		has_los = _check_line_of_sight(_target)
	else:
		_target = null

	# A non-hunter NOTICES a player who comes CLOSE even without clean LOS / loud steps —
	# so a patrol you walk right up to engages instead of standing there. Long-range stealth
	# is unchanged (beyond this radius it still needs hearing/LOS). Smoke MUFFLES: a target
	# standing in a cloud must be twice as close before the proximity sense trips.
	var proximity_radius := Settings.PROXIMITY_AGGRO_RADIUS
	if _target != null and _in_smoke(_target.global_position):
		proximity_radius *= 0.5
	var near := _target != null and dist <= proximity_radius

	# Night (batch C): sight range shrinks after dark — DayNight reads the synced match
	# clock, so server/headless agree. Hearing + proximity senses deliberately unchanged.
	var detect: float = _stat_detect * DayNight.detect_mult(DayNight.current_hour())

	# Smoke temporarily suppresses a hunter's wallhack: if the line to the target is
	# smoked, the force-CHASE override is withheld THIS tick and we fall through to the
	# normal perception evaluate (it resumes once the cloud fades or LOS re-confirms).
	var hunter_smoked := false
	if hunter and _target != null:
		var eye := global_position + Vector3.UP * 1.2
		var tpos := _target.global_position + Vector3.UP * 1.0
		hunter_smoked = _segment_crosses_smoke(eye, tpos)

	# Hunters always know where the player is (forced LOS + unlimited detect), so they
	# leave their nest and close in; they still ATTACK only inside attack range. Without
	# any smoke `hunter_smoked` is always false, so wave enemies rush exactly as before.
	if hunter and _target != null and not hunter_smoked:
		current_state = _fsm.evaluate(_target, dist, true, 1.0e9, _stat_attack_range)
	elif current_state != State.INVESTIGATE:
		current_state = _fsm.evaluate(_target, dist, has_los or near, detect, _stat_attack_range)
	else:
		# While investigating, promote to CHASE/ATTACK the moment LOS is confirmed
		# within detect — or the player gets close. evaluate() has no INVESTIGATE case (it
		# would return INVESTIGATE unchanged), so seed the FSM into CHASE first, then let
		# evaluate resolve CHASE→ATTACK (or back to PATROL if the gap reopens).
		if (
			_target != null
			and (has_los or near)
			and dist <= detect
			and Time.get_ticks_msec() >= _leash_calm_ms
		):
			_fsm.state = State.CHASE
			current_state = _fsm.evaluate(
				_target, dist, has_los or near, detect, _stat_attack_range
			)

	# Cascading alert edge detection: the moment we enter CHASE, wake nearby non-hunters.
	if current_state == State.CHASE and not _was_chasing:
		_cascade_alert()
	_was_chasing = (current_state == State.CHASE)

	# M3 territoriality: a non-hunter defends its spawn spot — a chase dragging it past
	# the leash breaks off toward home (calm window stops boundary flip-flop). Hunters exempt.
	var engaged := current_state == State.CHASE or current_state == State.ATTACK
	if not hunter and engaged and global_position.distance_to(_home) > Settings.ENEMY_LEASH_RADIUS:
		_target = null
		_leash_calm_ms = Time.get_ticks_msec() + 4000
		_start_investigate(_home)

	match current_state:
		State.PATROL:
			_do_patrol(delta)
		State.CHASE:
			_do_chase(delta)
		State.ATTACK:
			_do_attack(delta)
		State.INVESTIGATE:
			_do_investigate(delta)

	_update_stuck(delta)


func _process(delta: float) -> void:
	# Animation is purely visual and runs on BOTH server and clients: clients read
	# `current_state` (replicated by the MultiplayerSynchronizer) and Health.is_dead.
	# This deliberately lives outside _physics_process so AI gating is untouched.
	_update_animation()
	var dead := _health != null and _health.is_dead
	if dead:
		# Death owns ModelRoot via the scale-pop; skip idle anim + the stagger (which
		# would otherwise reset ModelRoot back to rest each frame and cancel the pop).
		if not _death_fx_started:
			_death_fx_started = true
			_start_death_fx()
		_tick_death_pop(delta)
		_tick_flash(delta)  # let a final hit-flash finish; it only touches emission
		return
	# Audible "spotted!" cue: calm→CHASE edge on the REPLICATED state (every peer hears
	# it positionally). Age-gated so hunter waves that spawn straight into CHASE don't
	# chorus; per-enemy cooldown so flapping LOS doesn't spam.
	_sfx_age += delta
	if current_state != _sfx_state_prev:
		var from_calm := _sfx_state_prev == State.PATROL or _sfx_state_prev == State.INVESTIGATE
		if (
			current_state == State.CHASE
			and from_calm
			and _sfx_age > 1.5
			and Time.get_ticks_msec() - _sfx_alert_last_ms > 4000
		):
			_sfx_alert_last_ms = Time.get_ticks_msec()
			Events.enemy_chase_started.emit(self)
		_sfx_state_prev = current_state
	if _has_proc_anim:
		# PERF: idle bobbing/rotor spin is invisible past ~60m — gate it on camera
		# distance (2 Hz check, per peer, render-only). Combat feedback below
		# (_tick_flash/_tick_stagger) is deliberately NEVER gated.
		_idle_gate_accum += delta
		if _idle_gate_accum >= 0.5:
			_idle_gate_accum = 0.0
			var cam := get_viewport().get_camera_3d()
			_idle_anim_on = (
				cam != null
				and cam.global_position.distance_squared_to(global_position) < 60.0 * 60.0
			)
		if _idle_anim_on:
			_anim_time += delta
			_animate_visual(delta)
	_tick_flash(delta)
	_tick_stagger(delta)


# --- Animation (visual only) ------------------------------------------------


## Find the GLB's AnimationPlayer under ModelRoot and resolve the clip names we
## care about against whatever the asset actually ships (case-insensitive,
## tolerant of the primitive fallback which has no AnimationPlayer).
func _setup_animation() -> void:
	_anim_player = _find_animation_player(_model_root)
	if _anim_player == null:
		return
	var names := _anim_player.get_animation_list()
	_anim_idle = _pick_anim(names, ["Idle"])
	_anim_walk = _pick_anim(names, ["Walking", "Walk"])
	_anim_run = _pick_anim(names, ["Running", "Run"])
	_anim_attack = _pick_anim(names, ["Punch", "Attack"])
	_anim_death = _pick_anim(names, ["Death", "Die"])
	# Make locomotion clips loop (RobotExpressive ships them as one-shots).
	for loop_name in [_anim_idle, _anim_walk, _anim_run]:
		if loop_name != "" and _anim_player.has_animation(loop_name):
			var a := _anim_player.get_animation(loop_name)
			if a:
				a.loop_mode = Animation.LOOP_LINEAR


## Drives the AnimationPlayer from current_state / death. Cheap: only switches
## clips when the desired animation changes. No-op without an AnimationPlayer.
func _update_animation() -> void:
	if _anim_player == null:
		return
	if _health != null and _health.is_dead:
		if not _death_anim_played:
			_death_anim_played = true
			if _anim_death != "":
				_play_anim(_anim_death)
		return
	var desired := _anim_idle
	match current_state:
		State.PATROL:
			desired = _anim_idle
		State.CHASE:
			desired = _anim_run if _anim_run != "" else _anim_walk
		State.ATTACK:
			desired = _anim_attack if _anim_attack != "" else _anim_idle
		State.INVESTIGATE:
			desired = _anim_walk if _anim_walk != "" else _anim_idle
	if desired != "" and desired != _current_anim:
		_play_anim(desired)


func _play_anim(anim_name: String) -> void:
	if _anim_player == null or anim_name == "":
		return
	if not _anim_player.has_animation(anim_name):
		return
	_current_anim = anim_name
	_anim_player.play(anim_name)


## Depth-first search for the first AnimationPlayer under `root`.
func _find_animation_player(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	for child in root.get_children():
		if child is AnimationPlayer:
			return child as AnimationPlayer
		var found := _find_animation_player(child)
		if found:
			return found
	return null


## Returns the first candidate present in `names` (case-insensitive), else "".
func _pick_anim(names: PackedStringArray, candidates: Array) -> String:
	for cand in candidates:
		for n in names:
			if n == cand:
				return n
	# Case-insensitive second pass.
	for cand in candidates:
		var lc := String(cand).to_lower()
		for n in names:
			if String(n).to_lower() == lc:
				return n
	return ""


# --- Procedural idle animation (visual only) --------------------------------


## Locate + cache the named parts ProceduralModels gave this enemy's model so
## _animate_visual can drive them cheaply. BASE = tick (eye + 6 legs). OVERRIDE in
## the ranged/flyer subclasses (wasp/bastion/boss) for their own parts. Sets
## `_has_proc_anim` true only if something animatable was actually found.
func _cache_proc_parts() -> void:
	# The procedural assembly is the first (only) child of ModelRoot.
	var asm := _proc_root()
	if asm == null:
		return
	var eye := asm.find_child("Eye", true, false)
	if eye is MeshInstance3D:
		_proc_eye = eye as MeshInstance3D
		_pulse_part = _proc_eye
		_pulse_base_energy = _read_emission_energy(_proc_eye)
	for i in 6:
		var leg := asm.find_child("Leg%d" % i, true, false)
		if leg is Node3D:
			_proc_legs.append(leg as Node3D)
			_proc_leg_rest.append((leg as Node3D).rotation)
	_has_proc_anim = _proc_eye != null or not _proc_legs.is_empty()


## The procedural model assembly node under ModelRoot (the Node3D ProceduralModels
## built), or null if this enemy uses a .glb / single primitive without named parts.
func _proc_root() -> Node3D:
	if _model_root == null:
		return null
	for c in _model_root.get_children():
		if c is Node3D:
			return c as Node3D
	return null


## BASE idle = the tick: a slow whole-body bob (on the assembly child, NOT ModelRoot
## which is the stagger's home), out-of-phase leg micro-sway, and an eye emission
## pulse. OVERRIDE for other archetypes.
func _animate_visual(_delta: float) -> void:
	var asm := _proc_root()
	if asm:
		asm.position.y = sin(_anim_time * 2.0) * 0.025
	for i in _proc_legs.size():
		var leg := _proc_legs[i]
		if leg == null or not is_instance_valid(leg):
			continue
		var phase := float(i) * 1.05
		var sway := sin(_anim_time * 3.5 + phase) * 0.10
		leg.rotation = _proc_leg_rest[i] + Vector3(sway * 0.5, 0.0, sway)
	_pulse_emission(0.7, 1.3, 3.0)


## Pulse the cached `_pulse_part`'s emission energy between base*lo and base*hi at
## `speed`. Skips while the hit-flash owns the emission (flash energy wins; it
## restores energy to 1.0 on finish, then this resumes). emission_energy_multiplier
## only — never touches the emission COLOR (flash lerps that). Safe on all peers.
func _pulse_emission(lo: float, hi: float, speed: float) -> void:
	if _pulse_part == null or _flash_t > 0.0:
		return
	var mat := _pulse_part.get_active_material(0)
	if mat is StandardMaterial3D:
		var k := 0.5 + 0.5 * sin(_anim_time * speed)
		(mat as StandardMaterial3D).emission_energy_multiplier = (
			_pulse_base_energy * lerpf(lo, hi, k)
		)


## Read a glowing part's authored emission energy (so the pulse oscillates around it).
func _read_emission_energy(part: MeshInstance3D) -> float:
	if part == null:
		return 6.0
	var mat := part.get_active_material(0)
	if mat is StandardMaterial3D and (mat as StandardMaterial3D).emission_enabled:
		return (mat as StandardMaterial3D).emission_energy_multiplier
	return 6.0


## Yaw a child pivot node toward the nearest player on the Y axis only (turret/torso
## tracking). Smoothly lerps `pivot.rotation.y` in the enemy-LOCAL frame so it reads
## as the head aiming at you. Visual only — never the body. Used by bastion/boss.
func _track_player_yaw(pivot: Node3D, delta: float, speed: float = 4.0) -> void:
	if pivot == null or not is_instance_valid(pivot):
		return
	var p := _nearest_player_visual()
	if p == null:
		return
	var to := p.global_position - global_position
	to.y = 0.0
	if to.length() < 0.05:
		return
	# Desired yaw in world space, minus the body's yaw = the local yaw the pivot
	# needs (the model authored facing -Z, matching the body's forward).
	var world_yaw := atan2(to.x, to.z)
	var local_yaw := wrapf(world_yaw - rotation.y, -PI, PI)
	pivot.rotation.y = lerp_angle(pivot.rotation.y, local_yaw, clampf(delta * speed, 0.0, 1.0))


## Nearest living player for VISUAL tracking — runs on all peers (no authority gate),
## reads the "players" group directly. Cheap; called at most once per frame per enemy.
func _nearest_player_visual() -> Node3D:
	var nearest: Node3D = null
	var best := INF
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		var pn := p as Node3D
		# Don't visually track a downed player (matches the AI ignoring them for targeting).
		if pn.has_method("is_downed") and pn.is_downed():
			continue
		# CLOAKED player (recon-family skill): machines can't see it at all.
		if SkillDirector.is_player_cloaked(pn):
			continue
		var d := global_position.distance_to(pn.global_position)
		if d < best:
			best = d
			nearest = pn
	return nearest


# --- Hit flash --------------------------------------------------------------

## Walk the model subtree and remember every StandardMaterial3D (and its base
## emission) so a hit can briefly drive emission white. We duplicate shared
## materials so flashing one enemy doesn't flash every instance sharing the art.
## OVERRIDE TRAP: procedural parts assign their material via `material_override`,
## which OUTRANKS surface overrides at draw time — installing the dup as a surface
## override left the flash mutating a material that was never drawn (the flash and
## the elite tint were silently invisible on every procedural enemy). When the
## active material IS the override, the dup must replace the override itself.
## `_flash_dups` maps each SOURCE material to its one dup, so the ~30 parts sharing a
## builder's 5 role materials keep sharing 5 dups — duplicating per PART exploded the
## scene's unique-material count ~6× and cost real frame time at 15+ enemies.
var _flash_dups: Dictionary = {}


func _collect_flash_materials(root: Node) -> void:
	if root is MeshInstance3D:
		var mi := root as MeshInstance3D
		var mesh := mi.mesh
		if mesh:
			for s in mesh.get_surface_count():
				var mat := mi.get_active_material(s)
				if mat is StandardMaterial3D:
					var dup: StandardMaterial3D
					if _flash_dups.has(mat):
						dup = _flash_dups[mat]
					else:
						dup = (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
						_flash_dups[mat] = dup
						_flash_mats.append(dup)
						_flash_base_emission.append(
							dup.emission if dup.emission_enabled else Color(0, 0, 0)
						)
					if mi.material_override == mat:
						mi.material_override = dup
					else:
						mi.set_surface_override_material(s, dup)
	for c in root.get_children():
		_collect_flash_materials(c)


func _start_flash() -> void:
	if _flash_mats.is_empty():
		return
	_flash_t = FLASH_TIME
	for m in _flash_mats:
		m.emission_enabled = true


## Decay the flash emission back to the base over FLASH_TIME. Cheap no-op when idle.
func _tick_flash(delta: float) -> void:
	if _flash_t <= 0.0:
		return
	_flash_t = maxf(0.0, _flash_t - delta)
	var k := _flash_t / FLASH_TIME  # 1 -> 0
	for i in _flash_mats.size():
		var base: Color = _flash_base_emission[i]
		var m := _flash_mats[i]
		m.emission = base.lerp(Color(1, 1, 1), k)
		m.emission_energy_multiplier = lerpf(1.0, 4.0, k)  # stronger spike
		if _flash_t <= 0.0:
			# Restore the original emission state exactly.
			m.emission = base
			m.emission_enabled = base.r > 0.0 or base.g > 0.0 or base.b > 0.0


func _on_health_changed(current: float, _max_health: float) -> void:
	# A drop in health = a hit; flash + stagger. (heal also fires this but is rare
	# for enemies.) Only react to actual damage (health went DOWN).
	var took_damage := _last_hit_health < 0.0 or current < _last_hit_health
	_last_hit_health = current
	if not _dying and not _health.is_dead and current > 0.0 and took_damage:
		_start_flash()
		_start_stagger()


## Kick the visual flinch (runs everywhere) and, on the authority, a tiny
## knockback away from the likely shooter (nearest player) so the body reacts.
func _start_stagger() -> void:
	_stagger_t = STAGGER_TIME
	# M1 feel: a quick scale-PUNCH so every single bullet visibly rocks the body
	# (the rotation flinch alone read as nothing at range).
	if _model_root != null and not _dying:
		_model_root.scale = Vector3.ONE * 1.07
		var tw := _model_root.create_tween()
		tw.tween_property(_model_root, "scale", Vector3.ONE, 0.12)
	if is_multiplayer_authority() and not _dying:
		var shooter := _find_nearest_player()
		if shooter and is_instance_valid(shooter):
			var away := global_position - shooter.global_position
			away.y = 0.0
			if away.length() > 0.001:
				_knockback = away.normalized() * KNOCKBACK_SPEED


## Decays the model-local flinch (a quick recoil dip + squash) back to rest, and
## bleeds off the knockback nudge. Visual flinch runs on server AND clients; the
## knockback velocity is consumed by the authority's _apply_movement.
func _tick_stagger(delta: float) -> void:
	if _stagger_t <= 0.0:
		if _model_root and _model_root.scale != _model_rest_scale:
			_model_root.scale = _model_rest_scale
			_model_root.position = _model_rest_pos
		return
	_stagger_t = maxf(0.0, _stagger_t - delta)
	var k := _stagger_t / STAGGER_TIME  # 1 -> 0
	if _model_root:
		# Quick squash + a small downward dip that eases back to rest.
		var squash := 1.0 - 0.12 * k
		_model_root.scale = _model_rest_scale * Vector3(1.0 + 0.08 * k, squash, 1.0 + 0.08 * k)
		_model_root.position = _model_rest_pos + Vector3(0.0, -0.06 * k, 0.0)


# --- HP bar -----------------------------------------------------------------


func _setup_health_bar() -> void:
	if not ResourceLoader.exists(HP_BAR_SCENE):
		return
	var packed := load(HP_BAR_SCENE)
	if not (packed is PackedScene):
		return
	_hp_bar = (packed as PackedScene).instantiate() as EnemyHealthBar
	if _hp_bar == null:
		return
	# Sit the bar above the model; scale roughly with the body height.
	_hp_bar.bar_y = _health_bar_height()
	add_child(_hp_bar)
	_hp_bar.setup(_health)
	_hp_bar.set_modifier_label(modifiers)  # M3: elite tag over the bar


## Default bar height; flyers/bosses override to clear taller models. OVERRIDE.
func _health_bar_height() -> float:
	return 2.0


# --- State behaviours -------------------------------------------------------


func _do_patrol(delta: float) -> void:
	# Idle a moment at each reached waypoint, then wander to a new one.
	if _fsm.tick_patrol_wait(delta):
		_apply_movement(Vector3.ZERO, delta)
		return
	if not _fsm.has_patrol_target():
		var p := _fsm.choose_patrol_point(_home, patrol_radius)
		_agent.set_target_position(p)
	if _agent.is_navigation_finished():
		_fsm.clear_patrol_target()
		_fsm.start_patrol_wait(randf_range(1.0, 2.5))
		_apply_movement(Vector3.ZERO, delta)
		return
	_navigate_to_agent(delta)


func _do_chase(delta: float) -> void:
	_fsm.clear_patrol_target()
	if _target == null:
		_apply_movement(Vector3.ZERO, delta)
		return
	# PERF: setting target_position to the LIVE player position every physics tick
	# forced a full navmesh A* replan per enemy per frame (~1ms each — 15 chasers ate
	# the whole frame; NavigationAgent3D's setter repaths unconditionally, it does NOT
	# compare values). Replan only when the target drifted >1.5m from the last goal;
	# the agent keeps following its computed path in between (visually identical).
	var goal: Vector3 = _target.global_position
	if goal.distance_squared_to(_last_nav_goal) > 2.25:
		_last_nav_goal = goal
		_agent.set_target_position(goal)
	_navigate_to_agent(delta)


func _do_attack(delta: float) -> void:
	# Hold position and strike on cooldown. Face the target for clarity.
	_apply_movement(Vector3.ZERO, delta)
	if _target and is_instance_valid(_target):
		_face_towards(_target.global_position, delta)
	if _attack_cooldown <= 0.0:
		_strike(_target)
		_attack_cooldown = _next_cooldown()


## Investigate the last-heard/seen point. Navigate there at reduced speed; look
## around on arrival; give up after INVESTIGATE_GIVEUP seconds with no confirmed LOS.
func _do_investigate(delta: float) -> void:
	_investigate_timer -= delta
	if _investigate_timer <= 0.0:
		# Give-up: return to patrol.
		current_state = State.PATROL
		_fsm.state = State.PATROL
		_investigate_arrived = false
		return

	var dist_to_point := global_position.distance_to(_investigate_point)
	if dist_to_point <= Settings.INVESTIGATE_ARRIVE:
		# Arrived — rotate slowly in place to "look around".
		_investigate_arrived = true
		rotation.y += delta * 1.2
		_apply_movement(Vector3.ZERO, delta)
	else:
		_investigate_arrived = false
		# Navigate at INVESTIGATE_SPEED_MULT of normal speed. PERF: the point is
		# static — re-issue the path only when it actually changed (the agent setter
		# repaths unconditionally on every call).
		if _investigate_point.distance_squared_to(_last_nav_goal) > 0.01:
			_last_nav_goal = _investigate_point
			_agent.set_target_position(_investigate_point)
		# Temporarily scale speed, navigate, then restore.
		var base_speed := _stat_speed
		_stat_speed = base_speed * Settings.INVESTIGATE_SPEED_MULT
		_navigate_to_agent(delta)
		_stat_speed = base_speed


## Begin investigating a world position. Resets the give-up timer.
## Called internally by perception and externally by alert_to().
func _start_investigate(world_pos: Vector3) -> void:
	_investigate_point = world_pos
	_investigate_timer = Settings.INVESTIGATE_GIVEUP
	_investigate_arrived = false
	current_state = State.INVESTIGATE
	_fsm.state = State.INVESTIGATE
	_fsm.clear_patrol_target()


## EMP stun entry point — the EMP grenade calls this duck-typed, SERVER-side only.
## Freezes movement + AI for `duration` seconds (a boss shrugs most of it off via
## EMP_BOSS_STUN_MULT). Server-gated because movement/AI are server-driven and the
## frozen body replicates to clients on its own (no extra synced state). The grenade
## emits Events.enemy_stunned itself; we just hold position until the deadline.
func apply_stun(duration: float) -> void:
	if not GameState.is_local_authority_server():
		return
	# Explicit typed local — an inferred `:=` on this ternary trips the Variant parse trap.
	var d: float = duration * (Settings.EMP_BOSS_STUN_MULT if _is_boss() else 1.0)
	# Nemesis "emp_hard" learned counter: a rival you kept EMP-locking shrugs most of it off.
	if "emp_hard" in nemesis_traits:
		d *= Settings.NEMESIS_EMP_STUN_MULT
	# maxi so a short chemistry SHOCK can never cut a long EMP stun short (and vice-versa).
	_stunned_until_ms = maxi(_stunned_until_ms, Time.get_ticks_msec() + int(d * 1000.0))


## Machine Chemistry (Phase 5) — the raw duck-typed status setter, called by
## MachineChemistry.apply() (which has already resolved climate + fires reactions) and by
## the chain/freeze reactions. Server-side only; the result replicates via HP/position and
## the visual flag-sync RPC. Identity-safe to call on any enemy.
func apply_chemistry(kind: String, dur: float, mag: float) -> void:
	if not GameState.is_local_authority_server() or _status == null:
		return
	_status.apply(kind, dur, mag)


## Active status for the harness (state.enemies[].status). On the authority: remaining
## seconds per kind. On a CLIENT (the status logic is server-only): the synced visual flags
## as active-kind bools — so co-op parity is verifiable even though clients don't simulate it.
func chemistry_status() -> Dictionary:
	if _status != null and is_multiplayer_authority():
		return _status.status_dict()
	var out: Dictionary = {}
	for kind in ["shock", "burn", "slow", "brittle"]:
		if (_status_flags_visual & MachineChemistry.bit_for(kind)) != 0:
			out[kind] = true
	return out


## Broadcast the active-status flag set to every peer (call_local runs it here too) so each
## builds the identical per-status FX. The authority is the only writer; clients are visual.
@rpc("authority", "call_local", "reliable")
func sync_chemistry_flags(flags: int) -> void:
	var changed: int = flags ^ _status_flags_visual
	_status_flags_visual = flags
	if DisplayServer.get_name() == "headless":
		return
	for kind in ["shock", "burn", "slow", "brittle"]:
		var bit: int = MachineChemistry.bit_for(kind)
		if (changed & bit) != 0:
			apply_chemistry_fx(kind, (flags & bit) != 0)


## Add (active) / free (inactive) the per-status FX aura. Distance-gated on spawn (cheap
## like the idle-anim gate); render-only, every peer. Frees all on death via the flags=0 sync.
func apply_chemistry_fx(kind: String, active: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not active:
		var old: Node = _chem_fx.get(kind)
		if old != null and is_instance_valid(old):
			old.queue_free()
		_chem_fx.erase(kind)
		return
	if _chem_fx.has(kind):
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var dd: float = cam.global_position.distance_squared_to(global_position)
	if dd > Settings.CHEM_FX_DIST * Settings.CHEM_FX_DIST:
		return
	var fx := MachineChemistry.make_fx(kind)
	if fx != null:
		add_child(fx)
		_chem_fx[kind] = fx


## Health.damage_filter hook for BRITTLE: amplify incoming damage while brittle is active.
## Exempts our own burn DoT (is_dot_tick) so burn never compounds. The amplified value flows
## on through Events.damage_dealt (correct — the grudge telemetry should see real damage).
func _chemistry_damage_filter(amount: float, _source: Node) -> float:
	if _status == null or _status.is_dot_tick():
		return amount
	var amplified: float = amount * _status.incoming_damage_mult()
	# SHATTER flavor: a brittle machine this hit will kill (server-side notify on the host).
	if _status.has("brittle") and amplified > amount and _health.current - amplified <= 0.0:
		Events.notify.emit(tr("SHATTER!"), 1)
	return amplified


## Public cascading-alert entry point. Another enemy (or the caller) tells this
## enemy to INVESTIGATE a position. Respects the refractory window and skips
## hunters / dead / already-chasing enemies. Called on the server only.
func alert_to(world_pos: Vector3) -> void:
	if hunter:
		return
	if _dying or (_health != null and _health.is_dead):
		return
	if current_state == State.CHASE or current_state == State.ATTACK:
		return
	if _last_alert_time > 0.0:
		return
	_last_alert_time = Settings.ALERT_REFRACTORY
	_start_investigate(world_pos)


## Footstep perception: called every ~0.4s for non-hunter enemies.
## Checks all players and reacts to noise_radius() audible footsteps.
func _check_footstep_perception() -> void:
	var loudest_dist := INF
	var loudest_player: Node3D = null
	var loudest_radius: float = 0.0

	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		# Skip dead players.
		var ph := (p as Node3D).get_node_or_null(Groups.NODE_HEALTH)
		if ph and ph is Health and (ph as Health).is_dead:
			continue
		# Guard: only call noise_radius if the method exists.
		if not p.has_method("noise_radius"):
			continue
		var heard_radius: float = float(p.call("noise_radius"))
		# Smoke MUFFLES footsteps: a target inside a cloud is half as audible.
		if _in_smoke((p as Node3D).global_position):
			heard_radius *= 0.5
		if heard_radius <= 0.0:
			continue
		var d := global_position.distance_to((p as Node3D).global_position)
		if d <= heard_radius and d < loudest_dist:
			loudest_dist = d
			loudest_player = p as Node3D
			loudest_radius = heard_radius

	if loudest_player == null:
		return
	# Already chasing this target? Skip (don't downgrade a confirmed chase).
	if (
		(current_state == State.CHASE or current_state == State.ATTACK)
		and _target == loudest_player
	):
		return

	if loudest_dist <= loudest_radius * Settings.NOISE_CHASE_FRACTION:
		# Very close/loud — go straight to CHASE.
		_target = loudest_player
		current_state = State.CHASE
		_fsm.state = State.CHASE
		_fsm.clear_patrol_target()
	else:
		# Heard but not immediate — investigate the player's position.
		_start_investigate(loudest_player.global_position)


## Cascade: on entering CHASE, alert nearby non-hunter enemies to investigate
## the current target position.
func _cascade_alert() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var target_pos := _target.global_position
	for e in get_tree().get_nodes_in_group(Groups.ENEMIES):
		if e == self or e == null or not is_instance_valid(e):
			continue
		if not e.has_method("alert_to"):
			continue
		if not (e is Node3D):
			continue
		if (
			global_position.distance_to((e as Node3D).global_position)
			<= Settings.ALERT_CASCADE_RADIUS
		):
			e.call("alert_to", target_pos)


## Noise event handler (gunfire / grenades from Events.noise_emitted).
## Only runs on the authority (connected in _ready only when authority).
## PERF: EVERY enemy receives EVERY noise event (4 players sustained-firing = ~40
## events/s × N enemies) — cheap squared-distance cull first, plus a short per-enemy
## cooldown once a noise was actually HANDLED so a barrage costs ≤3 reactions/s each.
func _on_noise_emitted(world_pos: Vector3, loudness: float, kind: int) -> void:
	if hunter:
		return
	var now := Time.get_ticks_msec()
	if now < _noise_ignore_until_ms:
		return
	if _dying or (_health != null and _health.is_dead):
		return
	var dsq := global_position.distance_squared_to(world_pos)
	if dsq > loudness * loudness:
		return
	_noise_ignore_until_ms = now + 300
	var d := sqrt(dsq)
	# Already chasing something nearby? Don't downgrade.
	if current_state == State.CHASE or current_state == State.ATTACK:
		return
	# A DECOY chirp (kind 3) lures to the SOUND, never to the player — the loud-close
	# rule below would otherwise redirect a nearby robot at the nearest player, which
	# defeats the point of throwing a decoy.
	if kind == 3:
		_start_investigate(world_pos)
		return
	if d <= loudness * Settings.NOISE_CHASE_FRACTION:
		# Very loud up close — go to CHASE toward the noise origin and pick nearest player.
		if _target != null and is_instance_valid(_target):
			current_state = State.CHASE
			_fsm.state = State.CHASE
			_fsm.clear_patrol_target()
		else:
			# No current target — investigate the noise source.
			_start_investigate(world_pos)
	else:
		_start_investigate(world_pos)


## Gap until the next attack. Default = the archetype's stat cooldown; ranged
## archetypes override to insert a longer recovery between bursts. OVERRIDE.
func _next_cooldown() -> float:
	return _stat_cooldown


# --- Stuck detection / recovery ---------------------------------------------


## Tracks progress TOWARD the target while CHASING. Only melee chasers must close the
## gap — ranged archetypes (wasp/bastion/boss) deliberately hold their distance, so
## they're excluded (a maintained stand-off is not "stuck"). An enemy that jitters in
## place without reducing its distance to the target (e.g. a heavy jammed in a POI) is
## caught here and recovered; patrol idling is excluded so a waypoint pause never trips it.
func _update_stuck(delta: float) -> void:
	if (
		(current_state != State.CHASE and current_state != State.INVESTIGATE)
		or current_state == State.INVESTIGATE
		or _stat_attack_range >= 5.0
		or _target == null
		or not is_instance_valid(_target)
	):
		_stuck_time = 0.0
		_stuck_dist = INF
		_recover_count = 0
		return
	var d := global_position.distance_to(_target.global_position)
	if d < _stuck_dist - STUCK_PROGRESS:
		_stuck_dist = d
		_stuck_time = 0.0
		_recover_count = 0
		return
	# A cryo-SLOWED machine makes slow progress legitimately — don't count it as stuck
	# (else the recovery re-seat would fire falsely and teleport it).
	if _status != null and _status.speed_mult() < 0.99:
		return
	_stuck_time += delta
	if _stuck_time >= STUCK_LIMIT:
		_recover_unstuck()
		_stuck_time = 0.0
		_stuck_dist = global_position.distance_to(_target.global_position)


## Escalating recovery: first attempt re-seats the body on the nearest navmesh point
## in place and re-issues the path (fixes spawned-in-wall / off-mesh). If that doesn't
## free it, relocate onto open navmesh near the target so it becomes reachable AND
## killable — never auto-killed, so the wave keeps its challenge.
func _recover_unstuck() -> void:
	_recover_count += 1
	if _recover_count <= 1 and _target and is_instance_valid(_target):
		global_position = _snap_to_navmesh(global_position)
		velocity = Vector3.ZERO
		_agent.set_target_position(_target.global_position)
		return
	var anchor := _target.global_position if (_target and is_instance_valid(_target)) else _home
	_teleport_to(_navmesh_point_near(anchor))
	_recover_count = 0


## Public hook for the wave watchdog: relocate next to the nearest player on the mesh.
func force_unstuck() -> void:
	var p := _find_nearest_player()
	var anchor := p.global_position if p else _home
	_teleport_to(_navmesh_point_near(anchor))
	_recover_count = 0
	_stuck_time = 0.0


## Nearest walkable navmesh point to `pos`, via the agent's navigation map. Returns
## `pos` unchanged if the map isn't ready (returns origin) — callers tolerate that.
func _snap_to_navmesh(pos: Vector3) -> Vector3:
	var map := _agent.get_navigation_map()
	if not map.is_valid():
		return pos
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return pos  # map not synced yet — leave position unchanged
	var p: Vector3 = NavigationServer3D.map_get_closest_point(map, pos)
	if p == Vector3.ZERO and pos.length() > 1.0:
		return pos
	return p


## A navmesh point on open ground a short way from `center` (a player) — the
## relocation target for a trapped enemy.
func _navmesh_point_near(center: Vector3) -> Vector3:
	var ang := randf() * TAU
	var rad := randf_range(8.0, 13.0)
	var probe := center + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	return _snap_to_navmesh(probe)


func _teleport_to(pos: Vector3) -> void:
	if pos == Vector3.ZERO:
		return
	global_position = pos
	velocity = Vector3.ZERO
	if _target and is_instance_valid(_target):
		_agent.set_target_position(_target.global_position)


# --- Movement helpers -------------------------------------------------------


func _navigate_to_agent(delta: float) -> void:
	var next := _agent.get_next_path_position()
	var to_next := next - global_position
	to_next.y = 0.0
	var dir := to_next.normalized() if to_next.length() > 0.001 else Vector3.ZERO
	_apply_movement(dir, delta)
	if dir != Vector3.ZERO:
		_face_towards(next, delta)


func _apply_movement(dir: Vector3, delta: float) -> void:
	# Blend in a separation steer so enemies don't pile into one point. The body
	# collision (mask now includes the enemy layer) resolves hard overlaps; this
	# soft push keeps them spread BEFORE they touch, which reads much better.
	# CRITICAL: separation must only NUDGE — never overpower the unit-length pursuit
	# `dir`, or a dense crowd repels itself into a ring WIDER than attack range and the
	# enemies can never reach melee (looks like "they run in place and won't attack").
	# So we clamp the separation magnitude well below 1.0 AND fade it out as the enemy
	# closes on its target, letting the swarm commit to a dogpile within attack range.
	# M3 combat dance: shooters strafe-orbit in ATTACK, anyone jukes when aimed
	# at (helper keeps its state in node meta; boss excluded — BossBrain leads).
	if enemy_id != "robot_boss":
		dir = EnemyDance.adjust(self, _target, dir, _stat_attack_range, int(current_state))
	var sep := _separation_steer()
	if sep.length() > SEPARATION_MAX:
		sep = sep.normalized() * SEPARATION_MAX
	if _target != null and is_instance_valid(_target):
		var td := (
			Vector2(
				global_position.x - _target.global_position.x,
				global_position.z - _target.global_position.z
			)
			. length()
		)
		# Fade separation from full (at >2× attack range) to zero (at attack range) so the
		# final approach is pure pursuit and crowded enemies still reach the player.
		var fade := clampf((td - _stat_attack_range) / maxf(0.1, _stat_attack_range), 0.0, 1.0)
		sep *= fade
	var move := dir + sep
	if move.length() > 1.0:
		move = move.normalized()
	# Machine Chemistry: a cryo SLOW scales movement (authority-local; the slowed body
	# replicates via position, so clients see it without extra state).
	var speed: float = _stat_speed * (_status.speed_mult() if _status != null else 1.0)
	velocity.x = move.x * speed + _knockback.x
	velocity.z = move.z * speed + _knockback.z
	# Bleed off the hit knockback nudge.
	if _knockback.length() > 0.01:
		_knockback = _knockback.move_toward(Vector3.ZERO, KNOCKBACK_DECAY * delta)
	else:
		_knockback = Vector3.ZERO
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0
	move_and_slide()


## Sum of away-vectors from nearby enemies (group "enemies") within
## SEPARATION_RADIUS, weighted by closeness. Flat on the XZ plane. Returns a small
## steering vector added to the desired direction. OVERRIDE for flyers (3D).
func _separation_steer() -> Vector3:
	var push := Vector3.ZERO
	var count := 0
	for other in get_tree().get_nodes_in_group(Groups.ENEMIES):
		if other == self or not is_instance_valid(other) or not (other is Node3D):
			continue
		var on := other as Node3D
		var away := global_position - on.global_position
		away.y = 0.0
		var d := away.length()
		if d > 0.001 and d < SEPARATION_RADIUS:
			# Closer = stronger (inverse falloff), normalized direction.
			push += (away / d) * (1.0 - d / SEPARATION_RADIUS)
			count += 1
	if count == 0:
		return Vector3.ZERO
	return push * SEPARATION_STRENGTH


func _face_towards(world_point: Vector3, delta: float) -> void:
	var flat := world_point - global_position
	flat.y = 0.0
	if flat.length() < 0.01:
		return
	var desired_yaw := atan2(flat.x, flat.z)
	rotation.y = lerp_angle(rotation.y, desired_yaw, clampf(delta * 8.0, 0.0, 1.0))


# --- Combat -----------------------------------------------------------------


## Default melee strike. OVERRIDE in ranged archetypes (wasp/bastion/boss) to
## fire a projectile/hitscan instead.
func _strike(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	# Prefer the target's Hurtbox.apply_hit (handles authority forwarding); fall
	# back to a direct Health.take_damage if it has no hurtbox.
	var hb := target.get_node_or_null(Groups.NODE_HURTBOX)
	if hb and hb.has_method("apply_hit"):
		hb.apply_hit(_stat_damage, self)
		return
	var hp := target.get_node_or_null(Groups.NODE_HEALTH)
	if hp and hp.has_method("take_damage"):
		hp.take_damage(_stat_damage, self)


# --- Perception -------------------------------------------------------------


func _find_nearest_player() -> Node3D:
	var nearest: Node3D = null
	var best := INF
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		var pn := p as Node3D
		# Skip dead players if they expose a Health child.
		var ph := pn.get_node_or_null(Groups.NODE_HEALTH)
		if ph and ph is Health and (ph as Health).is_dead:
			continue
		# Skip DOWNED players — AI fully ignores a downed player (it's threatened only by
		# the bleedout timer), so the revive window isn't a near-instant death in combat.
		if pn.has_method("is_downed") and pn.is_downed():
			continue
		# Skip CLOAKED players (recon-family active camo) — invisible to machines.
		if SkillDirector.is_player_cloaked(pn):
			continue
		var d := global_position.distance_to(pn.global_position)
		if d < best:
			best = d
			nearest = pn
	return nearest


func _check_line_of_sight(target: Node3D) -> bool:
	if _los_ray == null:
		return true
	# Aim the ray from our "eyes" at the target's centre and test for blockers.
	var from := global_position + Vector3.UP * 1.2
	var to := target.global_position + Vector3.UP * 1.0
	# Smoke is a SOFT counter to perception: a deployed cloud makes an otherwise-clear
	# geometric ray report blocked, so a smoked target can break line of sight.
	if _segment_crosses_smoke(from, to):
		return false
	_los_ray.global_position = from
	_los_ray.target_position = _los_ray.to_local(to)
	_los_ray.force_raycast_update()
	if not _los_ray.is_colliding():
		return true
	var collider := _los_ray.get_collider()
	# Clear LOS if the first thing we hit is the target (or part of it).
	var n: Node = collider
	while n != null:
		if n == target:
			return true
		n = n.get_parent()
	return false


# --- Smoke (soft perception counter) ----------------------------------------


## Segment-vs-sphere test against every active smoke cloud. A cloud is a Node3D in the
## SMOKE group exposing `radius`; we test the eye→target segment against each sphere
## (global_position, radius). Cheap — only ≤2-3 clouds are ever alive at once. Returns
## false instantly when no smoke exists, so vision is byte-identical without clouds.
func _segment_crosses_smoke(from: Vector3, to: Vector3) -> bool:
	var clouds := get_tree().get_nodes_in_group(Groups.SMOKE)
	if clouds.is_empty():
		return false
	var seg := to - from
	var seg_len_sq := seg.length_squared()
	for cloud in clouds:
		if cloud == null or not is_instance_valid(cloud) or not (cloud is Node3D):
			continue
		var radius: float = float(cloud.get("radius"))
		if radius <= 0.0:
			continue
		var center := (cloud as Node3D).global_position
		# Closest point on the segment to the cloud centre, then compare to the radius.
		var t := 0.0
		if seg_len_sq > 0.0001:
			t = clampf((center - from).dot(seg) / seg_len_sq, 0.0, 1.0)
		var closest := from + seg * t
		if closest.distance_squared_to(center) <= radius * radius:
			return true
	return false


## True when `pos` sits inside ANY active smoke cloud — used to MUFFLE hearing/proximity
## (a target standing in smoke is half as detectable). Cheap; false without clouds.
func _in_smoke(pos: Vector3) -> bool:
	var clouds := get_tree().get_nodes_in_group(Groups.SMOKE)
	if clouds.is_empty():
		return false
	for cloud in clouds:
		if cloud == null or not is_instance_valid(cloud) or not (cloud is Node3D):
			continue
		var radius: float = float(cloud.get("radius"))
		if radius <= 0.0:
			continue
		if pos.distance_squared_to((cloud as Node3D).global_position) <= radius * radius:
			return true
	return false


# --- Death / loot -----------------------------------------------------------


## DEATH POLISH: don't free immediately. Disable AI + collision, play the Death
## clip + let the SFX/debris play, drop loot, THEN free after DEATH_LINGER.
## Events.entity_died already fired from Health._die at the moment of death, so
## wave-clear detection stays correct even though the corpse lingers.
func _on_died(_killer: Node) -> void:
	if _dying:
		return
	_dying = true
	# Volatile elites detonate an AoE on death (server-authoritative — apply_hit routes to
	# the server anyway, but gate it so only the authority rolls the blast once).
	if "volatile" in modifiers and GameState.is_local_authority_server():
		_detonate_volatile()
	# Stop moving + colliding so the corpse doesn't shove the player or block nav.
	velocity = Vector3.ZERO
	set_physics_process(false)
	collision_layer = 0
	collision_mask = 0
	var hb := get_node_or_null(Groups.NODE_HURTBOX)
	if hb and hb is CollisionObject3D:
		(hb as CollisionObject3D).set_deferred("monitorable", false)
	if _agent:
		_agent.avoidance_enabled = false
	if _hp_bar:
		_hp_bar.visible = false

	_spawn_loot.call_deferred()
	_spawn_debris.call_deferred()
	# Linger so the death anim + explosion SFX read, then free.
	get_tree().create_timer(DEATH_LINGER).timeout.connect(queue_free)


## Optional ragdoll/debris from fx-dev. Guarded so we never hard-depend on it.
## Scaled + tinted to the enemy so a boss erupts in big purple chunks, a tick pops
## small orange ones. setup() must be called BEFORE add_child (the scene reads it in _ready).
func _spawn_debris() -> void:
	if not ResourceLoader.exists(DEBRIS_SCENE):
		return
	var packed := load(DEBRIS_SCENE)
	if not (packed is PackedScene):
		return
	var debris: Node = (packed as PackedScene).instantiate()
	if debris.has_method("setup"):
		debris.call("setup", _debris_scale(), _body_tint())
	var container := _loot_container()  # reuse the sibling FX-safe container
	container.add_child(debris)
	if debris is Node3D:
		(debris as Node3D).global_position = global_position + Vector3.UP * 0.8


## Debris size, scaled off the HP-bar height (a decent proxy for body size):
## tick≈2 → ~1.0, bastion → ~1.3, boss(4.6) → ~2.0.
func _debris_scale() -> float:
	return clampf(_health_bar_height() * 0.45, 0.7, 2.0)


## The enemy's signature colour (orange tick / cyan wasp / red bastion / purple boss),
## desaturated toward metal so debris reads as charred-tinted chunks not pure neon.
func _body_tint() -> Color:
	var c := AssetRegistry.get_color(enemy_id)
	return c.lerp(Color(0.5, 0.5, 0.52), 0.55)


## DEATH JUICE (all peers): a bright enemy spark/oil burst at the body core + a
## scale-pop kick. The pop itself decays in _tick_death_pop. Boss adds screen shake.
func _start_death_fx() -> void:
	_death_pop_t = 0.0
	# Kill any in-flight stagger so it stops fighting the death pop for ModelRoot.
	_stagger_t = 0.0
	_spawn_death_burst()
	# The machine breaks into its family LIMBS (the same model the loot uses).
	LimbBurst.burst(enemy_id, global_position, _loot_container(), _debris_scale())
	if _is_boss():
		Events.screen_shake.emit(0.6)


## Boss subclasses flag this so the death burst shakes the screen + scales bigger.
func _is_boss() -> bool:
	return false


## Instance a bright enemy-hit Impact at the body core for the death flash/sparks.
func _spawn_death_burst() -> void:
	if not ResourceLoader.exists(IMPACT_SCENE):
		return
	var packed := load(IMPACT_SCENE)
	if not (packed is PackedScene):
		return
	var burst: Node = (packed as PackedScene).instantiate()
	if burst.has_method("set_enemy_hit"):
		burst.call("set_enemy_hit", true)
	# Park it in the FX-safe sibling container (survives our queue_free).
	var container := _loot_container()
	container.add_child(burst)
	if burst is Node3D:
		(burst as Node3D).global_position = (
			global_position + Vector3.UP * maxf(0.6, _health_bar_height() * 0.4)
		)


## Animate the ModelRoot scale-pop on death: a quick swell then a collapse to ~0,
## so the corpse "bursts" instead of statically lingering. ModelRoot is the stagger's
## home, but the stagger is finished by death; this fully owns ModelRoot now.
func _tick_death_pop(delta: float) -> void:
	if _model_root == null:
		return
	_death_pop_t = minf(DEATH_POP_TIME, _death_pop_t + delta)
	var k := _death_pop_t / DEATH_POP_TIME  # 0 -> 1
	# Swell to 1.25 in the first third, then collapse to ~0.05 by the end.
	var s: float
	if k < 0.33:
		s = lerpf(1.0, 1.25, k / 0.33)
	else:
		s = lerpf(1.25, 0.05, (k - 0.33) / 0.67)
	_model_root.scale = _model_rest_scale * s


func _spawn_loot() -> void:
	if not ResourceLoader.exists(LOOT_SCENE):
		print(
			(
				"[RobotEnemy] %s died at %s — LootPickup.tscn not present, no drop"
				% [enemy_id, global_position]
			)
		)
		return
	var loot_id: String = LOOT_IDS[randi() % LOOT_IDS.size()]
	var container := _loot_container()
	# Route through LootPickup.spawn_at so the drop goes via the Net/LootSpawner's
	# custom spawn_function and replicates to clients with the CORRECT id. A raw
	# add_child here was auto-spawned with the scene's default item_id, so clients
	# saw the wrong model (or nothing) for every enemy drop.
	LootPickup.spawn_at(container, global_position, loot_id, 1)
	# Mutant Harvest: every enemy ALSO drops its signature body-part as a pickup-able skill.
	# M4.1: count SMUGGLES the limb tier (1 common / 2 rare 14% / 3 exotic 2%).
	if Settings.SKILL_DROP_GUARANTEED:
		var skill_id: String = Settings.skill_for_enemy(enemy_id)
		var troll: float = randf()
		var part_tier: int = 3 if troll < 0.02 else (2 if troll < 0.16 else 1)
		LootPickup.spawn_at(
			container, global_position + Vector3(-0.6, 0.0, 0.0), "bodypart_" + skill_id, part_tier
		)
		# Loud on-screen toast so the drop is unmissable (the floating part + beam can be easy to miss).
		# Throttled so a full wave of kills doesn't spam the feed (UI-only — not a deterministic path).
		var now_ms: int = Time.get_ticks_msec()
		if now_ms - _last_part_toast_ms > 2500:
			_last_part_toast_ms = now_ms
			var sname: String = String(Settings.skill_def(skill_id).get("name", skill_id))
			Events.notify.emit(tr("⚙ %s part dropped — press E") % sname, 1)
	# Batch C: elites/minibosses may ALSO drop a biome-matched annex key — an extra
	# independent roll (LootTables gates it on this enemy's modifiers/enemy_id).
	var key_id: String = LootTables.roll_key_drop(self, global_position)
	if key_id != "":
		LootPickup.spawn_at(container, global_position + Vector3(0.7, 0.0, 0.0), key_id, 1)


## Find the sibling Net/Loot container (../../Loot relative to Net/Enemies);
## fall back to our own parent so the drop always lands somewhere valid.
func _loot_container() -> Node:
	var enemies_parent := get_parent()  # Net/Enemies
	if enemies_parent:
		var net := enemies_parent.get_parent()  # Net
		if net:
			var loot := net.get_node_or_null("Loot")
			if loot:
				return loot
	return enemies_parent if enemies_parent else self


# --- Elite modifiers --------------------------------------------------------


## Parse the elite modifier list from our node name (every peer). See EnemyModifiers.
func _parse_modifiers_from_name() -> void:
	modifiers = EnemyModifiers.parse_from_name(str(name))


## Apply modifier stat multipliers onto the resolved _stat_* (authority-meaningful, but
## harmless to compute everywhere). Called right after _load_stats(), before the refill +
## avoidance setup. Also caches the regen rate for _physics_process.
func _apply_modifier_stats() -> void:
	# Generic field-driven fold so a new modifier (e.g. golden) needs no code here.
	for m in modifiers:
		var ms: Dictionary = EnemyModifiers.stats_for(m)
		_stat_health *= float(ms.get("health_mult", 1.0))
		_stat_speed *= float(ms.get("speed_mult", 1.0))
		_regen_rate = maxf(_regen_rate, float(ms.get("regen", 0.0)))


## Detonate the volatile death blast: a flat-falloff radial hit on nearby players (downed
## included so it can finish them). Stats from Settings.ELITE_MOD_STATS["volatile"].
func _detonate_volatile() -> void:
	var v: Dictionary = EnemyModifiers.stats_for("volatile")
	var radius := float(v.get("aoe_radius", 4.0))
	var dmg := float(v.get("aoe_damage", 25.0))
	CombatAoe.damage_players(global_position, radius, dmg, self, 1.0, 0.3, true)


## Tint the model + add a feet glow ring in the PRIMARY modifier's color (every peer,
## render-only, skipped headless). Tints the already-duplicated _flash_mats so the color
## is per-instance and never fights the hit-flash/idle pulse (those own emission only).
func _apply_modifier_visuals() -> void:
	if modifiers.is_empty() or DisplayServer.get_name() == "headless":
		return
	var color := EnemyModifiers.primary_color(modifiers)
	EnemyModifiers.tint_materials(_flash_mats, color, 0.45)
	EnemyModifiers.build_glow_ring(_model_root, color)


## Parse the Machine Nemesis `_NEM` token off the node name (every peer). Sets is_nemesis +
## tier/traits/scar_seed so the appliers below can rebuild the rival's body identically.
func _parse_nemesis_from_name() -> void:
	var info := NemesisProfile.parse_token(str(name))
	if info.is_empty():
		return
	is_nemesis = true
	nemesis_tier = int(info.get("tier", 1))
	scar_seed = int(info.get("scar_seed", 0))
	var raw: Array = info.get("traits", [])
	var typed: Array[String] = []
	for t in raw:
		typed.append(String(t))
	nemesis_traits = typed


## Nemesis tier/trait stat counters, layered after the elite mults (same pre-refill window).
## Tier makes a returning rival tankier; "keen" sharpens its senses; "weakpoint_armored"
## armors the former weak spot. EMP/blast resists are read at their own sites (apply_stun /
## filter_blast), not here. Harmless to compute on every peer (the WeakPoint Hurtbox is a
## scene child, already _ready by the time this runs in the parent's _ready).
func _apply_nemesis_stats() -> void:
	if not is_nemesis:
		return
	_stat_health *= 1.0 + float(nemesis_tier) * Settings.NEMESIS_TIER_HEALTH
	if "keen" in nemesis_traits:
		_stat_detect *= float(Settings.NEMESIS_TRAIT_STATS.get("keen", {}).get("detect_mult", 1.0))
	if "weakpoint_armored" in nemesis_traits:
		var wp := get_node_or_null(Groups.NODE_WEAKPOINT)
		if wp != null and "damage_multiplier" in wp:
			# ABSOLUTE armor value (not a base mult) — works for any 2.0/2.5/×3 weak-point.
			wp.damage_multiplier = float(
				Settings.NEMESIS_TRAIT_STATS.get("weakpoint_armored", {}).get("armor_mult", 0.8)
			)


## Blast/AoE resist hook for the "blast_hard" learned counter — called duck-typed by the
## grenade's radial-damage loop BEFORE Health.take_damage (the grenade's damage source is the
## thrower, not the grenade, so this can't live in Health.damage_filter). Identity on a
## non-blast-hard enemy, so it's safe to call on every enemy.
func filter_blast(dmg: float) -> float:
	if "blast_hard" in nemesis_traits:
		return dmg * Settings.NEMESIS_BLAST_MULT
	return dmg


## Render the rival's scars (charred wash + blood-red ring + blown/bent plating) via the
## shared static so the Hub codex portrait gets the IDENTICAL look. Deterministic in
## scar_seed → every peer scars identically. Render-only, skipped headless.
func _apply_nemesis_scars() -> void:
	if not is_nemesis or DisplayServer.get_name() == "headless":
		return
	ProceduralModels.apply_nemesis_scars(_model_root, _proc_root(), scar_seed, nemesis_tier)


## Armored elites get a larger (×1.3) and brighter (×3 emission) weak-point marker so the
## "shoot the glowing spot" read stays obvious through the steel-blue tint. Render-only;
## no-op headless or if there's no marker. Must run AFTER _setup_weakpoint_marker().
func _boost_weakpoint_for_armored() -> void:
	if "armored" not in modifiers or DisplayServer.get_name() == "headless":
		return
	var wp := get_node_or_null(Groups.NODE_WEAKPOINT)
	if wp == null:
		return
	for c in wp.get_children():
		if not (c is MeshInstance3D):
			continue
		var mi := c as MeshInstance3D
		mi.scale *= 1.3
		var mat := mi.material_override
		if mat is StandardMaterial3D:
			(mat as StandardMaterial3D).emission_energy_multiplier *= 3.0


# --- Target helper (exposed for waves / debugging) --------------------------


func get_target() -> Node3D:
	return _target
