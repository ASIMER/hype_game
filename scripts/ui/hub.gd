extends Control
## Between-match Lobby / Hub shell (Arc-Raiders style). Shown fullscreen between the
## main menu and a deployment. Hosts three tabs — STASH, LOADOUT, and WORKSHOP — plus
## a footer with a difficulty selector, BACK, and a large DEPLOY button.
##
## Process mode: PROCESS_MODE_ALWAYS so the scene works if shown while the world tree
## is paused (matches the pattern used by Workshop.tscn).
##
## Signals (exact names — main.gd connects these the same way it connected Workshop):
##   deploy_requested  — lead connects to start the match.
##   back_requested    — lead connects to return to the main menu.
##
## Usage (lead / main.gd):
##   var hub = preload("res://scenes/ui/Hub.tscn").instantiate()
##   ui_layer.add_child(hub)
##   hub.deploy_requested.connect(_on_deploy_requested)
##   hub.back_requested.connect(_on_back_requested)
##
## The three tab scenes live at:
##   res://scenes/ui/tabs/StashTab.tscn
##   res://scenes/ui/tabs/LoadoutTab.tscn
##   res://scenes/ui/tabs/WorkshopTab.tscn
## Each is instantiated once in _ready; missing scenes fall back to a placeholder label.

signal deploy_requested()
signal back_requested()

# Tab index constants for clarity.
const TAB_STASH    := 0
const TAB_LOADOUT  := 1
const TAB_WORKSHOP := 2
const TAB_SHOP     := 3
const TAB_QUESTS   := 4
const TAB_GUNSMITH := 5

# Paths to tab scenes (built by other agents — guarded with ResourceLoader.exists).
const TAB_PATHS := [
	"res://scenes/ui/tabs/StashTab.tscn",
	"res://scenes/ui/tabs/LoadoutTab.tscn",
	"res://scenes/ui/tabs/WorkshopTab.tscn",
	"res://scenes/ui/tabs/ShopTab.tscn",
	"res://scenes/ui/tabs/QuestsTab.tscn",
	"res://scenes/ui/tabs/GunsmithTab.tscn",
]

# Difficulty one-line descriptions (mirrors Workshop.gd).
const DIFFICULTY_DESCS := [
	"EASY — fewer, weaker enemies. Good for learning the map.",
	"NORMAL — balanced threat. Recommended for most runs.",
	"HARD — more enemies, higher damage. Extraction is brutal.",
]

# Project theme colours (match Workshop.gd / MainMenu.tscn).
const COL_AMBER := Color(0.91, 0.64, 0.24, 1.0)
const COL_TEAL  := Color(0.247, 0.71, 0.79, 1.0)
const COL_DIM   := Color(0.45, 0.50, 0.55, 1.0)

# ── node refs ────────────────────────────────────────────────────────────────
@onready var _currency_label: Label       = $Layout/Header/HeaderVBox/HRow/CurrencyLabel
@onready var _tab_buttons: Array          = []  # populated in _ready from TabBar
@onready var _content_area: Control       = $Layout/Body/ContentArea
@onready var _diff_option: OptionButton   = $Layout/Footer/FooterRow/DiffOption
@onready var _diff_desc: Label            = $Layout/Footer/FooterRow/DiffDesc
@onready var _back_btn: Button            = $Layout/Footer/FooterRow/BackBtn
@onready var _deploy_btn: Button          = $Layout/Footer/FooterRow/DeployBtn

