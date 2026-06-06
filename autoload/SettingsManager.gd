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
	"window_mode": 0,        # 0 windowed, 1 borderless fullscreen, 2 exclusive fullscreen
	"resolution": "1280x720",
	"vsync": 1,              # 0 off, 1 on, 2 adaptive
	"msaa": 2,              # 0 off, 1 2x, 2 4x, 3 8x
	"shadows": 2,          # 0 1024, 1 2048, 2 4096, 3 8192
	"fov": 60.0,           # 60..100
	# Graphics quality (Godot does NOT auto-scale to hardware — these presets do it).
	"graphics_quality": 3,    # 0 Low, 1 Medium, 2 High, 3 Ultra (default = current look)
	"render_scale": 1.0,      # 0.5..1.0 viewport 3D render scale (FSR-style upscale; cheapest lever)
	"sdfgi": true,            # global illumination (heavy)
	"ssao": true,             # ambient occlusion
	"glow": true,             # bloom
	"clouds": true,           # Sky3D volumetric cumulus
	"water_refraction": true, # screen-space refractive water (vs flat cheap water)
	"grass_density": 1.0,     # 0.3..1.0 grass-cap multiplier (rebuild-bound; applies next raid)
	# Diagnostics overlay
	"show_fps": false,            # minimal FPS counter
	"show_detailed_stats": false, # full perf + network panel
	"stats_display_mode": 0,      # 0 Numeric, 1 Graphs
	# Audio (linear 0..1)
	"master_volume": 0.9,
	"sfx_volume": 0.9,
	"mute": false,
	# Controls
	"sensitivity": 1.0,    # multiplier of Settings.MOUSE_SENSITIVITY
	"invert_y": false,
	"ads_toggle": false,   # false = hold to aim, true = toggle
}

const RES_OPTIONS := ["1280x720", "1600x900", "1920x1080", "2560x1440", "960x540"]
const SHADOW_SIZES := [1024, 2048, 4096, 8192]

## Quality preset table. Index = graphics_quality (0 Low → 3 Ultra). Ultra = the current
## (hand-tuned) look. apply_quality_preset() writes each of these into the live settings,
## then the per-lever apply functions + Events.graphics_quality_changed carry them to the
## viewport / Environment / sky / grass / water. Order: Low, Medium, High, Ultra.
const QUALITY_PRESETS := {
	"render_scale":     [0.6,  0.75, 0.9,  1.0],
	"msaa":             [0,    1,    2,    2],     # off / 2x / 4x / 4x
	"shadows":          [0,    1,    2,    2],     # 1024 / 2048 / 4096 / 4096
	"sdfgi":            [false, false, true, true],
	"ssao":             [false, false, true, true],
	"glow":             [true,  true,  true, true],
	"clouds":           [false, true,  true, true],
	"water_refraction": [false, false, true, true],
	"grass_density":    [0.3,  0.6,  0.85, 1.0],
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
			push_warning("[SettingsManager] settings.cfg is from a newer game version (v%s > v%s) — loading what we can." % [save_ver, Settings.GAME_VERSION])
			Events.notify.emit("Save is from a newer game version (v%s) — loading what we can." % save_ver, 2)
	# Load only known keys defensively; an unknown/newer key is simply ignored, a known
	# key keeps its DEFAULT if absent.
	for key in DEFAULTS:
		if cfg.has_section_key("settings", key):
			_values[key] = cfg.get_value("settings", key)

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
		"window_mode": _apply_window_mode(int(v))
		"resolution": _apply_resolution(str(v))
		"vsync": _apply_vsync(int(v))
		"msaa": _apply_msaa(int(v))
		"shadows": _apply_shadows(int(v))
		"fov": Settings.fov = clampf(float(v), 50.0, 110.0)
		"graphics_quality": Events.graphics_quality_changed.emit(int(v))
		"render_scale": _apply_render_scale(float(v))
		"sdfgi", "ssao", "glow", "clouds", "water_refraction", "grass_density":
			_apply_quality_lever()
		"show_fps", "show_detailed_stats", "stats_display_mode": _apply_stats_overlay()
		"master_volume": _apply_master(float(v))
		"sfx_volume": Settings.sfx_volume = clampf(float(v), 0.0, 1.0)
		"mute": _apply_mute(bool(v))
		"sensitivity": Settings.mouse_sensitivity = Settings.MOUSE_SENSITIVITY * clampf(float(v), 0.1, 4.0)
		"invert_y": Settings.invert_y = bool(v)
		"ads_toggle": Settings.ads_toggle = bool(v)

func _apply_window_mode(mode: int) -> void:
	if _headless() or AgentBridge.active:
		return   # --agent parks the window off-screen; don't fight it
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

## Mirror the rebuild-bound levers (grass/water) into Settings (read at next arena build)
## and broadcast graphics_quality_changed so scene-side render levers (Environment SDFGI/
## SSAO/glow, Sky3D clouds — applied by world_atmosphere) re-read the live settings.
func _apply_quality_lever() -> void:
	Settings.grass_density_scale = clampf(float(get_value("grass_density")), 0.1, 1.0)
	Settings.water_refraction = 0.12 if bool(get_value("water_refraction")) else 0.0
	Events.graphics_quality_changed.emit(int(get_value("graphics_quality")))

## Push the current overlay config to the StatsOverlay (instanced in main.gd).
func _apply_stats_overlay() -> void:
	Events.stats_overlay_changed.emit(
		bool(get_value("show_fps")),
		bool(get_value("show_detailed_stats")),
		int(get_value("stats_display_mode")))

## Apply a whole quality tier (0 Low → 3 Ultra) from QUALITY_PRESETS in one batch: write
## every lever, push the immediate ones to the engine, mirror the rebuild-bound ones, and
## emit the scene-side signal ONCE. Persists. The settings menu calls this from the preset
## dropdown; individual set_value() calls afterward override one lever ("Custom").
func apply_quality_preset(level: int) -> void:
	level = clampi(level, 0, 3)
	for key in QUALITY_PRESETS:
		_values[key] = QUALITY_PRESETS[key][level]
	_values["graphics_quality"] = level
	_apply_render_scale(float(_values["render_scale"]))
	_apply_msaa(int(_values["msaa"]))
	_apply_shadows(int(_values["shadows"]))
	_apply_quality_lever()
	save()
	settings_changed.emit("graphics_quality", level)

## Returns the preset index (0..3) whose lever bundle exactly matches the live settings, or
## -1 if the user has diverged ("Custom"). Lets the menu label the preset dropdown honestly.
func current_preset_or_custom() -> int:
	for level in 4:
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
