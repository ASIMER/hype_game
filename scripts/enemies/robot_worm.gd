extends RobotEnemy
class_name RobotWorm
## DESERT SAND-WORM — the burrowing ambusher. Cycle:
##   BURROWED  - hidden + untargetable, travels FAST under the ground straight at its
##               prey (no navmesh — underground can't be blocked); a dust-mound trail
##               marks it on the surface so players can read the approach.
##   EMERGE    - bursts out of the ground in a LEAP at the player (up + forward arc,
##               gravity finishes it); landing bites everyone around the impact.
##   SURFACE   - crawls/chases on the navmesh and melee-bites for `surface_time` —
##               THE vulnerability window (shoot the glowing maw weak point ×2.5).
##   SUBMERGE  - sinks back under and returns to BURROWED. Repeat.
##
## Replication: `phase` is replicated by the scene's SceneReplicationConfig (next to
## current_state); EVERY peer drives visibility/dust/sink purely from it in _process,
## so co-op clients see the worm vanish/erupt exactly like the host. All gameplay
## (movement, damage, collision toggles) is authority-only, like every enemy.
##
## The shared FSM/state enum is untouched: we fully override _physics_process and only
## write `current_state` as an ANIMATION hint (PATROL idle / CHASE moving / ATTACK bite).

enum Phase { BURROWED, EMERGE, SURFACE, SUBMERGE }

## Replicated worm phase (see RobotSandworm.tscn SceneReplicationConfig).
var phase: int = Phase.BURROWED

const BURROW_DEPTH: float = 1.6        # how far below ground the body travels
const MIN_BURROW_TIME: float = 1.2     # so the cycle never strobes
const BURROW_TIMEOUT: float = 8.0      # force an emerge even if the prey kept distance
const SUBMERGE_TIME: float = 0.6
const LAND_GRACE: float = 0.25         # min airtime before a landing can register

# Stats-driven behaviour params (Settings.ENEMY_STATS["robot_sandworm"]).
var _burrow_speed: float = 7.5
var _surface_time: float = 5.0
var _emerge_range: float = 5.0
var _leap_damage: float = 14.0
var _leap_radius: float = 2.4

var _phase_t: float = 0.0              # seconds in the current phase (authority)
var _air_t: float = 0.0                # EMERGE airtime
var _landed: bool = false

# --- Visual-only (all peers) -------------------------------------------------
var _dust: GPUParticles3D = null
var _seg_pivots: Array[Node3D] = []
var _seg_rest: Array[Vector3] = []
var _seen_phase: int = -1              # last phase applied to the visuals

func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	_burrow_speed = float(stats.get("burrow_speed", _burrow_speed))
	_surface_time = float(stats.get("surface_time", _surface_time))
	_emerge_range = float(stats.get("emerge_range", _emerge_range))
	_leap_damage = float(stats.get("leap_damage", _leap_damage))
	_leap_radius = float(stats.get("leap_radius", _leap_radius))
	_build_dust_trail()
	# Spawn already burrowed: the worm announces itself by erupting, not by standing
	# around. Authority owns the gameplay toggles; visuals follow `phase` everywhere.
	if is_multiplayer_authority():
		_enter_burrowed()

## OVERRIDE: sit the bar above the crawling body.
func _health_bar_height() -> float:
	return 1.6

# ------------------------------------------------------------------ phase machine
func _physics_process(delta: float) -> void:
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
	_phase_t += delta

	match phase:
		Phase.BURROWED:
			_tick_burrowed(delta)
		Phase.EMERGE:
			_tick_emerge(delta)
		Phase.SURFACE:
			_tick_surface(delta)
		Phase.SUBMERGE:
			_tick_submerge(delta)

## Underground travel: straight-line XZ toward the prey at burrow_speed, body pinned
## BURROW_DEPTH below the terrain. Position is set directly (no move_and_slide — there
## is nothing to collide with under the ground). Non-hunters only pursue inside the
## detect radius (the worm "feels" footsteps); idle worms drift near home.
func _tick_burrowed(delta: float) -> void:
	var dest := Vector3.ZERO
	var has_prey := false
	if _target != null and is_instance_valid(_target):
		var d := global_position.distance_to(_target.global_position)
		if hunter or d <= _stat_detect:
			dest = _target.global_position
			has_prey = true
	if not has_prey:
		current_state = State.PATROL
		velocity = Vector3.ZERO
		_pin_underground()
		return
	current_state = State.CHASE
	var to := dest - global_position
	to.y = 0.0
	var dist := to.length()
	# Close enough (or hunted too long) — burst out.
	if (_phase_t >= MIN_BURROW_TIME and dist <= _emerge_range) or _phase_t >= BURROW_TIMEOUT:
		_begin_emerge()
		return
	if dist > 0.01:
		var step := to.normalized() * minf(_burrow_speed * delta, dist)
		global_position += step
		rotation.y = lerp_angle(rotation.y, atan2(to.x, to.z), clampf(delta * 6.0, 0.0, 1.0))
	_pin_underground()

