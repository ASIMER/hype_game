class_name EnemyGait
extends Node
## Procedural WALK CYCLE for machines built out of Node3D part trees (D2.4).
##
## Machines used to slide: the body translated, the legs stayed rigid, and nothing about the
## motion said "this thing is walking". This node swings each named hip pivot from the body's
## OWN measured speed, so the stride is always in step with the movement — no animation
## state, no clip, nothing to desync.
##
## RUNS ON EVERY PEER, DERIVED FROM POSITION. The gait is pure render, and it is driven by the
## frame-to-frame position delta rather than `velocity`, because velocity is authority-side
## state while POSITION is what actually replicates. A client therefore reproduces the same
## stride for a remote machine without a single new byte on the wire.
##
## Instantiated in code by EnemyStatus (robot_enemy.gd is at the 1800-line gdlint ceiling and
## cannot take another child), and a no-op on any body whose builder does not publish
## "GaitLeg*" pivots — so adding the pivots to a builder is what opts that machine in.

const LEG_PREFIX := "GaitLeg"
## Radians of hip swing at full stride, and the speed (m/s) that counts as full stride.
const SWING_MAX := 0.62
const FULL_STRIDE_SPEED := 4.2
## Stride phase advances with DISTANCE, not time — so a slowed machine takes slower steps
## instead of the same steps in place. Radians of phase per metre travelled.
const PHASE_PER_METRE := 3.6
## Vertical body bob at full stride (m), twice per stride (once per footfall).
const BOB_MAX := 0.045
## Beyond this the stride is invisible and not worth the per-frame work.
const GAIT_DIST := 45.0
## How fast the measured speed follows reality (exponential); raw deltas are noisy.
const SPEED_SMOOTH := 6.0

var _e: Node3D = null
var _legs: Array[Node3D] = []
var _rest: Array[Vector3] = []
var _body: Node3D = null  # the proc-model root we bob (never the scene's ModelRoot)
var _body_rest_y: float = 0.0
var _phase: float = 0.0
var _speed: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _have_last: bool = false


## Find the hip pivots under the enemy's model. Returns false when this machine has none,
## which is the normal case for every builder that has not been converted yet.
func setup(enemy: Node3D) -> bool:
	_e = enemy
	var root: Node = enemy.get_node_or_null(Groups.NODE_MODEL_ROOT)
	if root == null:
		return false
	_collect(root)
	if _legs.is_empty():
		return false
	if _body != null:
		_body_rest_y = _body.position.y
	return true


## Walk the model tree once, caching the hip pivots (and their authored rest rotations, which
## the swing is applied ON TOP of so a builder can angle a leg and keep that angle).
func _collect(n: Node) -> void:
	for c in n.get_children():
		if not (c is Node3D):
			continue
		var n3 := c as Node3D
		if str(n3.name).begins_with(LEG_PREFIX):
			_legs.append(n3)
			_rest.append(n3.rotation)
			continue
		if _body == null and n3.get_child_count() > 0:
			_body = n3  # the builder's wrapper ("Rig"), i.e. what bobs with the stride
		_collect(n3)


func _process(delta: float) -> void:
	if _e == null or _legs.is_empty() or not is_instance_valid(_e):
		return
	if GameState.phase != GameState.Phase.IN_MATCH:
		return
	var pos: Vector3 = _e.global_position
	if not _have_last:
		_last_pos = pos
		_have_last = true
		return
	var step: Vector3 = pos - _last_pos
	_last_pos = pos
	step.y = 0.0
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.global_position.distance_to(pos) > GAIT_DIST:
		_relax(delta)
		return
	# Smooth the raw per-frame delta: a physics tick that lands short would otherwise stutter.
	var inst: float = step.length() / maxf(delta, 0.0001)
	_speed = lerpf(_speed, inst, clampf(delta * SPEED_SMOOTH, 0.0, 1.0))
	var drive: float = clampf(_speed / FULL_STRIDE_SPEED, 0.0, 1.0)
	if drive < 0.02:
		_relax(delta)
		return
	_phase += step.length() * PHASE_PER_METRE
	var swing: float = SWING_MAX * drive
	for i in _legs.size():
		var leg: Node3D = _legs[i]
		if leg == null or not is_instance_valid(leg):
			continue
		# Alternating legs: every other pivot is half a cycle out of phase.
		var off: float = PI * float(i % 2)
		leg.rotation = _rest[i] + Vector3(sin(_phase + off) * swing, 0.0, 0.0)
	if _body != null and is_instance_valid(_body):
		# Twice per stride — the body rises on each footfall, not once per full cycle.
		_body.position.y = _body_rest_y + absf(sin(_phase)) * BOB_MAX * drive


## Ease the pose back to rest when the machine stops or leaves gait range, so a stopped
## enemy is not frozen mid-step.
func _relax(delta: float) -> void:
	var k: float = clampf(delta * 6.0, 0.0, 1.0)
	_speed = lerpf(_speed, 0.0, k)
	for i in _legs.size():
		var leg: Node3D = _legs[i]
		if leg != null and is_instance_valid(leg):
			leg.rotation = leg.rotation.lerp(_rest[i], k)
	if _body != null and is_instance_valid(_body):
		_body.position.y = lerpf(_body.position.y, _body_rest_y, k)
