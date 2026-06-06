extends RefCounted
class_name EnemyStateMachine
## Lightweight finite state machine for the robot enemy. Kept as a plain
## RefCounted helper (no nodes) so the whole AI is one cheap object the
## authority steps each physics tick. The enemy script owns it and supplies the
## world queries; this class only decides transitions + drives the agent.
##
## States mirror robot_enemy.gd's State enum so the synchronizer can replicate a
## single int and clients can react (e.g. animation) without running the logic.

enum State { PATROL, CHASE, ATTACK, INVESTIGATE }

var enemy: Node              # the RobotEnemy (CharacterBody3D) that owns us
var state: int = State.PATROL

# --- Patrol wander ---
var _patrol_target: Vector3 = Vector3.ZERO
var _patrol_wait: float = 0.0
var _has_patrol_target: bool = false

func setup(owner_enemy: Node) -> void:
	enemy = owner_enemy

## Decide which state we should be in based on the current target + distances.
## Returns the (possibly unchanged) state so the enemy can detect transitions.
## `detect`/`attack` are passed in per-archetype (Settings.ENEMY_STATS); they
## default to the legacy grunt constants when omitted so existing callers work.
func evaluate(target: Node3D, dist: float, has_los: bool,
		detect: float = Settings.ENEMY_DETECT_RADIUS,
		attack: float = Settings.ENEMY_ATTACK_RANGE) -> int:
	if target == null:
		state = State.PATROL
		return state
	match state:
		State.PATROL:
			if dist <= detect and has_los:
				state = State.CHASE
		State.CHASE:
			if dist <= attack and has_los:
				state = State.ATTACK
			elif dist > detect * 1.25:
				# Lost the target — give a little hysteresis before patrolling.
				state = State.PATROL
		State.ATTACK:
			if dist > attack * 1.15 or not has_los:
				state = State.CHASE
	return state

## Pick a fresh wander point near home. Called by the enemy when it needs one.
func choose_patrol_point(origin: Vector3, radius: float) -> Vector3:
	var ang := randf() * TAU
	var r := radius * sqrt(randf())
	_patrol_target = origin + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	_has_patrol_target = true
	return _patrol_target

func has_patrol_target() -> bool:
	return _has_patrol_target

func clear_patrol_target() -> void:
	_has_patrol_target = false

func get_patrol_target() -> Vector3:
	return _patrol_target

func tick_patrol_wait(delta: float) -> bool:
	# Returns true while still waiting (idle) at a reached point.
	if _patrol_wait > 0.0:
		_patrol_wait -= delta
		return _patrol_wait > 0.0
	return false

func start_patrol_wait(seconds: float) -> void:
	_patrol_wait = seconds
