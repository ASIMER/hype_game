extends Control
## Between-run Workshop hub (Arc-Raiders style). Shown fullscreen between the main menu
## and a deployment. Lets the player spend currency on weapon unlocks + permanent
## upgrades, configure a loadout, and pick a difficulty.
##
## Process mode: PROCESS_MODE_ALWAYS so this works if shown while the world tree is
## paused. In practice the lead shows it at menu time (world not yet loaded), so either
## mode is fine — ALWAYS is the safe default.
##
## Signals:
##   deploy_requested  — lead connects to start the match.
##   back_requested    — lead connects to return to main menu.
##
## All purchases refresh the relevant panel rows immediately; currency_changed also
## keeps the header readout in sync live.

signal deploy_requested()
signal back_requested()

# Weapon display names and canonical id order.
const WEAPON_DISPLAY := {
	"rifle":   "RIFLE",
	"pistol":  "PISTOL",
	"smg":     "SMG",
	"shotgun": "SHOTGUN",
	"dmr":     "DMR",
}
const WEAPON_ORDER: Array[String] = ["rifle", "pistol", "smg", "shotgun", "dmr"]

# Difficulty labels + one-line description shown in the selector.
const DIFFICULTY_DESCS := [
	"EASY — fewer, weaker enemies. Good for learning the map.",
	"NORMAL — balanced threat. Recommended for most runs.",
	"HARD — more enemies, higher damage. Extraction is brutal.",
]

# Colours matching the project theme.
const COL_AMBER  := Color(0.91, 0.64, 0.24, 1.0)   # amber accent
const COL_TEAL   := Color(0.247, 0.71, 0.79, 1.0)  # teal accent
const COL_DIM    := Color(0.45, 0.50, 0.55, 1.0)   # muted label
const COL_WHITE  := Color(0.88, 0.90, 0.92, 1.0)   # body text
const COL_RED    := Color(0.85, 0.30, 0.25, 1.0)   # locked / unaffordable hint

# ---------------------------------------------------------------- node refs
@onready var _currency_label: Label      = $Layout/Header/HRow/CurrencyLabel
@onready var _weapon_rows: VBoxContainer = $Layout/Body/BodyMargin/Columns/Left/LoadoutPanel/Scroll/WeaponRows
@onready var _upgrade_rows: VBoxContainer = $Layout/Body/BodyMargin/Columns/Right/UpgradesPanel/Scroll/UpgradeRows
@onready var _diff_option: OptionButton  = $Layout/Body/BodyMargin/Columns/Right/DifficultyPanel/DiffVBox/DiffOption
@onready var _diff_desc: Label           = $Layout/Body/BodyMargin/Columns/Right/DifficultyPanel/DiffVBox/DiffDesc
@onready var _deploy_btn: Button         = $Layout/Footer/FooterRow/DeployBtn
@onready var _back_btn: Button           = $Layout/Footer/FooterRow/BackBtn

# Runtime state -------------------------------------------------------
## Weapon rows: id -> { check: CheckButton, unlock_btn: Button, cost_label: Label }
var _weapon_ui: Dictionary = {}
## Upgrade rows: key -> { level_label: Label, cost_label: Label, btn: Button }
var _upgrade_ui: Dictionary = {}
## Current loadout selection (set synced with MetaProgression).
var _selected: Array[String] = []


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS

	# Wire footer.
	if _deploy_btn:
		_deploy_btn.pressed.connect(func() -> void: deploy_requested.emit())
	if _back_btn:
		_back_btn.pressed.connect(func() -> void: back_requested.emit())

	# Wire difficulty selector.
	if _diff_option:
		_diff_option.clear()
		_diff_option.add_item("EASY",   GameState.Difficulty.EASY)
		_diff_option.add_item("NORMAL", GameState.Difficulty.NORMAL)
		_diff_option.add_item("HARD",   GameState.Difficulty.HARD)
		_diff_option.selected = GameState.difficulty
		_diff_option.item_selected.connect(_on_difficulty_selected)

	# Live currency updates.
	Events.currency_changed.connect(_on_currency_changed)

	_build_weapon_rows()
	_build_upgrade_rows()
	_refresh()


func _exit_tree() -> void:
	if Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.disconnect(_on_currency_changed)


