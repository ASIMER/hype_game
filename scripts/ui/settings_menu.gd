extends Control
## Reusable settings overlay (graphics / audio / controls). Reads & writes through
## SettingsManager, which applies + persists live. Tabs are button-driven page swaps
## (no TabContainer) for clean theming. Open from the main menu OR the pause menu via
## open()/close(); emits `closed` when the user backs out.

signal closed

# --- tabs ---
@onready var _tab_graphics: Button = $Panel/Root/Tabs/GraphicsTab
@onready var _tab_audio: Button = $Panel/Root/Tabs/AudioTab
@onready var _tab_controls: Button = $Panel/Root/Tabs/ControlsTab

@onready var _page_graphics: Control = $Panel/Root/Content/GraphicsPage
@onready var _page_audio: Control = $Panel/Root/Content/AudioPage
@onready var _page_controls: Control = $Panel/Root/Content/ControlsPage

# --- graphics controls ---
@onready var _window_mode: OptionButton = $Panel/Root/Content/GraphicsPage/V/WindowRow/WindowMode
@onready var _resolution: OptionButton = $Panel/Root/Content/GraphicsPage/V/ResRow/Resolution
@onready var _vsync: OptionButton = $Panel/Root/Content/GraphicsPage/V/VSyncRow/VSync
@onready var _msaa: OptionButton = $Panel/Root/Content/GraphicsPage/V/MsaaRow/Msaa
@onready var _shadows: OptionButton = $Panel/Root/Content/GraphicsPage/V/ShadowRow/Shadows
@onready var _fov: HSlider = $Panel/Root/Content/GraphicsPage/V/FovRow/Fov
@onready var _fov_value: Label = $Panel/Root/Content/GraphicsPage/V/FovRow/FovValue
@onready var _preset: OptionButton = $Panel/Root/Content/GraphicsPage/V/PresetRow/Preset
@onready var _graphics_v: VBoxContainer = $Panel/Root/Content/GraphicsPage/V

# --- quality lever controls (built programmatically in _build_quality_rows) ---
var _render_scale: HSlider
var _render_scale_value: Label
var _toggle_sdfgi: CheckButton
var _toggle_ssao: CheckButton
var _toggle_glow: CheckButton
var _toggle_clouds: CheckButton
var _toggle_water: CheckButton
var _toggle_ssr: CheckButton
var _toggle_ssil: CheckButton
var _toggle_reflection_probes: CheckButton
var _toggle_voxelgi: CheckButton
var _grass_density: HSlider
var _grass_density_value: Label

# --- stats overlay controls (built programmatically) ---
var _show_fps: CheckButton
var _show_detailed: CheckButton
var _stats_mode: OptionButton

# --- audio controls ---
@onready var _master: HSlider = $Panel/Root/Content/AudioPage/MasterRow/Master
@onready var _master_value: Label = $Panel/Root/Content/AudioPage/MasterRow/MasterValue
@onready var _sfx: HSlider = $Panel/Root/Content/AudioPage/SfxRow/Sfx
@onready var _sfx_value: Label = $Panel/Root/Content/AudioPage/SfxRow/SfxValue
@onready var _mute: CheckButton = $Panel/Root/Content/AudioPage/MuteRow/Mute

# --- controls controls ---
@onready var _sens: HSlider = $Panel/Root/Content/ControlsPage/V/SensRow/Sens
@onready var _sens_value: Label = $Panel/Root/Content/ControlsPage/V/SensRow/SensValue
@onready var _invert_y: CheckButton = $Panel/Root/Content/ControlsPage/V/InvertRow/InvertY
@onready var _aim_mode: OptionButton = $Panel/Root/Content/ControlsPage/V/AimRow/AimMode
@onready var _keybinds: VBoxContainer = $Panel/Root/Content/ControlsPage/V/Keybinds

@onready var _reset: Button = $Panel/Root/Buttons/Reset
@onready var _back: Button = $Panel/Root/Buttons/Back

const KEYBINDS := [
	["Move", "WASD"], ["Sprint", "Shift"], ["Jump", "Space"], ["Fire", "LMB"],
	["Aim", "RMB"], ["Reload", "R"], ["Swap shoulder", "Q"], ["Weapons", "1-5 / Wheel"],
	["Grenade", "G"], ["Heal", "H"], ["Loot", "E"], ["Inventory", "I"], ["Pause", "Esc"],
]

