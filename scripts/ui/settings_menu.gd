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
@onready var _tab_interface: Button = $Panel/Root/Tabs/InterfaceTab

@onready var _page_graphics: Control = $Panel/Root/Content/GraphicsPage
@onready var _page_audio: Control = $Panel/Root/Content/AudioPage
@onready var _page_controls: Control = $Panel/Root/Content/ControlsPage
@onready var _page_interface: Control = $Panel/Root/Content/InterfacePage
@onready var _interface_v: VBoxContainer = $Panel/Root/Content/InterfacePage/V

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

# --- cinematic / beyond ultra controls (built programmatically) ---
var _draw_distance: HSlider
var _draw_distance_value: Label
var _particle_density: HSlider
var _particle_density_value: Label
var _terrain_detail: HSlider
var _terrain_detail_value: Label
var _volumetric_fog_density: HSlider
var _volumetric_fog_density_value: Label
var _climate_density: HSlider
var _climate_density_value: Label
var _shadow_distance: HSlider
var _shadow_distance_value: Label
var _dof_amount: HSlider
var _dof_amount_value: Label
var _toggle_volumetric_fog: CheckButton
var _toggle_local_fog: CheckButton
var _toggle_climate_zones: CheckButton
var _toggle_god_rays: CheckButton
var _toggle_dof: CheckButton
var _toggle_terrain_parallax: CheckButton

# --- stats overlay controls (built programmatically, on the Interface page) ---
var _show_fps: CheckButton
var _show_detailed: CheckButton
var _stats_mode: OptionButton
var _ui_fx: CheckButton

# --- interface / HUD-layout controls (built programmatically) ---
var _ui_edge_margin: HSlider
var _ui_edge_margin_value: Label
var _ui_top_margin: HSlider
var _ui_top_margin_value: Label
var _hud_scale: HSlider
var _hud_scale_value: Label
var _camera_distance: HSlider
var _camera_distance_value: Label
var _camera_shoulder: HSlider
var _camera_shoulder_value: Label

# Dynamic resolution list for the current monitor (built in _populate_options).
var _res_list: Array = []

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

# M7.6 remap: rows with a real ACTION name are REBINDABLE (click → press a key);
# rows with "" stay informational (mouse/composite bindings).
const KEYBINDS := [
	["Move", "WASD", ""],
	["Sprint", "Shift", "sprint"],
	["Jump", "Space", "jump"],
	["Fire", "LMB", ""],
	["Aim", "RMB", ""],
	["Reload", "R", "reload"],
	["Swap shoulder", "Q", "shoulder_swap"],
	["Weapons", "1-5 / Wheel", ""],
	["Grenade", "G", "grenade"],
	["Heal", "H", "heal"],
	["Loot", "E", "interact"],
	["Inventory", "I", "toggle_inventory"],
	["Crouch", "Ctrl", "crouch"],
	["Map", "M", "map"],
	["Camera zoom", "V", "toggle_view"],
	["Pause", "Esc", ""],
]

# Remap capture state: the action currently waiting for a key ("" = idle).
var _remap_action: String = ""
var _remap_btn: Button = null

# Guards re-entrant signals while we sync control values from SettingsManager.
var _syncing := false

# Frosted-glass backdrop (lazy-created once; reused on every open()).
var _glass_bg: GlassBackdrop = null


func _ready() -> void:
	_populate_options()
	_build_quality_rows()
	_build_interface_rows()
	_populate_keybinds()
	_wire()
	sync_from_settings()
	_show_page(0)
	# Style the scene-side Title label with Russo One header face.
	UIStyle.make_header($Panel/Root/Title, UIStyle.AMBER, 30)
	# Hover-lift on the primary action buttons.
	UIStyle.hover_lift(_reset)
	UIStyle.hover_lift(_back)


