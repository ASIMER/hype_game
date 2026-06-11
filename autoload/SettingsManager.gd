extends Node
## Loads, applies, and persists user settings (graphics / audio / controls) via a
## ConfigFile at user://settings.cfg. The Settings menu reads/writes through here.
## All display calls are guarded for headless so import/CI never crash.

signal settings_changed(key: String, value: Variant)


# Per-instance settings path (Settings.user_path) so parallel game instances don't
# race on the shared settings.cfg. Single instance → user://settings.cfg.
func _path() -> String:
	return Settings.user_path("settings", "cfg")


const DEFAULTS := {
	# Graphics
	"window_mode": 0,  # 0 windowed, 1 borderless fullscreen, 2 exclusive fullscreen
	"resolution": "1280x720",
	"vsync": 1,  # 0 off, 1 on, 2 adaptive
	"msaa": 2,  # 0 off, 1 2x, 2 4x, 3 8x
	"shadows": 2,  # 0 1024, 1 2048, 2 4096, 3 8192
	"fov": 60.0,  # 60..100
	# Graphics quality (Godot does NOT auto-scale to hardware — these presets do it).
	"graphics_quality": 3,  # 0 Low, 1 Medium, 2 High, 3 Ultra, 4 Ultra+RT (default = Ultra)
	"render_scale": 1.0,  # 0.5..1.0 viewport 3D render scale (FSR-style upscale; cheapest lever)
	"sdfgi": true,  # global illumination (heavy)
	"ssao": true,  # ambient occlusion
	"glow": true,  # bloom
	"clouds": true,  # Sky3D volumetric cumulus
	"water_refraction": true,  # screen-space refractive water (vs flat cheap water)
	"grass_density": 1.0,  # 0.3..1.0 grass-cap multiplier (rebuild-bound; applies next raid)
	# "RT-style" reflections/GI tier (raster — Godot 4.6.3 has NO hardware ray tracing).
	"ssr": false,  # screen-space reflections (Forward+; water/metal/wet) — Ultra+RT only
	"ssil": false,  # screen-space indirect lighting — Ultra+RT only
	"reflection_probes": false,  # baked ReflectionProbes at POIs (rebuild-bound; off-screen reflections)
	"voxelgi": false,  # EXPERIMENTAL voxel GI bake (rebuild-bound; heavy — never in a preset)
	# Cinematic pass III — sliders have SANE CLAMPS but a "beyond Ultra" headroom; presets stay
	# safe, the player can crank further. Numeric value is shown beside each slider in the menu.
	"draw_distance": 1.0,  # 0.5..2.0 flora/grass visibility-range multiplier (rebuild-bound)
	"particle_density": 1.0,  # 0.0..1.5 ambient dust/ember amount multiplier (immediate)
	"terrain_detail": 1.0,  # 1.0..2.0 ground-mesh subdivision multiplier (rebuild-bound)
	"volumetric_fog_density": 1.0,  # 0.0..2.0 LOCAL fog-zone density multiplier (immediate; global density is always 0)
	"shadow_distance": 140.0,  # 60..250 m directional shadow max distance (immediate)
	"dof_amount": 0.0,  # 0.0..0.2 far depth-of-field blur amount (immediate; 0 = none)
	"volumetric_fog": false,  # enable the global froxel volumetric fog (immediate)
	"local_fog": false,  # spawn localized FogVolume zones at POIs (rebuild-bound)
	"climate_zones": true,  # spawn localized rain/snow/desert zones at the far landmarks (rebuild-bound)
	"climate_density": 1.0,  # 0.0..2.0 climate precipitation/haze density multiplier (immediate)
	"god_rays": false,  # sun light shafts through the volumetric fog (immediate)
	"dof": false,  # cinematic far depth-of-field (immediate)
	"terrain_parallax": false,  # parallax-occlusion mapping on the ground (rebuild-bound; heavy)
	# Diagnostics overlay
	"language": "en",  # UI locale ("en" base/fallback, "ru", ... — TranslationServer)
	"show_fps": false,  # minimal FPS counter
	"show_detailed_stats": false,  # full perf + network panel
	"stats_display_mode": 0,  # 0 Numeric, 1 Graphs, 2 Graphs+Numbers
	"ui_fx_enabled": true,  # "military glass" UI FX: scanline/grain/vignette + modal blur
	# Interface / HUD layout (ultrawide comfort — lives in the Interface settings tab).
	"ui_edge_margin": 0.0,  # 0.0..0.2 pull edge-anchored UI in toward center (frac of width)
	"ui_top_margin": 0.0,  # 0.0..0.2 vertical inset for top/bottom-anchored UI (frac of height)
	"hud_scale": 1.0,  # 0.8..1.4 global UI scale (Window.content_scale_factor)
	# Camera (third-person rig — also in the Interface tab).
	"camera_distance": 1.0,  # 0.6..1.4 × default third-person spring length
	"camera_shoulder": 1.0,  # 0.0..1.0 × over-the-shoulder side offset
	"default_view": 0,  # 0 third-person, 1 first-person (on spawn)
	# Audio (linear 0..1)
	"master_volume": 0.9,
	"sfx_volume": 0.9,
	"mute": false,
	# Controls
	"sensitivity": 1.0,  # multiplier of Settings.MOUSE_SENSITIVITY
	"invert_y": false,
	"ads_toggle": false,  # false = hold to aim, true = toggle
}

