extends Node3D
class_name WorldAtmosphere
## Ambient mood for the urban-ruins map: slow-drifting dust motes + a few warm
## rising embers, plus the day->storm visual transition driven by
## Events.final_wave_started. Procedural — zero external assets.
##
## Instanced into world_root by main.gd (non-headless, guarded). On _ready it
## finds the active WorldEnvironment (a Sky3D node), the Sky3D SkyDome, and the
## scene's main DirectionalLight3D at runtime (never references Arena.tscn) and,
## on the final wave, tweens the Sky3D clouds/atmosphere, fog, ambient light and
## the sun into a dark overcast storm look.
##
## Sky3D integration (Lane B): the procedural sky shader was replaced by the
## Sky3D plugin. The storm no longer drives a `storm` shader uniform or billboard
## cloud puffs; instead it raises cumulus coverage/thickness + atm_darkness and
## drops sun_energy/exposure on the live SkyDome so the cinematic clouds go dark
## and overcast.

# 4× MAP: the world is the rectangle X∈[-80,240], Z∈[-80,240] (320×320, centre 80,80). The
# ambient particle fields cover the whole rectangle, centred on (80,80) — not the old origin.
const MAP_SPAN := 320.0         # full world edge (was 160)
const WORLD_CX := 80.0          # rectangle centre X
const WORLD_CZ := 80.0          # rectangle centre Z
const DUST_BOX := Vector3(320.0, 30.0, 320.0)

var _dust: GPUParticles3D
var _embers: GPUParticles3D
var _ember_mat: ParticleProcessMaterial
var _dust_mat: ParticleProcessMaterial

var _env: Environment
var _sun: DirectionalLight3D
# The WorldEnvironment NODE (carries `.camera_attributes`, where DOF lives). Captured
# alongside `_env` in _find_env_and_light so the DOF lever has somewhere to write.
var _world_env_node: WorldEnvironment
# The Sky3D SkyDome node (driving clouds/atmosphere). Typed as Node so this script
# does not hard-depend on the Sky3D class_name being registered.
var _skydome: Node

# Captured baseline (day) values. These are CAPTURED from the live Environment +
# SkyDome in _ready() so the storm tween always scales the real defaults. The
# initial values here are only fallbacks if capture fails.
var _base_ambient := 0.95
var _base_fog_density := 0.001
var _base_fog_color := Color(0.64, 0.68, 0.72, 1)
var _base_glow := 0.55
# Live volumetric-fog density (the value the quality setting last applied). The storm
# tween thickens FROM this, and _restore_day() resets BACK to it.
var _base_vol_fog_density := 0.025
var _base_sun_energy := 1.35
var _base_sun_rot := Vector3.ZERO
# SkyDome baselines.
var _base_cumulus_coverage := 0.55
var _base_cumulus_thickness := 0.0243
var _base_cumulus_intensity := 0.7
var _base_atm_darkness := 0.45
var _base_skydome_exposure := 1.0
var _captured := false

# Explicit DAY look — the known-good bright-day values authored in Arena.tscn /
# default_env.tres. We force the (shared, in-place-mutated) Environment + SkyDome
# back to these whenever a NEW match begins, so a raid never inherits the previous
# raid's storm darkness after a restart. Capture then scales the storm tween from
# the live values, but these are the source-of-truth fallbacks/resets.
const DAY_AMBIENT := 0.95
const DAY_FOG_DENSITY := 0.001
const DAY_FOG_COLOR := Color(0.64, 0.68, 0.72, 1.0)
const DAY_GLOW := 0.55
const DAY_SUN_ENERGY := 1.35
const DAY_CUMULUS_COVERAGE := 0.55
const DAY_CUMULUS_THICKNESS := 0.0243
const DAY_CUMULUS_INTENSITY := 0.7
const DAY_ATM_DARKNESS := 0.45
const DAY_SKYDOME_EXPOSURE := 1.0

