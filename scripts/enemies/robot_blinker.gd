extends RobotGunner
class_name RobotBlinker
## RAIN RAIJU — a storm-spirit skirmisher. Fires the inherited hitscan and, on a
## cooldown while fighting, BLINKS: a short instant sideways teleport (4-6 m on the
## tangent around the target, snapped to the navmesh) that makes it maddening to
## track. The teleport is just a server-side position write — it replicates through
## the standard synchronizer like any movement.

var _blink_range: float = 5.0
var _blink_cooldown: float = 3.0
var _blink_cd: float = 0.0
var _blink_side: float = 1.0

# Visual: antler arcs pulse.
var _antlers: Array[Node3D] = []


func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	_blink_range = float(stats.get("blink_range", _blink_range))
	_blink_cooldown = float(stats.get("blink_cooldown", _blink_cooldown))
	_blink_cd = _blink_cooldown * 0.5


## OVERRIDE: tick the blink while fighting; blink sideways when ready.
func _do_attack(delta: float) -> void:
	_tick_blink(delta)
	super._do_attack(delta)


func _do_chase(delta: float) -> void:
	_tick_blink(delta)
	super._do_chase(delta)


func _tick_blink(delta: float) -> void:
	if _blink_cd > 0.0:
		_blink_cd -= delta
		return
	if _target == null or not is_instance_valid(_target):
		return
	# Tangential hop around the target (alternating sides), kept on the navmesh.
	var radial := global_position - _target.global_position
	radial.y = 0.0
	if radial.length() < 0.01:
		return
	radial = radial.normalized()
	var tangent := Vector3(-radial.z, 0.0, radial.x) * _blink_side
	_blink_side = -_blink_side
	var hop := global_position + tangent * randf_range(_blink_range * 0.8, _blink_range * 1.2)
	var snapped := _snap_to_navmesh(hop)
	if snapped == Vector3.ZERO or snapped.distance_to(global_position) < 1.0:
		_blink_cd = 0.6  # bad spot — retry soon
		return
	global_position = snapped
	velocity = Vector3.ZERO
	_blink_cd = _blink_cooldown
	if _target and is_instance_valid(_target):
		_face_towards(_target.global_position, 1.0)


## OVERRIDE: cache the antler pivots + the electric core.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	for i in 2:
		var ant := asm.find_child("Antler%d" % i, true, false)
		if ant is Node3D:
			_antlers.append(ant as Node3D)
	var core := asm.find_child("Core", true, false)
	if core is MeshInstance3D:
		_pulse_part = core as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(core as MeshInstance3D)
	_has_proc_anim = not _antlers.is_empty() or _pulse_part != null


## OVERRIDE: crackling pulse — fast flicker (storm-spirit energy), antlers quiver.
func _animate_visual(_delta: float) -> void:
	for i in _antlers.size():
		var ant := _antlers[i]
		if ant and is_instance_valid(ant):
			ant.rotation.z = sin(_anim_time * 11.0 + float(i) * PI) * 0.06
	var atk := current_state == State.ATTACK
	_pulse_emission(0.5, 1.8, 12.0 if atk else 6.0)
