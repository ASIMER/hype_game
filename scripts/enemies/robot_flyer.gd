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
const ORBIT_BAND: float = 2.5          # acceptable +/- around ORBIT_DISTANCE
const STRAFE_SPEED_SCALE: float = 0.85

var _hover_height: float = 4.5
var _strafe_dir: float = 1.0           # +1 / -1, flips occasionally
var _strafe_flip_t: float = 0.0
var _ground_y: float = 0.0             # sampled ground level under us

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

## Horizontal steering toward the orbit ring + a tangential strafe component.
func _orbit_dir(delta: float) -> Vector3:
	if _target == null or not is_instance_valid(_target):
		return Vector3.ZERO
	_strafe_flip_t -= delta
	if _strafe_flip_t <= 0.0:
		_strafe_flip_t = randf_range(2.0, 4.0)
		if randf() < 0.5:
			_strafe_dir = -_strafe_dir
	var to_target := _target.global_position - global_position
	to_target.y = 0.0
	var d := to_target.length()
	if d < 0.001:
		return Vector3.ZERO
	var radial := to_target / d                      # toward target
	var move := Vector3.ZERO
	# Hold the ring: move in if too far, out if too close.
	if d > ORBIT_DISTANCE + ORBIT_BAND:
		move += radial
	elif d < ORBIT_DISTANCE - ORBIT_BAND:
		move -= radial
	# Tangential strafe (perpendicular on XZ).
	var tangent := Vector3(-radial.z, 0.0, radial.x) * _strafe_dir
	move += tangent * STRAFE_SPEED_SCALE
	if move.length() > 0.001:
		move = move.normalized()
	return move

## OVERRIDE: fly — no gravity. Hold the hover height above the sampled ground and
## blend in 3D separation. dir is the desired XZ move from _orbit_dir.
func _apply_movement(dir: Vector3, delta: float) -> void:
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

## OVERRIDE: full-3D separation so wasps spread in the air, not just on XZ.
func _separation_steer() -> Vector3:
	var push := Vector3.ZERO
	var count := 0
	for other in get_tree().get_nodes_in_group("enemies"):
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
