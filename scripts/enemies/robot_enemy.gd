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
const HP_BAR_SCENE := "res://scenes/enemies/EnemyHealthBar.tscn"
const DEBRIS_SCENE := "res://scenes/fx/RobotDebris.tscn"

# How long the corpse lingers (death anim + SFX) before it is freed.
const DEATH_LINGER: float = 1.0
# Separation: nearby enemies within this radius push us apart so they don't blob.
const SEPARATION_RADIUS: float = 1.6
const SEPARATION_STRENGTH: float = 3.2

# Mirror of EnemyStateMachine.State so the synchronizer replicates a plain int
# and clients can map it to animation without the helper class.
enum State { PATROL, CHASE, ATTACK }

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

# --- Stuck detection / recovery --------------------------------------------
# A chasing enemy that spawns inside a building or jams on geometry yields a zero
# nav direction and freezes — which deadlocks the wave (a wave only clears when
# every spawned enemy is dead). We watch planar progress while chasing and, after
# STUCK_LIMIT seconds without moving STUCK_PROGRESS metres, re-seat on the navmesh
# and (if still unreachable) relocate to open navmesh near the target.
var _stuck_dist: float = INF        # best (smallest) distance-to-target seen while chasing
var _stuck_time: float = 0.0
var _recover_count: int = 0
const STUCK_PROGRESS: float = 1.0   # metres the gap must close to count as progress
const STUCK_LIMIT: float = 2.5      # seconds chasing without closing the gap -> recover

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
var _flash_base_emission: Array = []        # parallel: original emission colors
var _flash_t: float = 0.0
const FLASH_TIME: float = 0.14        # longer so hits read clearly

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
const KNOCKBACK_SPEED: float = 2.2    # m/s initial nudge (small)
const KNOCKBACK_DECAY: float = 12.0   # how fast the nudge bleeds off
# Last attacker position (for knockback direction); set by Health via apply_hit
# chain isn't available, so we derive direction from the nearest threat instead.
var _last_hit_health: float = -1.0

var _hp_bar: EnemyHealthBar = null

# Replicated to clients by the MultiplayerSynchronizer (see .tscn). Authority
# writes it each tick; clients read it for animation/state-driven visuals.
var current_state: int = State.PATROL

# Hunter mode: wave-spawned enemies actively seek the nearest player (ignoring the
# detect radius / line-of-sight gate) so survival waves stay aggressive on the big
# map instead of idling at their nest. Set by the wave manager on spawn.
var hunter: bool = false

func _ready() -> void:
	add_to_group("enemies")
	_home = global_position
	_load_stats()

	# Populate the visual model from the registry (CC0 art or primitive).
	var model := AssetRegistry.get_model(enemy_id)
	if model:
		_model_root.add_child(model)
		_setup_animation()
		_collect_flash_materials(model)
	# Remember the model's rest transform so the hit flinch can return to it.
	if _model_root:
		_model_rest_pos = _model_root.position
		_model_rest_scale = _model_root.scale

	# Health is configured via the scene export; ensure max matches stats even if
	# the scene drifts, then refill. Only the authority should own its state.
	_health.max_health = _stat_health
	_health.current = _health.max_health
	if not _health.died.is_connected(_on_died):
		_health.died.connect(_on_died)
	if not _health.health_changed.is_connected(_on_health_changed):
		_health.health_changed.connect(_on_health_changed)

	_setup_health_bar()
	_setup_collision_and_avoidance()

	_fsm = EnemyStateMachine.new()
	_fsm.setup(self)

	_agent.path_desired_distance = 0.6
	_agent.target_desired_distance = maxf(1.0, _stat_attack_range * 0.6)

	Events.enemy_spawned.emit(self)

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

	if _attack_cooldown > 0.0:
		_attack_cooldown -= delta
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = 0.4
		_target = _find_nearest_player()

	var dist := INF
	var has_los := false
	if _target != null and is_instance_valid(_target):
		dist = global_position.distance_to(_target.global_position)
		has_los = _check_line_of_sight(_target)
	else:
		_target = null

	# Hunters always know where the player is (forced LOS + unlimited detect), so they
	# leave their nest and close in; they still ATTACK only inside attack range.
	if hunter and _target != null:
		current_state = _fsm.evaluate(_target, dist, true, 1.0e9, _stat_attack_range)
	else:
		current_state = _fsm.evaluate(_target, dist, has_los, _stat_detect, _stat_attack_range)

	match current_state:
		State.PATROL:
			_do_patrol(delta)
		State.CHASE:
			_do_chase(delta)
		State.ATTACK:
			_do_attack(delta)

	_update_stuck(delta)

func _process(delta: float) -> void:
	# Animation is purely visual and runs on BOTH server and clients: clients read
	# `current_state` (replicated by the MultiplayerSynchronizer) and Health.is_dead.
	# This deliberately lives outside _physics_process so AI gating is untouched.
	_update_animation()
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

# --- Hit flash --------------------------------------------------------------

