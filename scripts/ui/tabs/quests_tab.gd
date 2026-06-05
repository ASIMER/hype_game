extends Control
## QuestsTab — the QUESTS hub tab. Shown/hidden by the Hub; all child nodes are
## built procedurally in _build_layout(). Refreshes on _ready and whenever
## quest progress / stash changes on the Events bus.
##
## Two sections:
##   DAILY CONTRACTS  — Quests.get_daily_quests() (rotating, resets each day)
##   STANDING CONTRACTS — Quests.standing() (one-and-done, non-daily)
## Reads Quests.progress(), Quests.is_complete(), Quests.claim()
## and QuestData fields (id, title, desc, daily, obj_count, reward_currency,
## reward_items(), reward_blueprints). Item names are resolved via ItemCatalog.


# Project theme colours (matching loadout_tab.gd / workshop.gd).
const COL_AMBER := Color(0.91, 0.64, 0.24, 1.0)   # amber accent / header
const COL_TEAL  := Color(0.247, 0.71, 0.79, 1.0)  # teal accent / section
const COL_DIM   := Color(0.45, 0.50, 0.55, 1.0)   # muted label
const COL_WHITE := Color(0.88, 0.90, 0.92, 1.0)   # body text
const COL_GREEN := Color(0.30, 0.75, 0.40, 1.0)   # complete / claimable
const COL_RED   := Color(0.85, 0.30, 0.25, 1.0)   # incomplete / locked


# ---------------------------------------------------------------- node refs
# Populated in _build_layout() (called once from _ready).
var _cards_container: VBoxContainer
var _empty_label: Label


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	Events.quest_progress.connect(_on_quest_event_id_cur_target)
	Events.quest_completed.connect(_on_quest_event_id)
	Events.stash_changed.connect(_on_stash_changed)
	Events.dailies_rotated.connect(_on_dailies_rotated)
	_refresh()


func _exit_tree() -> void:
	if Events.quest_progress.is_connected(_on_quest_event_id_cur_target):
		Events.quest_progress.disconnect(_on_quest_event_id_cur_target)
	if Events.quest_completed.is_connected(_on_quest_event_id):
		Events.quest_completed.disconnect(_on_quest_event_id)
	if Events.stash_changed.is_connected(_on_stash_changed):
		Events.stash_changed.disconnect(_on_stash_changed)
	if Events.dailies_rotated.is_connected(_on_dailies_rotated):
		Events.dailies_rotated.disconnect(_on_dailies_rotated)


# ---------------------------------------------------------------- layout construction
## Builds the full UI tree procedurally. Called once from _ready.
func _build_layout() -> void:
	# ── Scroll root ──────────────────────────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	scroll.add_child(body)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	body.add_child(margin)

	var inner := VBoxContainer.new()
	inner.name = "Inner"
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 20)
	margin.add_child(inner)

	# ── Page header ──────────────────────────────────────────────────────────
	var hdr := Label.new()
	hdr.name = "Header"
	hdr.text = "QUESTS"
	hdr.add_theme_font_size_override("font_size", 42)
	hdr.add_theme_color_override("font_color", COL_AMBER)
	inner.add_child(hdr)

	# ── "No contracts available" placeholder (shown when both lists are empty) ─
	_empty_label = Label.new()
	_empty_label.name = "EmptyLabel"
	_empty_label.text = "No contracts available"
	_empty_label.add_theme_color_override("font_color", COL_DIM)
	_empty_label.add_theme_font_size_override("font_size", 16)
	_empty_label.visible = false
	inner.add_child(_empty_label)

	# ── Quest cards container ────────────────────────────────────────────────
	_cards_container = VBoxContainer.new()
	_cards_container.name = "Cards"
	_cards_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_container.add_theme_constant_override("separation", 12)
	inner.add_child(_cards_container)


# ---------------------------------------------------------------- refresh
## Full rebuild from Quests.get_daily_quests() + Quests.standing().
## Called on _ready + any quest / stash / dailies_rotated event.
func _refresh() -> void:
	if not _cards_container:
		return

	# Clear all existing section nodes.
	for child in _cards_container.get_children():
		child.queue_free()

	var dailies: Array = Quests.get_daily_quests()
	var standing: Array = Quests.standing()
	var both_empty: bool = dailies.is_empty() and standing.is_empty()

	_empty_label.visible = both_empty
	_cards_container.visible = not both_empty

	if both_empty:
		return

	# ── DAILY CONTRACTS section ──────────────────────────────────────────────
	_cards_container.add_child(_build_section_header(
		"DAILY CONTRACTS", "Refreshes each day", COL_TEAL))

	for q_var in dailies:
		var q := q_var as QuestData
		if q == null:
			continue
		_cards_container.add_child(_build_card(q))

	# ── STANDING CONTRACTS section ───────────────────────────────────────────
	_cards_container.add_child(_build_section_header("CONTRACTS", "", COL_AMBER))

	for q_var in standing:
		var q := q_var as QuestData
		if q == null:
			continue
		_cards_container.add_child(_build_card(q))


## Builds a labelled section header with an optional sub-note beneath it.
func _build_section_header(title: String, note: String, accent: Color) -> VBoxContainer:
	var sec := VBoxContainer.new()
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sec.add_theme_constant_override("separation", 2)

	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", accent)
	sec.add_child(lbl)

	if note != "":
		var note_lbl := Label.new()
		note_lbl.text = note
		note_lbl.add_theme_font_size_override("font_size", 12)
		note_lbl.add_theme_color_override("font_color", COL_DIM)
		sec.add_child(note_lbl)

	return sec


