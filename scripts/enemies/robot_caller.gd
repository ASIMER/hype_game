extends RobotEnemy
class_name RobotCaller
## The "Snitch" caller archetype. Has zero melee damage but instead broadcasts
## Events.enemy_alerted on its attack cooldown whenever it has a target, summoning
## reinforcements via the AIDirector. Keeps its distance rather than closing to melee.
##
## Behaviour: sight/hearing perception is inherited from RobotEnemy (non-hunter
## by default). In ATTACK state it backpedals to maintain standoff at ~attack_range
## and calls for help each cooldown cycle instead of striking.

# Minimum and preferred standoff distances (metres). The caller walks away from the
# player if closer than STANDOFF_MIN, and is satisfied if past STANDOFF_PREF.
const STANDOFF_MIN: float = 6.0
const STANDOFF_PREF: float = 10.0

## OVERRIDE: instead of melee damage, emit enemy_alerted so the AIDirector can
## summon reinforcements toward our position. The attack_range (14 m) is the
## distance at which the ATTACK state activates, i.e. call range.
func _strike(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	Events.enemy_alerted.emit(global_position, 1.0)

## OVERRIDE: hold position at standoff distance while calling on cooldown.
## Backpedal if the player closes in, advance (slowly) if they're too far.
func _do_attack(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		_apply_movement(Vector3.ZERO, delta)
		return

	_face_towards(_target.global_position, delta)

	var dist_to_target := global_position.distance_to(_target.global_position)

	if dist_to_target < STANDOFF_MIN:
		# Player too close — backpedal away.
		var away := global_position - _target.global_position
		away.y = 0.0
		if away.length() > 0.01:
			away = away.normalized()
		_apply_movement(away, delta)
	elif dist_to_target > STANDOFF_PREF:
		# Target drifted out — inch forward to maintain call range.
		var toward := _target.global_position - global_position
		toward.y = 0.0
		if toward.length() > 0.01:
			toward = toward.normalized() * 0.5   # half-speed advance
		_apply_movement(toward, delta)
	else:
		# Within standoff band — hold position.
		_apply_movement(Vector3.ZERO, delta)

	# Call for help on cooldown.
	if _attack_cooldown <= 0.0:
		_strike(_target)
		_attack_cooldown = _next_cooldown()
