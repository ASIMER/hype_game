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
const COL_TEAL  := Color(0.247, 0.71, 0.79, 1.0)
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

# ── Progression section (injected dynamically before _sep_bot in _ready) ─────
var _prog_section: VBoxContainer = null
var _prog_list: VBoxContainer    = null

# ── per-run accumulators (reset on match_started) ─────────────────────────────
## Raw loot deposited this run: id -> count.
var _loot_counts: Dictionary = {}
## Currency bonus earned this run (from raid_loot_granted).
var _loot_bonus: int = 0
## Blueprint ids learned this run.
var _blueprints: Array[String] = []
## Quest ids completed this run.
var _quests_done: Array[String] = []

# ── Progression accumulators ──────────────────────────────────────────────────
## XP earned this run by source: "kill", "extract", "event", "loot".
var _xp_by_source: Dictionary = {}
## New raider level reached this run (0 = no level-up).
var _new_raider_level: int = 0
## vendor_rep value at match start (to compute delta at show time).
var _rep_before: int = 0
## Rep tier at the START of the run (to detect tier-ups).
var _rep_tier_start: int = 0
## Weapon ids whose mastery levelled this run.
var _mastery_leveled: Array[String] = []


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

	# Progression accumulation.
	Events.xp_gained.connect(_on_xp_gained)
	Events.raider_level_up.connect(_on_raider_level_up)
	Events.reputation_changed.connect(_on_reputation_changed)
	Events.weapon_mastery_changed.connect(_on_weapon_mastery_changed)

	# Match-end triggers.
	Events.match_won.connect(_on_match_won)
	Events.match_lost.connect(_on_match_lost)

	# ── Inject progression section into the VBox before the bottom separator ──
	var vbox: VBoxContainer = get_node_or_null("Root/Panel/VBox") as VBoxContainer
	if vbox != null and _sep_bot != null:
		_prog_section = VBoxContainer.new()
		_prog_section.name = "ProgSection"
		_prog_section.add_theme_constant_override("separation", 4)
		_prog_section.visible = false

		var prog_hdr := Label.new()
		prog_hdr.name = "ProgHeader"
		prog_hdr.text = "PROGRESSION"
		prog_hdr.add_theme_font_size_override("font_size", 13)
		prog_hdr.add_theme_color_override("font_color", COL_DIM)
		_prog_section.add_child(prog_hdr)

		_prog_list = VBoxContainer.new()
		_prog_list.name = "ProgList"
		_prog_list.add_theme_constant_override("separation", 3)
		_prog_section.add_child(_prog_list)

		# Insert before the bottom separator so buttons stay at the bottom.
		var sep_idx: int = _sep_bot.get_index()
		vbox.add_child(_prog_section)
		vbox.move_child(_prog_section, sep_idx)

	hide()


# ── Event handlers — accumulate ───────────────────────────────────────────────

## Reset all accumulators when a NEW match begins so each run is clean.
func _on_match_started() -> void:
	_loot_counts.clear()
	_loot_bonus = 0
	_blueprints.clear()
	_quests_done.clear()
	_xp_by_source.clear()
	_new_raider_level = 0
	_rep_before = MetaProgression.vendor_rep
	_rep_tier_start = MetaProgression.rep_tier()
	_mastery_leveled.clear()


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


# ── Progression accumulation ──────────────────────────────────────────────────

func _on_xp_gained(amount: int, source: String) -> void:
	var src: String = source if source != "" else "misc"
	_xp_by_source[src] = int(_xp_by_source.get(src, 0)) + amount

func _on_raider_level_up(new_level: int, _skill_points: int) -> void:
	_new_raider_level = new_level

func _on_reputation_changed(_rep: int, _tier: int) -> void:
	pass  # Delta computed in _show_summary via the _rep_before snapshot.

func _on_weapon_mastery_changed(weapon_id: String, _level: int) -> void:
	if weapon_id not in _mastery_leveled:
		_mastery_leveled.append(weapon_id)


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

	# Progression section.
	_show_progression_section()

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	show()


func _show_progression_section() -> void:
	if _prog_section == null or _prog_list == null:
		return
	_clear_children(_prog_list)

	var any_line: bool = false

	# ── XP breakdown ─────────────────────────────────────────────────────────
	var total_xp: int = 0
	for src in _xp_by_source:
		total_xp += int(_xp_by_source[src])

	if total_xp > 0:
		# Build a compact breakdown: "+XP 1440  (kills 900 · extract 500 · loot 40)"
		var parts: Array[String] = []
		var kill_xp: int   = int(_xp_by_source.get("kill", 0))
		var ext_xp: int    = int(_xp_by_source.get("extract", 0))
		var event_xp: int  = int(_xp_by_source.get("event", 0))
		var loot_xp: int   = int(_xp_by_source.get("loot", 0))
		if kill_xp > 0:
			parts.append("kills %d" % kill_xp)
		if ext_xp > 0:
			parts.append("extract %d" % ext_xp)
		if event_xp > 0:
			parts.append("events %d" % event_xp)
		if loot_xp > 0:
			parts.append("loot %d" % loot_xp)

		var xp_lbl := Label.new()
		xp_lbl.add_theme_font_size_override("font_size", 14)
		xp_lbl.add_theme_color_override("font_color", COL_AMBER)
		if parts.is_empty():
			xp_lbl.text = "+XP %d" % total_xp
		else:
			xp_lbl.text = "+XP %d  (%s)" % [total_xp, "  ·  ".join(parts)]
		_prog_list.add_child(xp_lbl)
		any_line = true

	# ── Level-up ─────────────────────────────────────────────────────────────
	if _new_raider_level > 0:
		var lvl_lbl := Label.new()
		lvl_lbl.text = "RAIDER LEVEL UP  →  %d" % _new_raider_level
		lvl_lbl.add_theme_font_size_override("font_size", 15)
		lvl_lbl.add_theme_color_override("font_color", COL_TEAL)
		_prog_list.add_child(lvl_lbl)
		any_line = true

	# ── Rep gained ───────────────────────────────────────────────────────────
	var rep_gained: int = MetaProgression.vendor_rep - _rep_before
	if rep_gained > 0:
		var tier_now: int  = MetaProgression.rep_tier()
		var rep_lbl := Label.new()
		rep_lbl.add_theme_font_size_override("font_size", 13)
		rep_lbl.add_theme_color_override("font_color", COL_DIM)
		if tier_now > _rep_tier_start:
			rep_lbl.text = "+REP %d  (Tier %d → Tier %d)" % [rep_gained, _rep_tier_start, tier_now]
			rep_lbl.add_theme_color_override("font_color", COL_TEAL)
		else:
			rep_lbl.text = "+REP %d  (Tier %d)" % [rep_gained, tier_now]
		_prog_list.add_child(rep_lbl)
		any_line = true

	# ── Weapon mastery level-ups ──────────────────────────────────────────────
	for wid in _mastery_leveled:
		var lvl: int = MetaProgression.weapon_mastery_level(String(wid))
		var m_lbl := Label.new()
		m_lbl.text = "Mastery: %s  Lv%d" % [String(wid).to_upper(), lvl]
		m_lbl.add_theme_font_size_override("font_size", 13)
		m_lbl.add_theme_color_override("font_color", COL_AMBER)
		_prog_list.add_child(m_lbl)
		any_line = true

	_prog_section.visible = any_line


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
