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
##
## Day-night cycle: every frame while a match runs (and not yet stormed), the sky clock +
## the Arena sun + ambient are driven from DayNight (scripts/core/day_night.gd) — a PURE
## function of the synced match timer, so the sky is identical on every peer with zero new
## netcode. Sky3D's own Sun/Moon lights + auto-clock are disabled (the Arena's root
## DirectionalLight3D is the only sun), and the "fog" raid mutator lays a permanent
## half-storm volumetric murk from t=0.

# World bounds: WorldBounds.* (scripts/core/world_bounds.gd) is the ONE source. The
# ambient particle fields cover the whole rectangle, centred on (CX,CZ) — not the origin.
const DUST_BOX := Vector3(WorldBounds.SPAN, 30.0, WorldBounds.SPAN)

var _dust: GPUParticles3D
var _embers: GPUParticles3D
var _ember_mat: ParticleProcessMaterial
var _dust_mat: ParticleProcessMaterial

var _env: Environment
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D = null  # weak shadowless counter-sun (shade legibility)
# The WorldEnvironment NODE (carries `.camera_attributes`, where DOF lives). Captured
# alongside `_env` in _find_env_and_light so the DOF lever has somewhere to write.
var _world_env_node: WorldEnvironment
# The Sky3D SkyDome node (driving clouds/atmosphere). Typed as Node so this script
# does not hard-depend on the Sky3D class_name being registered.
var _skydome: Node
# The Sky3D WorldEnvironment node itself (== _world_env_node when Sky3D is present) and its
# TimeOfDay child. Setting TimeOfDay.current_time spins the sky dome to that hour; we drive
# it every frame from DayNight so the sky is a pure function of the synced match clock. Both
# typed as Node so this script never hard-depends on the Sky3D class_names being registered.
var _sky3d: Node
var _tod: Node

# Captured baseline (day) values. These are CAPTURED from the live Environment +
# SkyDome in _ready() so the storm tween always scales the real defaults. The
# initial values here are only fallbacks if capture fails.
var _base_ambient := 0.95
var _base_fog_density := 0.0008
var _base_fog_color := Color(0.62, 0.66, 0.72, 1)
var _base_glow := 0.5
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
# 0.48 → 0.62 in the texture-quality pass: shaded building faces read as pure coal
# under the cold grade (containers «чёрные» from the south-west) — a modest ambient
# floor keeps shadow sides legible without breaking the moody look.
const DAY_AMBIENT := 0.70
const DAY_FOG_DENSITY := 0.001
const DAY_FOG_COLOR := Color(0.54, 0.59, 0.67, 1.0)
const DAY_GLOW := 0.5
# Art-panel "turn the sun on": the fill used to OUT-power the key (1.4 vs 1.35),
# erasing all modeling — AgX wants a hot key + weak fill (~6:1) to sculpt shadows.
const DAY_SUN_ENERGY := 2.8
const DAY_CUMULUS_COVERAGE := 0.66
const DAY_CUMULUS_THICKNESS := 0.04
const DAY_CUMULUS_INTENSITY := 0.42
const DAY_ATM_DARKNESS := 0.72
const DAY_SKYDOME_EXPOSURE := 0.8

# Day-night drive (per-frame, from DayNight.sun_ratio). The sun energy + ambient + sun pitch
# lerp between a NIGHT floor (sun_ratio 0) and the bright-DAY top (sun_ratio 1) — DAY_SUN_ENERGY
# is the noon energy, so the drive never exceeds the authored day. Pitch sweeps shallow at
# dawn/dusk to steep at noon (the sun rides high mid-day), yaw/roll kept from the captured base.
# D1 RELIGHT: the photostand measured night frames at 97-99% of world pixels under the
# grade's readable floor — night was not "moody", it was unlit. Moonlight and the ambient
# floor both come up so silhouettes, ground and facades stay legible while staying clearly
# night (day noon still runs 12× the moon energy).
const NIGHT_SUN_ENERGY := 0.26
const NIGHT_AMBIENT := 0.60
# How much of the ambient comes from the SKY vs the explicit `ambient_light_color`
# (see _apply_sun_ambient). Day leans on the sky; night leans on the authored colour.
const NIGHT_SKY_CONTRIB := 0.28
# Day stays sky-dominated: pulling it to 0.82 measurably DARKENED the daylight biomes whose
# ambient colour is cooler than their sky (rain lost 0.08 of median luma), which is the
# opposite of the intent. The blend is a night lever, not a day one.
const DAY_SKY_CONTRIB := 0.96
# Shadow-side fill light (see _apply_sun_ambient): weak, cool, shadowless, opposite the sun.
# Re-tuned with the 2.8 sun (art-panel key:fill ≈6:1): 1.4 against the old 1.35 sun
# out-powered the key and flattened all modeling; 0.45 keeps shade legible without
# fighting the sun. (History: 0.55 vanished only because the SUN was too weak.)
# D1 RELIGHT 0.45 → 0.72: still well under the 2.8 key (≈4:1, modeling intact) but enough
# that the shadow side of a machine or a facade resolves as cold steel instead of one flat
# value — the "readable but not flat" point the ratio is actually protecting.
const FILL_ENERGY := 0.72
const FILL_PITCH_DEG := -35.0
const DAYNIGHT_PITCH_LOW := -8.0  # sun pitch (deg) at dawn/dusk (sun_ratio 0) — low golden-hour rake
const DAYNIGHT_PITCH_HIGH := -42.0  # sun pitch (deg) at noon — kept low so shadows stay long/dramatic

# Storm look targets for the SkyDome.
const STORM_CUMULUS_COVERAGE := 0.92
const STORM_CUMULUS_THICKNESS := 0.06
const STORM_CUMULUS_INTENSITY := 0.18
const STORM_ATM_DARKNESS := 0.85
const STORM_SKYDOME_EXPOSURE := 0.45
# Storm-only GLOBAL volumetric haze (normal play keeps global density at 0 — fog lives
# only in the localized FogZones; the storm justifies a brief whole-map murk).
const STORM_VOLUMETRIC_DENSITY := 0.035
# Storm fog tint. RELIGHT: the pre-D6.4 value was (0.22,0.20,0.24) — under the light
# palette + cold grade that pulled every distant surface below the readable floor
# (the same failure mode the crush 0.05 bug had). A storm-GREY keeps depth legible.
const STORM_FOG_COLOR := Color(0.34, 0.33, 0.38, 1.0)