# ---------------------------------------------------------------- build phase
## Creates one row per weapon in WEAPON_ORDER inside _weapon_rows (called once).
func _build_weapon_rows() -> void:
	if not _weapon_rows:
		return
	for id in WEAPON_ORDER:
		var row := HBoxContainer.new()
		row.name = "Row_" + id
		row.add_theme_constant_override("separation", 12)

		var name_lbl := Label.new()
		name_lbl.name = "NameLbl"
		name_lbl.custom_minimum_size = Vector2(90, 0)
		name_lbl.text = WEAPON_DISPLAY.get(id, id.to_upper())
		name_lbl.add_theme_color_override("font_color", COL_WHITE)
		row.add_child(name_lbl)

		var cost_lbl := Label.new()
		cost_lbl.name = "CostLbl"
		cost_lbl.custom_minimum_size = Vector2(110, 0)
		cost_lbl.add_theme_color_override("font_color", COL_DIM)
		cost_lbl.add_theme_font_size_override("font_size", 13)
		row.add_child(cost_lbl)

		var check := CheckButton.new()
		check.name = "Check"
		check.text = "IN LOADOUT"
		check.focus_mode = Control.FOCUS_NONE
		check.toggled.connect(func(pressed: bool) -> void: _on_weapon_toggled(id, pressed))
		row.add_child(check)

		var unlock_btn := Button.new()
		unlock_btn.name = "UnlockBtn"
		unlock_btn.custom_minimum_size = Vector2(90, 32)
		unlock_btn.text = "UNLOCK"
		unlock_btn.pressed.connect(func() -> void: _on_unlock_pressed(id))
		row.add_child(unlock_btn)

		_weapon_rows.add_child(row)
		_weapon_ui[id] = {
			"row":        row,
			"name_lbl":   name_lbl,
			"cost_lbl":   cost_lbl,
			"check":      check,
			"unlock_btn": unlock_btn,
		}


## Creates one row per upgrade key inside _upgrade_rows (called once).
func _build_upgrade_rows() -> void:
	if not _upgrade_rows:
		return
	for key in MetaProgression.UPGRADES:
		var info: Dictionary = MetaProgression.UPGRADES[key]

		var row := HBoxContainer.new()
		row.name = "Row_" + key
		row.add_theme_constant_override("separation", 10)

		var vname := VBoxContainer.new()
		vname.custom_minimum_size = Vector2(170, 0)
		vname.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var title_lbl := Label.new()
		title_lbl.name = "TitleLbl"
		title_lbl.text = info["name"]
		title_lbl.add_theme_color_override("font_color", COL_WHITE)
		vname.add_child(title_lbl)

		var desc_lbl := Label.new()
		desc_lbl.name = "DescLbl"
		desc_lbl.text = info["desc"]
		desc_lbl.add_theme_color_override("font_color", COL_DIM)
		desc_lbl.add_theme_font_size_override("font_size", 12)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vname.add_child(desc_lbl)

		row.add_child(vname)

		var level_lbl := Label.new()
		level_lbl.name = "LevelLbl"
		level_lbl.custom_minimum_size = Vector2(60, 0)
		level_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		level_lbl.add_theme_color_override("font_color", COL_TEAL)
		row.add_child(level_lbl)

		var cost_lbl := Label.new()
		cost_lbl.name = "CostLbl"
		cost_lbl.custom_minimum_size = Vector2(80, 0)
		cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		cost_lbl.add_theme_font_size_override("font_size", 13)
		cost_lbl.add_theme_color_override("font_color", COL_AMBER)
		row.add_child(cost_lbl)

		var btn := Button.new()
		btn.name = "UpgradeBtn"
		btn.custom_minimum_size = Vector2(90, 32)
		btn.text = "UPGRADE"
		btn.pressed.connect(func() -> void: _on_upgrade_pressed(key))
		row.add_child(btn)

		_upgrade_rows.add_child(row)
		_upgrade_ui[key] = {
			"level_lbl": level_lbl,
			"cost_lbl":  cost_lbl,
			"btn":       btn,
		}


# ---------------------------------------------------------------- refresh
## Full state sync from MetaProgression. Call on _ready + after every purchase.
func _refresh() -> void:
	_refresh_currency()
	_selected = Array(MetaProgression.get_loadout(), TYPE_STRING, "", null)
	_refresh_weapon_rows()
	_refresh_upgrade_rows()
	_refresh_difficulty()


func _refresh_currency() -> void:
	if not _currency_label:
		return
	_currency_label.text = "CR %d" % MetaProgression.currency


