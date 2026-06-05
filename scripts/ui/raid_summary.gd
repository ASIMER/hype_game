extends CanvasLayer
## Post-raid summary overlay. Shown at match end (win or loss) to display the
## player's haul — items extracted, currency earned, blueprints learned, and
## quests completed — then routes them back to the Hub (CONTINUE) or into a
## fresh raid (RESTART). Accumulates run data from the Events bus in _ready.
##
## Signals (exact names — lead connects these):
##   continue_requested  — lead routes back to the Hub.
##   restart_requested   — lead reloads a fresh raid.
##
## Usage (lead / main.gd):
##   var summary = preload("res://scenes/ui/RaidSummary.tscn").instantiate()
##   ui_layer.add_child(summary)
##   summary.continue_requested.connect(_on_continue_requested)
##   summary.restart_requested.connect(_on_restart_requested)
## The scene starts HIDDEN; show() is called internally on match_won/match_lost.

signal continue_requested()
signal restart_requested()

# Project theme colours — mirror hub.gd / Workshop.gd.
const COL_WIN  := Color(0.40, 1.00, 0.60, 1.0)   # green "EXTRACTED"
const COL_LOSS := Color(1.00, 0.35, 0.35, 1.0)   # red   "KIA"
const COL_AMBER := Color(0.91, 0.64, 0.24, 1.0)
const COL_DIM   := Color(0.55, 0.60, 0.65, 1.0)

# ── node refs (all populated in _ready via @onready) ─────────────────────────
@onready var _panel: PanelContainer       = $Root/Panel
@onready var _title: Label                = $Root/Panel/VBox/Title
@onready var _subtitle: Label             = $Root/Panel/VBox/Subtitle
@onready var _sep_top: HSeparator         = $Root/Panel/VBox/SepTop
@onready var _loot_section: VBoxContainer = $Root/Panel/VBox/LootSection
@onready var _loot_header: Label          = $Root/Panel/VBox/LootSection/LootHeader
@onready var _loot_list: VBoxContainer    = $Root/Panel/VBox/LootSection/LootList
@onready var _currency_label: Label       = $Root/Panel/VBox/LootSection/CurrencyLabel
@onready var _bp_section: VBoxContainer   = $Root/Panel/VBox/BpSection
@onready var _bp_header: Label            = $Root/Panel/VBox/BpSection/BpHeader
@onready var _bp_list: VBoxContainer      = $Root/Panel/VBox/BpSection/BpList
@onready var _quest_section: VBoxContainer = $Root/Panel/VBox/QuestSection
@onready var _quest_header: Label          = $Root/Panel/VBox/QuestSection/QuestHeader
@onready var _quest_list: VBoxContainer    = $Root/Panel/VBox/QuestSection/QuestList
@onready var _sep_bot: HSeparator          = $Root/Panel/VBox/SepBot
@onready var _btn_continue: Button         = $Root/Panel/VBox/Buttons/ContinueBtn
@onready var _btn_restart: Button          = $Root/Panel/VBox/Buttons/RestartBtn

# ── per-run accumulators (reset on match_started) ─────────────────────────────
## Raw loot deposited this run: id -> count.
var _loot_counts: Dictionary = {}
## Currency bonus earned this run (from raid_loot_granted).
var _loot_bonus: int = 0
## Blueprint ids learned this run.
var _blueprints: Array[String] = []
## Quest ids completed this run.
var _quests_done: Array[String] = []


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS

	# Wire buttons.
	_btn_continue.pressed.connect(_on_continue)
	_btn_restart.pressed.connect(_on_restart)

	# Accumulate run data from the Events bus.
	Events.match_started.connect(_on_match_started)
	Events.raid_loot_granted.connect(_on_raid_loot_granted)
	Events.blueprint_learned.connect(_on_blueprint_learned)
	Events.quest_completed.connect(_on_quest_completed)

	# Match-end triggers.
	Events.match_won.connect(_on_match_won)
	Events.match_lost.connect(_on_match_lost)

	hide()


# ── Event handlers — accumulate ───────────────────────────────────────────────

## Reset all accumulators when a NEW match begins so each run is clean.
func _on_match_started() -> void:
	_loot_counts.clear()
	_loot_bonus = 0
	_blueprints.clear()
	_quests_done.clear()