# ---------------------------------------------------------------------------
# D6.4 — STORM FRONT v2: the storm ARRIVES instead of cross-fading everywhere at once.
#
# The old implementation was one global Tween over the sky/fog/sun parameters: the colour
# changed but nothing HAPPENED. v2 replaces the tween with a per-frame drive of a single
# storm mix `k`, computed as a function of TIME and the CAMERA's distance to a moving
# FRONT PLANE — so the darkness, the fog, the wind and the debris all roll over you as a
# wall passing by, and a squadmate on the far side of the map is still in clear sky for a
# few more seconds.
#
# WHY A PLANE AND NOT A RADIUS: a front is directional. `_front_dir` is a unit XZ vector
# picked deterministically from the match seed (same on every peer — and the whole system
# is render-only anyway, so even a mismatch could only differ cosmetically, never in
# gameplay). `_front_s` is the front's signed distance along that axis from the map centre;
# it sweeps from fully upwind to fully downwind across `_front_time` seconds.
#
# EVERYTHING HERE IS RENDER-ONLY AND MUST NOT FIGHT `_restore_day()`: the mix writes the
# SAME properties `_restore_day()` owns (sun energy/rotation, ambient, fog, glow, SkyDome)
# and nothing else, so a match restart resets every one of them by simply calling
# `_restore_day()`; `_storm_reset()` (called from there) clears the extra state this batch
# owns — the grass wind uniforms, the debris field and the fog wall.
# ---------------------------------------------------------------------------
const FRONT_TIME_MULT := 1.6  # front travel time = STORM_TWEEN_TIME × this
const FRONT_SOFT := 34.0  # half-width (m) of the front's soft edge — the "wall" thickness
# Half the distance the front travels. Must clear the map's HALF-DIAGONAL plus the soft
# edge, or a player standing in the far corner would never reach mix=1 (the storm would
# visibly stall at ~0.6 for them).
const FRONT_HALF_TRAVEL := WorldBounds.SPAN * 0.7072 + FRONT_SOFT + 24.0
# Ambient floor for the stormed look. RELIGHT: the storm target used to be a flat
# base×0.5; at night that stacked on an already-dim frame. The floor keeps machines and
# facades above the grade's readable threshold while the frame still reads as a storm.
const STORM_AMBIENT_FLOOR := 0.42
const DUST_DAY_COLOR := Color(0.85, 0.84, 0.8, 0.18)
const DUST_STORM_COLOR := Color(0.62, 0.60, 0.58, 0.30)

# WIND — multipliers applied to the LIVE grass ShaderMaterial's authored wind uniforms
# (shaders/grass.gdshader `sway_strength` / `sway_speed`, set in procedural_flora
# _build_grass). Only the uniform VALUES are touched; the material, the shader and the
# flora builder are untouched, and `_storm_reset()` writes the captured base back.
# Both products stay inside the shader's authored hint_range (0.34×2.35=0.80 ≤ 1.0,
# 2.0×2.10=4.2 ≤ 5.0) so the sway never clips into a jelly wobble.
const WIND_SWAY_MULT := 2.35
const WIND_SPEED_MULT := 2.10

# WIND-BLOWN DEBRIS — one small camera-riding GPUParticles3D field. Riding the camera IS
# the distance gate: nothing ever simulates out in the empty quadrants, and the count is
# fixed (no pooling needed — a single emitter, built once, toggled by `emitting`).
const DEBRIS_COUNT := 90
const DEBRIS_BOX := Vector3(30.0, 11.0, 30.0)
const DEBRIS_UPWIND := 16.0  # emitter sits this far UPWIND of the camera so scraps blow past
const DEBRIS_SPEED_MIN := 11.0
const DEBRIS_SPEED_MAX := 26.0
# Light tan scraps, ALPHA-blended (never additive): an additive volume you can be INSIDE
# is exactly the beacon-pillar whiteout lesson (extraction_zone.gd::_additive).
const DEBRIS_COLOR := Color(0.74, 0.70, 0.62, 0.85)

# THE VISIBLE WALL — a box FogVolume spanning the map, travelling with the front so the
# storm is something you SEE coming. Only built when volumetric fog is actually enabled
# (FogVolumes render nowhere otherwise); when it is off the mix's distance-fog ramp still
# carries the arrival, so this is a pure bonus layer, never load-bearing.
const WALL_THICK := 42.0
const WALL_HEIGHT := 76.0
# Density/albedo deliberately UNDER the landmark FogZones (0.40-0.55 @ ZONE_ALBEDO): the
# front sweeps THROUGH the squad during the deadliest wave of the raid, and the fog-zone
# art-panel lesson is that a bright, dense bank "erases enemies at 8 m". Thick enough to
# read as a wall from 200 m, thin enough that you can still fight inside it.
const WALL_DENSITY := 0.34
const WALL_ALBEDO := Color(0.54, 0.59, 0.67)

# LIGHTNING — no bolt geometry, no new material: a short spike ADDED on top of the mixed
# sun + ambient energies, so it can never fight the per-frame drive.
const FLASH_LEN := 0.55
const FLASH_SUN := 2.6
const FLASH_AMBIENT := 0.55
const STRIKE_MIN := 2.6  # seconds between strikes (deterministic, hashed per strike index)
const STRIKE_MAX := 7.4
const STRIKE_K_MIN := 0.35  # no lightning in the clear sky AHEAD of the front
const SOUND_SPEED := 340.0  # m/s — thunder delay = distance / this

var _stormed := false
# Storm-front runtime state (all reset by _storm_reset()).
var _storm_t: float = 0.0
var _front_time: float = 9.6
var _front_dir: Vector2 = Vector2(0.0, 1.0)
var _front_s: float = -FRONT_HALF_TRAVEL
var _storm_seed: int = 0
var _last_storm_k: float = -1.0
# "From" side of every storm ramp — captured LIVE at storm start, not from the DAY_*
# constants: at dusk/night the day-night drive has already dimmed the sun and ambient, and
# ramping from the noon constants would make the storm BRIGHTEN a night raid.
var _pre_sun_energy: float = DAY_SUN_ENERGY
var _pre_sun_rot: Vector3 = Vector3.ZERO
var _pre_ambient: float = DAY_AMBIENT
var _pre_fog_density: float = DAY_FOG_DENSITY
var _pre_fog_color: Color = DAY_FOG_COLOR
var _pre_glow: float = DAY_GLOW
# Mixed (flash-free) light energies — the flash is added on top of these every frame.
var _storm_sun_e: float = DAY_SUN_ENERGY
var _storm_amb_e: float = DAY_AMBIENT
# Lightning
var _flash: float = 0.0
var _flash_t: float = 1000.0
var _strike_accum: float = 0.0
var _strike_idx: int = 0
var _next_strike: float = STRIKE_MIN
var _last_strike_pos: Vector3 = Vector3.ZERO
var _last_strike_dist: float = 0.0
var _last_strike_delay: float = 0.0
# Live grass wind materials + their authored base (sway_strength, sway_speed).
var _grass_mats: Array[ShaderMaterial] = []
var _grass_base_wind: Array[Vector2] = []
# Debris field + the travelling fog wall (both built lazily on the first storm).
var _debris: GPUParticles3D = null
var _debris_mat: ParticleProcessMaterial = null
var _debris_k: float = -1.0
var _front_fog: FogVolume = null
var _front_fog_mat: FogMaterial = null
var _wall_mult: float = 1.0
# "fog" raid mutator: when active, the GLOBAL volumetric fog base density is raised from 0 to
# Settings.MUTATOR_FOG_DENSITY (a permanent half-storm murk from t=0). The storm still wins
# while it is active (it tweens density higher); _restore_day resets BACK to this base, so the
# murk persists across the storm fade-out as long as the mutator is set.
var _fog_mutator_active := false