## Clamp inside the world rectangle + pin the body below the terrain surface.
func _pin_underground() -> void:
	global_position.x = clampf(global_position.x, ProceduralTerrain.X_MIN + 4.0, ProceduralTerrain.X_MAX - 4.0)
	global_position.z = clampf(global_position.z, ProceduralTerrain.Z_MIN + 4.0, ProceduralTerrain.Z_MAX - 4.0)
	global_position.y = ProceduralTerrain.height_at(global_position.x, global_position.z) - BURROW_DEPTH

## Burst out of the ground in a leap toward the prey.
func _begin_emerge() -> void:
	# Surface on walkable ground (navmesh) so the crawl phase can path.
	var surf := _snap_to_navmesh(Vector3(global_position.x,
		ProceduralTerrain.height_at(global_position.x, global_position.z), global_position.z))
	global_position = surf + Vector3.UP * 0.1
	_set_targetable(true)
	var fwd := Vector3.FORWARD
	if _target != null and is_instance_valid(_target):
		var to := _target.global_position - global_position
		to.y = 0.0
		if to.length() > 0.01:
			fwd = to.normalized()
			rotation.y = atan2(fwd.x, fwd.z)
	velocity = fwd * 5.0 + Vector3.UP * 10.0
	_air_t = 0.0
	_landed = false
	_set_phase(Phase.EMERGE)
	current_state = State.CHASE

## Airborne leap arc: gravity pulls it down; landing bites everyone nearby.
func _tick_emerge(delta: float) -> void:
	_air_t += delta
	velocity.y -= _gravity * delta
	move_and_slide()
	if _air_t >= LAND_GRACE and (is_on_floor() or _air_t > 2.5):
		if not _landed:
			_landed = true
			_bite_area(_leap_damage, _leap_radius)
		velocity = Vector3.ZERO
		_set_phase(Phase.SURFACE)

## Surface crawl: normal nav-chase + melee bites — the kill window.
func _tick_surface(delta: float) -> void:
	if _phase_t >= _surface_time:
		_begin_submerge()
		return
	if _target == null or not is_instance_valid(_target):
		current_state = State.PATROL
		_apply_movement(Vector3.ZERO, delta)
		return
	var dist := global_position.distance_to(_target.global_position)
	if dist <= _stat_attack_range:
		current_state = State.ATTACK
		_apply_movement(Vector3.ZERO, delta)
		_face_towards(_target.global_position, delta)
		if _attack_cooldown <= 0.0:
			_strike(_target)
			_attack_cooldown = _next_cooldown()
	else:
		current_state = State.CHASE
		_agent.set_target_position(_target.global_position)
		_navigate_to_agent(delta)

func _begin_submerge() -> void:
	velocity = Vector3.ZERO
	_set_targetable(false)
	_set_phase(Phase.SUBMERGE)
	current_state = State.CHASE

func _tick_submerge(_delta: float) -> void:
	if _phase_t >= SUBMERGE_TIME:
		_enter_burrowed()

func _enter_burrowed() -> void:
	_set_targetable(false)
	_set_phase(Phase.BURROWED)
	_pin_underground()
	current_state = State.PATROL

## Flip the worm's hit-ability + world collision (authority). Underground it can't be
## shot (body layer 0 → weapon raycasts miss) and doesn't collide with anything.
func _set_targetable(on: bool) -> void:
	collision_layer = 4 if on else 0
	collision_mask = (1 | 2 | 4) if on else 0
	for hb_name in ["Hurtbox", "WeakPoint"]:
		var hb := get_node_or_null(hb_name)
		if hb and hb is CollisionObject3D:
			(hb as CollisionObject3D).set_deferred("monitorable", on)

## Authority phase switch (resets the phase clock; replicates via the synchronizer).
func _set_phase(p: int) -> void:
	phase = p
	_phase_t = 0.0