func _refresh_weapon_rows() -> void:
	var selected_count := _selected.size()
	for id in WEAPON_ORDER:
		var ui: Dictionary = _weapon_ui.get(id, {})
		if ui.is_empty():
			continue
		var owned: bool = MetaProgression.is_unlocked(id)
		var is_free: bool = id in MetaProgression.FREE_WEAPONS
		var cost: int = MetaProgression.weapon_cost(id)
		var in_load: bool = id in _selected

		var cost_lbl: Label  = ui["cost_lbl"]
		var check: CheckButton = ui["check"]
		var unlock_btn: Button = ui["unlock_btn"]

		if owned:
			cost_lbl.text = "OWNED" if not is_free else "FREE"
			cost_lbl.add_theme_color_override("font_color", COL_DIM)
			check.visible = true
			unlock_btn.visible = false

			# Disable toggle if already at MAX_LOADOUT and this one is not selected.
			var would_exceed := selected_count >= MetaProgression.MAX_LOADOUT and not in_load
			check.disabled = would_exceed
			# Block the toggled signal while we set the state programmatically.
			check.set_block_signals(true)
			check.button_pressed = in_load
			check.set_block_signals(false)
		else:
			cost_lbl.text = "CR %d" % cost
			var affordable: bool = MetaProgression.currency >= cost
			cost_lbl.add_theme_color_override("font_color", COL_AMBER if affordable else COL_RED)
			check.visible = false
			unlock_btn.visible = true
			unlock_btn.disabled = not affordable


func _refresh_upgrade_rows() -> void:
	for key in _upgrade_ui:
		var ui: Dictionary = _upgrade_ui[key]
		if ui.is_empty():
			continue
		var lvl: int  = MetaProgression.upgrade_level(key)
		var maxl: int = MetaProgression.upgrade_max(key)
		var cost: int = MetaProgression.upgrade_cost(key)

		var level_lbl: Label  = ui["level_lbl"]
		var cost_lbl: Label   = ui["cost_lbl"]
		var btn: Button       = ui["btn"]

		level_lbl.text = "Lv %d / %d" % [lvl, maxl]

		if cost < 0:
			cost_lbl.text = "MAX"
			cost_lbl.add_theme_color_override("font_color", COL_TEAL)
			btn.disabled = true
		else:
			cost_lbl.text = "CR %d" % cost
			var affordable: bool = MetaProgression.currency >= cost
			cost_lbl.add_theme_color_override("font_color", COL_AMBER if affordable else COL_RED)
			btn.disabled = not affordable


func _refresh_difficulty() -> void:
	if not _diff_option:
		return
	_diff_option.set_block_signals(true)
	_diff_option.selected = GameState.difficulty
	_diff_option.set_block_signals(false)
	if _diff_desc:
		_diff_desc.text = DIFFICULTY_DESCS[clamp(GameState.difficulty, 0, 2)]


# ---------------------------------------------------------------- event handlers
func _on_currency_changed(_amount: int) -> void:
	_refresh_currency()
	_refresh_weapon_rows()
	_refresh_upgrade_rows()


func _on_weapon_toggled(id: String, pressed: bool) -> void:
	if pressed:
		if id not in _selected and _selected.size() < MetaProgression.MAX_LOADOUT:
			_selected.append(id)
	else:
		_selected.erase(id)
	MetaProgression.set_loadout(_selected)
	# Re-read from MetaProgression so _selected stays authoritative.
	_selected = Array(MetaProgression.get_loadout(), TYPE_STRING, "", null)
	_refresh_weapon_rows()


func _on_unlock_pressed(id: String) -> void:
	var ok: bool = MetaProgression.unlock_weapon(id)
	if ok:
		# If we're under MAX_LOADOUT, auto-add the newly unlocked weapon.
		if _selected.size() < MetaProgression.MAX_LOADOUT and id not in _selected:
			_selected.append(id)
			MetaProgression.set_loadout(_selected)
		_refresh()


func _on_upgrade_pressed(key: String) -> void:
	var ok: bool = MetaProgression.buy_upgrade(key)
	if ok:
		_refresh_currency()
		_refresh_upgrade_rows()
		_refresh_weapon_rows()  # afford state may change for weapons too


func _on_difficulty_selected(index: int) -> void:
	# OptionButton item id == Difficulty enum value (set in _ready).
	GameState.difficulty = _diff_option.get_item_id(index)
	MetaProgression.save_profile()
	_refresh_difficulty()
