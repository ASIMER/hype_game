extends Node3D
class_name MuzzleSmoke
## A faint little grey smoke wisp off the muzzle each shot — drifts up, fades over ~0.7s.
## Deliberately small + low-alpha so it never walls the (first-person) view. One-shot
## GPUParticles3D; frees itself. Local/visual.

const LIFETIME := 0.7

var _ps: GPUParticles3D
var _scale_mult := 1.0


func _ready() -> void:
	_ps = GPUParticles3D.new()
	_ps.one_shot = true
	_ps.explosiveness = 0.7
	_ps.amount = 5
	_ps.lifetime = LIFETIME
	_ps.local_coords = false

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.03
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 30.0
	pm.gravity = Vector3(0, 0.5, 0)
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.55
	pm.damping_min = 0.4
	pm.damping_max = 0.9
	pm.scale_min = 0.5 * _scale_mult
	pm.scale_max = 1.0 * _scale_mult
	pm.color = Color(0.6, 0.6, 0.62, 0.22)  # faint grey
	_ps.process_material = pm

	# Small billboard quad (0.12 m base) so even at full scale it's a wisp, not a wall.
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.16, 0.16)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.6, 0.6, 0.62, 0.22)
	mat.disable_receive_shadows = true
	mesh.material = mat
	_ps.draw_pass_1 = mesh
	add_child(_ps)
	_ps.emitting = true

	get_tree().create_timer(LIFETIME + 0.4).timeout.connect(queue_free)


func set_scale_mult(m: float) -> void:
	_scale_mult = clampf(m, 0.4, 2.0)
	if _ps != null and _ps.process_material is ParticleProcessMaterial:
		var pm := _ps.process_material as ParticleProcessMaterial
		pm.scale_min = 0.5 * _scale_mult
		pm.scale_max = 1.0 * _scale_mult