# ---------------------------------------------------------------- public API
func open() -> void:
	sync_from_settings()
	# Lazy-create the frosted backdrop the first time (first child = behind the panel).
	if _glass_bg == null:
		_glass_bg = GlassBackdrop.new()
		add_child(_glass_bg)
		move_child(_glass_bg, 0)
	show()
	# Bring overlay to front when instanced over gameplay.
	move_to_front()
	UIStyle.pop_in($Panel)


func close() -> void:
	hide()
	closed.emit()


# ---------------------------------------------------------------- setup
func _populate_options() -> void:
	_window_mode.clear()
	for s in ["Windowed", "Borderless Fullscreen", "Exclusive Fullscreen"]:
		_window_mode.add_item(s)

	_resolution.clear()
	_res_list = SettingsManager.build_resolution_list()
	for r in _res_list:
		_resolution.add_item(str(r))

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
		row.add_child(name_l)
		var action: String = String(pair[2])
		if action == "":
			var key_l := Label.new()
			key_l.text = pair[1]
			key_l.add_theme_color_override("font_color", Color(0.91, 0.64, 0.24, 1))
			row.add_child(key_l)
		else:
			# M7.6 remap: a button shows the LIVE binding; click arms capture.
			var btn := Button.new()
			btn.text = _binding_label(action, String(pair[1]))
			btn.custom_minimum_size = Vector2(120, 0)
			btn.pressed.connect(_arm_remap.bind(action, btn))
			row.add_child(btn)
		_keybinds.add_child(row)


## Current key label for an action (falls back to the authored default text).
func _binding_label(action: String, fallback: String) -> String:
	if not InputMap.has_action(action):
		return fallback
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			var k := ev as InputEventKey
			return OS.get_keycode_string(k.physical_keycode if k.keycode == 0 else k.keycode)
	return fallback


func _arm_remap(action: String, btn: Button) -> void:
	if _remap_btn != null:
		_populate_keybinds()  # un-arm any previous row
	_remap_action = action
	_remap_btn = btn
	btn.text = tr("Press a key…")


func _unhandled_key_input(event: InputEvent) -> void:
	if _remap_action == "":
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	get_viewport().set_input_as_handled()
	if key.keycode == KEY_ESCAPE:
		_remap_action = ""
		_remap_btn = null
		_populate_keybinds()
		return
	_apply_remap(_remap_action, key.keycode)
	_remap_action = ""
	_remap_btn = null
	_populate_keybinds()