# Storm look targets for the SkyDome.
const STORM_CUMULUS_COVERAGE := 0.92
const STORM_CUMULUS_THICKNESS := 0.06
const STORM_CUMULUS_INTENSITY := 0.18
const STORM_ATM_DARKNESS := 0.85
const STORM_SKYDOME_EXPOSURE := 0.45
# Storm-only GLOBAL volumetric haze (normal play keeps global density at 0 — fog lives
# only in the localized FogZones; the storm justifies a brief whole-map murk).
const STORM_VOLUMETRIC_DENSITY := 0.035

var _storm_tween: Tween
var _stormed := false

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_build_dust()
	_build_embers()
	_find_env_and_light()
	# The Environment is a SHARED resource that the storm mutates IN PLACE; across a
	# mid-match restart / fresh raid the same object persists, so it may still be in
	# its stormed (dark) state when we load. Force it back to explicit bright-day
	# BEFORE capturing, so the captured baseline is the true day (not a stormed one)
	# and the storm tween scales correctly.
	_restore_day()
	_capture_baseline()
	# If the match somehow already flipped to the final wave before we loaded.
	if GameState and GameState.final_wave:
		_apply_storm_instant()
	if Events and not Events.final_wave_started.is_connected(_on_final_wave):
		Events.final_wave_started.connect(_on_final_wave)
	# Every new match starts bright-day: re-apply the day baseline + clear the storm
	# flag (covers a debug restart where this Atmosphere may NOT be re-instanced).
	if Events and not Events.match_started.is_connected(_on_match_started):
		Events.match_started.connect(_on_match_started)
	# Graphics-quality render levers (SDFGI/SSAO/glow on the Environment, Sky3D clouds):
	# apply the current setting now + on every change. Scene-side levers live here because
	# this is the one node that captures the live Environment + SkyDome.
	if Events and not Events.graphics_quality_changed.is_connected(_apply_graphics_quality):
		Events.graphics_quality_changed.connect(_apply_graphics_quality)
	_apply_graphics_quality(int(SettingsManager.get_value("graphics_quality")))

