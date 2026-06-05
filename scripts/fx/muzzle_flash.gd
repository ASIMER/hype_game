extends Node3D
class_name MuzzleFlash
## Brief muzzle flash: a short OmniLight3D pulse plus a small additive emissive
## quad that scales/fades, then frees itself after ~0.06s. Purely visual/local —
## never networked. Spawn one at the weapon muzzle each shot and forget it.

const LIFETIME := 0.06

var _t := 0.0
var _light: OmniLight3D
var _quad: MeshInstance3D
var _quad_mat: StandardMaterial3D

func _ready() -> void:
	# Light pulse — gives nearby surfaces a quick kick of light.
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.85, 0.45)
	_light.light_energy = 6.0
	_light.omni_range = 4.0
	_light.shadow_enabled = false
	add_child(_light)

	# Additive emissive quad facing outward, billboarded so it always reads.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.35, 0.35)
	_quad = MeshInstance3D.new()
	_quad.mesh = quad
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad_mat = StandardMaterial3D.new()
	_quad_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_quad_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_quad_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_quad_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_quad_mat.albedo_color = Color(1.0, 0.8, 0.4, 1.0)
	_quad_mat.disable_receive_shadows = true
	_quad.material_override = _quad_mat
	add_child(_quad)

func _process(delta: float) -> void:
	_t += delta
	var k := clampf(_t / LIFETIME, 0.0, 1.0)
	# Light decays fast; quad expands slightly and fades out.
	if _light:
		_light.light_energy = lerpf(6.0, 0.0, k)
	if _quad_mat:
		_quad_mat.albedo_color.a = 1.0 - k
	if _quad:
		var s := 1.0 + k * 0.6
		_quad.scale = Vector3(s, s, s)
	if _t >= LIFETIME:
		queue_free()
