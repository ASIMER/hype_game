extends Node3D
class_name WorldAtmosphere
## Ambient mood for the urban-ruins map: slow-drifting dust motes + a few warm
## rising embers, plus the day->storm visual transition driven by
## Events.final_wave_started. Procedural — zero external assets.
##
## Instanced into world_root by main.gd (non-headless, guarded). On _ready it
## finds the active WorldEnvironment + the scene's DirectionalLight3D at runtime
## (never references Arena.tscn) and, on the final wave, tweens the sky shader's
## `storm` uniform, fog, ambient light and the sun into a stormy look.

const MAP_HALF := 80.0          # 160x160 map -> +/-80
const DUST_BOX := Vector3(160.0, 30.0, 160.0)

var _dust: GPUParticles3D
var _embers: GPUParticles3D
var _ember_mat: ParticleProcessMaterial
var _dust_mat: ParticleProcessMaterial

var _env: Environment
var _sky_mat: ShaderMaterial
var _sun: DirectionalLight3D

# Captured baseline (day) values so a fresh match can be reset, and so the tween
# always lerps from the real defaults rather than whatever the last run left.
var _base_ambient := 0.7
var _base_fog_density := 0.0022
var _base_fog_color := Color(0.46, 0.48, 0.52, 1)
var _base_glow := 0.7
var _base_sun_energy := 1.0
var _base_sun_rot := Vector3.ZERO
var _captured := false

var _storm_tween: Tween
var _stormed := false

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_build_dust()
	_build_embers()
	_find_env_and_light()
	_capture_baseline()
	# If the match somehow already flipped to the final wave before we loaded.
	if GameState and GameState.final_wave:
		_apply_storm_instant()
	if Events and not Events.final_wave_started.is_connected(_on_final_wave):
		Events.final_wave_started.connect(_on_final_wave)

# ---------------------------------------------------------------------------
# Particles
# ---------------------------------------------------------------------------
func _build_dust() -> void:
	var p := GPUParticles3D.new()
	p.name = "DustMotes"
	p.amount = max(1, Settings.ATMOSPHERE_DUST)
	p.lifetime = 18.0
	p.preprocess = 18.0
	p.randomness = 1.0
	p.fixed_fps = 20
	p.visibility_aabb = AABB(Vector3(-MAP_HALF, -2.0, -MAP_HALF), Vector3(160.0, 34.0, 160.0))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(0.0, 14.0, 0.0)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = DUST_BOX * 0.5
	pm.direction = Vector3(0.2, -1.0, 0.1)
	pm.spread = 35.0
	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = 0.15
	pm.initial_velocity_max = 0.5
	pm.scale_min = 0.4
	pm.scale_max = 1.1
	# Gentle sideways sway so motes don't fall in straight lines.
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.25
	pm.turbulence_noise_scale = 0.6
	pm.turbulence_influence_min = 0.05
	pm.turbulence_influence_max = 0.2
	pm.color = Color(0.85, 0.84, 0.8, 0.18)
	_dust_mat = pm
	p.process_material = pm
	p.draw_pass_1 = _dot_mesh(0.035, Color(0.9, 0.88, 0.82, 0.18))
	add_child(p)
	p.emitting = true
	_dust = p

func _build_embers() -> void:
	var p := GPUParticles3D.new()
	p.name = "Embers"
	p.amount = max(1, Settings.ATMOSPHERE_EMBERS)
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.randomness = 1.0
	p.fixed_fps = 24
	p.visibility_aabb = AABB(Vector3(-MAP_HALF, -2.0, -MAP_HALF), Vector3(160.0, 30.0, 160.0))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(0.0, 1.0, 0.0)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(MAP_HALF, 4.0, MAP_HALF)
	pm.direction = Vector3(0.1, 1.0, 0.0)
	pm.spread = 25.0
	pm.gravity = Vector3(0.0, 1.2, 0.0)
	pm.initial_velocity_min = 0.4
	pm.initial_velocity_max = 1.3
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.5
	pm.turbulence_noise_scale = 0.9
	pm.turbulence_influence_min = 0.1
	pm.turbulence_influence_max = 0.4
	# Flicker via per-particle alpha over lifetime.
	var ramp := _flicker_ramp()
	pm.alpha_curve = ramp
	pm.color = Color(1.0, 0.55, 0.2, 0.9)
	_ember_mat = pm
	p.process_material = pm
	p.draw_pass_1 = _dot_mesh(0.05, Color(1.0, 0.6, 0.25, 1.0))
	add_child(p)
	p.emitting = true
	_embers = p

func _dot_mesh(radius: float, col: Color) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(radius, radius) * 2.0
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_color = col
	m.disable_receive_shadows = true
	q.material = m
	return q