# Guards re-entrant signals while we sync control values from SettingsManager.
var _syncing := false


func _ready() -> void:
	_populate_options()
	_build_quality_rows()
	_populate_keybinds()
	_wire()
	sync_from_settings()
	_show_page(0)


# ---------------------------------------------------------------- public API
func open() -> void:
	sync_from_settings()
	show()
	# Bring overlay to front when instanced over gameplay.
	move_to_front()

func close() -> void:
	hide()
	closed.emit()


# ---------------------------------------------------------------- setup
func _populate_options() -> void:
	_window_mode.clear()
	for s in ["Windowed", "Borderless Fullscreen", "Exclusive Fullscreen"]:
		_window_mode.add_item(s)

	_resolution.clear()
	for r in SettingsManager.RES_OPTIONS:
		_resolution.add_item(r)

	_vsync.clear()
	for s in ["Off", "On", "Adaptive"]:
		_vsync.add_item(s)

	_msaa.clear()
	for s in ["Off", "2x", "4x", "8x"]:
		_msaa.add_item(s)

	_shadows.clear()
	for s in ["Low", "Medium", "High", "Ultra"]:
		_shadows.add_item(s)

	_preset.clear()
	for s in ["Low", "Medium", "High", "Ultra", "Ultra+RT", "Custom"]:
		_preset.add_item(s)

	_aim_mode.clear()
	for s in ["Hold", "Toggle"]:
		_aim_mode.add_item(s)


func _populate_keybinds() -> void:
	for child in _keybinds.get_children():
		child.queue_free()
	for pair in KEYBINDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		var name_l := Label.new()
		name_l.text = pair[0]
		name_l.custom_minimum_size = Vector2(220, 0)
		var key_l := Label.new()
		key_l.text = pair[1]
		key_l.add_theme_color_override("font_color", Color(0.91, 0.64, 0.24, 1))
		row.add_child(name_l)
		row.add_child(key_l)
		_keybinds.add_child(row)


# Builds the manual quality-lever rows + the stats-overlay section programmatically,
# appending to the graphics page VBox (which already lives inside a ScrollContainer).
func _build_quality_rows() -> void:
	var accent := Color(0.247, 0.71, 0.79, 1)
	var next_raid := "(applies next raid)"

	# Section header for the manual levers.
	_graphics_v.add_child(_make_header("ADVANCED QUALITY", accent))

	# Render Scale slider.
	var rs_row := _make_slider_row("Render Scale", 0.5, 1.0, 0.05)
	_render_scale = rs_row[1]
	_render_scale_value = rs_row[2]
	_render_scale.value_changed.connect(_on_render_scale)
	_graphics_v.add_child(rs_row[0])

	# Per-lever toggles.
	_toggle_sdfgi = _add_toggle_row("Global Illumination (SDFGI)", "sdfgi", "")
	_toggle_ssao = _add_toggle_row("Ambient Occlusion (SSAO)", "ssao", "")
	_toggle_glow = _add_toggle_row("Bloom / Glow", "glow", "")
	_toggle_clouds = _add_toggle_row("Volumetric Clouds", "clouds", "")
	_toggle_water = _add_toggle_row("Water Refraction", "water_refraction", next_raid)

	# --- RT-style reflections (Ultra+RT tier sub-levers) ---
	_graphics_v.add_child(_make_header("RT-STYLE REFLECTIONS", accent))
	_toggle_ssr = _add_toggle_row("Screen-Space Reflections (SSR)", "ssr", "")
	_toggle_ssil = _add_toggle_row("Screen-Space Indirect Light (SSIL)", "ssil", "")
	_toggle_reflection_probes = _add_toggle_row("Reflection Probes", "reflection_probes", next_raid)
	_toggle_voxelgi = _add_toggle_row("VoxelGI (experimental)", "voxelgi", "(experimental — applies next raid)")

	# Grass Density slider (applies next raid).
	var gd_row := _make_slider_row("Grass Density", 0.3, 1.0, 0.05, next_raid)
	_grass_density = gd_row[1]
	_grass_density_value = gd_row[2]
	_grass_density.value_changed.connect(_on_grass_density)
	_graphics_v.add_child(gd_row[0])

	# --- Statistics overlay section ---
	_graphics_v.add_child(_make_header("STATISTICS OVERLAY", accent))

	_show_fps = _add_toggle_row("Show FPS", "show_fps", "")
	_show_detailed = _add_toggle_row("Detailed Stats", "show_detailed_stats", "")
	# Detailed toggle also drives the display-mode dropdown's enabled state.
	_show_detailed.toggled.connect(func(p): _stats_mode.disabled = not p)

	var sm_row := HBoxContainer.new()
	sm_row.add_theme_constant_override("separation", 16)
	var sm_label := Label.new()
	sm_label.text = "Stats Display"
	sm_label.custom_minimum_size = Vector2(220, 0)
	_stats_mode = OptionButton.new()
	_stats_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["Numeric", "Graphs"]:
		_stats_mode.add_item(s)
	_stats_mode.item_selected.connect(func(i): _apply_setting("stats_display_mode", i))
	sm_row.add_child(sm_label)
	sm_row.add_child(_stats_mode)
	_graphics_v.add_child(sm_row)


