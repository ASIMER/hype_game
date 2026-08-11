class_name EnemyDance
extends RefCounted
## M3 «combat dance» — enemies FIGHT instead of walking at you (playtest: «они
## просто на меня идут — не живые»). A stateless steering layer (sibling of
## Steering): robot_enemy passes its nav-desired planar dir through adjust()
## every movement tick; the helper blends in
##   • strafe-orbit for RANGED units in ATTACK — tangential slide around the
##     target with a per-enemy orbit sign that FLIPS on a time bucket, plus a
##     radial correction holding the attack-range band;
##   • surround phase — the orbit sign/phase derive from the instance id, so a
##     pack naturally spreads around the player instead of stacking one lane;
##   • juke — a short perpendicular burst when the TARGET IS LOOKING at this
##     enemy (body yaw ≈ camera yaw, so dot against the player's facing works
##     server-side), cooldown-gated per enemy.
## All per-enemy state lives in node meta (no new fields in robot_enemy, which
## sits near the 1800-line ceiling). Server-side only — the result replicates
## through position sync like every other movement.

const RANGED_MIN_RANGE := 5.0  # attack_range >= this = shooter → full strafe
const ORBIT_WEIGHT := 0.62  # tangential blend vs pursuit
const BAND_SOFT := 0.25  # radial correction gain inside the range band
const FLIP_BUCKET := 3.2  # seconds between orbit-direction rethinks
const JUKE_TIME := 0.42
const JUKE_COOLDOWN := 2.4
const JUKE_DOT := 0.988  # target facing-dot that counts as «taking aim at me»
const JUKE_MAX_DIST := 42.0
const META_JUKE_UNTIL := "dance_juke_until"
const META_JUKE_DIR := "dance_juke_dir"
const META_JUKE_NEXT := "dance_juke_next"


## Blend combat movement into the nav-desired planar `dir` (unit or zero).
## Only reshapes movement in ATTACK (shooters) or when a juke is active; every
## other state returns `dir` untouched. `rng_range` is the enemy's attack range.
static func adjust(
	e: CharacterBody3D, target: Node3D, dir: Vector3, rng_range: float, state: int
) -> Vector3:
	if e == null or target == null or not is_instance_valid(target):
		return dir
	var now_ms: int = Time.get_ticks_msec()
	# An active juke overrides everything for its fraction of a second.
	if int(e.get_meta(META_JUKE_UNTIL, 0)) > now_ms:
		var jd: Vector3 = e.get_meta(META_JUKE_DIR, Vector3.ZERO)
		return jd if jd != Vector3.ZERO else dir
	_maybe_start_juke(e, target, now_ms)
	# Strafe-orbit only for shooters actually IN combat.
	if state != 2 or rng_range < RANGED_MIN_RANGE:
		return dir
	var to_e := e.global_position - target.global_position
	to_e.y = 0.0
	var dist := to_e.length()
	if dist < 0.5:
		return dir
	var radial := to_e / dist
	# Per-enemy orbit sign, re-rolled every FLIP_BUCKET seconds (deterministic in
	# (id, bucket) so it's stable within a bucket, varied across the pack).
	var bucket: int = int(float(now_ms) / 1000.0 / FLIP_BUCKET)
	var sign_hash: int = int(e.get_instance_id()) * 31 + bucket * 17
	var tangent := Vector3(-radial.z, 0.0, radial.x) * (1.0 if (sign_hash & 2) == 0 else -1.0)
	# Radial correction: hold ~85% of attack range (slide OUT when the player
	# closes in, drift IN when drifting out of range).
	var want: float = rng_range * 0.85
	var radial_err := clampf((want - dist) / maxf(1.0, want), -1.0, 1.0)
	var move := tangent * ORBIT_WEIGHT + radial * radial_err * BAND_SOFT * -1.0
	# Keep a slice of the nav dir so obstacle avoidance still matters.
	move += dir * 0.35
	return move.normalized() if move.length() > 0.05 else dir


## Start a sidestep burst when the target is drawing a bead on this enemy.
static func _maybe_start_juke(e: CharacterBody3D, target: Node3D, now_ms: int) -> void:
	if int(e.get_meta(META_JUKE_NEXT, 0)) > now_ms:
		return
	var to_e := e.global_position - target.global_position
	to_e.y = 0.0
	var dist := to_e.length()
	if dist > JUKE_MAX_DIST or dist < 2.0:
		return
	# The player body yaw tracks the camera each frame, so -basis.z is the aim.
	var facing := -target.global_transform.basis.z
	facing.y = 0.0
	if facing.length() < 0.01:
		return
	if facing.normalized().dot(to_e / dist) < JUKE_DOT:
		return
	var side := Vector3(-to_e.z, 0.0, to_e.x).normalized()
	if (int(e.get_instance_id()) ^ (now_ms / 1000)) & 1:
		side = -side
	e.set_meta(META_JUKE_DIR, side)
	e.set_meta(META_JUKE_UNTIL, now_ms + int(JUKE_TIME * 1000.0))
	e.set_meta(META_JUKE_NEXT, now_ms + int(JUKE_COOLDOWN * 1000.0))