## payload: [{id: String, count: int}, …], bonus: currency earned this extraction.
func _on_raid_loot_granted(payload: Array, bonus: int) -> void:
	for entry in payload:
		var id := String(entry["id"])
		var cnt := int(entry["count"])
		_loot_counts[id] = _loot_counts.get(id, 0) + cnt
	_loot_bonus += bonus


func _on_blueprint_learned(blueprint: String) -> void:
	if blueprint not in _blueprints:
		_blueprints.append(blueprint)


func _on_quest_completed(quest_id: String) -> void:
	if quest_id not in _quests_done:
		_quests_done.append(quest_id)


# ── Match-end display ─────────────────────────────────────────────────────────

func _on_match_won() -> void:
	_show_summary(true)


func _on_match_lost() -> void:
	_show_summary(false)


## Populates all sections and reveals the overlay.
func _show_summary(won: bool) -> void:
	# Title + subtitle.
	if won:
		_title.text = "EXTRACTED"
		_title.add_theme_color_override("font_color", COL_WIN)
		_subtitle.text = "Gear secured. Head back to the Hub."
		_subtitle.add_theme_color_override("font_color", COL_WIN)
	else:
		_title.text = "KIA"
		_title.add_theme_color_override("font_color", COL_LOSS)
		_subtitle.text = "Gear lost. Better luck next time."
		_subtitle.add_theme_color_override("font_color", COL_LOSS)

	# Loot section.
	_clear_children(_loot_list)
	if _loot_counts.is_empty():
		var empty_lbl := _make_dim_label("Nothing extracted.")
		_loot_list.add_child(empty_lbl)
	else:
		for id in _loot_counts:
			var count: int = int(_loot_counts[id])
			_loot_list.add_child(_make_item_row(String(id), count))

	# Currency line (always shown on a win; zero on a loss).
	if _loot_bonus > 0:
		_currency_label.text = "+CR %d" % _loot_bonus
		_currency_label.add_theme_color_override("font_color", COL_AMBER)
	else:
		_currency_label.text = "+CR 0"
		_currency_label.add_theme_color_override("font_color", COL_DIM)

	# Blueprints section.
	_clear_children(_bp_list)
	_bp_section.visible = not _blueprints.is_empty()
	for bp in _blueprints:
		var lbl := _make_dim_label("  %s" % String(bp))
		lbl.add_theme_color_override("font_color", COL_AMBER)
		_bp_list.add_child(lbl)

	# Quests section.
	_clear_children(_quest_list)
	_quest_section.visible = not _quests_done.is_empty()
	for qid in _quests_done:
		var title_str := String(qid)
		var qd: QuestData = Quests.quest_by_id(String(qid))
		if qd != null:
			title_str = (qd as QuestData).title
		_quest_list.add_child(_make_dim_label("  %s" % title_str))

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	show()


# ── Row builders ──────────────────────────────────────────────────────────────

## Builds a single loot row: [icon?] display_name ×count
func _make_item_row(id: String, count: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	# Icon — try AssetRegistry; fall back to a colored swatch.
	var tex: Texture2D = AssetRegistry.get_icon(id)
	if tex != null:
		var icon_rect := TextureRect.new()
		icon_rect.texture = tex
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.custom_minimum_size = Vector2(24, 24)
		icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(icon_rect)
	else:
		# Tinted box using the catalog color as a stand-in when no icon file exists.
		var swatch := ColorRect.new()
		swatch.color = AssetRegistry.get_color(id)
		swatch.custom_minimum_size = Vector2(18, 18)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)

	# Display name.
	var name_lbl := Label.new()
	var item_data: ItemData = ItemCatalog.get_item(id)
	if item_data != null:
		name_lbl.text = (item_data as ItemData).display_name
	else:
		name_lbl.text = id
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	# Count.
	var count_lbl := Label.new()
	count_lbl.text = "x%d" % count
	count_lbl.add_theme_color_override("font_color", COL_AMBER)
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(count_lbl)

	return row


## Dim single-line label used for blueprint / quest / empty-state text.
func _make_dim_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", COL_DIM)
	return lbl


## Removes all children from a container (so sections can be rebuilt on each show).
func _clear_children(container: Control) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


# ── Button handlers ───────────────────────────────────────────────────────────

func _on_continue() -> void:
	hide()
	continue_requested.emit()


func _on_restart() -> void:
	hide()
	restart_requested.emit()