# Builds a labelled CheckButton row, wires it to apply `key` + refresh the preset label,
# appends it, and returns the CheckButton. `note` (if non-empty) adds a dim trailing hint.
func _add_toggle_row(text: String, key: String, note: String) -> CheckButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(220, 0)
	var cb := CheckButton.new()
	cb.toggled.connect(func(p):
		_apply_setting(key, p)
		_refresh_preset_label())
	row.add_child(label)
	row.add_child(cb)
	if not note.is_empty():
		row.add_child(_make_note(note))
	_graphics_v.add_child(row)
	return cb


# Builds a labelled HSlider row [HBox, HSlider, value Label]; optional dim note.
func _make_slider_row(text: String, mn: float, mx: float, step: float, note := "") -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(220, 0)
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(0, 24)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.min_value = mn
	slider.max_value = mx
	slider.step = step
	var value_l := Label.new()
	value_l.custom_minimum_size = Vector2(56, 0)
	value_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(label)
	row.add_child(slider)
	row.add_child(value_l)
	if not note.is_empty():
		row.add_child(_make_note(note))
	return [row, slider, value_l]


func _make_header(text: String, accent: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", accent)
	l.add_theme_font_size_override("font_size", 14)
	return l


func _make_note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1))
	l.add_theme_font_size_override("font_size", 11)
	return l


func _wire() -> void:
	_tab_graphics.pressed.connect(_show_page.bind(0))
	_tab_audio.pressed.connect(_show_page.bind(1))
	_tab_controls.pressed.connect(_show_page.bind(2))

	_window_mode.item_selected.connect(func(i): _apply_setting("window_mode", i))
	_resolution.item_selected.connect(func(i): _apply_setting("resolution", SettingsManager.RES_OPTIONS[i]))
	_vsync.item_selected.connect(func(i): _apply_setting("vsync", i))
	_msaa.item_selected.connect(func(i):
		_apply_setting("msaa", i)
		_refresh_preset_label())
	_shadows.item_selected.connect(func(i):
		_apply_setting("shadows", i)
		_refresh_preset_label())
	_fov.value_changed.connect(_on_fov)
	_preset.item_selected.connect(_on_preset)

	_master.value_changed.connect(_on_master)
	_sfx.value_changed.connect(_on_sfx)
	_mute.toggled.connect(func(p): _apply_setting("mute", p))

	_sens.value_changed.connect(_on_sens)
	_invert_y.toggled.connect(func(p): _apply_setting("invert_y", p))
	_aim_mode.item_selected.connect(func(i): _apply_setting("ads_toggle", i == 1))

	_reset.pressed.connect(_on_reset)
	_back.pressed.connect(close)


# ---------------------------------------------------------------- tab switching
func _show_page(index: int) -> void:
	_tab_graphics.set_pressed_no_signal(index == 0)
	_tab_audio.set_pressed_no_signal(index == 1)
	_tab_controls.set_pressed_no_signal(index == 2)
	_page_graphics.visible = index == 0
	_page_audio.visible = index == 1
	_page_controls.visible = index == 2


