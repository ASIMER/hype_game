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

var _values: Dictionary = {}


func _ready() -> void:
	load_config()
	# Apply after the first frame so the root viewport exists.
	apply_all.call_deferred()


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
	if cfg.load(_path()) == OK:
		for key in DEFAULTS:
			if cfg.has_section_key("settings", key):
				_values[key] = cfg.get_value("settings", key)

func save() -> void:
	var cfg := ConfigFile.new()
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

func _apply_master(v: float) -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(clampf(v, 0.0001, 1.0)))

func _apply_mute(m: bool) -> void:
	AudioServer.set_bus_mute(0, m)
	AudioManager.enabled = not m