const RES_OPTIONS := ["1280x720", "1600x900", "1920x1080", "2560x1440", "960x540"]
const SHADOW_SIZES := [1024, 2048, 4096, 8192]

## Curated resolutions across aspect ratios (16:9 / 16:10+MacBook / 21:9 / 32:9). The actual
## dropdown is built at runtime from this, FILTERED to the monitor's native size — so a 32:9 or
## 16:10/MacBook panel gets the right modes, not a fixed 16:9 list.
const RES_CANDIDATES := [
	# 16:9
	"1280x720",
	"1600x900",
	"1920x1080",
	"2560x1440",
	"3840x2160",
	# 16:10 / MacBook (incl. notched ~1.54 panels)
	"1280x800",
	"1440x900",
	"1680x1050",
	"1920x1200",
	"2560x1600",
	"2880x1800",
	"2560x1664",
	"3024x1964",
	"3456x2234",
	# 21:9 ultrawide
	"2560x1080",
	"3440x1440",
	"3840x1600",
	# 32:9 super-ultrawide
	"3840x1080",
	"5120x1440",
	"5120x2160",
]


## Builds the resolution dropdown list at runtime: the curated candidates that fit within the
## monitor's native size, plus the native resolution itself (so any panel — ultrawide, 16:10,
## MacBook — is selectable), plus the currently-saved value (so a res saved on another monitor
## stays selectable). Sorted by area. Headless falls back to RES_OPTIONS.
func build_resolution_list() -> Array:
	if _headless():
		return RES_OPTIONS.duplicate()
	var native := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	var seen := {}
	var out: Array = []
	# Candidates that fit the native panel.
	for r in RES_CANDIDATES:
		var s := _parse_res(r)
		if s.x <= native.x and s.y <= native.y and not seen.has(r):
			seen[r] = true
			out.append(r)
	# Always include the exact native + the saved value.
	var native_str := "%dx%d" % [native.x, native.y]
	if not seen.has(native_str):
		seen[native_str] = true
		out.append(native_str)
	var saved := str(get_value("resolution"))
	if saved != "" and not seen.has(saved):
		seen[saved] = true
		out.append(saved)
	# Sort by pixel area so the list reads small→large.
	out.sort_custom(
		func(a, b):
			var sa := _parse_res(a)
			var sb := _parse_res(b)
			return sa.x * sa.y < sb.x * sb.y
	)
	return out


## "WxH" → Vector2i (0,0 on a malformed string).
func _parse_res(res: String) -> Vector2i:
	var parts := res.split("x")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


