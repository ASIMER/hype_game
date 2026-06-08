extends Node3D
class_name Tracer
## A thin bright beam drawn from the muzzle to the hit point, fading out over
## ~0.07s then freeing. Purely visual/local — never networked. Set the endpoints
## with setup() BEFORE adding to the tree (or any time after _ready()).

const LIFETIME := 0.09

var _t := 0.0
var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _has_endpoints := false
var _mesh_inst: MeshInstance3D
var _mat: StandardMaterial3D

## Endpoints in WORLD space. Safe to call before or after _ready().
func setup(from_world: Vector3, to_world: Vector3) -> void:
	_from = from_world
	_to = to_world
	_has_endpoints = true
	if is_inside_tree():
		_rebuild()

func _ready() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.022
	cyl.bottom_radius = 0.022
	cyl.height = 1.0
	cyl.radial_segments = 6
	cyl.rings = 0
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.mesh = cyl
	_mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat.albedo_color = Color(1.0, 0.92, 0.62, 1.0)
	_mat.emission_enabled = true
	_mat.emission = Color(1.0, 0.8, 0.4)
	_mat.emission_energy_multiplier = 2.0
	_mat.disable_receive_shadows = true
	_mesh_inst.material_override = _mat
	add_child(_mesh_inst)
	if _has_endpoints:
		_rebuild()

## Orient and stretch the unit cylinder (default axis +Y) between the two points.
func _rebuild() -> void:
	if _mesh_inst == null:
		return
	var dir := _to - _from
	var dist := dir.length()
	if dist < 0.0001:
		_mesh_inst.visible = false
		return
	_mesh_inst.visible = true
	var mid := (_from + _to) * 0.5
	var up := dir.normalized()
	# Build an orthonormal basis with +Y aligned to the beam direction.
	var arbitrary := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD
	var x := arbitrary.cross(up).normalized()
	var z := x.cross(up).normalized()
	var basis := Basis(x, up, z)
	basis = basis.scaled(Vector3(1.0, dist, 1.0))
	_mesh_inst.global_transform = Transform3D(basis, mid)

func _process(delta: float) -> void:
	_t += delta
	var k := clampf(_t / LIFETIME, 0.0, 1.0)
	if _mat:
		_mat.albedo_color.a = 1.0 - k
	if _t >= LIFETIME:
		queue_free()