# Day-night throttle state (PERF): the Sky3D clock writes at 4 Hz; sun/ambient floats
# write only when sun_ratio actually changed. -1.0 sentinels force a write after any
# reset (match start / _restore_day) so a fresh raid never holds a stale sky.
var _tod_accum: float = 0.0
var _last_tod_hour: float = -1.0
var _last_sun_ratio: float = -1.0

# Climate-zone distance gate (PERF): the 3 landmark precip systems (~1700 particles)
# + their FogVolumes/Decals simulate even when nobody is in that quadrant. Checked at
# 1 Hz; 130m covers every zone radius (33-38m) + a 90m approach margin, so an 8s
# snow column is fully populated before flakes are resolvable. The full-map ambient
# dust/embers are deliberately NOT gated — the player is always inside those fields.
var _climate_gate_accum: float = 1.0
var _climate_root: Node3D = null

# D1 RELIGHT — per-biome light TEMPERATURE (see _apply_biome_look). Colour only: energy,
# rotation, fog and sky density all belong to _restore_day / the storm tween, and anything
# written here that they also write would be reverted on the next match start.
# Urban stays the neutral cold-steel reference the identity was tuned on; snow goes bluer
# and brighter in ambient (snow bounces), desert warms hard (sand bounces warm), rain goes
# cold and dim (overcast). The fill is the counter-sun, so it leans OPPOSITE the key.
const _BIOME_LOOK := {
	"urban":
	{
		"sun": Color(1.0, 0.965, 0.905),
		"fill": Color(0.58, 0.66, 0.80),
		"ambient": Color(0.50, 0.56, 0.66),
	},
	"snow":
	{
		"sun": Color(0.955, 0.975, 1.0),
		"fill": Color(0.62, 0.72, 0.88),
		"ambient": Color(0.58, 0.65, 0.78),
	},
	"desert":
	{
		"sun": Color(1.0, 0.925, 0.795),
		"fill": Color(0.66, 0.66, 0.72),
		"ambient": Color(0.64, 0.60, 0.53),
	},
	"rain":
	{
		"sun": Color(0.90, 0.945, 1.0),
		"fill": Color(0.54, 0.64, 0.78),
		"ambient": Color(0.48, 0.545, 0.63),
	},
}
var _biome_look_accum: float = 0.0


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
	# Raid mutators: the "fog" mutator lays a permanent half-storm murk from t=0; listen for
	# changes AND apply whatever the match already started with (the signal may have fired
	# before this node loaded).
	if Events and not Events.raid_mutator_changed.is_connected(_on_raid_mutator_changed):
		Events.raid_mutator_changed.connect(_on_raid_mutator_changed)
	if GameState:
		_apply_fog_mutator(GameState.raid_mutator == "fog")
	# Drive the day-night sky every frame (in _process). Headless already returned above.
	set_process(true)


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
			_env.sdfgi_energy = 1.2 if rt else 1.0
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
			_env.ssil_intensity = 1.15
		# Volumetric fog = the CARRIER for the localized FogVolume smoke banks ONLY. The
		# GLOBAL ambient density is ALWAYS ZERO (the map itself stays clear — the player
		# explicitly does not want whole-map haze); fog exists only inside the FogZones
		# placed at landmarks. volumetric_fog_length is raised so a smoke bank is visible
		# from across the 160 m map (the 80 m default culled zones beyond 80 m entirely).
		# The "volumetric_fog_density" setting is now the ZONES' density multiplier
		# (applied below via ProceduralFogZones.apply_density), not a global density.
		_env.volumetric_fog_enabled = bool(SettingsManager.get_value("volumetric_fog"))
		# Base global density is 0 normally, or the fog-mutator murk when that mutator is on.
		_base_vol_fog_density = _vol_fog_base()
		if _env.volumetric_fog_enabled:
			# Don't stomp the storm's higher density mid-storm; otherwise apply the base.
			if not _stormed:
				_env.volumetric_fog_density = _base_vol_fog_density
			_env.volumetric_fog_length = 220.0
			_env.volumetric_fog_detail_spread = 2.6
		# Rescale the local fog zones' density from the settings slider (live, no rebuild).
		ProceduralFogZones.apply_density(get_tree().current_scene if get_tree() else null)
		# Same live rescale for the localized climate zones (particle amount_ratio + fog density).
		ProceduralClimateZones.apply_density(get_tree().current_scene if get_tree() else null)
	# Soft-shadow FILTER quality (penumbra sampling noise, an image-quality knob —
	# the penumbra WIDTH itself is the sun's light_angular_distance, identical for
	# everyone). Derived from the preset level; no settings key of its own.
	var soft_q: Array = [
		RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
		RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
		RenderingServer.SHADOW_QUALITY_SOFT_ULTRA,
	]
	var sq: RenderingServer.ShadowQuality = soft_q[clampi(level, 0, 4)]
	RenderingServer.directional_soft_shadow_filter_set_quality(sq)
	RenderingServer.positional_soft_shadow_filter_set_quality(sq)
	# God rays: let the sun cast volumetric shafts THROUGH the global fog (no-op when
	# volumetric fog is off). Shadow distance also lives on the sun. Guard non-null.
	if _sun != null:
		_sun.light_volumetric_fog_energy = (
			1.0 if bool(SettingsManager.get_value("god_rays")) else 0.0
		)
		_sun.directional_shadow_max_distance = clampf(
			float(SettingsManager.get_value("shadow_distance")), 60.0, 250.0
		)
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
		Vector3(
			WorldBounds.CX - WorldBounds.SPAN * 0.5, -2.0, WorldBounds.CZ - WorldBounds.SPAN * 0.5
		),
		Vector3(WorldBounds.SPAN, 34.0, WorldBounds.SPAN)
	)
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(WorldBounds.CX, 14.0, WorldBounds.CZ)

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
		Vector3(
			WorldBounds.CX - WorldBounds.SPAN * 0.5, -2.0, WorldBounds.CZ - WorldBounds.SPAN * 0.5
		),
		Vector3(WorldBounds.SPAN, 30.0, WorldBounds.SPAN)
	)
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(WorldBounds.CX, 1.0, WorldBounds.CZ)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(WorldBounds.SPAN * 0.5, 4.0, WorldBounds.SPAN * 0.5)
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
	# The Sky3D node itself + its TimeOfDay child (drives the sky dome's clock). When Sky3D
	# is present, `we` IS the Sky3D node (Sky3D extends WorldEnvironment).
	_sky3d = we if (we != null and we.get("sky3d_enabled") != null) else null
	_tod = _find_tod(we)
	# "Two suns" guard: make absolutely sure Sky3D does NOT cast its own Sun/Moon lights and
	# does NOT auto-progress its clock — we own both (the Arena's root DirectionalLight3D for
	# light, DayNight for the clock). The scene already authors these off; re-assert at runtime
	# so a future scene edit / shared resource can't reintroduce a second sun.
	if _sky3d != null:
		_sky3d.set("lights_enabled", false)
		_sky3d.set("game_time_enabled", false)
		_sky3d.set("editor_time_enabled", false)
	if _tod != null:
		_tod.set("game_time_enabled", false)
		_tod.set("editor_time_enabled", false)
	# Our main shadow-casting sun lives at the scene root (NOT under Sky3D, whose
	# own SunLight/MoonLight are disabled). Prefer that one.
	_sun = _find_main_sun(root, we)
	_ensure_fill_light()
	if Settings and Settings.NET_DEBUG:
		print(
			"[atmosphere] env=",
			_env != null,
			" skydome=",
			_skydome != null,
			" tod=",
			_tod != null,
			" sun=",
			_sun != null
		)


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


