extends Node3D
class_name MuzzleFlash
## Brief muzzle flash: a punchy OmniLight3D pulse + an additive billboard flash sprite with a
## random roll + per-shot scale jitter (so no two flashes look identical) and a crossed streak.
## Purely visual/local — spawn one at the gun muzzle each shot and forget it.

const LIFETIME := 0.055

var pooled := false  # set by FXPool; end-of-life releases instead of freeing
var _t := 0.0
var _intensity := 1.0  # per-weapon-class size/brightness (set_intensity)
var _base_energy := 8.0
var _base_size := 0.3
var _light: OmniLight3D
var _quad: MeshInstance3D
var _streak: MeshInstance3D
var _quad_mat: StandardMaterial3D
var _streak_mat: StandardMaterial3D


func _ready() -> void:
	# Bright warm light pulse.
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.82, 0.42)
	_light.shadow_enabled = false
	add_child(_light)

	# Main flash sprite — billboarded, additive, random roll so the bloom varies per shot.
	_quad_mat = _add_mat(Color(1.0, 0.82, 0.45, 1.0))
	_quad = _make_quad(_base_size, _quad_mat)
	_quad.rotation.z = randf() * TAU
	add_child(_quad)

	# A thin crossed streak (muzzle "star") at a random angle for a gritty spark.
	_streak_mat = _add_mat(Color(1.0, 0.9, 0.6, 0.9))
	var sm := QuadMesh.new()
	sm.size = Vector2(_base_size * 2.4, _base_size * 0.18)
	_streak = MeshInstance3D.new()
	_streak.mesh = sm
	_streak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_streak.material_override = _streak_mat
	_streak.rotation.z = randf() * TAU
	add_child(_streak)

	_apply_intensity()


## Per-weapon-class size + brightness (shotgun big, SMG small/fast, DMR sharp). Called by the
## weapon right after spawn.
func set_intensity(mult: float) -> void:
	_intensity = clampf(mult, 0.4, 2.5)
	_apply_intensity()


## (Re)start the flash for a pooled reuse: reset the clock, re-randomize the roll
## (keeps the per-shot variation the one-shot path had), restore alphas.
func fire() -> void:
	_t = 0.0
	visible = true
	set_process(true)
	if _quad != null:
		_quad.rotation.z = randf() * TAU
	if _streak != null:
		_streak.rotation.z = randf() * TAU
	if _quad_mat != null:
		_quad_mat.albedo_color.a = 1.0
	if _streak_mat != null:
		_streak_mat.albedo_color.a = 0.9
	_apply_intensity()


func _apply_intensity() -> void:
	var jit := randf_range(0.85, 1.2)
	var s := _intensity * jit
	if _light != null:
		_light.light_energy = _base_energy * _intensity
		_light.omni_range = 4.0 * _intensity
	if _quad != null:
		_quad.scale = Vector3(s, s, s)
	if _streak != null:
		_streak.scale = Vector3(s, s, s)


func _make_quad(sz: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = Vector2(sz, sz)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = mat
	return mi


func _add_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = col
	m.disable_receive_shadows = true
	return m


func _process(delta: float) -> void:
	_t += delta
	var k := clampf(_t / LIFETIME, 0.0, 1.0)
	if _light != null:
		_light.light_energy = lerpf(_base_energy * _intensity, 0.0, k)
	if _quad_mat != null:
		_quad_mat.albedo_color.a = 1.0 - k
	if _streak_mat != null:
		_streak_mat.albedo_color.a = (1.0 - k) * 0.9
	if _quad != null:
		var s := _intensity * (1.0 + k * 0.7)
		_quad.scale = Vector3(s, s, s)
	if _t >= LIFETIME:
		if pooled and FXPool.active != null:
			FXPool.active.release(self)
		else:
			queue_free()
