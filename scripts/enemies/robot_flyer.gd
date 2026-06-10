extends RobotGunner
class_name RobotFlyer
## Flying ranged enemy (wasp). Hovers at a fixed height above the ground, strafes
## around the player while keeping its distance, and fires hitscan shots (inherited
## from RobotGunner). No gravity; Y is lerped toward the hover height. Separation
## is done in full 3D so wasps don't share the same air column.
##
## Reuses everything else from RobotEnemy/RobotGunner (HP-bar, flash, death,
## perception). It does NOT shove bodies (flyers shouldn't block ground units),
## so it drops the player/enemy bits from its collision mask and relies purely on
## steering separation.

# How far the wasp likes to sit from the target horizontally — it strafes at this
# ring rather than charging into melee.
const ORBIT_DISTANCE: float = 9.0
const ORBIT_BAND: float = 2.5  # acceptable +/- around ORBIT_DISTANCE
const STRAFE_SPEED_SCALE: float = 0.85

var _hover_height: float = 4.5
var _strafe_dir: float = 1.0  # +1 / -1, flips occasionally
var _strafe_flip_t: float = 0.0
var _ground_y: float = 0.0  # sampled ground level under us

# Procedural idle parts (visual only): the rotor pivots spin, the body bobs, the
# core pulses. Cached once in _cache_proc_parts (OVERRIDE of the base).
var _proc_rotors: Array[Node3D] = []
var _proc_body: Node3D = null
var _proc_body_rest_y: float = 0.0


func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	_hover_height = stats.get("hover", 4.5)
	_ground_y = global_position.y
	# A flyer that's airborne shouldn't body-block ground units; keep its own layer
	# (4, so weapons/raycasts on the enemy mask still hit it) but only collide with
	# the world so it can't be shoved by players/other enemies. Separation is steered.
	collision_mask = 1


## OVERRIDE: only collide with world; avoidance stays on for path fan-out.
func _setup_collision_and_avoidance() -> void:
	collision_mask = 1
	if _agent:
		_agent.avoidance_enabled = true
		_agent.radius = 0.6
		_agent.max_speed = _stat_speed


## OVERRIDE: sit the bar higher (wasp floats well above origin).
func _health_bar_height() -> float:
	return 1.2


## OVERRIDE: chase = approach the orbit ring, not the target's feet. We steer in
## the XZ plane toward/away to hold ORBIT_DISTANCE and add a tangential strafe,
## then let _apply_movement handle the hover Y.
func _do_chase(delta: float) -> void:
	_fsm.clear_patrol_target()
	if _target == null:
		_apply_movement(Vector3.ZERO, delta)
		return
	_apply_movement(_orbit_dir(delta), delta)
	_face_towards(_target.global_position, delta)


## OVERRIDE: when in range, keep orbiting WHILE firing rather than standing still —
## a strafing flyer is much harder to hit and reads as "alive".
func _do_attack(delta: float) -> void:
	_apply_movement(_orbit_dir(delta), delta)
	if _target and is_instance_valid(_target):
		_face_towards(_target.global_position, delta)
	if _attack_cooldown <= 0.0:
		_strike(_target)
		_attack_cooldown = _next_cooldown()


## Horizontal steering toward the orbit ring + a tangential strafe component
## (shared Steering.orbit_dir — it reads/writes our _strafe_dir/_strafe_flip_t).
func _orbit_dir(delta: float) -> Vector3:
	return Steering.orbit_dir(self, _target, delta, ORBIT_DISTANCE, ORBIT_BAND, STRAFE_SPEED_SCALE)


## OVERRIDE: fly — no gravity. Hold the hover height above the sampled ground and
## blend in 3D separation. dir is the desired XZ move from _orbit_dir.
func _apply_movement(dir: Vector3, _delta: float) -> void:
	var sep := _separation_steer()
	var move := dir + sep
	if move.length() > 1.0:
		move = move.normalized()
	var speed: float = _stat_speed
	velocity.x = move.x * speed
	velocity.z = move.z * speed
	# Vertical: lerp toward hover height above ground (track target/ground baseline).
	var target_y := _ground_y + _hover_height
	if _target and is_instance_valid(_target):
		target_y = _target.global_position.y + _hover_height
	var dy := target_y - global_position.y
	velocity.y = clampf(dy * 4.0, -speed, speed)
	move_and_slide()


## OVERRIDE: cache the wasp's rotor pivots + body + glowing core for idle motion.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	var hub := asm.find_child("RotorHub", true, false)
	if hub is Node3D:
		for i in 4:
			var r := (hub as Node3D).find_child("Rotor%d" % i, true, false)
			if r is Node3D:
				_proc_rotors.append(r as Node3D)
	var bodyn := asm.find_child("Body", true, false)
	if bodyn is Node3D:
		_proc_body = bodyn as Node3D
		_proc_body_rest_y = _proc_body.position.y
	var core := asm.find_child("Core", true, false)
	if core is MeshInstance3D:
		_pulse_part = core as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(core as MeshInstance3D)
	_has_proc_anim = not _proc_rotors.is_empty() or _proc_body != null or _pulse_part != null


## OVERRIDE: fast rotor spin (each pivot about its own Y), gentle body bob, core pulse.
func _animate_visual(delta: float) -> void:
	for r in _proc_rotors:
		if r and is_instance_valid(r):
			r.rotation.y += delta * 38.0
	if _proc_body and is_instance_valid(_proc_body):
		_proc_body.position.y = _proc_body_rest_y + sin(_anim_time * 3.0) * 0.05
	# Core glows brighter/faster while attacking.
	var atk := current_state == State.ATTACK
	_pulse_emission(0.6, 1.5, 5.0 if atk else 3.0)


## OVERRIDE: full-3D separation so wasps spread in the air, not just on XZ.
func _separation_steer() -> Vector3:
	var push := Vector3.ZERO
	var count := 0
	for other in get_tree().get_nodes_in_group(Groups.ENEMIES):
		if other == self or not is_instance_valid(other) or not (other is Node3D):
			continue
		var on := other as Node3D
		var away := global_position - on.global_position
		var dist := away.length()
		if dist > 0.001 and dist < SEPARATION_RADIUS:
			push += (away / dist) * (1.0 - dist / SEPARATION_RADIUS)
			count += 1
	if count == 0:
		return Vector3.ZERO
	return push * SEPARATION_STRENGTH
