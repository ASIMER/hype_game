extends Node3D
class_name RobotDebris
## A one-shot physics burst spawned at a robot's transform on death: several
## RigidBody3D box chunks fly outward with random impulse + torque, plus a smoke
## puff. Chunks fade and the whole node frees after LIFETIME. Purely visual/local
## — never networked (clients each spawn their own on the death event).
##
## Optional: call setup(scale, tint) BEFORE adding to the tree so big/special
## enemies make bigger / differently-coloured debris.

const LIFETIME := 3.0
const FADE_START := 2.0  # chunks begin fading at this age
const CHUNK_COUNT := 11

var _t := 0.0
var _scale := 1.0
var _tint := Color(0.55, 0.57, 0.6)  # default robot grey
var _chunks: Array[MeshInstance3D] = []
var _mats: Array[StandardMaterial3D] = []
var _smoke: GPUParticles3D


## scale multiplies chunk size + spread; tint colours the metal chunks.
func setup(scale: float, tint: Color = Color(0.55, 0.57, 0.6)) -> void:
	_scale = maxf(0.2, scale)
	_tint = tint


func _ready() -> void:
	_spawn_chunks()
	_spawn_smoke()
	_spawn_embers()


func _spawn_chunks() -> void:
	for i in CHUNK_COUNT:
		var body := RigidBody3D.new()
		body.gravity_scale = 1.4
		body.mass = 0.4 * _scale
		body.continuous_cd = false
		body.can_sleep = true
		# Collide with the world only; ignore players/enemies/each other so chunks
		# can't shove gameplay bodies around. Layer 0 = no layer (nothing hits us).
		body.collision_layer = 0
		body.collision_mask = 1

		# Slightly varied box sizes per chunk for a broken-apart look.
		var sx := randf_range(0.12, 0.28) * _scale
		var sy := randf_range(0.12, 0.28) * _scale
		var sz := randf_range(0.12, 0.28) * _scale

		var box := BoxMesh.new()
		box.size = Vector3(sx, sy, sz)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = _tint
		mat.metallic = 0.7
		mat.roughness = 0.4
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		box.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(mi)

		var shape := BoxShape3D.new()
		shape.size = Vector3(sx, sy, sz)
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)

		# Start just above the origin, scattered a little in the XZ plane.
		body.position = Vector3(
			randf_range(-0.2, 0.2) * _scale,
			randf_range(0.4, 1.0) * _scale,
			randf_range(-0.2, 0.2) * _scale
		)
		add_child(body)

		# Burst outward + up, with a random tumble. Each chunk differs.
		var dir := (
			Vector3(randf_range(-1.0, 1.0), randf_range(0.4, 1.2), randf_range(-1.0, 1.0))
			. normalized()
		)
		var power := randf_range(2.5, 5.0) * _scale
		body.apply_impulse(dir * power)
		body.angular_velocity = Vector3(
			randf_range(-8.0, 8.0), randf_range(-8.0, 8.0), randf_range(-8.0, 8.0)
		)

		_chunks.append(mi)
		_mats.append(mat)


func _spawn_smoke() -> void:
	_smoke = GPUParticles3D.new()
	_smoke.one_shot = true
	_smoke.explosiveness = 0.7
	_smoke.amount = 14
	_smoke.lifetime = 1.2
	_smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 80.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 2.0 * _scale
	pm.gravity = Vector3(0, 0.5, 0)
	pm.scale_min = 1.5 * _scale
	pm.scale_max = 3.5 * _scale
	pm.color = Color(0.1, 0.09, 0.08, 0.7)
	_smoke.process_material = pm
	var puff := SphereMesh.new()
	puff.radius = 0.08
	puff.height = 0.16
	puff.radial_segments = 6
	puff.rings = 3
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.albedo_color = Color(0.1, 0.09, 0.08, 0.7)
	puff.material = puff_mat
	_smoke.draw_pass_1 = puff
	_smoke.position = Vector3(0, 0.6 * _scale, 0)
	add_child(_smoke)
	_smoke.emitting = true


## A quick burst of bright, enemy-tinted embers that arc out and fall — adds spark
## "juice" on top of the grey chunks + smoke. Short-lived + unshaded so it glows.
func _spawn_embers() -> void:
	var embers := GPUParticles3D.new()
	embers.one_shot = true
	embers.explosiveness = 1.0
	embers.amount = int(round(16 * _scale))
	embers.lifetime = 0.7
	embers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var em := ParticleProcessMaterial.new()
	em.direction = Vector3(0, 1, 0)
	em.spread = 180.0
	em.initial_velocity_min = 2.5 * _scale
	em.initial_velocity_max = 7.0 * _scale
	em.gravity = Vector3(0, -10.0, 0)
	em.scale_min = 0.5
	em.scale_max = 1.2
	# Brighten the body tint so embers read as hot sparks, not dull paint.
	em.color = _tint.lerp(Color(1.0, 0.85, 0.4), 0.5)
	embers.process_material = em
	var dot := SphereMesh.new()
	dot.radius = 0.045 * _scale
	dot.height = 0.09 * _scale
	dot.radial_segments = 6
	dot.rings = 3
	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.albedo_color = em.color
	dot.material = dot_mat
	embers.draw_pass_1 = dot
	embers.position = Vector3(0, 0.6 * _scale, 0)
	add_child(embers)
	embers.emitting = true


func _process(delta: float) -> void:
	_t += delta
	if _t >= FADE_START:
		var fk := clampf((_t - FADE_START) / (LIFETIME - FADE_START), 0.0, 1.0)
		var a := 1.0 - fk
		for mat in _mats:
			if mat:
				mat.albedo_color.a = a
	if _t >= LIFETIME:
		queue_free()