## Finds the Sky3D TimeOfDay child by its signature properties (current_time + minutes_per_day,
## which the SkyDome does NOT have). Returns null when Sky3D is absent — the day-night drive
## then simply no-ops (env/sun-only). Searched among the WorldEnvironment's CHILDREN, so the
## Sky3D node's own current_time alias is not mistaken for it.
func _find_tod(we: Node) -> Node:
	if we == null:
		return null
	for c in we.get_children():
		if c.get("current_time") != null and c.get("minutes_per_day") != null:
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


## Create the weak cool shadow-side fill once (idempotent across arena reloads — the
## node lives under this atmosphere instance and dies with it). Not a "second sun" in
## the Sky3D sense: shadowless, ~1/6 the sun's energy, pure shade-legibility fill.
func _ensure_fill_light() -> void:
	if _fill != null and is_instance_valid(_fill):
		return
	_fill = DirectionalLight3D.new()
	_fill.name = "ShadeFill"
	_fill.light_color = Color(0.58, 0.66, 0.80)
	_fill.light_energy = FILL_ENERGY
	_fill.shadow_enabled = false
	_fill.rotation = Vector3(deg_to_rad(FILL_PITCH_DEG), deg_to_rad(115.0), 0.0)
	add_child(_fill)


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
	_stormed = false
	# _restore_day() also calls _storm_reset(), which puts the grass wind uniforms, the
	# debris field and the fog wall back — so a restart mid-storm leaves nothing behind.
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
		# Reset volumetric fog to its base density (0, or the fog-mutator murk), undoing the
		# storm thicken.
		if _env.volumetric_fog_enabled:
			_env.volumetric_fog_density = _vol_fog_base()
	if _sun != null:
		_sun.light_energy = DAY_SUN_ENERGY
		if _base_sun_rot != Vector3.ZERO:
			_sun.rotation = _base_sun_rot
	if _dust_mat != null:
		_dust_mat.color = DUST_DAY_COLOR
	# D6.4: everything the storm front owns OUTSIDE the properties reset above (grass wind
	# uniforms, debris emitter, fog wall, front/lightning sentinels). Kept here so there is
	# exactly ONE reset path for the whole atmosphere, shared by _ready and match start.
	_storm_reset()
	# Reset the sky clock + day-night sun/ambient to the match-start hour, so a fresh raid never
	# inherits the previous raid's night. The per-frame drive corrects to the true hour next
	# frame (e.g. immediately under the night_raid mutator). Guarded: this runs once at _ready
	# BEFORE _capture_baseline, when _base_sun_rot is still ZERO and _tod may be null — both
	# branches inside _apply_daynight are null-safe, and _base_sun_rot.y/.z = 0 is the harmless
	# default pre-capture (the authored yaw is applied from the very first _process frame).
	_apply_daynight(Settings.DAY_NIGHT_START_HOUR)


func _on_final_wave() -> void:
	if _stormed:
		return
	_stormed = true
	_storm_begin()


## Arm the front: pick the (deterministic) approach azimuth, capture the LIVE day values as
## the "from" side of every ramp, park the front fully upwind and build the render-only
## layers. From here `_storm_process` drives everything per frame — there is no Tween, so
## nothing keeps writing after a restart kills the state.
func _storm_begin() -> void:
	_storm_reset()
	_storm_seed = _match_seed()
	_front_time = maxf(3.0, Settings.STORM_TWEEN_TIME * FRONT_TIME_MULT)
	# Deterministic azimuth from the match seed: identical on every peer, different between
	# raids that differ in mutator/difficulty/duration, and never randf() (rules + habit).
	var ang: float = ProcHash.hf(_storm_seed) * TAU
	_front_dir = Vector2(sin(ang), cos(ang))
	_next_strike = ProcHash.hrange(_storm_seed + 17, STRIKE_MIN, STRIKE_MAX)
	_pre_sun_rot = _base_sun_rot
	if _sun != null:
		_pre_sun_energy = _sun.light_energy
		_pre_sun_rot = _sun.rotation
	if _env != null:
		_pre_ambient = _env.ambient_light_energy
		_pre_fog_density = _env.fog_density
		_pre_fog_color = _env.fog_light_color
		_pre_glow = _env.glow_intensity
	_wall_mult = clampf(float(SettingsManager.get_value("volumetric_fog_density")), 0.0, 2.0)
	_resolve_grass_mats()
	_ensure_debris()
	_ensure_front_fog()


## The match "seed" for the front azimuth. There is no per-raid world seed (the world is
## TERRAIN_SEED-fixed), so this folds in the three per-match values that ARE synced to
## every peer — mutator, difficulty and match duration — on top of the world seed.
func _match_seed() -> int:
	var m: int = 0
	if GameState != null:
		m = (
			GameState.raid_mutator.hash()
			+ GameState.difficulty * 7919
			+ int(GameState.match_duration)
		)
	return Settings.TERRAIN_SEED * 31 + m


## Late-load / already-in-the-final-wave: skip the arrival and hold the fully-passed look.
func _apply_storm_instant() -> void:
	_stormed = true
	_storm_begin()
	_storm_t = _front_time
	_front_s = FRONT_HALF_TRAVEL
	_apply_storm_mix(1.0)
	_drive_front_wall(1.0)


# ---------------------------------------------------------------------------
# Storm front — per-frame drive (replaces the old global Tween)
# ---------------------------------------------------------------------------
## One storm frame. `k` (0 = clear sky ahead of the wall, 1 = fully inside the storm) is a
## function of TIME (the front's position along its axis) and the CAMERA's distance to that
## front plane — which is what makes the storm a wave that passes rather than a fade.
func _storm_process(delta: float) -> void:
	_storm_t += delta
	var tt: float = clampf(_storm_t / _front_time, 0.0, 1.0)
	_front_s = lerpf(-FRONT_HALF_TRAVEL, FRONT_HALF_TRAVEL, tt)
	var cam := get_viewport().get_camera_3d()
	# No camera (headless never gets here; a frame between arena swaps can): hold the mix.
	var k: float = maxf(_last_storm_k, 0.0)
	if cam != null:
		var p: Vector3 = cam.global_position
		var d: float = (p.x - WorldBounds.CX) * _front_dir.x + (p.z - WorldBounds.CZ) * _front_dir.y
		k = smoothstep(-FRONT_SOFT, FRONT_SOFT, _front_s - d)
	_tick_lightning(delta, k)
	# PERF: the heavy writes (SkyDome shader params, fog, grass uniforms) only run while the
	# mix is actually moving — once the front has passed, k pins at 1.0 and this costs the
	# two light-energy floats below and nothing else.
	if absf(k - _last_storm_k) > 0.002:
		_apply_storm_mix(k)
	else:
		_apply_lights()
	_drive_debris(cam, k)
	_drive_front_wall(tt)


