## Shared enemy steering helpers (docs/AUDIT.md F5). orbit_dir was byte-identical in
## robot_flyer and robot_strafer; the per-instance wobble state (_strafe_dir /
## _strafe_flip_t) stays declared on each enemy class — this helper reads/writes it
## duck-typed. The randf wobble is movement flavor on the server only (positions
## replicate), so it is deliberately NOT seed-deterministic.
class_name Steering


## Hold an orbit ring around `target`: move radially in/out when outside
## [orbit_distance ± orbit_band], plus a tangential strafe whose direction flips at
## random 2–4 s intervals. Returns the normalized desired XZ move (Vector3.ZERO when
## there is no valid target). `enemy` must declare _strafe_dir / _strafe_flip_t.
static func orbit_dir(enemy: Node3D, target: Node3D, delta: float,
		orbit_distance: float, orbit_band: float, strafe_speed_scale: float) -> Vector3:
	if target == null or not is_instance_valid(target):
		return Vector3.ZERO
	enemy._strafe_flip_t -= delta
	if enemy._strafe_flip_t <= 0.0:
		enemy._strafe_flip_t = randf_range(2.0, 4.0)
		if randf() < 0.5:
			enemy._strafe_dir = -enemy._strafe_dir
	var to_target: Vector3 = target.global_position - enemy.global_position
	to_target.y = 0.0
	var d := to_target.length()
	if d < 0.001:
		return Vector3.ZERO
	var radial := to_target / d  # toward target
	var move := Vector3.ZERO
	# Hold the ring: move in if too far, out if too close.
	if d > orbit_distance + orbit_band:
		move += radial
	elif d < orbit_distance - orbit_band:
		move -= radial
	# Tangential strafe (perpendicular on XZ).
	var tangent := Vector3(-radial.z, 0.0, radial.x) * float(enemy._strafe_dir)
	move += tangent * strafe_speed_scale
	if move.length() > 0.001:
		move = move.normalized()
	return move
