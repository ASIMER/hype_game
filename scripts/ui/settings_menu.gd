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
	for s in ["Low", "Medium", "High"]:
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


func _wire() -> void:
	_tab_graphics.pressed.connect(_show_page.bind(0))
	_tab_audio.pressed.connect(_show_page.bind(1))
	_tab_controls.pressed.connect(_show_page.bind(2))

	_window_mode.item_selected.connect(func(i): _apply_setting("window_mode", i))
	_resolution.item_selected.connect(func(i): _apply_setting("resolution", SettingsManager.RES_OPTIONS[i]))
	_vsync.item_selected.connect(func(i): _apply_setting("vsync", i))
	_msaa.item_selected.connect(func(i): _apply_setting("msaa", i))
	_shadows.item_selected.connect(func(i): _apply_setting("shadows", i))
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


func _on_preset(index: int) -> void:
	if _syncing:
		return
	# Low -> msaa0/shadows0, Med -> msaa2/shadows2, High -> msaa3/shadows3.
	var levels := [0, 2, 3]
	var v: int = levels[index]
	SettingsManager.set_value("msaa", v)
	SettingsManager.set_value("shadows", v)
	# Re-sync so the MSAA/Shadow dropdowns reflect the preset.
	sync_from_settings()


func _on_reset() -> void:
	SettingsManager.reset_defaults()
	sync_from_settings()