## Write the whole stormed look for mix `k`. Deliberately touches ONLY the properties
## `_restore_day()` also writes (plus the wind/particle layers `_storm_reset()` clears), so
## a match restart is guaranteed to undo every line of this.
func _apply_storm_mix(k: float) -> void:
	_last_storm_k = k
	if _skydome != null:
		_skydome.set("cumulus_coverage", lerpf(DAY_CUMULUS_COVERAGE, STORM_CUMULUS_COVERAGE, k))
		_skydome.set("cumulus_thickness", lerpf(DAY_CUMULUS_THICKNESS, STORM_CUMULUS_THICKNESS, k))
		_skydome.set("cumulus_intensity", lerpf(DAY_CUMULUS_INTENSITY, STORM_CUMULUS_INTENSITY, k))
		_skydome.set("atm_darkness", lerpf(DAY_ATM_DARKNESS, STORM_ATM_DARKNESS, k))
		_skydome.set("exposure", lerpf(DAY_SKYDOME_EXPOSURE, STORM_SKYDOME_EXPOSURE, k))
	# Targets are clamped against the LIVE pre-storm values so the storm can only ever
	# DARKEN (a night raid used to get a brighter sun when the storm hit), and floored so
	# the relight's readable threshold survives.
	var amb_target: float = maxf(minf(_pre_ambient, _base_ambient * 0.5), STORM_AMBIENT_FLOOR)
	_storm_amb_e = lerpf(_pre_ambient, amb_target, k)
	_storm_sun_e = lerpf(_pre_sun_energy, minf(_pre_sun_energy, _base_sun_energy * 0.4), k)
	if _env != null:
		_env.fog_density = lerpf(_pre_fog_density, _pre_fog_density * 3.2, k)
		_env.fog_light_color = _pre_fog_color.lerp(STORM_FOG_COLOR, k)
		_env.glow_intensity = lerpf(_pre_glow, _pre_glow * 1.25, k)
		if _env.volumetric_fog_enabled:
			_env.volumetric_fog_density = lerpf(_base_vol_fog_density, STORM_VOLUMETRIC_DENSITY, k)
	if _sun != null:
		# Roll the sun lower/sideways like the cloud deck sweeping in.
		_sun.rotation = _pre_sun_rot + Vector3(deg_to_rad(-18.0) * k, deg_to_rad(35.0) * k, 0.0)
	if _dust_mat != null:
		_dust_mat.color = DUST_DAY_COLOR.lerp(DUST_STORM_COLOR, k)
	if _embers != null:
		# Thicken the embers, but stay MULTIPLIED by the user's particle-density lever
		# instead of stomping it to 1.0 the way the old tween did.
		_embers.amount_ratio = clampf(_particle_density() * lerpf(1.0, 1.5, k), 0.0, 1.0)
	_apply_wind(k)
	_apply_lights()


## The two per-frame light floats: the mixed energies plus the lightning spike. Split out of
## _apply_storm_mix so a flash never has to re-run the heavy writes (and can never fight
## them — it is strictly additive on top of the mixed value).
func _apply_lights() -> void:
	if _sun != null:
		_sun.light_energy = _storm_sun_e + FLASH_SUN * _flash
	if _env != null:
		_env.ambient_light_energy = _storm_amb_e + FLASH_AMBIENT * _flash


# ---------------------------------------------------------------------------
# Day-night cycle (per-frame; a pure function of the synced match clock via DayNight)
# ---------------------------------------------------------------------------
## Drive the sky clock + sun + ambient from the match timer every frame while a match is
## running. The STORM owns the look once it has fired (its tween animates the same props), so
## skip entirely while `_stormed`. Works offline too — DayNight reads GameState, which is set
## in single-player as well as co-op. Headless never reaches here (set_process false in _ready
## via the early return).
func _process(delta: float) -> void:
	if GameState == null or GameState.phase != GameState.Phase.IN_MATCH:
		# Match over (results screen): the sky/fog hold until _restore_day, but the storm's
		# own particle field must stop — it would otherwise keep blowing behind RaidSummary.
		if _debris != null and is_instance_valid(_debris) and _debris.emitting:
			_debris.emitting = false
		return
	# Housekeeping that must keep running in BOTH phases: the climate gate is a PERF gate
	# (it would otherwise freeze mid-storm, leaving far-quadrant precip simulating), and the
	# biome look writes light COLOUR only — the storm owns energy/rotation/fog, so the two
	# never write the same property and a storm still reads as its biome.
	_climate_gate_accum += delta
	if _climate_gate_accum >= 1.0:
		_climate_gate_accum = 0.0
		_gate_climate_zones()
	_biome_look_accum += delta
	if _biome_look_accum >= 0.25:
		_apply_biome_look(_biome_look_accum)
		_biome_look_accum = 0.0
	if _stormed:
		_storm_process(delta)
		return
	# PERF: the Sky3D TimeOfDay setter runs a full celestial recompute (trig + sky
	# shader params + signals) on EVERY write, and the sun/ambient writes dirty the
	# environment — at 12 in-game hours per match the per-frame delta is invisible.
	# Throttle the expensive sky-clock write to 4 Hz (dome step ≈0.08° — sub-pixel)
	# and gate the cheap sun/ambient floats on an actual sun_ratio change (the ratio
	# plateaus at 1.0 all day / 0.0 deep night, so writes only happen across the
	# dawn/dusk ramps — per-frame-smooth exactly where the eye watches the change).
	var hour: float = DayNight.current_hour()
	_tod_accum += delta
	if _tod_accum >= 0.25:
		_tod_accum = 0.0
		if _tod != null and absf(hour - _last_tod_hour) > 0.0005:
			_last_tod_hour = hour
			_tod.set("current_time", hour)
	var s: float = DayNight.sun_ratio(hour)
	if absf(s - _last_sun_ratio) > 0.0005:
		_last_sun_ratio = s
		_apply_sun_ambient(s)


## Apply one day-night frame for the given in-game hour: spin the Sky3D dome to that hour and
## lerp the Arena sun energy + pitch and the WorldEnvironment ambient off DayNight.sun_ratio.
## Used by the throttled _process drive and as the FORCED reset in _restore_day (which also
## clears the throttle sentinels so the next frame re-writes everything).
func _apply_daynight(hour: float) -> void:
	if _tod != null:
		_tod.set("current_time", hour)
	_last_tod_hour = hour
	var s: float = DayNight.sun_ratio(hour)
	_last_sun_ratio = s
	_apply_sun_ambient(s)