## Builds a self-contained card PanelContainer for a single QuestData.
func _build_card(q: QuestData) -> PanelContainer:
	var complete: bool = Quests.is_complete(q)
	var cur: int = Quests.progress(q.id)

	# ── Card panel ───────────────────────────────────────────────────────────
	var card := PanelContainer.new()
	card.name = "Quest_" + q.id
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.106, 0.133, 0.157, 0.97)
	sb.border_width_left = 3
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = COL_GREEN if complete else Color(0.235, 0.3, 0.36, 1.0)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_right = 8
	sb.corner_radius_bottom_left = 8
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 14
	sb.content_margin_left = 16.0
	sb.content_margin_top = 14.0
	sb.content_margin_right = 16.0
	sb.content_margin_bottom = 14.0
	card.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	# ── Title row (title + optional DAILY chip) ──────────────────────────────
	var title_row := HBoxContainer.new()
	title_row.name = "TitleRow"
	title_row.add_theme_constant_override("separation", 8)
	vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.name = "Title"
	title_lbl.text = q.title
	title_lbl.add_theme_color_override("font_color", COL_AMBER)
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)

	if q.daily:
		var chip := Label.new()
		chip.name = "DailyChip"
		chip.text = "DAILY"
		chip.add_theme_font_size_override("font_size", 11)
		chip.add_theme_color_override("font_color", COL_TEAL)
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		title_row.add_child(chip)

	# ── Description ──────────────────────────────────────────────────────────
	if q.desc != "":
		var desc_lbl := Label.new()
		desc_lbl.name = "Desc"
		desc_lbl.text = q.desc
		desc_lbl.add_theme_color_override("font_color", COL_DIM)
		desc_lbl.add_theme_font_size_override("font_size", 13)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(desc_lbl)

	# ── Progress bar + counter ───────────────────────────────────────────────
	var prog_row := HBoxContainer.new()
	prog_row.name = "ProgressRow"
	prog_row.add_theme_constant_override("separation", 10)
	vbox.add_child(prog_row)

	var bar := ProgressBar.new()
	bar.name = "ProgressBar"
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.custom_minimum_size = Vector2(0, 12)
	bar.min_value = 0.0
	bar.max_value = float(maxi(1, q.obj_count))
	bar.value = float(clampi(cur, 0, q.obj_count))
	bar.show_percentage = false
	prog_row.add_child(bar)

	var counter_lbl := Label.new()
	counter_lbl.name = "Counter"
	counter_lbl.text = "%d / %d" % [clampi(cur, 0, q.obj_count), q.obj_count]
	counter_lbl.add_theme_color_override("font_color", COL_GREEN if complete else COL_WHITE)
	counter_lbl.add_theme_font_size_override("font_size", 13)
	counter_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	prog_row.add_child(counter_lbl)

	# ── Reward line ──────────────────────────────────────────────────────────
	var reward_parts: Array[String] = []
	if q.reward_currency > 0:
		reward_parts.append("CR %d" % q.reward_currency)
	for it_var in q.reward_items():
		var it: Dictionary = it_var as Dictionary
		var item_id: String = String(it.get("id", ""))
		var item_count: int = int(it.get("count", 1))
		var item_data: ItemData = ItemCatalog.get_item(item_id)
		var item_name: String = item_data.display_name if item_data != null else item_id
		reward_parts.append("%s x%d" % [item_name, item_count])
	for bp in q.reward_blueprints:
		if String(bp) != "":
			reward_parts.append("Blueprint: %s" % String(bp))

	if not reward_parts.is_empty():
		var reward_lbl := Label.new()
		reward_lbl.name = "Reward"
		reward_lbl.text = "Reward: " + ", ".join(reward_parts)
		reward_lbl.add_theme_color_override("font_color", COL_TEAL)
		reward_lbl.add_theme_font_size_override("font_size", 13)
		reward_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		reward_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(reward_lbl)

	# ── CLAIM / IN PROGRESS button ───────────────────────────────────────────
	var btn_row := HBoxContainer.new()
	btn_row.name = "BtnRow"
	vbox.add_child(btn_row)

	# Spacer to right-align the button.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)

	var claim_btn := Button.new()
	claim_btn.name = "ClaimBtn"
	claim_btn.focus_mode = Control.FOCUS_NONE
	claim_btn.custom_minimum_size = Vector2(140, 36)
	if complete:
		claim_btn.text = "CLAIM"
		claim_btn.disabled = false
		claim_btn.add_theme_color_override("font_color", COL_GREEN)
		# Capture q.id by value for the closure.
		var quest_id: String = q.id
		claim_btn.pressed.connect(func() -> void: _on_claim_pressed(quest_id))
	else:
		claim_btn.text = "IN PROGRESS"
		claim_btn.disabled = true
		claim_btn.add_theme_color_override("font_color", COL_DIM)
	btn_row.add_child(claim_btn)

	return card


# ---------------------------------------------------------------- event handlers
func _on_quest_event_id_cur_target(_id: String, _cur: int, _target: int) -> void:
	_refresh()


func _on_quest_event_id(_id: String) -> void:
	_refresh()


func _on_stash_changed() -> void:
	_refresh()


func _on_dailies_rotated() -> void:
	_refresh()


func _on_claim_pressed(quest_id: String) -> void:
	Quests.claim(quest_id)
	_refresh()