## Swap the action's KEY events for the new keycode (mouse/pad events untouched)
## and persist the override so SettingsManager re-applies it on every boot.
func _apply_remap(action: String, keycode: int) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action).duplicate():
		if ev is InputEventKey:
			InputMap.action_erase_event(action, ev)
	var nk := InputEventKey.new()
	nk.keycode = keycode as Key
	InputMap.action_add_event(action, nk)
	var overrides: Dictionary = {}
	var raw: Variant = SettingsManager.get_value("input_overrides")
	if raw is Dictionary:
		overrides = (raw as Dictionary).duplicate()
	overrides[action] = keycode
	_apply_setting("input_overrides", overrides)


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
	_toggle_voxelgi = _add_toggle_row(
		"VoxelGI (experimental)", "voxelgi", "(experimental — applies next raid)"
	)

	# Grass Density slider (applies next raid).
	var gd_row := _make_slider_row("Grass Density", 0.3, 2.0, 0.05, next_raid)
	_grass_density = gd_row[1]
	_grass_density_value = gd_row[2]
	_grass_density.value_changed.connect(_on_grass_density)
	_graphics_v.add_child(gd_row[0])

	# --- Cinematic / beyond-ultra section ---
	_graphics_v.add_child(_make_header("CINEMATIC / BEYOND ULTRA", accent))

	# Draw Distance — label in metres (58 m = base near-grass range).
	var dd_row := _make_slider_row("Draw Distance", 0.5, 2.0, 0.05, next_raid)
	_draw_distance = dd_row[1]
	_draw_distance_value = dd_row[2]
	_draw_distance.value_changed.connect(_on_draw_distance)
	_graphics_v.add_child(dd_row[0])

	# Particle Density.
	var pd_row := _make_slider_row("Particle Density", 0.0, 1.5, 0.05)
	_particle_density = pd_row[1]
	_particle_density_value = pd_row[2]
	_particle_density.value_changed.connect(_on_particle_density)
	_graphics_v.add_child(pd_row[0])

	# Terrain Detail.
	var td_row := _make_slider_row("Terrain Detail", 1.0, 2.0, 0.1, "(applies next raid; heavy)")
	_terrain_detail = td_row[1]
	_terrain_detail_value = td_row[2]
	_terrain_detail.value_changed.connect(_on_terrain_detail)
	_graphics_v.add_child(td_row[0])

	# Volumetric Fog Density.
	# NB: now a MULTIPLIER on the localized FogVolume smoke banks (global density is 0).
	var vfd_row := _make_slider_row("Local Fog Density", 0.0, 2.0, 0.1)
	_volumetric_fog_density = vfd_row[1]
	_volumetric_fog_density_value = vfd_row[2]
	_volumetric_fog_density.value_changed.connect(_on_volumetric_fog_density)
	_graphics_v.add_child(vfd_row[0])

	# Climate Density (rain/snow/sand precipitation + haze multiplier at the far landmarks).
	var cd_row := _make_slider_row("Climate Density", 0.0, 2.0, 0.1)
	_climate_density = cd_row[1]
	_climate_density_value = cd_row[2]
	_climate_density.value_changed.connect(_on_climate_density)
	_graphics_v.add_child(cd_row[0])

	# Shadow Distance.
	var sd_row := _make_slider_row("Shadow Distance", 60.0, 250.0, 10.0)
	_shadow_distance = sd_row[1]
	_shadow_distance_value = sd_row[2]
	_shadow_distance.value_changed.connect(_on_shadow_distance)
	_graphics_v.add_child(sd_row[0])

	# DOF Amount.
	var dof_row := _make_slider_row("DOF Amount", 0.0, 0.2, 0.01)
	_dof_amount = dof_row[1]
	_dof_amount_value = dof_row[2]
	_dof_amount.value_changed.connect(_on_dof_amount)
	_graphics_v.add_child(dof_row[0])

	# Cinematic toggles.
	_toggle_volumetric_fog = _add_toggle_row("Volumetric Fog", "volumetric_fog", "")
	_toggle_local_fog = _add_toggle_row("Local Fog Zones", "local_fog", next_raid)
	_toggle_climate_zones = _add_toggle_row(
		"Climate Zones (rain/snow/desert)", "climate_zones", next_raid
	)
	_toggle_god_rays = _add_toggle_row("God Rays", "god_rays", "")
	_toggle_dof = _add_toggle_row("Depth of Field", "dof", "")
	_toggle_terrain_parallax = _add_toggle_row(
		"Terrain Parallax (POM)", "terrain_parallax", "(applies next raid; heavy)"
	)