## Quality preset table. Index = graphics_quality (0 Low → 3 Ultra → 4 Ultra+RT). Ultra =
## the hand-tuned look; Ultra+RT = Ultra plus the raster "RT-style" reflection/GI stack
## (SSR + SSIL + reflection probes + max SDFGI). apply_quality_preset() writes each of these
## into the live settings, then the per-lever apply functions + Events.graphics_quality_changed
## carry them to the viewport / Environment / sky / grass / water. Order: Low, Med, High, Ultra, Ultra+RT.
const QUALITY_PRESETS := {
	"render_scale": [0.6, 0.75, 0.9, 1.0, 1.0],
	"msaa": [0, 1, 2, 2, 2],  # off / 2x / 4x / 4x / 4x
	"shadows": [0, 1, 2, 2, 3],  # 1024 / 2048 / 4096 / 4096 / 8192
	"sdfgi": [false, false, true, true, true],
	"ssao": [false, false, true, true, true],
	"glow": [true, true, true, true, true],
	"clouds": [false, true, true, true, true],
	"water_refraction": [false, false, true, true, true],
	"grass_density": [0.3, 0.6, 0.85, 1.0, 1.0],
	# RT-style tier (index 4 only): screen-space reflections + indirect light + baked probes.
	# voxelgi stays false in every preset — it's an experimental manual-only toggle.
	"ssr": [false, false, false, false, true],
	"ssil": [false, false, false, false, true],
	"reflection_probes": [false, false, false, false, true],
	"voxelgi": [false, false, false, false, false],
	# Cinematic pass III — tasteful defaults per tier; sliders can push beyond ("Custom").
	"draw_distance": [0.6, 0.8, 1.0, 1.0, 1.2],
	"particle_density": [0.3, 0.5, 0.85, 1.0, 1.0],
	"terrain_detail": [1.0, 1.0, 1.0, 1.3, 1.5],
	"volumetric_fog_density": [1.0, 1.0, 1.0, 1.0, 1.0],
	"shadow_distance": [80.0, 110.0, 140.0, 160.0, 200.0],
	"dof_amount": [0.0, 0.0, 0.0, 0.06, 0.08],
	"volumetric_fog": [false, false, false, true, true],
	"local_fog": [false, false, false, true, true],
	"climate_zones": [true, true, true, true, true],
	"climate_density": [0.5, 0.7, 1.0, 1.0, 1.2],
	"god_rays": [false, false, true, true, true],
	"dof": [false, false, false, true, true],
	"terrain_parallax": [false, false, false, true, true],
}

var _values: Dictionary = {}

## Set once if a save from a NEWER game version was loaded this session (guards the
## version-mismatch toast so it fires at most once per file per session).
var _warned_newer := false


func _ready() -> void:
	load_config()
	# Apply after the first frame so the root viewport exists.
	apply_all.call_deferred()