## D1 RELIGHT — per-biome LIGHT COLOUR (not energy): the four quadrants shared one white
## sun and one ambient, so snow, desert, rain and urban only differed by ground tint and
## particles. Each biome now carries its own sun/fill/ambient temperature, which is what
## actually makes a place read as somewhere.
##
## THREE CONSTRAINTS THIS FUNCTION IS BUILT AROUND:
##  1. `_restore_day()` and the storm tween own `light_energy`, `rotation`, `ambient_energy`,
##     `fog_*`, `glow_intensity` and the SkyDome cumulus/darkness/exposure — writing any of
##     those here would be silently reverted on every match start. So this touches ONLY
##     colour: sun colour, fill colour, ambient colour.
##  2. `WorldBounds.biome_at` is a hard split at the map centre with no seam, so blending by
##     POSITION would pop. We blend in TIME instead (exponential approach), which reads as
##     the light changing as you walk into a region.
##  3. `_apply_sun_ambient` only runs when `sun_ratio` CHANGES, and that ratio plateaus for
##     most of the match — anything put in there would freeze mid-day. Hence the own tick.
func _apply_biome_look(delta: float) -> void:
	if _sun == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var p: Vector3 = cam.global_position
	var look: Dictionary = _BIOME_LOOK.get(WorldBounds.biome_at(p.x, p.z), _BIOME_LOOK["urban"])
	# Exponential approach — frame-rate independent, ~1.5 s to cross a biome border.
	var k: float = 1.0 - exp(-delta * 2.2)
	var sun_c: Color = look["sun"]
	var fill_c: Color = look["fill"]
	var amb_c: Color = look["ambient"]
	_sun.light_color = _sun.light_color.lerp(sun_c, k)
	if _fill != null:
		_fill.light_color = _fill.light_color.lerp(fill_c, k)
	if _env != null:
		_env.ambient_light_color = _env.ambient_light_color.lerp(amb_c, k)


## PERF: pause the landmark climate systems (precip particles / fog volume / ground
## decal) while the camera is far from that zone. Visibility only — deterministic
## world build untouched. Re-resolves the ClimateZones root per arena (it dies with
## the world); a camera-less frame (hub/menu) gates everything off.
func _gate_climate_zones() -> void:
	if _climate_root == null or not is_instance_valid(_climate_root):
		_climate_root = null
		var arena: Node = get_tree().get_first_node_in_group(Groups.ARENA)
		if arena != null:
			_climate_root = arena.find_child("ClimateZones", true, false) as Node3D
	if _climate_root == null:
		return
	var cam := get_viewport().get_camera_3d()
	for zone in _climate_root.get_children():
		if not (zone is Node3D):
			continue
		var near := (
			cam != null
			and (
				cam.global_position.distance_squared_to((zone as Node3D).global_position)
				< 130.0 * 130.0
			)
		)
		var precip := zone.get_node_or_null("Precip") as GPUParticles3D
		if precip != null and precip.emitting != near:
			precip.emitting = near
		var fog := zone.get_node_or_null("ClimateFog") as FogVolume
		if fog != null and fog.visible != near:
			fog.visible = near
		var tint := zone.get_node_or_null("GroundTint") as Decal
		if tint != null and tint.visible != near:
			tint.visible = near


## The cheap per-ramp writes: sun energy + pitch and the environment ambient.
func _apply_sun_ambient(s: float) -> void:
	if _sun != null:
		_sun.light_energy = lerpf(NIGHT_SUN_ENERGY, DAY_SUN_ENERGY, s)
		# Only sweep pitch once the authored yaw/roll have been captured — before that (the
		# single _restore_day call inside _ready, pre-capture) leave rotation untouched so
		# _capture_baseline reads the real authored sun rotation, not a zero-yaw computed one.
		if _captured:
			var pitch: float = deg_to_rad(lerpf(DAYNIGHT_PITCH_LOW, DAYNIGHT_PITCH_HIGH, s))
			_sun.rotation = Vector3(pitch, _base_sun_rot.y, _base_sun_rot.z)
	if _env != null:
		_env.ambient_light_energy = lerpf(NIGHT_AMBIENT, DAY_AMBIENT, s)
		# D1 RELIGHT — the ambient SOURCE is SKY (default_env.tres `ambient_light_source = 3`),
		# which means `ambient_light_color` was inert and raising `ambient_light_energy` at
		# night only scaled a nearly-black night sky: measured night frames sat at 97-99% of
		# world pixels under the readable floor no matter what the energy said. Blending the
		# sky DOWN at night hands those frames the explicit (cool, per-biome) ambient colour
		# instead, which is the only ambient with any level in it after dusk. Daylight keeps
		# a sky-dominated blend so outdoor shading still picks up real sky colour.
		_env.ambient_light_sky_contribution = lerpf(NIGHT_SKY_CONTRIB, DAY_SKY_CONTRIB, s)
	# Cool shadow-side FILL (texture-quality pass): with SDFGI driving indirect light the
	# env ambient barely reaches steep shaded faces — buildings read as pure coal from
	# their south-west. A weak shadowless counter-sun keeps shade legible; scaled down at
	# night so the dark identity survives.
	if _fill != null:
		_fill.light_energy = FILL_ENERGY * lerpf(0.35, 1.0, s)
		if _captured:
			_fill.rotation = Vector3(deg_to_rad(FILL_PITCH_DEG), _base_sun_rot.y + PI, 0.0)
	# Night identity: warm window panes (shared glass pool) + street-lamp lights/heads
	# fade IN as the sun fades OUT. Render-only; already throttled by the caller's
	# sun_ratio change gate, so these writes only happen across the dawn/dusk ramps.
	var night: float = 1.0 - s
	var pool: Array[StandardMaterial3D] = ProceduralBuildings.glass_pool()
	if pool.size() == 3:
		# Glass is now TRANSPARENT (alpha-blended) — the blend scales perceived
		# emission down ~×0.3, so the night multipliers compensate (was 1.2 / 2.6).
		pool[1].emission_energy_multiplier = 3.5 * night
		pool[2].emission_energy_multiplier = 7.5 * night
	for ln in get_tree().get_nodes_in_group(Groups.NIGHT_LIGHTS):
		var lamp := ln as OmniLight3D
		if lamp == null:
			continue
		# D1 RELIGHT 2.2 → 3.4: a night frame is legitimately dark overall, so what makes it
		# NAVIGABLE is not a raised floor but readable pools of light to move between.
		lamp.light_energy = 3.4 * night
		var gm: Variant = lamp.get_meta("night_glow_mat", null)
		if gm is StandardMaterial3D:
			(gm as StandardMaterial3D).emission_energy_multiplier = 3.0 * night


# ---------------------------------------------------------------------------
# Fog raid mutator
# ---------------------------------------------------------------------------
## The base GLOBAL volumetric-fog density for normal play: 0 (fog lives only in FogZones),
## or Settings.MUTATOR_FOG_DENSITY while the "fog" mutator is active.
func _vol_fog_base() -> float:
	return Settings.MUTATOR_FOG_DENSITY if _fog_mutator_active else 0.0