# Builds the INTERFACE page: the moved statistics-overlay section + HUD-layout sliders,
# appending to the interface page VBox (inside a ScrollContainer).
func _build_interface_rows() -> void:
	var accent := Color(0.247, 0.71, 0.79, 1)

	# --- Language (UI locale) -------------------------------------------------
	# English is the base/fallback; additional languages = columns in locale/ui.csv.
	# Static Control texts re-translate LIVE on change (Godot auto-translate).
	_interface_v.add_child(_make_header("LANGUAGE", accent))
	var lang_row := HBoxContainer.new()
	lang_row.add_theme_constant_override("separation", 16)
	var lang_label := Label.new()
	lang_label.text = "Language"
	lang_label.custom_minimum_size = Vector2(220, 0)
	var lang_opt := OptionButton.new()
	lang_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Display names stay in their OWN language (the convention for language pickers),
	# so they are deliberately NOT translated.
	lang_opt.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var lang_codes: Array[String] = ["en", "ru"]
	lang_opt.add_item("English")
	lang_opt.add_item("Русский")
	var cur_lang := str(SettingsManager.get_value("language"))
	var cur_idx := lang_codes.find(cur_lang)
	lang_opt.selected = cur_idx if cur_idx >= 0 else 0
	lang_opt.item_selected.connect(func(i): _apply_setting("language", lang_codes[i]))
	lang_row.add_child(lang_label)
	lang_row.add_child(lang_opt)
	_interface_v.add_child(lang_row)

	# --- Statistics overlay section (moved here from the graphics page) ---
	_interface_v.add_child(_make_header("STATISTICS OVERLAY", accent))

	_show_fps = _add_interface_toggle_row("Show FPS", "show_fps", "")
	_show_detailed = _add_interface_toggle_row("Detailed Stats", "show_detailed_stats", "")
	# Detailed toggle also drives the display-mode dropdown's enabled state.
	_show_detailed.toggled.connect(func(p): _stats_mode.disabled = not p)

	var sm_row := HBoxContainer.new()
	sm_row.add_theme_constant_override("separation", 16)
	var sm_label := Label.new()
	sm_label.text = "Stats Display"
	sm_label.custom_minimum_size = Vector2(220, 0)
	_stats_mode = OptionButton.new()
	_stats_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["Numeric", "Graphs", "Graphs + Numbers"]:
		_stats_mode.add_item(s)
	_stats_mode.item_selected.connect(func(i): _apply_setting("stats_display_mode", i))
	sm_row.add_child(sm_label)
	sm_row.add_child(_stats_mode)
	_interface_v.add_child(sm_row)

	# --- Visual FX ("military glass" look) ---
	_interface_v.add_child(_make_header("VISUAL FX", accent))
	_ui_fx = _add_interface_toggle_row(
		"UI Glass FX", "ui_fx_enabled", "Scanlines, grain & frosted-glass blur behind menus"
	)
	# M7.6 accessibility: bigger, outlined map/minimap markers (colorblind assist).
	_add_interface_toggle_row(
		"High-Contrast Markers",
		"hi_contrast_markers",
		"Larger map/minimap markers with outlines (colorblind assist)"
	)

	# --- HUD layout (ultrawide-friendly insets + global scale) ---
	_interface_v.add_child(_make_header("HUD LAYOUT (ULTRAWIDE)", accent))

	var edge_row := _make_slider_row("UI Horizontal Offset", 0.0, 0.2, 0.01)
	_ui_edge_margin = edge_row[1]
	_ui_edge_margin_value = edge_row[2]
	_ui_edge_margin.value_changed.connect(_on_ui_edge_margin)
	_interface_v.add_child(edge_row[0])

	var top_row := _make_slider_row("UI Vertical Offset", 0.0, 0.2, 0.01)
	_ui_top_margin = top_row[1]
	_ui_top_margin_value = top_row[2]
	_ui_top_margin.value_changed.connect(_on_ui_top_margin)
	_interface_v.add_child(top_row[0])

	var scale_row := _make_slider_row("HUD Scale", 0.8, 1.4, 0.05)
	_hud_scale = scale_row[1]
	_hud_scale_value = scale_row[2]
	_hud_scale.value_changed.connect(_on_hud_scale)
	_interface_v.add_child(scale_row[0])

	# --- Camera (third-person rig) ---
	_interface_v.add_child(_make_header("CAMERA", accent))

	var dist_row := _make_slider_row("Camera Distance", 0.6, 1.4, 0.05)
	_camera_distance = dist_row[1]
	_camera_distance_value = dist_row[2]
	_camera_distance.value_changed.connect(_on_camera_distance)
	_interface_v.add_child(dist_row[0])

	var sh_row := _make_slider_row("Camera Shoulder", 0.0, 1.0, 0.05)
	_camera_shoulder = sh_row[1]
	_camera_shoulder_value = sh_row[2]
	_camera_shoulder.value_changed.connect(_on_camera_shoulder)
	_interface_v.add_child(sh_row[0])

	# The "Default View" first-person picker is GONE (user verdict: the helmet view
	# is deleted — V now cycles the three third-person zooms only).
	_interface_v.add_child(_make_note("(camera zoom in-game: V)"))


