extends Node3D
class_name SmokeCloud
## A lingering smoke volume spawned by a Smoke Grenade. Purely local FX + a
## group node the AI segment-tests for line-of-sight blocking: it lives in group
## Groups.SMOKE and exposes `var radius` (metres). The enemy perception code
## checks whether a LOS ray passes within `radius` of `global_position`.
##
## Never networked — the smoke grenade is spawned on every peer, so each peer
## builds its own deterministic cloud. Lifetime is delta-accumulated (NOT a
## SceneTreeTimer) so it survives engine pauses cleanly.

const _FADE_TIME := 1.0  # seconds of alpha fade-out before freeing
const _SPHERE_ALPHA := 0.25  # base opacity of the volume shell

## LOS-blocking sphere radius (m). FROZEN contract consumed by the enemy AI.
var radius: float = Settings.SMOKE_RADIUS

var _t := 0.0
var _shell_mat: StandardMaterial3D
var _particles: GPUParticles3D


func _ready() -> void:
	add_to_group(Groups.SMOKE)
	_build_shell()
	_build_particles()


# A large translucent unshaded sphere so the volume reads as a solid bank from a
# distance (the particles alone get sparse far away).
func _build_shell() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 10
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell_mat = StandardMaterial3D.new()
	_shell_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shell_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shell_mat.albedo_color = Color(0.62, 0.63, 0.64, _SPHERE_ALPHA)
	# Draw both faces so the player inside still sees the murk.
	_shell_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = _shell_mat
	add_child(mesh)


# Soft grey billboard puffs filling the sphere so the cloud churns and reads as
# volumetric up close.
func _build_particles() -> void:
	_particles = GPUParticles3D.new()
	_particles.amount = 120
	_particles.lifetime = 2.5
	_particles.preprocess = 1.0  # start already filled, no ramp-up pop
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius * 0.85
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.1
	pm.initial_velocity_max = 0.5
	pm.gravity = Vector3(0, 0.2, 0)
	pm.scale_min = 2.5
	pm.scale_max = 5.0
	pm.color = Color(0.6, 0.61, 0.62, 0.35)
	_particles.process_material = pm
	var puff := SphereMesh.new()
	puff.radius = 0.1
	puff.height = 0.2
	puff.radial_segments = 6
	puff.rings = 3
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.albedo_color = Color(0.6, 0.61, 0.62, 0.35)
	puff.material = puff_mat
	_particles.draw_pass_1 = puff
	add_child(_particles)
	_particles.emitting = true


func _physics_process(delta: float) -> void:
	_t += delta
	# Hold full opacity for the active life, then fade the shell + stop emitting.
	if _t >= Settings.SMOKE_DURATION:
		if _particles and _particles.emitting:
			_particles.emitting = false
		var fade_k := clampf((_t - Settings.SMOKE_DURATION) / _FADE_TIME, 0.0, 1.0)
		if _shell_mat:
			_shell_mat.albedo_color.a = lerpf(_SPHERE_ALPHA, 0.0, fade_k)
		if fade_k >= 1.0:
			queue_free()
