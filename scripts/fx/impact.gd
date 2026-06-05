extends Node3D
class_name Impact
## A small one-shot burst at a hit point: GPUParticles3D sparks plus a quick
## emissive flash, auto-frees when finished. Purely visual/local — never
## networked. Call set_enemy_hit(true) before adding to the tree to switch from
## dusty world-impact to bright enemy sparks.
##
## Enemy hits add a second, slower "oil/smoke" puff so robot hits read as a
## meaty spray of sparks + dark mist. World hits leave a short-lived dark Decal
## scorch on the surface below (projected down -Y, the common floor/ground case),
## which fades over a few seconds before freeing.

const LIFETIME := 0.5
const DECAL_LIFETIME := 4.0

var _t := 0.0
var _enemy := false
var _particles: GPUParticles3D
var _smoke: GPUParticles3D          # enemy-only oil/smoke puff
var _flash: MeshInstance3D
var _flash_mat: StandardMaterial3D
var _decal: Decal                   # world-only scorch mark
var _decal_t := 0.0

## true -> orange/yellow sparks + oil puff (enemy), false -> grey dust + scorch (world).
func set_enemy_hit(is_enemy: bool) -> void:
	_enemy = is_enemy
	if is_inside_tree():
		_apply_tint()
		_apply_mode()

func _ready() -> void:
	var tint := _tint()

	_particles = GPUParticles3D.new()
	_particles.one_shot = true
	_particles.explosiveness = 1.0
	_particles.amount = 12
	_particles.lifetime = 0.4
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 3.5
	pm.gravity = Vector3(0, -6.0, 0)
	pm.scale_min = 0.4
	pm.scale_max = 1.0
	pm.color = tint
	_particles.process_material = pm

	var dot := SphereMesh.new()
	dot.radius = 0.03
	dot.height = 0.06
	dot.radial_segments = 6
	dot.rings = 3
	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.albedo_color = tint
	dot.material = dot_mat
	_particles.draw_pass_1 = dot
	add_child(_particles)
	_particles.emitting = true

	# Slow, dark oil/smoke puff — created lazily, only shown for enemy hits.
	_smoke = GPUParticles3D.new()
	_smoke.one_shot = true
	_smoke.explosiveness = 0.85
	_smoke.amount = 8
	_smoke.lifetime = 0.6
	_smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := ParticleProcessMaterial.new()
	sm.direction = Vector3(0, 1, 0)
	sm.spread = 60.0
	sm.initial_velocity_min = 0.4
	sm.initial_velocity_max = 1.2
	sm.gravity = Vector3(0, 0.6, 0)        # smoke drifts up slightly
	sm.scale_min = 1.2
	sm.scale_max = 2.4
	sm.color = Color(0.08, 0.07, 0.06, 0.7)
	_smoke.process_material = sm
	var puff := SphereMesh.new()
	puff.radius = 0.06
	puff.height = 0.12
	puff.radial_segments = 6
	puff.rings = 3
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.albedo_color = Color(0.08, 0.07, 0.06, 0.7)
	puff.material = puff_mat
	_smoke.draw_pass_1 = puff
	add_child(_smoke)
	_smoke.emitting = false

	# Brief central flash so the impact reads even before particles travel.
	var fq := QuadMesh.new()
	fq.size = Vector2(0.25, 0.25)
	_flash = MeshInstance3D.new()
	_flash.mesh = fq
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_flash_mat.albedo_color = tint
	_flash.material_override = _flash_mat
	add_child(_flash)

	_apply_mode()

func _tint() -> Color:
	return Color(1.0, 0.7, 0.25) if _enemy else Color(0.7, 0.68, 0.62)

func _apply_tint() -> void:
	var tint := _tint()
	if _flash_mat:
		_flash_mat.albedo_color = tint
	if _particles and _particles.process_material is ParticleProcessMaterial:
		(_particles.process_material as ParticleProcessMaterial).color = tint

## Toggle the enemy oil puff vs the world scorch decal based on _enemy.
func _apply_mode() -> void:
	if _smoke:
		_smoke.emitting = _enemy
	# World hits: drop a fading scorch decal projected onto the surface below.
	if not _enemy and _decal == null:
		_decal = Decal.new()
		_decal.size = Vector3(0.6, 0.6, 0.6)   # extents box the projection
		_decal.albedo_mix = 1.0
		_decal.modulate = Color(0.05, 0.05, 0.05, 0.85)
		_decal.texture_albedo = _scorch_texture()
		# Project straight down so it lands on the floor under the hit point.
		add_child(_decal)
	elif _enemy and _decal:
		_decal.queue_free()
		_decal = null

## A soft radial dark blob used as the scorch albedo. Built once per impact;
## cheap (16x16) and good enough for a quick fading mark.
func _scorch_texture() -> ImageTexture:
	var size := 16
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size * 0.5, size * 0.5)
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / (size * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)

func _process(delta: float) -> void:
	_t += delta
	# Flash lives only for the first ~0.08s.
	if _flash_mat:
		var fk := clampf(_t / 0.08, 0.0, 1.0)
		_flash_mat.albedo_color.a = 1.0 - fk
	# Scorch decal lingers and fades over DECAL_LIFETIME, outliving the sparks.
	if _decal:
		_decal_t += delta
		var dk := clampf(_decal_t / DECAL_LIFETIME, 0.0, 1.0)
		_decal.modulate.a = 0.85 * (1.0 - dk)
		if _decal_t >= DECAL_LIFETIME:
			_decal.queue_free()
			_decal = null
	# Keep the node alive while either the burst or its decal still has work.
	if _t >= LIFETIME and _decal == null:
		queue_free()