## AoE bite around the body (the emerge-leap landing).
func _bite_area(damage: float, radius: float) -> void:
	for p in get_tree().get_nodes_in_group("players"):
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		var pn := p as Node3D
		if pn.has_method("is_downed") and pn.is_downed():
			continue
		if global_position.distance_to(pn.global_position) > radius:
			continue
		var hb := pn.get_node_or_null("Hurtbox")
		if hb and hb.has_method("apply_hit"):
			hb.apply_hit(damage, self)

## OVERRIDE the wave-watchdog hook: a "stuck" worm just re-burrows next to a player
## (teleporting it onto open navmesh like the base would break the underground fiction).
func force_unstuck() -> void:
	var p := _find_nearest_player()
	var anchor := p.global_position if p else _home
	var ang := randf() * TAU
	var rad := randf_range(8.0, 13.0)
	global_position = anchor + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	velocity = Vector3.ZERO
	_enter_burrowed()

# ------------------------------------------------------------------ visuals (all peers)
## Per-frame visual layer on every peer: base juice + the phase-driven look.
func _process(delta: float) -> void:
	super._process(delta)
	_apply_phase_visuals(delta)

## Dust-mound trail that marks the burrowed worm on the surface. Render-only.
func _build_dust_trail() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_dust = GPUParticles3D.new()
	_dust.name = "DustTrail"
	_dust.amount = 28
	_dust.lifetime = 0.7
	_dust.emitting = false
	_dust.top_level = true   # world-space: we park it at GROUND level above the body
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.5
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 35.0
	pm.gravity = Vector3(0, -3.0, 0)
	pm.initial_velocity_min = 1.2
	pm.initial_velocity_max = 2.6
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	pm.color = Color(0.62, 0.5, 0.34, 0.7)
	_dust.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.45, 0.45)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	qm.vertex_color_use_as_albedo = true
	qm.albedo_color = Color(0.62, 0.5, 0.34, 0.7)
	quad.material = qm
	_dust.draw_pass_1 = quad
	add_child(_dust)

## Drive visibility/dust/sink from the REPLICATED `phase` so clients match the host.
func _apply_phase_visuals(_delta: float) -> void:
	var asm := _proc_root()
	# Phase transition edge: flip visibility + dust.
	if phase != _seen_phase:
		_seen_phase = phase
		var under := phase == Phase.BURROWED
		if _model_root:
			_model_root.visible = not under
		if _hp_bar:
			_hp_bar.visible = not under and not (_health != null and _health.is_dead)
		if _dust:
			_dust.emitting = under or phase == Phase.SUBMERGE
		# Eruption burst on EMERGE (all peers — driven by the replicated phase).
		if phase == Phase.EMERGE:
			_spawn_death_burst()   # reuse the spark/dirt burst FX at the body
	# Park the dust at ground level above wherever the (replicated) body is.
	if _dust and _dust.emitting:
		_dust.global_position = Vector3(global_position.x,
			ProceduralTerrain.height_at(global_position.x, global_position.z) + 0.15,
			global_position.z)
	# SUBMERGE sink: the model slides down into the ground over the phase window.
	if asm:
		if phase == Phase.SUBMERGE:
			asm.position.y = move_toward(asm.position.y, -BURROW_DEPTH, _delta * (BURROW_DEPTH / SUBMERGE_TIME))
		elif asm.position.y != 0.0:
			asm.position.y = 0.0

## OVERRIDE: cache the worm's segment pivots + glowing maw for the idle/crawl anim.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	for i in 7:
		var seg := asm.find_child("Seg%d" % i, true, false)
		if seg is Node3D:
			_seg_pivots.append(seg as Node3D)
			_seg_rest.append((seg as Node3D).position)
	var maw := asm.find_child("Maw", true, false)
	if maw is MeshInstance3D:
		_pulse_part = maw as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(maw as MeshInstance3D)
	_has_proc_anim = not _seg_pivots.is_empty() or _pulse_part != null

## OVERRIDE: sinusoidal segment undulation while surfaced (a travelling wave down the
## body) + a maw pulse that burns hotter while biting.
func _animate_visual(_delta: float) -> void:
	if phase == Phase.SURFACE or phase == Phase.EMERGE:
		for i in _seg_pivots.size():
			var seg := _seg_pivots[i]
			if seg == null or not is_instance_valid(seg):
				continue
			var wave := sin(_anim_time * 6.0 - float(i) * 0.9)
			seg.position = _seg_rest[i] + Vector3(wave * 0.07, absf(wave) * 0.04, 0.0)
	var atk := current_state == State.ATTACK
	_pulse_emission(0.7, 1.5, 8.0 if atk else 3.0)
