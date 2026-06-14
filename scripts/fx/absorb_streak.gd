extends Node3D
## Homing "absorb" streak: a small copy of the dead enemy's signature part flies from the corpse
## to the killer's back over ~0.4s on a lofted arc, then a weld FLASH as it lands and shrinks in
## (the back cluster grows from the replicated `absorbed` dict at the same beat). Render-only,
## per-peer, self-freeing. Spawned by AbsorbDirector on every peer off Events.enemy_absorbed.

const _ABS := preload("res://scripts/visual/procedural_absorbed.gd")
const LIFE := 0.42

var _start: Vector3 = Vector3.ZERO
var _target: Node3D = null
var _t: float = 0.0
var _mesh: Node3D = null
var _light: OmniLight3D = null


## Configure + arm the streak (called right after add_child, before the first _process).
func setup(start: Vector3, target: Node3D, color: Color, token: String) -> void:
	_start = start
	_target = target
	global_position = start
	_mesh = _ABS.build_part_node(token, color)
	_mesh.scale = Vector3.ONE * 0.85
	add_child(_mesh)
	_light = OmniLight3D.new()
	_light.light_color = color
	_light.light_energy = 2.2
	_light.omni_range = 2.4
	add_child(_light)


func _target_point() -> Vector3:
	if is_instance_valid(_target):
		return _target.global_position + Vector3(0.0, 1.4, 0.0)
	return _start  # target gone → collapse in place


func _process(delta: float) -> void:
	_t += delta / LIFE
	if _mesh != null:
		_mesh.rotate_y(delta * 12.0)
	if _t >= 1.0:
		_land()
		return
	var dest: Vector3 = _target_point()
	var mid: Vector3 = _start.lerp(dest, 0.5) + Vector3(0.0, 2.5, 0.0)  # lofted control point
	# Quadratic Bezier(start, control=mid, dest).
	var a: Vector3 = _start.lerp(mid, _t)
	var b: Vector3 = mid.lerp(dest, _t)
	global_position = a.lerp(b, _t)


func _land() -> void:
	set_process(false)
	global_position = _target_point()
	if _light != null:
		_light.light_energy = 6.0
		_light.omni_range = 3.2
	# Weld pop: shrink to nothing as the cluster part appears, then free.
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3.ZERO, 0.14)
	tw.tween_callback(queue_free)