## Walk the model subtree and remember every StandardMaterial3D (and its base
## emission) so a hit can briefly drive emission white. We duplicate shared
## materials so flashing one enemy doesn't flash every instance sharing the art.
func _collect_flash_materials(root: Node) -> void:
	if root is MeshInstance3D:
		var mi := root as MeshInstance3D
		var mesh := mi.mesh
		if mesh:
			for s in mesh.get_surface_count():
				var mat := mi.get_active_material(s)
				if mat is StandardMaterial3D:
					var dup := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
					mi.set_surface_override_material(s, dup)
					_flash_mats.append(dup)
					_flash_base_emission.append(dup.emission if dup.emission_enabled else Color(0, 0, 0))
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
	var k := _flash_t / FLASH_TIME            # 1 -> 0
	for i in _flash_mats.size():
		var base: Color = _flash_base_emission[i]
		var m := _flash_mats[i]
		m.emission = base.lerp(Color(1, 1, 1), k)
		m.emission_energy_multiplier = lerpf(1.0, 4.0, k)   # stronger spike
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
	var k := _stagger_t / STAGGER_TIME      # 1 -> 0
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
	_agent.set_target_position(_target.global_position)
	_navigate_to_agent(delta)

func _do_attack(delta: float) -> void:
	# Hold position and strike on cooldown. Face the target for clarity.
	_apply_movement(Vector3.ZERO, delta)
	if _target and is_instance_valid(_target):
		_face_towards(_target.global_position, delta)
	if _attack_cooldown <= 0.0:
		_strike(_target)
		_attack_cooldown = _next_cooldown()

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
	if current_state != State.CHASE or _stat_attack_range >= 5.0 \
			or _target == null or not is_instance_valid(_target):
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
		return pos   # map not synced yet — leave position unchanged
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
	var sep := _separation_steer()
	var move := dir + sep
	if move.length() > 1.0:
		move = move.normalized()
	var speed: float = _stat_speed
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
	for other in get_tree().get_nodes_in_group("enemies"):
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
	var hb := target.get_node_or_null("Hurtbox")
	if hb and hb.has_method("apply_hit"):
		hb.apply_hit(_stat_damage, self)
		return
	var hp := target.get_node_or_null("Health")
	if hp and hp.has_method("take_damage"):
		hp.take_damage(_stat_damage, self)

# --- Perception -------------------------------------------------------------

func _find_nearest_player() -> Node3D:
	var nearest: Node3D = null
	var best := INF
	for p in get_tree().get_nodes_in_group("players"):
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		var pn := p as Node3D
		# Skip dead players if they expose a Health child.
		var ph := pn.get_node_or_null("Health")
		if ph and ph is Health and (ph as Health).is_dead:
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

# --- Death / loot -----------------------------------------------------------

## DEATH POLISH: don't free immediately. Disable AI + collision, play the Death
## clip + let the SFX/debris play, drop loot, THEN free after DEATH_LINGER.
## Events.entity_died already fired from Health._die at the moment of death, so
## wave-clear detection stays correct even though the corpse lingers.
func _on_died(_killer: Node) -> void:
	if _dying:
		return
	_dying = true
	# Stop moving + colliding so the corpse doesn't shove the player or block nav.
	velocity = Vector3.ZERO
	set_physics_process(false)
	collision_layer = 0
	collision_mask = 0
	var hb := get_node_or_null("Hurtbox")
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
func _spawn_debris() -> void:
	if not ResourceLoader.exists(DEBRIS_SCENE):
		return
	var packed := load(DEBRIS_SCENE)
	if not (packed is PackedScene):
		return
	var debris: Node = (packed as PackedScene).instantiate()
	var container := _loot_container()      # reuse the sibling FX-safe container
	container.add_child(debris)
	if debris is Node3D:
		(debris as Node3D).global_position = global_position + Vector3.UP * 0.8

func _spawn_loot() -> void:
	if not ResourceLoader.exists(LOOT_SCENE):
		print("[RobotEnemy] %s died at %s — LootPickup.tscn not present, no drop" % [enemy_id, global_position])
		return
	var packed := load(LOOT_SCENE)
	if not (packed is PackedScene):
		return
	var loot_node: Node = (packed as PackedScene).instantiate()
	var loot_id: String = LOOT_IDS[randi() % LOOT_IDS.size()]
	# LootPickup exposes `item_id` (see scripts/loot/loot_pickup.gd) — seed it
	# before the node enters the tree so _ready() builds the right model.
	if "item_id" in loot_node:
		loot_node.set("item_id", loot_id)
	var container := _loot_container()
	container.add_child(loot_node, true)
	if loot_node is Node3D:
		(loot_node as Node3D).global_position = global_position

## Find the sibling Net/Loot container (../../Loot relative to Net/Enemies);
## fall back to our own parent so the drop always lands somewhere valid.
func _loot_container() -> Node:
	var enemies_parent := get_parent()                     # Net/Enemies
	if enemies_parent:
		var net := enemies_parent.get_parent()             # Net
		if net:
			var loot := net.get_node_or_null("Loot")
			if loot:
				return loot
	return enemies_parent if enemies_parent else self

# --- Target helper (exposed for waves / debugging) --------------------------

func get_target() -> Node3D:
	return _target