## Semantic-version compare: -1 if a<b, 0 if equal, 1 if a>b. Splits on ".",
## compares ints positionally; missing/non-numeric parts count as 0.
func _cmp_version(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	var n: int = maxi(pa.size(), pb.size())
	for i in n:
		var ai := int(pa[i]) if i < pa.size() else 0
		var bi := int(pb[i]) if i < pb.size() else 0
		if ai < bi:
			return -1
		if ai > bi:
			return 1
	return 0


func _headless() -> bool:
	return DisplayServer.get_name() == "headless"


# ---------------------------------------------------------------- get / set
func get_value(key: String) -> Variant:
	return _values.get(key, DEFAULTS.get(key))


func set_value(key: String, value: Variant, do_apply := true, do_save := true) -> void:
	_values[key] = value
	if do_apply:
		apply(key)
	settings_changed.emit(key, value)
	if do_save:
		save()


func reset_defaults() -> void:
	_values = DEFAULTS.duplicate(true)
	apply_all()
	save()


# ---------------------------------------------------------------- persistence
func load_config() -> void:
	_values = DEFAULTS.duplicate(true)
	var cfg := ConfigFile.new()
	if cfg.load(_path()) != OK:
		return
	# Version resilience: stamp lives in a "_meta" section (kept out of the settings
	# key space). Missing = legacy save (compatible). NEWER than this build → warn once.
	var save_ver := String(cfg.get_value("_meta", "save_version", ""))
	if save_ver != "" and _cmp_version(save_ver, Settings.GAME_VERSION) > 0:
		if not _warned_newer:
			_warned_newer = true
			push_warning(
				(
					"[SettingsManager] settings.cfg is from a newer game version (v%s > v%s) — loading what we can."
					% [save_ver, Settings.GAME_VERSION]
				)
			)
			Events.notify.emit(
				"Save is from a newer game version (v%s) — loading what we can." % save_ver, 2
			)
	# Load only known keys defensively; an unknown/newer key is simply ignored, a known
	# key keeps its DEFAULT if absent.
	for key in DEFAULTS:
		if cfg.has_section_key("settings", key):
			_values[key] = cfg.get_value("settings", key)
	# MIGRATION: "volumetric_fog_density" changed meaning (old: 0..0.08 GLOBAL density;
	# new: 0..2 multiplier on the local fog ZONES). An old-scale saved value would make
	# the zones invisible — coerce anything in the old range to the 1.0 default.
	if float(_values.get("volumetric_fog_density", 1.0)) <= 0.081:
		_values["volumetric_fog_density"] = 1.0


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("_meta", "save_version", Settings.GAME_VERSION)
	for key in _values:
		cfg.set_value("settings", key, _values[key])
	cfg.save(_path())


# ---------------------------------------------------------------- apply
func apply_all() -> void:
	for key in _values:
		apply(key)


func apply(key: String) -> void:
	var v: Variant = get_value(key)
	match key:
		"window_mode":
			_apply_window_mode(int(v))
		"resolution":
			_apply_resolution(str(v))
		"vsync":
			_apply_vsync(int(v))
		"msaa":
			_apply_msaa(int(v))
		"shadows":
			_apply_shadows(int(v))
		"fov":
			Settings.fov = clampf(float(v), 50.0, 110.0)
		"graphics_quality":
			Events.graphics_quality_changed.emit(int(v))
		"render_scale":
			_apply_render_scale(float(v))
		# One match arm enumerating every graphics lever — GDScript can't wrap a
		# pattern list across lines, so this one stays long by necessity.
		"sdfgi", "ssao", "glow", "clouds", "water_refraction", "grass_density", "ssr", "ssil", "reflection_probes", "voxelgi", "draw_distance", "particle_density", "terrain_detail", "volumetric_fog_density", "shadow_distance", "dof_amount", "volumetric_fog", "local_fog", "god_rays", "dof", "terrain_parallax", "climate_zones", "climate_density":  # gdlint: ignore=max-line-length
			_apply_quality_lever()
		"language":
			_apply_language(str(v))
		"show_fps", "show_detailed_stats", "stats_display_mode":
			_apply_stats_overlay()
		"ui_fx_enabled":
			_apply_ui_fx(bool(v))
		"ui_edge_margin", "ui_top_margin":
			_apply_ui_margins()
		"hud_scale":
			_apply_hud_scale(float(v))
		"camera_distance", "camera_shoulder", "default_view":
			_apply_camera()
		"master_volume":
			_apply_master(float(v))
		"sfx_volume":
			Settings.sfx_volume = clampf(float(v), 0.0, 1.0)
		"mute":
			_apply_mute(bool(v))
		"sensitivity":
			Settings.mouse_sensitivity = Settings.MOUSE_SENSITIVITY * clampf(float(v), 0.1, 4.0)
		"invert_y":
			Settings.invert_y = bool(v)
		"ads_toggle":
			Settings.ads_toggle = bool(v)


## UI locale. English is the BASE language: en has no translation table — tr() falls
## back to the key, which IS the English source string ("English-as-key" scheme; see
## locale/ui.csv). Static Control texts auto-retranslate live on locale change.
func _apply_language(code: String) -> void:
	if code == "":
		code = "en"
	TranslationServer.set_locale(code)


func _apply_window_mode(mode: int) -> void:
	if _headless() or AgentBridge.active:
		return  # --agent parks the window off-screen; don't fight it
	match mode:
		0:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
		1:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		2:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)


func _apply_resolution(res: String) -> void:
	if _headless() or AgentBridge.active:
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var parts := res.split("x")
	if parts.size() != 2:
		return
	var size := Vector2i(int(parts[0]), int(parts[1]))
	DisplayServer.window_set_size(size)
	var screen := DisplayServer.screen_get_size()
	DisplayServer.window_set_position((screen - size) / 2)


func _apply_vsync(mode: int) -> void:
	if _headless():
		return
	var m := DisplayServer.VSYNC_ENABLED
	if mode == 0:
		m = DisplayServer.VSYNC_DISABLED
	elif mode == 2:
		m = DisplayServer.VSYNC_ADAPTIVE
	DisplayServer.window_set_vsync_mode(m)


func _apply_msaa(level: int) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var modes := [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X, Viewport.MSAA_8X]
	vp.msaa_3d = modes[clampi(level, 0, 3)]


func _apply_shadows(level: int) -> void:
	var size: int = SHADOW_SIZES[clampi(level, 0, 3)]
	RenderingServer.directional_shadow_atlas_set_size(size, true)


## Viewport 3D render scale — the cheapest big perf lever. <1.0 renders 3D at a lower
## internal resolution and upscales (bilinear), leaving UI crisp. Headless-safe.
func _apply_render_scale(scale: float) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = clampf(scale, 0.5, 1.0)