# ---------------------------------------------------------------- value sync
func sync_from_settings() -> void:
	_syncing = true
	var g := SettingsManager

	_window_mode.select(int(g.get_value("window_mode")))
	_resolution.select(maxi(0, SettingsManager.RES_OPTIONS.find(str(g.get_value("resolution")))))
	_vsync.select(int(g.get_value("vsync")))
	_msaa.select(int(g.get_value("msaa")))
	_shadows.select(int(g.get_value("shadows")))
	_fov.value = float(g.get_value("fov"))
	_fov_value.text = "%d" % int(_fov.value)

	# Quality preset + manual levers.
	var preset: int = g.current_preset_or_custom()
	_preset.select(5 if preset < 0 else preset)

	_render_scale.value = float(g.get_value("render_scale"))
	_render_scale_value.text = "%d%%" % roundi(_render_scale.value * 100.0)
	_toggle_sdfgi.button_pressed = bool(g.get_value("sdfgi"))
	_toggle_ssao.button_pressed = bool(g.get_value("ssao"))
	_toggle_glow.button_pressed = bool(g.get_value("glow"))
	_toggle_clouds.button_pressed = bool(g.get_value("clouds"))
	_toggle_water.button_pressed = bool(g.get_value("water_refraction"))
	_toggle_ssr.button_pressed = bool(g.get_value("ssr"))
	_toggle_ssil.button_pressed = bool(g.get_value("ssil"))
	_toggle_reflection_probes.button_pressed = bool(g.get_value("reflection_probes"))
	_toggle_voxelgi.button_pressed = bool(g.get_value("voxelgi"))
	_grass_density.value = float(g.get_value("grass_density"))
	_grass_density_value.text = "%d%%" % roundi(_grass_density.value * 100.0)

	# Stats overlay.
	_show_fps.button_pressed = bool(g.get_value("show_fps"))
	var detailed: bool = bool(g.get_value("show_detailed_stats"))
	_show_detailed.button_pressed = detailed
	_stats_mode.select(int(g.get_value("stats_display_mode")))
	_stats_mode.disabled = not detailed

	_master.value = float(g.get_value("master_volume"))
	_master_value.text = "%d%%" % roundi(_master.value * 100.0)
	_sfx.value = float(g.get_value("sfx_volume"))
	_sfx_value.text = "%d%%" % roundi(_sfx.value * 100.0)
	_mute.button_pressed = bool(g.get_value("mute"))

	_sens.value = float(g.get_value("sensitivity"))
	_sens_value.text = "%.2f" % _sens.value
	_invert_y.button_pressed = bool(g.get_value("invert_y"))
	_aim_mode.select(1 if bool(g.get_value("ads_toggle")) else 0)

	_syncing = false


func _apply_setting(key: String, value: Variant) -> void:
	if _syncing:
		return
	SettingsManager.set_value(key, value)


# ---------------------------------------------------------------- live-label handlers
func _on_fov(v: float) -> void:
	_fov_value.text = "%d" % int(v)
	_apply_setting("fov", v)

func _on_master(v: float) -> void:
	_master_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("master_volume", v)

func _on_sfx(v: float) -> void:
	_sfx_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("sfx_volume", v)

func _on_sens(v: float) -> void:
	_sens_value.text = "%.2f" % v
	_apply_setting("sensitivity", v)


func _on_render_scale(v: float) -> void:
	_render_scale_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("render_scale", v)
	_refresh_preset_label()

func _on_grass_density(v: float) -> void:
	_grass_density_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("grass_density", v)
	_refresh_preset_label()


# Sets the preset dropdown to the matching tier 0..4, or Custom (index 5) when diverged.
func _refresh_preset_label() -> void:
	if _syncing:
		return
	var p: int = SettingsManager.current_preset_or_custom()
	_preset.select(5 if p < 0 else p)


func _on_preset(index: int) -> void:
	if _syncing:
		return
	# Index 5 ("Custom") is a display-only state — never an action.
	if index <= 4:
		SettingsManager.apply_quality_preset(index)
		sync_from_settings()


func _on_reset() -> void:
	SettingsManager.reset_defaults()
	sync_from_settings()