## React to the active raid mutator changing mid-session (server broadcasts it). Only the fog
## mutator changes anything here; night_raid is handled purely by DayNight.current_hour (the
## clock start shifts), and the per-frame drive picks it up with no extra work.
func _on_raid_mutator_changed(mutator: String) -> void:
	_apply_fog_mutator(mutator == "fog")


## Turn the fog-mutator murk on/off: update the tracked base and, unless the storm currently
## owns the density, write it live so the change is immediate. The storm tween (if active) keeps
## its higher value; _restore_day will settle back onto this base when the storm clears.
func _apply_fog_mutator(active: bool) -> void:
	_fog_mutator_active = active
	_base_vol_fog_density = _vol_fog_base()
	if _env == null or _stormed:
		return
	if _env.volumetric_fog_enabled:
		_env.volumetric_fog_density = _base_vol_fog_density
	# Volumetric fog is a manual graphics lever (off for most presets) and the murk is
	# gated on it — exactly like the storm's. So the mutator ALSO raises the classic
	# distance fog (gate-free) or it would be a visual no-op on those configs; the
	# baseline DAY_FOG_DENSITY is near-imperceptible, ×12 reads as a hazy raid.
	_env.fog_density = DAY_FOG_DENSITY * (12.0 if active else 1.0)


# ---------------------------------------------------------------------------
# D6.4 — WIND (live grass shader uniforms)
# ---------------------------------------------------------------------------
## Push the grass wind uniforms with the storm mix. procedural_flora builds ONE shared
## ShaderMaterial for every grass tile of both LOD layers, so this is a handful of
## set_shader_parameter calls no matter how many tiles exist — and only on a mix change.
## Values only: the material instance, the shader and the flora builder are never touched,
## and k=0 writes the captured base back verbatim.
func _apply_wind(k: float) -> void:
	for i in range(_grass_mats.size()):
		var m: ShaderMaterial = _grass_mats[i]
		if m == null:
			continue
		var b: Vector2 = _grass_base_wind[i]
		m.set_shader_parameter("sway_strength", b.x * lerpf(1.0, WIND_SWAY_MULT, k))
		m.set_shader_parameter("sway_speed", b.y * lerpf(1.0, WIND_SPEED_MULT, k))


## Find the live grass material(s) + remember their authored wind values. Resolved fresh at
## every storm start (the arena — and its materials — die with the raid), and dropped in
## _storm_reset so a stale material from a previous world is never written to.
## NOTE: trees/bushes are Quaternius StandardMaterial3D (no wind uniform at all), so the
## storm wind reads through the grass, the debris and the fog wall only — giving the
## canopies sway needs a vertex-wind shader in the flora lane, not here.
func _resolve_grass_mats() -> void:
	_grass_mats.clear()
	_grass_base_wind.clear()
	var arena: Node = get_tree().get_first_node_in_group(Groups.ARENA)
	if arena == null:
		return
	var flora: Node = arena.find_child("Flora", true, false)
	if flora == null:
		return
	var roots: PackedStringArray = ["Grass_Near", "Grass_Far"]
	for gname in roots:
		var groot: Node = flora.get_node_or_null(NodePath(gname))
		if groot == null:
			continue
		for c in groot.get_children():
			var mmi := c as MultiMeshInstance3D
			if mmi == null:
				continue
			# Every tile under a root shares the SAME material instance — one probe is enough.
			var m := mmi.material_override as ShaderMaterial
			if m != null and not _grass_mats.has(m):
				_grass_mats.append(m)
				_grass_base_wind.append(
					Vector2(_shader_f(m, "sway_strength", 0.34), _shader_f(m, "sway_speed", 2.0))
				)
			break


## Read a float shader uniform with a fallback. Written as an if (not a ternary): a
## `var x := <Variant>` inference is a hard parse error in this project's warnings-as-errors
## build, and get_shader_parameter returns Variant/null.
func _shader_f(m: ShaderMaterial, key: String, fallback: float) -> float:
	var v: Variant = m.get_shader_parameter(key)
	if v == null:
		return fallback
	return float(v)


# ---------------------------------------------------------------------------
# D6.4 — WIND-BLOWN DEBRIS
# ---------------------------------------------------------------------------
## Build the (single, pooled-by-construction) debris emitter once. Alpha-blended light
## scraps — never additive, and never a volume you can be inside.
func _ensure_debris() -> void:
	if _debris != null and is_instance_valid(_debris):
		_orient_debris()
		return
	var p := GPUParticles3D.new()
	p.name = "StormDebris"
	p.amount = DEBRIS_COUNT
	p.lifetime = 3.2
	p.randomness = 1.0
	p.fixed_fps = 30
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# GLOBAL coords (the engine default, made explicit): the emitter node rides the camera,
	# so local coords would drag already-spawned scraps along with it instead of letting
	# them stream past the player.
	p.local_coords = false
	# Local AABB (the node rides the camera), generous enough that fast scraps never pop out.
	p.visibility_aabb = AABB(Vector3(-60.0, -30.0, -60.0), Vector3(120.0, 70.0, 120.0))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = DEBRIS_BOX * 0.5
	pm.spread = 22.0
	pm.initial_velocity_min = DEBRIS_SPEED_MIN
	pm.initial_velocity_max = DEBRIS_SPEED_MAX
	pm.scale_min = 0.5
	pm.scale_max = 1.5
	pm.angular_velocity_min = -220.0
	pm.angular_velocity_max = 220.0
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.6
	pm.turbulence_noise_scale = 1.4
	pm.turbulence_influence_min = 0.2
	pm.turbulence_influence_max = 0.7
	pm.color = DEBRIS_COLOR
	_debris_mat = pm
	p.process_material = pm
	p.draw_pass_1 = _scrap_mesh()
	add_child(p)
	p.emitting = false
	_debris = p
	_orient_debris()


## Point the debris field down the front's travel direction (called per storm — the azimuth
## is re-rolled every match).
func _orient_debris() -> void:
	if _debris_mat == null:
		return
	_debris_mat.direction = Vector3(_front_dir.x, 0.06, _front_dir.y)
	# A little downwind acceleration + slight sink, so scraps skate rather than fall.
	_debris_mat.gravity = Vector3(_front_dir.x * 6.0, -1.6, _front_dir.y * 6.0)


## Small tumbling scrap quad. ALPHA blend (see DEBRIS_COLOR) and a light tan tone — the
## relight brief bans new dark surfaces, and additive volumes you can stand inside.
func _scrap_mesh() -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(0.13, 0.09)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_color = DEBRIS_COLOR
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	q.material = m
	return q