## Mirror the rebuild-bound levers (grass/water/reflection-probes/voxelgi) into Settings
## (read at next arena build) and broadcast graphics_quality_changed so scene-side render
## levers (Environment SDFGI/SSAO/glow/SSR/SSIL, Sky3D clouds — applied by world_atmosphere)
## re-read the live settings immediately.
func _apply_quality_lever() -> void:
	# Grass cap multiplier — widened to a 2.0 "beyond Ultra" ceiling (was 1.0).
	Settings.grass_density_scale = clampf(float(get_value("grass_density")), 0.1, 2.0)
	Settings.water_refraction = 0.12 if bool(get_value("water_refraction")) else 0.0
	Settings.reflection_probes_enabled = bool(get_value("reflection_probes"))
	Settings.voxelgi_enabled = bool(get_value("voxelgi"))
	# Cinematic pass III rebuild-bound levers (read at next arena build).
	Settings.draw_distance_scale = clampf(float(get_value("draw_distance")), 0.5, 2.0)
	Settings.terrain_detail_scale = clampf(float(get_value("terrain_detail")), 1.0, 2.0)
	Settings.terrain_parallax_enabled = bool(get_value("terrain_parallax"))
	Settings.local_fog_enabled = bool(get_value("local_fog"))
	Settings.climate_zones_enabled = bool(get_value("climate_zones"))
	Settings.climate_density = clampf(float(get_value("climate_density")), 0.0, 2.0)
	Events.graphics_quality_changed.emit(int(get_value("graphics_quality")))


## Push the current overlay config to the StatsOverlay (instanced in main.gd).
func _apply_stats_overlay() -> void:
	Events.stats_overlay_changed.emit(
		bool(get_value("show_fps")),
		bool(get_value("show_detailed_stats")),
		int(get_value("stats_display_mode"))
	)


## "Military glass" UI FX master toggle → mirror into Settings + tell FXOverlay /
## GlassBackdrops to enable or fall back to plain dim.
func _apply_ui_fx(enabled: bool) -> void:
	Settings.ui_fx_enabled = enabled
	Events.ui_fx_changed.emit(enabled)


## Mirror the camera prefs into Settings + tell the player rig to re-read them.
func _apply_camera() -> void:
	Settings.camera_distance_scale = clampf(float(get_value("camera_distance")), 0.6, 1.4)
	Settings.camera_shoulder_scale = clampf(float(get_value("camera_shoulder")), 0.0, 1.0)
	Settings.default_first_person = int(get_value("default_view")) == 1
	Events.camera_settings_changed.emit()


## Mirror the HUD edge-inset fractions into Settings + tell edge-anchored UI to re-inset.
func _apply_ui_margins() -> void:
	Settings.ui_edge_margin = clampf(float(get_value("ui_edge_margin")), 0.0, 0.2)
	Settings.ui_top_margin = clampf(float(get_value("ui_top_margin")), 0.0, 0.2)
	Events.ui_layout_changed.emit()


## Global UI scale via the root window's content scale factor (all canvas_items UI). Headless-safe.
func _apply_hud_scale(v: float) -> void:
	if _headless():
		return
	var w := get_window()
	if w != null:
		w.content_scale_factor = clampf(v, 0.8, 1.4)


## Apply a whole quality tier (0 Low → 3 Ultra) from QUALITY_PRESETS in one batch: write
## every lever, push the immediate ones to the engine, mirror the rebuild-bound ones, and
## emit the scene-side signal ONCE. Persists. The settings menu calls this from the preset
## dropdown; individual set_value() calls afterward override one lever ("Custom").
func apply_quality_preset(level: int) -> void:
	level = clampi(level, 0, 4)
	for key in QUALITY_PRESETS:
		_values[key] = QUALITY_PRESETS[key][level]
	_values["graphics_quality"] = level
	_apply_render_scale(float(_values["render_scale"]))
	_apply_msaa(int(_values["msaa"]))
	_apply_shadows(int(_values["shadows"]))
	_apply_quality_lever()
	save()
	settings_changed.emit("graphics_quality", level)


## Returns the preset index (0..4) whose lever bundle exactly matches the live settings, or
## -1 if the user has diverged ("Custom"). Lets the menu label the preset dropdown honestly.
func current_preset_or_custom() -> int:
	for level in 5:
		var match_all := true
		for key in QUALITY_PRESETS:
			if not _values_equal(get_value(key), QUALITY_PRESETS[key][level]):
				match_all = false
				break
		if match_all:
			return level
	return -1


func _values_equal(a: Variant, b: Variant) -> bool:
	if a is float or b is float:
		return is_equal_approx(float(a), float(b))
	return a == b


func _apply_master(v: float) -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(clampf(v, 0.0001, 1.0)))


func _apply_mute(m: bool) -> void:
	AudioServer.set_bus_mute(0, m)
	AudioManager.enabled = not m
