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

const LIFETIME := 0.7    # outlive the longest burst (smoke 0.6 / debris 0.55)
const DECAL_LIFETIME := 4.0

var _t := 0.0
var _enemy := false
var _particles: GPUParticles3D
var _smoke: GPUParticles3D          # enemy-only oil/smoke puff
var _debris: GPUParticles3D         # enemy-only chunky metal shards
var _flash: MeshInstance3D
var _flash_mat: StandardMaterial3D
var _decal: Decal                   # world-only scorch mark
var _decal_t := 0.0
# Surface normal (world space) of the hit, used to orient the burst so sparks
# spray OUT of the surface rather than always straight up. Vector3.ZERO = unknown.
var _normal: Vector3 = Vector3.ZERO

## true -> orange/yellow sparks + oil puff (enemy), false -> grey dust + scorch (world).
func set_enemy_hit(is_enemy: bool) -> void:
	_enemy = is_enemy
	if is_inside_tree():
		_apply_tint()
		_apply_mode()

## Orient the burst to the hit surface normal (world space). Call before/after
## entering the tree; re-applied in _ready. Vector3.ZERO leaves the default (+Y).
func set_surface_normal(normal: Vector3) -> void:
	_normal = normal
	if is_inside_tree():
		_apply_normal()

func _ready() -> void:
	var tint := _tint()

	_particles = GPUParticles3D.new()
	_particles.one_shot = true
	_particles.explosiveness = 1.0
	# Punchier spark burst: more sparks, snappier, flung harder than before.
	_particles.amount = 28 if _enemy else 16
	_particles.lifetime = 0.45
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 3.0 if _enemy else 1.8
	pm.initial_velocity_max = 8.0 if _enemy else 4.0
	pm.gravity = Vector3(0, -8.0, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.4 if _enemy else 1.0
	pm.color = tint
	_particles.process_material = pm

	var dot := SphereMesh.new()
	dot.radius = 0.035
	dot.height = 0.07
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

	# Enemy-only chunky metal debris: a few heavier shards that arc out and fall,
	# selling a robot taking a solid hit. Cheap (small amount, short life).
	_debris = GPUParticles3D.new()
	_debris.one_shot = true
	_debris.explosiveness = 1.0
	_debris.amount = 6
	_debris.lifetime = 0.55
	_debris.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dbm := ParticleProcessMaterial.new()
	dbm.direction = Vector3(0, 1, 0)
	dbm.spread = 120.0
	dbm.initial_velocity_min = 2.5
	dbm.initial_velocity_max = 6.0
	dbm.gravity = Vector3(0, -14.0, 0)
	dbm.angular_velocity_min = -720.0
	dbm.angular_velocity_max = 720.0
	dbm.scale_min = 0.6
	dbm.scale_max = 1.3
	dbm.color = Color(0.55, 0.5, 0.45)
	_debris.process_material = dbm
	var chunk := BoxMesh.new()
	chunk.size = Vector3(0.05, 0.05, 0.05)
	var chunk_mat := StandardMaterial3D.new()
	chunk_mat.albedo_color = Color(0.45, 0.42, 0.38)
	chunk.material = chunk_mat
	_debris.draw_pass_1 = chunk
	add_child(_debris)
	_debris.emitting = false

	# Brief central flash so the impact reads even before particles travel.
	var fq := QuadMesh.new()
	fq.size = Vector2(0.5, 0.5) if _enemy else Vector2(0.28, 0.28)
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
	_apply_normal()

func _tint() -> Color:
	return Color(1.0, 0.7, 0.25) if _enemy else Color(0.7, 0.68, 0.62)

func _apply_tint() -> void:
	var tint := _tint()
	if _flash_mat:
		_flash_mat.albedo_color = tint
	if _particles and _particles.process_material is ParticleProcessMaterial:
		(_particles.process_material as ParticleProcessMaterial).color = tint

## Re-orient the spark/debris emitters so the burst sprays OUT of the hit surface
## (along its normal) instead of always straight up. No-op for an unknown normal.
func _apply_normal() -> void:
	if _normal.length() < 0.001:
		return
	var n := _normal.normalized()
	if _particles and _particles.process_material is ParticleProcessMaterial:
		(_particles.process_material as ParticleProcessMaterial).direction = n
	if _debris and _debris.process_material is ParticleProcessMaterial:
		(_debris.process_material as ParticleProcessMaterial).direction = n

## Toggle the enemy oil puff + debris vs the world scorch decal based on _enemy.
func _apply_mode() -> void:
	if _smoke:
		_smoke.emitting = _enemy
	if _debris:
		_debris.emitting = _enemy
	# World hits: drop a fading scorch decal projected onto the surface below.
	if not _enemy and _decal == null:
		_decal = Decal.new()
		_decal.size = Vector3(0.8, 0.8, 0.8)   # extents box the projection (bigger puff/scorch)
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
	# Flash lives only for the first ~0.1s; enemy hits start brighter (1.6) so the
	# additive sprite punches harder before fading out.
	if _flash_mat:
		var dur := 0.1 if _enemy else 0.08
		var fk := clampf(_t / dur, 0.0, 1.0)
		var peak := 1.6 if _enemy else 1.0
		_flash_mat.albedo_color.a = peak * (1.0 - fk)
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
