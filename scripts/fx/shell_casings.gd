extends Node3D
class_name ShellCasings
## A few tiny brass casings flung out the gun's side ejection port each shot — tumble with
## gravity and fade after ~1.5 s. The node's global_transform is set to the weapon's "Eject"
## marker, so +X is the gun's right and -Z is forward; casings eject right + up + slightly back.
## One-shot GPUParticles3D; frees itself. Local/visual.

const LIFETIME := 1.5

var pooled := false  # set by FXPool; end-of-life releases instead of freeing
var _t := 0.0
var _ps: GPUParticles3D


func _ready() -> void:
	var ps := GPUParticles3D.new()
	ps.one_shot = true
	ps.explosiveness = 1.0
	ps.amount = 3
	ps.lifetime = LIFETIME
	ps.local_coords = false

	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(1.0, 0.55, 0.25)  # right + up + slightly back (gun-local)
	pm.spread = 18.0
	pm.gravity = Vector3(0, -9.8, 0)
	pm.initial_velocity_min = 1.8
	pm.initial_velocity_max = 3.2
	pm.angular_velocity_min = -720.0  # tumble
	pm.angular_velocity_max = 720.0
	pm.scale_min = 0.9
	pm.scale_max = 1.1
	# Brass, dimming at the end.
	var grad := Gradient.new()
	grad.set_color(0, Color(0.72, 0.55, 0.22, 1.0))
	grad.add_point(0.8, Color(0.6, 0.45, 0.18, 1.0))
	grad.set_color(1, Color(0.5, 0.38, 0.15, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	ps.process_material = pm

	# A tiny elongated brass casing.
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.012
	mesh.bottom_radius = 0.012
	mesh.height = 0.05
	mesh.radial_segments = 6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.55, 0.22)
	mat.metallic = 0.8
	mat.roughness = 0.35
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	ps.draw_pass_1 = mesh
	add_child(ps)
	ps.emitting = true
	_ps = ps


## (Re)start the brass burst for a pooled reuse.
func fire() -> void:
	_t = 0.0
	visible = true
	set_process(true)
	if _ps != null:
		_ps.restart()


## Delta-accumulated end-of-life (was a per-shot create_timer). Pooled instances
## return to the pool, standalone ones free.
func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFETIME + 0.3:
		if pooled and FXPool.active != null:
			FXPool.active.release(self)
		else:
			queue_free()