## Ride the camera (offset UPWIND so scraps blow past the player). Parking the emitter on
## the camera IS the distance gate: the field only ever simulates where someone is looking,
## and it stops emitting entirely until the front actually reaches them.
func _drive_debris(cam: Camera3D, k: float) -> void:
	if _debris == null or not is_instance_valid(_debris):
		return
	var on: bool = cam != null and k > 0.10
	if _debris.emitting != on:
		_debris.emitting = on
	if not on:
		return
	var p: Vector3 = cam.global_position
	_debris.global_position = Vector3(
		p.x - _front_dir.x * DEBRIS_UPWIND, p.y + 2.0, p.z - _front_dir.y * DEBRIS_UPWIND
	)
	if absf(k - _debris_k) > 0.02:
		_debris_k = k
		_debris.amount_ratio = clampf(k * _particle_density(), 0.0, 1.0)


## The user's particle-density lever (shared by the embers + debris scaling).
func _particle_density() -> float:
	return clampf(float(SettingsManager.get_value("particle_density")), 0.0, 1.5)


# ---------------------------------------------------------------------------
# D6.4 — THE VISIBLE WALL (travelling box FogVolume)
# ---------------------------------------------------------------------------
## Build the map-spanning fog slab that travels with the front, so the storm is something
## you watch ARRIVE. Only exists when volumetric fog is enabled — FogVolumes are invisible
## otherwise, and the mix's distance-fog ramp already carries the arrival on those configs.
func _ensure_front_fog() -> void:
	if _env == null or not _env.volumetric_fog_enabled:
		if _front_fog != null and is_instance_valid(_front_fog):
			_front_fog.visible = false
		return
	if _front_fog == null or not is_instance_valid(_front_fog):
		var f := FogVolume.new()
		f.name = "StormFront"
		f.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
		f.size = Vector3(WorldBounds.SPAN * 1.7, WALL_HEIGHT, WALL_THICK)
		var mat := FogMaterial.new()
		mat.density = 0.0
		mat.albedo = WALL_ALBEDO
		# A wide edge fade is what makes walking INTO the wall read as fog rolling over you
		# rather than crossing a hard plane (the FogZones lesson).
		mat.edge_fade = 0.65
		mat.height_falloff = 0.05
		f.material = mat
		_front_fog_mat = mat
		add_child(f)
		_front_fog = f
	# Local +Z must point along the travel direction (a Y-rotation by θ maps +Z to
	# (sin θ, 0, cos θ)), so the slab's THICKNESS is along the wind and its width spans
	# the map across it.
	_front_fog.rotation = Vector3(0.0, atan2(_front_dir.x, _front_dir.y), 0.0)
	_front_fog.visible = false


## Slide the wall along the front axis and fade its density in at the map edge / out once it
## has swept past, so it never lingers as a static slab over the downwind quadrant.
func _drive_front_wall(tt: float) -> void:
	if _front_fog == null or not is_instance_valid(_front_fog):
		return
	var vis: bool = tt < 0.999
	if _front_fog.visible != vis:
		_front_fog.visible = vis
	if not vis:
		return
	_front_fog.global_position = Vector3(
		WorldBounds.CX + _front_dir.x * _front_s,
		WALL_HEIGHT * 0.30,
		WorldBounds.CZ + _front_dir.y * _front_s
	)
	if _front_fog_mat != null:
		var a: float = smoothstep(0.0, 0.10, tt) * (1.0 - smoothstep(0.80, 1.0, tt))
		_front_fog_mat.density = WALL_DENSITY * a * _wall_mult


# ---------------------------------------------------------------------------
# D6.4 — LIGHTNING
# ---------------------------------------------------------------------------
## Decay the current flash and, on a deterministic schedule, fire a new strike. No bolt
## geometry and no new material: the flash is a scalar that `_apply_lights` ADDS on top of
## the mixed sun + ambient energies, so it can never fight the per-frame storm drive and
## `_storm_reset()` clearing `_flash` is enough to undo it.
func _tick_lightning(delta: float, k: float) -> void:
	_flash_t += delta
	_flash = 0.0
	if _flash_t < FLASH_LEN:
		# Decaying flicker (the double-blink of a real strike) — one sin, no allocations.
		var u: float = _flash_t / FLASH_LEN
		_flash = clampf((1.0 - u) * (0.55 + 0.45 * sin(u * 26.0)), 0.0, 1.0)
	# No lightning in the clear sky AHEAD of the wall — the first strike IS the arrival.
	if k < STRIKE_K_MIN:
		return
	_strike_accum += delta
	if _strike_accum < _next_strike:
		return
	_strike_accum = 0.0
	_strike_idx += 1
	_next_strike = ProcHash.hrange(_storm_seed + _strike_idx * 7919, STRIKE_MIN, STRIKE_MAX)
	_flash_t = 0.0
	# Strike point: on the front line, offset laterally (deterministic, so every peer
	# flashes on the same schedule for free — render-only, no RPC).
	var lat: float = (
		ProcHash.hrange(_storm_seed + _strike_idx * 104729, -0.5, 0.5) * WorldBounds.SPAN
	)
	var perp := Vector2(_front_dir.y, -_front_dir.x)
	var sp := Vector2(WorldBounds.CX, WorldBounds.CZ) + _front_dir * (_front_s + 20.0) + perp * lat
	_last_strike_pos = Vector3(sp.x, 34.0, sp.y)
	_last_strike_dist = 90.0
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		_last_strike_dist = cam.global_position.distance_to(_last_strike_pos)
	_last_strike_delay = _last_strike_dist / SOUND_SPEED
	# AUDIO HOOK (lead): THUNDER goes here. The strike is already resolved into
	# `_last_strike_pos` (world), `_last_strike_dist` (m) and `_last_strike_delay`
	# (seconds = dist / 340 m/s — a far strike should rumble ~0.6 s late and quieter, a near
	# one crack almost immediately). AudioManager is not mine to call, so wire e.g.
	#   AudioManager.play_delayed_3d("thunder", _last_strike_pos, _last_strike_delay)
	# here (or emit a new Events signal if you'd rather keep this file signal-free).


# ---------------------------------------------------------------------------
# D6.4 — reset
# ---------------------------------------------------------------------------
## Undo everything the storm front owns beyond the properties `_restore_day()` already
## rewrites. Called FROM `_restore_day()` (so _ready + every match start hit it) and again
## at `_storm_begin()` so an interrupted storm can never leave doubled state behind.
## Null-safe by construction: at the `_ready` call none of these layers exist yet.
func _storm_reset() -> void:
	_storm_t = 0.0
	_front_s = -FRONT_HALF_TRAVEL
	_last_storm_k = -1.0
	_debris_k = -1.0
	_flash = 0.0
	_flash_t = 1000.0
	_strike_accum = 0.0
	_strike_idx = 0
	_next_strike = STRIKE_MIN
	# Put the authored wind back BEFORE dropping the references (a new raid rebuilds the
	# world and resolves fresh materials anyway, but the old ones must not be left gusting).
	_apply_wind(0.0)
	_grass_mats.clear()
	_grass_base_wind.clear()
	if _debris != null and is_instance_valid(_debris):
		_debris.emitting = false
	if _front_fog != null and is_instance_valid(_front_fog):
		_front_fog.visible = false
		if _front_fog_mat != null:
			_front_fog_mat.density = 0.0
	if _embers != null:
		_embers.amount_ratio = clampf(_particle_density(), 0.0, 1.0)