## Instantiated tab controls (indexed by TAB_* constants). May be Label placeholders.
var _tabs: Array[Control] = []
## Which tab is currently visible.
var _active_tab: int = TAB_STASH


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	# Drop any equipped attachment lost on a failed raid (not in the stash anymore).
	MetaProgression.reconcile_attachments()

	# ── Wire footer buttons ───────────────────────────────────────────────────
	if _back_btn:
		_back_btn.pressed.connect(func() -> void: back_requested.emit())
	if _deploy_btn:
		_deploy_btn.pressed.connect(func() -> void: deploy_requested.emit())

	# ── Wire difficulty selector ──────────────────────────────────────────────
	if _diff_option:
		_diff_option.clear()
		_diff_option.add_item("EASY",   GameState.Difficulty.EASY)
		_diff_option.add_item("NORMAL", GameState.Difficulty.NORMAL)
		_diff_option.add_item("HARD",   GameState.Difficulty.HARD)
		_diff_option.selected = GameState.difficulty
		_diff_option.item_selected.connect(_on_difficulty_selected)

	# ── Instantiate tab scenes into the content area ──────────────────────────
	_tabs.resize(TAB_PATHS.size())
	if _content_area:
		for i in TAB_PATHS.size():
			var path: String = TAB_PATHS[i]
			var tab: Control
			if ResourceLoader.exists(path):
				tab = load(path).instantiate() as Control
			else:
				# Placeholder shown during bringup while the tab agent finishes.
				var lbl := Label.new()
				lbl.text = "Coming soon"
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				lbl.add_theme_color_override("font_color", COL_DIM)
				lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				lbl.size_flags_vertical   = Control.SIZE_EXPAND_FILL
				tab = lbl
			tab.visible = (i == TAB_STASH)
			_content_area.add_child(tab)
			_tabs[i] = tab

	# ── Wire tab bar buttons ──────────────────────────────────────────────────
	var bar := get_node_or_null("Layout/Header/HeaderVBox/TabBar")
	if bar:
		for child in bar.get_children():
			if child is Button:
				_tab_buttons.append(child)
		# Buttons are in order: STASH, LOADOUT, WORKSHOP.
		for i in _tab_buttons.size():
			var idx := i  # capture for lambda
			(_tab_buttons[i] as Button).pressed.connect(func() -> void: _switch_tab(idx))

	# ── Initial state ─────────────────────────────────────────────────────────
	_refresh_currency()
	_refresh_difficulty()
	_update_tab_button_states()

	# ── Live currency updates (reconnect-safe) ────────────────────────────────
	if not Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.connect(_on_currency_changed)


func _exit_tree() -> void:
	if Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.disconnect(_on_currency_changed)


# ── Tab switching ─────────────────────────────────────────────────────────────

## Show the tab at index `idx`; hide the rest; update button visual states.
func _switch_tab(idx: int) -> void:
	_active_tab = clamp(idx, 0, _tabs.size() - 1)
	for i in _tabs.size():
		if _tabs[i] != null:
			_tabs[i].visible = (i == _active_tab)
	_update_tab_button_states()


## Reflects active tab by dimming non-active tab buttons.
func _update_tab_button_states() -> void:
	for i in _tab_buttons.size():
		var btn := _tab_buttons[i] as Button
		if btn == null:
			continue
		if i == _active_tab:
			btn.add_theme_color_override("font_color", COL_AMBER)
		else:
			btn.remove_theme_color_override("font_color")


# ── Currency ──────────────────────────────────────────────────────────────────

func _refresh_currency() -> void:
	if not _currency_label:
		return
	_currency_label.text = "CR %d" % MetaProgression.currency


func _on_currency_changed(_amount: int) -> void:
	_refresh_currency()


# ── Difficulty ────────────────────────────────────────────────────────────────

func _refresh_difficulty() -> void:
	if not _diff_option:
		return
	_diff_option.set_block_signals(true)
	_diff_option.selected = GameState.difficulty
	_diff_option.set_block_signals(false)
	if _diff_desc:
		_diff_desc.text = DIFFICULTY_DESCS[clamp(GameState.difficulty, 0, 2)]


func _on_difficulty_selected(index: int) -> void:
	# OptionButton item id == Difficulty enum value (set in _ready).
	GameState.difficulty = _diff_option.get_item_id(index)
	MetaProgression.save_profile()
	_refresh_difficulty()