# ---------------------------------------------------------------------------
# Graphics-quality render levers (the one node that captures the live Environment +
# SkyDome, so the scene-side levers live here). Applied on _ready + every
# Events.graphics_quality_changed. Reads the LIVE per-lever settings (so manual toggles
# work too), not just the preset index — `level` only drives the SDFGI/cloud detail tier.
# Toggles are read both directions, so going Ultra+RT -> Ultra cleanly turns SSR/SSIL off.
# ---------------------------------------------------------------------------
func _apply_graphics_quality(level: int) -> void:
	if _env != null:
		# Global illumination + AO + bloom (immediate Environment flags).
		_env.sdfgi_enabled = bool(SettingsManager.get_value("sdfgi"))
		_env.ssao_enabled = bool(SettingsManager.get_value("ssao"))
		_env.glow_enabled = bool(SettingsManager.get_value("glow"))
		# Max-SDFGI for the RT tier (richer indirect bounce + sky reflections); authored
		# values otherwise. Guarded so it only costs when SDFGI is actually on.
		if _env.sdfgi_enabled:
			var rt := level >= 4
			_env.sdfgi_cascades = 6 if rt else 4
			_env.sdfgi_use_occlusion = true
			_env.sdfgi_bounce_feedback = 0.75 if rt else 0.5
			_env.sdfgi_energy = 1.1 if rt else 0.9
		# "RT-style" raster reflections: SSR (Forward+; water/metal/wet). Read both ways.
		_env.ssr_enabled = bool(SettingsManager.get_value("ssr"))
		if _env.ssr_enabled:
			_env.ssr_max_steps = 96
			_env.ssr_fade_in = 0.05
			_env.ssr_fade_out = 4.0
			_env.ssr_depth_tolerance = 0.2
		# Screen-space indirect lighting.
		_env.ssil_enabled = bool(SettingsManager.get_value("ssil"))
		if _env.ssil_enabled:
			_env.ssil_radius = 5.0
			_env.ssil_intensity = 1.0
		# Volumetric fog = the CARRIER for the localized FogVolume smoke banks ONLY. The
		# GLOBAL ambient density is ALWAYS ZERO (the map itself stays clear — the player
		# explicitly does not want whole-map haze); fog exists only inside the FogZones
		# placed at landmarks. volumetric_fog_length is raised so a smoke bank is visible
		# from across the 160 m map (the 80 m default culled zones beyond 80 m entirely).
		# The "volumetric_fog_density" setting is now the ZONES' density multiplier
		# (applied below via ProceduralFogZones.apply_density), not a global density.
		_env.volumetric_fog_enabled = bool(SettingsManager.get_value("volumetric_fog"))
		_base_vol_fog_density = 0.0
		if _env.volumetric_fog_enabled:
			_env.volumetric_fog_density = 0.0
			_env.volumetric_fog_length = 220.0
			_env.volumetric_fog_detail_spread = 2.6
		# Rescale the local fog zones' density from the settings slider (live, no rebuild).
		ProceduralFogZones.apply_density(get_tree().current_scene if get_tree() else null)
		# Same live rescale for the localized climate zones (particle amount_ratio + fog density).
		ProceduralClimateZones.apply_density(get_tree().current_scene if get_tree() else null)
	# God rays: let the sun cast volumetric shafts THROUGH the global fog (no-op when
	# volumetric fog is off). Shadow distance also lives on the sun. Guard non-null.
	if _sun != null:
		_sun.light_volumetric_fog_energy = 1.0 if bool(SettingsManager.get_value("god_rays")) else 0.0
		_sun.directional_shadow_max_distance = clampf(float(SettingsManager.get_value("shadow_distance")), 60.0, 250.0)
	# Cinematic depth-of-field — FAR-ONLY (the player/gun must stay sharp; never enable
	# near-blur). Lives on the WorldEnvironment node's CameraAttributes; create a
	# CameraAttributesPractical if the node has none yet.
	if _world_env_node != null:
		var ca := _world_env_node.camera_attributes as CameraAttributesPractical
		if ca == null:
			ca = CameraAttributesPractical.new()
			_world_env_node.camera_attributes = ca
		ca.dof_blur_far_enabled = bool(SettingsManager.get_value("dof"))
		ca.dof_blur_far_distance = 30.0
		ca.dof_blur_far_transition = 40.0
		ca.dof_blur_amount = clampf(float(SettingsManager.get_value("dof_amount")), 0.0, 0.2)
	# Particle-density scaling — thins the ambient dust/embers immediately (amount_ratio
	# caps at 1.0; values <1.0 cut particle count with no rebuild). Guard non-null.
	var pd := clampf(float(SettingsManager.get_value("particle_density")), 0.0, 1.5)
	if _dust != null:
		_dust.amount_ratio = clampf(pd, 0.0, 1.0)
	if _embers != null:
		_embers.amount_ratio = clampf(pd, 0.0, 1.0)
	if _skydome != null:
		var clouds := bool(SettingsManager.get_value("clouds"))
		_skydome.set("cumulus_visible", clouds)
		# Cheaper cloud march at lower tiers (clouds are off at Low anyway).
		_skydome.set("cumulus_noise_freq", 1.5 if level <= 1 else 2.7)

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
	p.visibility_aabb = AABB(
		Vector3(WORLD_CX - MAP_SPAN * 0.5, -2.0, WORLD_CZ - MAP_SPAN * 0.5),
		Vector3(MAP_SPAN, 34.0, MAP_SPAN))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(WORLD_CX, 14.0, WORLD_CZ)

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
	p.visibility_aabb = AABB(
		Vector3(WORLD_CX - MAP_SPAN * 0.5, -2.0, WORLD_CZ - MAP_SPAN * 0.5),
		Vector3(MAP_SPAN, 30.0, MAP_SPAN))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(WORLD_CX, 1.0, WORLD_CZ)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(MAP_SPAN * 0.5, 4.0, MAP_SPAN * 0.5)
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
# Env / light / Sky3D discovery (runtime; never touches Arena.tscn)
# ---------------------------------------------------------------------------
func _find_env_and_light() -> void:
	var root := get_tree().get_current_scene()
	if root == null:
		root = get_tree().root
	var we := _find_world_environment(root)
	_world_env_node = we
	if we != null and we.environment != null:
		_env = we.environment
	# Fall back to the viewport's world environment if no WorldEnvironment node.
	if _env == null:
		var vp := get_viewport()
		if vp != null and vp.world_3d != null and vp.world_3d.environment != null:
			_env = vp.world_3d.environment
	# The Sky3D SkyDome drives the cloud/atmosphere look. It is a child of the
	# Sky3D WorldEnvironment node and exposes cumulus_*/atm_darkness/exposure.
	_skydome = _find_skydome(we)
	# Our main shadow-casting sun lives at the scene root (NOT under Sky3D, whose
	# own SunLight/MoonLight are disabled). Prefer that one.
	_sun = _find_main_sun(root, we)
	if Settings and Settings.NET_DEBUG:
		print("[atmosphere] env=", _env != null, " skydome=", _skydome != null, " sun=", _sun != null)