func _flicker_ramp() -> CurveTexture:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(0.15, 1.0))
	c.add_point(Vector2(0.45, 0.4))
	c.add_point(Vector2(0.7, 0.9))
	c.add_point(Vector2(1.0, 0.0))
	var ct := CurveTexture.new()
	ct.curve = c
	return ct

# ---------------------------------------------------------------------------
# Env / light discovery (runtime; never touches Arena.tscn)
# ---------------------------------------------------------------------------
func _find_env_and_light() -> void:
	var root := get_tree().get_current_scene()
	if root == null:
		root = get_tree().root
	var we := _find_world_environment(root)
	if we != null and we.environment != null:
		_env = we.environment
	# Fall back to the viewport's world environment if no WorldEnvironment node.
	if _env == null:
		var vp := get_viewport()
		if vp != null and vp.world_3d != null and vp.world_3d.environment != null:
			_env = vp.world_3d.environment
	if _env != null and _env.sky != null and _env.sky.sky_material is ShaderMaterial:
		_sky_mat = _env.sky.sky_material as ShaderMaterial
	_sun = _find_directional_light(root)

func _find_world_environment(n: Node) -> WorldEnvironment:
	if n is WorldEnvironment:
		return n as WorldEnvironment
	for c in n.get_children():
		var r := _find_world_environment(c)
		if r != null:
			return r
	return null

func _find_directional_light(n: Node) -> DirectionalLight3D:
	if n is DirectionalLight3D:
		return n as DirectionalLight3D
	for c in n.get_children():
		var r := _find_directional_light(c)
		if r != null:
			return r
	return null

func _capture_baseline() -> void:
	if _env != null:
		_base_ambient = _env.ambient_light_energy
		_base_fog_density = _env.fog_density
		_base_fog_color = _env.fog_light_color
		_base_glow = _env.glow_intensity
	if _sun != null:
		_base_sun_energy = _sun.light_energy
		_base_sun_rot = _sun.rotation
	_captured = true

# ---------------------------------------------------------------------------
# Storm transition
# ---------------------------------------------------------------------------
func _on_final_wave() -> void:
	if _stormed:
		return
	_stormed = true
	_start_storm_tween()

func _start_storm_tween() -> void:
	var t: float = max(0.1, Settings.STORM_TWEEN_TIME)
	if _storm_tween != null and _storm_tween.is_valid():
		_storm_tween.kill()
	_storm_tween = create_tween()
	_storm_tween.set_parallel(true)
	_storm_tween.set_trans(Tween.TRANS_SINE)
	_storm_tween.set_ease(Tween.EASE_IN_OUT)

	# Sky shader storm uniform 0 -> 1.
	if _sky_mat != null:
		_storm_tween.tween_method(_set_sky_storm, 0.0, 1.0, t)

	if _env != null:
		_storm_tween.tween_property(_env, "ambient_light_energy", _base_ambient * 0.45, t)
		_storm_tween.tween_property(_env, "fog_density", _base_fog_density * 3.2, t)
		_storm_tween.tween_property(_env, "fog_light_color", Color(0.22, 0.20, 0.24, 1.0), t)
		_storm_tween.tween_property(_env, "glow_intensity", _base_glow * 1.25, t)

	if _sun != null:
		_storm_tween.tween_property(_sun, "light_energy", _base_sun_energy * 0.4, t)
		# Roll the sun lower/sideways like clouds sweeping in.
		var target_rot := _base_sun_rot + Vector3(deg_to_rad(-18.0), deg_to_rad(35.0), 0.0)
		_storm_tween.tween_property(_sun, "rotation", target_rot, t)

	# Thicken the ambient particles.
	if _dust_mat != null:
		_storm_tween.tween_property(_dust_mat, "color", Color(0.55, 0.52, 0.5, 0.3), t)
	if _embers != null:
		_storm_tween.tween_property(_embers, "amount_ratio", 1.0, t * 0.5)

func _set_sky_storm(v: float) -> void:
	if _sky_mat != null:
		_sky_mat.set_shader_parameter("storm", v)

func _apply_storm_instant() -> void:
	_stormed = true
	_set_sky_storm(1.0)
	if _env != null:
		_env.ambient_light_energy = _base_ambient * 0.45
		_env.fog_density = _base_fog_density * 3.2
		_env.fog_light_color = Color(0.22, 0.20, 0.24, 1.0)
		_env.glow_intensity = _base_glow * 1.25
	if _sun != null:
		_sun.light_energy = _base_sun_energy * 0.4
		_sun.rotation = _base_sun_rot + Vector3(deg_to_rad(-18.0), deg_to_rad(35.0), 0.0)