func _on_camera_distance(v: float) -> void:
	_camera_distance_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("camera_distance", v)


func _on_camera_shoulder(v: float) -> void:
	_camera_shoulder_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("camera_shoulder", v)


# Like _add_toggle_row but appends to the interface page and does NOT touch the preset
# label (these toggles are not part of the graphics quality preset).
func _add_interface_toggle_row(text: String, key: String, note: String) -> CheckButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(220, 0)
	var cb := CheckButton.new()
	cb.toggled.connect(func(p): _apply_setting(key, p))
	row.add_child(label)
	row.add_child(cb)
	if not note.is_empty():
		row.add_child(_make_note(note))
	_interface_v.add_child(row)
	return cb


# Builds a labelled CheckButton row, wires it to apply `key` + refresh the preset label,
# appends it, and returns the CheckButton. `note` (if non-empty) adds a dim trailing hint.
func _add_toggle_row(text: String, key: String, note: String) -> CheckButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(220, 0)
	var cb := CheckButton.new()
	cb.toggled.connect(
		func(p):
			_apply_setting(key, p)
			_refresh_preset_label()
	)
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
	return UIStyle.micro_header(text, accent, 13)


func _make_note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1))
	l.add_theme_font_size_override("font_size", 12)
	return l


func _wire() -> void:
	_tab_graphics.pressed.connect(_show_page.bind(0))
	_tab_audio.pressed.connect(_show_page.bind(1))
	_tab_controls.pressed.connect(_show_page.bind(2))
	_tab_interface.pressed.connect(_show_page.bind(3))

	_window_mode.item_selected.connect(func(i): _apply_setting("window_mode", i))
	_resolution.item_selected.connect(func(i): _apply_setting("resolution", str(_res_list[i])))
	_vsync.item_selected.connect(func(i): _apply_setting("vsync", i))
	_msaa.item_selected.connect(
		func(i):
			_apply_setting("msaa", i)
			_refresh_preset_label()
	)
	_shadows.item_selected.connect(
		func(i):
			_apply_setting("shadows", i)
			_refresh_preset_label()
	)
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
	_tab_interface.set_pressed_no_signal(index == 3)
	_page_graphics.visible = index == 0
	_page_audio.visible = index == 1
	_page_controls.visible = index == 2
	_page_interface.visible = index == 3