func _find_world_environment(n: Node) -> WorldEnvironment:
	if n is WorldEnvironment:
		return n as WorldEnvironment
	for c in n.get_children():
		var r := _find_world_environment(c)
		if r != null:
			return r
	return null

## Finds the SkyDome node by checking for the cumulus_coverage property. Returns
## null if Sky3D is not present (graceful fallback to env/light-only storm).
func _find_skydome(we: Node) -> Node:
	if we == null:
		return null
	for c in we.get_children():
		# SkyDome is the child carrying cloud/atmosphere setters.
		if c.get("cumulus_coverage") != null and c.get("atm_darkness") != null:
			return c
	return null

## Finds the Arena's main DirectionalLight3D, skipping any lights that live under
## the Sky3D node (its auto-created SunLight/MoonLight).
func _find_main_sun(root: Node, sky_we: Node) -> DirectionalLight3D:
	# Prefer a DirectionalLight3D that is NOT a descendant of the Sky3D node.
	var best := _find_directional_light_excluding(root, sky_we)
	if best != null:
		return best
	# Fallback: any directional light at all.
	return _find_directional_light(root)

func _find_directional_light_excluding(n: Node, exclude: Node) -> DirectionalLight3D:
	if n == exclude:
		return null
	if n is DirectionalLight3D:
		return n as DirectionalLight3D
	for c in n.get_children():
		var r := _find_directional_light_excluding(c, exclude)
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
	if _skydome != null:
		var cc: Variant = _skydome.get("cumulus_coverage")
		if cc != null:
			_base_cumulus_coverage = cc
		var ct: Variant = _skydome.get("cumulus_thickness")
		if ct != null:
			_base_cumulus_thickness = ct
		var ci: Variant = _skydome.get("cumulus_intensity")
		if ci != null:
			_base_cumulus_intensity = ci
		var ad: Variant = _skydome.get("atm_darkness")
		if ad != null:
			_base_atm_darkness = ad
		var ex: Variant = _skydome.get("exposure")
		if ex != null:
			_base_skydome_exposure = ex
	_captured = true

# ---------------------------------------------------------------------------
# Storm transition
# ---------------------------------------------------------------------------
## A fresh match started — guarantee a bright day even if the previous raid ended in a
## storm (the shared Environment persists across restarts).
func _on_match_started() -> void:
	if _storm_tween != null and _storm_tween.is_valid():
		_storm_tween.kill()
	_stormed = false
	_restore_day()
	# If this new match has *already* flipped to the final wave by the time the signal
	# lands (unlikely, but safe), re-storm.
	if GameState and GameState.final_wave:
		_apply_storm_instant()

