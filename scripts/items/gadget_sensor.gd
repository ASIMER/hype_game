extends GadgetBase
class_name GadgetSensor
## Motion Sensor: a placed tripod that periodically sweeps and TAGS nearby enemies with a
## floating amber ping marker (a see-through diamond that bobs above each robot for ~1.8 s),
## plus an expanding scan-ring pulse from the sensor itself each sweep.
##
## Pure detection/visual — runs on EVERY peer (enemy positions replicate so each peer tags
## the same robots; no authority gate, no netcode). The "Head" model part spins continuously.

const HEAD_SPIN := 1.6  # rad/s the sweep head rotates
const MARKER_LIFE := 1.8  # s a ping marker lives
const MARKER_BOB_SPEED := 4.0
const MARKER_BOB_AMP := 0.12
const MARKER_HEIGHT := 2.2  # m above the enemy origin the marker floats
const RING_LIFE := 0.9  # s a scan-ring pulse expands+fades over
const RING_MAX_SCALE := 1.0  # ring grows to SENSOR_RANGE * this

var _head: Node3D = null
var _pulse_t: float = 0.0
# Active ping markers: each { "node": MeshInstance3D, "age": float, "base_y": float }.
var _markers: Array[Dictionary] = []
# Active scan rings: each { "node": MeshInstance3D, "age": float }.
var _rings: Array[Dictionary] = []
var _amber := Color(0.98, 0.72, 0.25)


func _gadget_ready() -> void:
	_gadget_type = "gadget_sensor"
	_lifetime = Settings.SENSOR_DURATION
	var model := ProceduralModels.build("gadget_sensor")
	if model != null:
		model.name = "ModelRoot"
		add_child(model)
		_head = model.get_node_or_null("Head")
	_sweep()  # ping immediately on deploy


func _gadget_tick(delta: float) -> void:
	if _head != null:
		_head.rotation.y += HEAD_SPIN * delta
	_pulse_t += delta
	if _pulse_t >= Settings.SENSOR_PULSE:
		_pulse_t = 0.0
		_sweep()
	_age_markers(delta)
	_age_rings(delta)


## One detection sweep: spawn/refresh a ping marker over every enemy in range + emit a scan
## ring from the sensor.
func _sweep() -> void:
	_spawn_ring()
	for e in get_tree().get_nodes_in_group(Groups.ENEMIES):
		if e == null or not is_instance_valid(e) or not (e is Node3D):
			continue
		var en := e as Node3D
		if global_position.distance_to(en.global_position) > Settings.SENSOR_RANGE:
			continue
		_spawn_marker(en.global_position)


## A small billboarded amber diamond that ignores depth (visible through walls) + bobs.
func _spawn_marker(world_pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()  # low-poly sphere reads as a diamond pip
	mesh.radius = 0.18
	mesh.height = 0.42
	mesh.radial_segments = 4
	mesh.rings = 2
	mi.mesh = mesh
	mi.material_override = _marker_mat()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true  # world-space placement, ignore the sensor's transform
	add_child(mi)
	var base_y := world_pos.y + MARKER_HEIGHT
	mi.global_position = Vector3(world_pos.x, base_y, world_pos.z)
	_markers.append({"node": mi, "age": 0.0, "base_y": base_y})


func _marker_mat() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(_amber.r, _amber.g, _amber.b, 0.85)
	mat.emission_enabled = true
	mat.emission = _amber
	mat.emission_energy_multiplier = 4.0
	return mat


## Bob each marker + fade it out, freeing it past MARKER_LIFE.
func _age_markers(delta: float) -> void:
	for i in range(_markers.size() - 1, -1, -1):
		var m := _markers[i]
		var node := m["node"] as MeshInstance3D
		if node == null or not is_instance_valid(node):
			_markers.remove_at(i)
			continue
		var age: float = m["age"] + delta
		m["age"] = age
		if age >= MARKER_LIFE:
			node.queue_free()
			_markers.remove_at(i)
			continue
		var base_y: float = m["base_y"]
		node.global_position.y = base_y + sin(age * MARKER_BOB_SPEED) * MARKER_BOB_AMP
		var mat := node.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color.a = 0.85 * (1.0 - age / MARKER_LIFE)


## A flat additive ring on the ground that expands to SENSOR_RANGE and fades.
func _spawn_ring() -> void:
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.85
	torus.outer_radius = 1.0
	mi.mesh = torus
	mi.rotation.x = deg_to_rad(90.0)  # lay flat
	mi.position.y = 0.1
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(_amber.r, _amber.g, _amber.b, 0.5)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_rings.append({"node": mi, "age": 0.0})


## Expand + fade each scan ring, freeing it past RING_LIFE.
func _age_rings(delta: float) -> void:
	for i in range(_rings.size() - 1, -1, -1):
		var r := _rings[i]
		var node := r["node"] as MeshInstance3D
		if node == null or not is_instance_valid(node):
			_rings.remove_at(i)
			continue
		var age: float = r["age"] + delta
		r["age"] = age
		if age >= RING_LIFE:
			node.queue_free()
			_rings.remove_at(i)
			continue
		var t := age / RING_LIFE
		var s := lerpf(1.0, Settings.SENSOR_RANGE * RING_MAX_SCALE, t)
		node.scale = Vector3(s, 1.0, s)
		var mat := node.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color.a = 0.5 * (1.0 - t)