# ---------------------------------------------------------------- value sync
func sync_from_settings() -> void:
	_syncing = true
	var g := SettingsManager

	_window_mode.select(int(g.get_value("window_mode")))
	_resolution.select(maxi(0, _res_list.find(str(g.get_value("resolution")))))
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

	# Cinematic / beyond ultra.
	var draw_distance: float = float(g.get_value("draw_distance"))
	_draw_distance.value = draw_distance
	_draw_distance_value.text = tr("%d m") % roundi(58.0 * draw_distance)
	var particle_density: float = float(g.get_value("particle_density"))
	_particle_density.value = particle_density
	_particle_density_value.text = "%d%%" % roundi(particle_density * 100.0)
	var terrain_detail: float = float(g.get_value("terrain_detail"))
	_terrain_detail.value = terrain_detail
	_terrain_detail_value.text = tr("%.1fx") % terrain_detail
	var volumetric_fog_density: float = float(g.get_value("volumetric_fog_density"))
	_volumetric_fog_density.value = volumetric_fog_density
	_volumetric_fog_density_value.text = "%.1f" % volumetric_fog_density
	var climate_density: float = float(g.get_value("climate_density"))
	_climate_density.value = climate_density
	_climate_density_value.text = "%.1f" % climate_density
	var shadow_distance: float = float(g.get_value("shadow_distance"))
	_shadow_distance.value = shadow_distance
	_shadow_distance_value.text = tr("%d m") % roundi(shadow_distance)
	var dof_amount: float = float(g.get_value("dof_amount"))
	_dof_amount.value = dof_amount
	_dof_amount_value.text = "%d%%" % roundi(dof_amount * 100.0)
	_toggle_volumetric_fog.button_pressed = bool(g.get_value("volumetric_fog"))
	_toggle_local_fog.button_pressed = bool(g.get_value("local_fog"))
	_toggle_climate_zones.button_pressed = bool(g.get_value("climate_zones"))
	_toggle_god_rays.button_pressed = bool(g.get_value("god_rays"))
	_toggle_dof.button_pressed = bool(g.get_value("dof"))
	_toggle_terrain_parallax.button_pressed = bool(g.get_value("terrain_parallax"))

	# Stats overlay.
	_show_fps.button_pressed = bool(g.get_value("show_fps"))
	var detailed: bool = bool(g.get_value("show_detailed_stats"))
	_show_detailed.button_pressed = detailed
	_stats_mode.select(int(g.get_value("stats_display_mode")))
	_stats_mode.disabled = not detailed
	if _ui_fx != null:
		_ui_fx.button_pressed = bool(g.get_value("ui_fx_enabled"))

	# Interface / HUD layout.
	var edge_margin: float = float(g.get_value("ui_edge_margin"))
	_ui_edge_margin.value = edge_margin
	_ui_edge_margin_value.text = "%d%%" % roundi(edge_margin * 100.0)
	var top_margin: float = float(g.get_value("ui_top_margin"))
	_ui_top_margin.value = top_margin
	_ui_top_margin_value.text = "%d%%" % roundi(top_margin * 100.0)
	var hud_scale: float = float(g.get_value("hud_scale"))
	_hud_scale.value = hud_scale
	_hud_scale_value.text = "%d%%" % roundi(hud_scale * 100.0)
	var cam_dist: float = float(g.get_value("camera_distance"))
	_camera_distance.value = cam_dist
	_camera_distance_value.text = "%d%%" % roundi(cam_dist * 100.0)
	var cam_sh: float = float(g.get_value("camera_shoulder"))
	_camera_shoulder.value = cam_sh
	_camera_shoulder_value.text = "%d%%" % roundi(cam_sh * 100.0)

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


func _on_draw_distance(v: float) -> void:
	_draw_distance_value.text = tr("%d m") % roundi(58.0 * v)
	_apply_setting("draw_distance", v)
	_refresh_preset_label()


func _on_particle_density(v: float) -> void:
	_particle_density_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("particle_density", v)
	_refresh_preset_label()


func _on_terrain_detail(v: float) -> void:
	_terrain_detail_value.text = tr("%.1fx") % v
	_apply_setting("terrain_detail", v)
	_refresh_preset_label()


func _on_volumetric_fog_density(v: float) -> void:
	_volumetric_fog_density_value.text = "%.1f" % v
	_apply_setting("volumetric_fog_density", v)
	_refresh_preset_label()


func _on_climate_density(v: float) -> void:
	_climate_density_value.text = "%.1f" % v
	_apply_setting("climate_density", v)
	_refresh_preset_label()


func _on_shadow_distance(v: float) -> void:
	_shadow_distance_value.text = tr("%d m") % roundi(v)
	_apply_setting("shadow_distance", v)
	_refresh_preset_label()


func _on_dof_amount(v: float) -> void:
	_dof_amount_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("dof_amount", v)
	_refresh_preset_label()


# Interface / HUD-layout sliders — not part of the graphics preset, so no preset refresh.
func _on_ui_edge_margin(v: float) -> void:
	_ui_edge_margin_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("ui_edge_margin", v)


func _on_ui_top_margin(v: float) -> void:
	_ui_top_margin_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("ui_top_margin", v)


func _on_hud_scale(v: float) -> void:
	_hud_scale_value.text = "%d%%" % roundi(v * 100.0)
	_apply_setting("hud_scale", v)


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