## Reset every storm-mutated property on the (shared) Environment + SkyDome + sun back
## to its explicit bright-day value. Also re-sets the ambient particle tint. Uses the
## captured baselines where they exist (true authored values), falling back to the
## explicit DAY_* constants so this is correct even if capture ran on a stormed env.
func _restore_day() -> void:
	if _skydome != null:
		_skydome.set("cumulus_coverage", DAY_CUMULUS_COVERAGE)
		_skydome.set("cumulus_thickness", DAY_CUMULUS_THICKNESS)
		_skydome.set("cumulus_intensity", DAY_CUMULUS_INTENSITY)
		_skydome.set("atm_darkness", DAY_ATM_DARKNESS)
		_skydome.set("exposure", DAY_SKYDOME_EXPOSURE)
	if _env != null:
		_env.ambient_light_energy = DAY_AMBIENT
		_env.fog_density = DAY_FOG_DENSITY
		_env.fog_light_color = DAY_FOG_COLOR
		_env.glow_intensity = DAY_GLOW
		# Reset volumetric fog to its live (quality-setting) density, undoing any storm thicken.
		if _env.volumetric_fog_enabled:
			_env.volumetric_fog_density = _base_vol_fog_density
	if _sun != null:
		_sun.light_energy = DAY_SUN_ENERGY
		if _base_sun_rot != Vector3.ZERO:
			_sun.rotation = _base_sun_rot
	if _dust_mat != null:
		_dust_mat.color = Color(0.85, 0.84, 0.8, 0.18)

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

	# Sky3D clouds + atmosphere -> dark overcast.
	if _skydome != null:
		_storm_tween.tween_property(_skydome, "cumulus_coverage", STORM_CUMULUS_COVERAGE, t)
		_storm_tween.tween_property(_skydome, "cumulus_thickness", STORM_CUMULUS_THICKNESS, t)
		_storm_tween.tween_property(_skydome, "cumulus_intensity", STORM_CUMULUS_INTENSITY, t)
		_storm_tween.tween_property(_skydome, "atm_darkness", STORM_ATM_DARKNESS, t)
		_storm_tween.tween_property(_skydome, "exposure", STORM_SKYDOME_EXPOSURE, t)

	if _env != null:
		# Ambient floor ×0.5 (not ×0.45) so interiors stay readable in the storm.
		_storm_tween.tween_property(_env, "ambient_light_energy", _base_ambient * 0.5, t)
		_storm_tween.tween_property(_env, "fog_density", _base_fog_density * 3.2, t)
		_storm_tween.tween_property(_env, "fog_light_color", Color(0.22, 0.20, 0.24, 1.0), t)
		_storm_tween.tween_property(_env, "glow_intensity", _base_glow * 1.25, t)
		# Storm-only global volumetric haze (a fixed constant — the normal-play global
		# density is now permanently 0; the reset path restores _base_vol_fog_density=0).
		if _env.volumetric_fog_enabled:
			_storm_tween.tween_property(_env, "volumetric_fog_density", STORM_VOLUMETRIC_DENSITY, t)

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

func _apply_storm_instant() -> void:
	_stormed = true
	if _skydome != null:
		_skydome.set("cumulus_coverage", STORM_CUMULUS_COVERAGE)
		_skydome.set("cumulus_thickness", STORM_CUMULUS_THICKNESS)
		_skydome.set("cumulus_intensity", STORM_CUMULUS_INTENSITY)
		_skydome.set("atm_darkness", STORM_ATM_DARKNESS)
		_skydome.set("exposure", STORM_SKYDOME_EXPOSURE)
	if _env != null:
		_env.ambient_light_energy = _base_ambient * 0.5
		_env.fog_density = _base_fog_density * 3.2
		_env.fog_light_color = Color(0.22, 0.20, 0.24, 1.0)
		_env.glow_intensity = _base_glow * 1.25
	if _sun != null:
		_sun.light_energy = _base_sun_energy * 0.4
		_sun.rotation = _base_sun_rot + Vector3(deg_to_rad(-18.0), deg_to_rad(35.0), 0.0)
