extends Node3D
class_name GlassShatter
## One-shot window-shatter burst: a box of falling glass shards sized to the pane
## (set_pane) plus a brief additive glint so the break reads at distance. Pooled via
## FXPool ("glass_shatter" kind) — same contract as Impact: `pooled` flag, fire() to
## (re)start, end-of-life releases back to the pool. Purely visual/local.

const LIFETIME := 0.9  # outlives the shard fall (0.6 lifetime + spawn spread)

var pooled := false  # set by FXPool; end-of-life releases instead of freeing
var _t := 0.0
var _shards: GPUParticles3D
var _shard_mat: ParticleProcessMaterial
var _glint: MeshInstance3D
var _glint_mat: StandardMaterial3D


func _ready() -> void:
	_shards = GPUParticles3D.new()
	_shards.one_shot = true
	_shards.explosiveness = 1.0
	_shards.amount = 24
	_shards.lifetime = 0.6
	_shards.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_shard_mat = ParticleProcessMaterial.new()
	_shard_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_shard_mat.emission_box_extents = Vector3(0.5, 0.5, 0.04)
	_shard_mat.direction = Vector3(0, 0, 1)
	_shard_mat.spread = 180.0
	_shard_mat.initial_velocity_min = 1.5
	_shard_mat.initial_velocity_max = 4.0
	_shard_mat.gravity = Vector3(0, -12.0, 0)
	_shard_mat.angular_velocity_min = -540.0
	_shard_mat.angular_velocity_max = 540.0
	_shard_mat.scale_min = 0.6
	_shard_mat.scale_max = 1.2
	_shard_mat.color = Color(0.75, 0.85, 0.95, 0.85)
	_shards.process_material = _shard_mat

	var quad := QuadMesh.new()
	quad.size = Vector2(0.06, 0.09)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.albedo_color = Color(0.78, 0.88, 0.98, 0.85)
	qm.vertex_color_use_as_albedo = true
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	qm.billboard_keep_scale = true
	quad.material = qm
	_shards.draw_pass_1 = quad
	add_child(_shards)
	_shards.emitting = false

	# Brief additive glint at the pane centre so the break reads even at distance.
	var gq := QuadMesh.new()
	gq.size = Vector2(0.7, 0.7)
	_glint = MeshInstance3D.new()
	_glint.mesh = gq
	_glint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glint_mat = StandardMaterial3D.new()
	_glint_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glint_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glint_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_glint_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_glint_mat.albedo_color = Color(0.85, 0.92, 1.0, 1.0)
	_glint.material_override = _glint_mat
	add_child(_glint)


## Size the shard emission box to the breaking pane (full opening rains shards).
func set_pane(size: Vector3) -> void:
	if _shard_mat != null:
		_shard_mat.emission_box_extents = Vector3(
			maxf(size.x * 0.5, 0.1), maxf(size.y * 0.5, 0.1), maxf(size.z * 0.5, 0.03)
		)


## (Re)start at the current transform/config — the pool calls this on every reuse.
func fire() -> void:
	_t = 0.0
	visible = true
	set_process(true)
	if _glint_mat != null:
		_glint_mat.albedo_color.a = 1.0
	if _shards != null:
		_shards.restart()


func _process(delta: float) -> void:
	_t += delta
	if _glint_mat != null:
		_glint_mat.albedo_color.a = maxf(0.0, 1.0 - _t / 0.12)
	if _t >= LIFETIME:
		_finish()


func _finish() -> void:
	if pooled and FXPool.active != null:
		FXPool.active.release(self)
	else:
		queue_free()
