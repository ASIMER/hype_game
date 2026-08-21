extends Control
class_name QuestDetail
## Rich quest DETAIL modal (Iteration 2): full lore + giver + (if part of a questline) the
## ordered step list with ✓ claimed / ▶ current / 🔒 locked glyphs, plus ACCEPT/CLAIM for the
## focused quest. Built in code per the project's "military glass" UI conventions
## (GlassBackdrop + glass panel + pop_in). Self-contained: open(quest_id) builds it; ACCEPT/
## CLAIM route through Quests then rebuild + emit `changed`; backdrop/Esc/✕ → queue_free + `closed`.

signal changed
signal closed

const COL_AMBER := UIStyle.AMBER
const COL_TEAL := UIStyle.TEAL
const COL_GREEN := UIStyle.GREEN
const COL_RED := UIStyle.RED
const COL_DIM := UIStyle.DIM
const COL_WHITE := UIStyle.WHITE

var _quest_id: String = ""
var _body: VBoxContainer = null
var _center: Control = null


func _ready() -> void:
	top_level = true  # cover the whole viewport regardless of parent transform
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Frosted-glass backdrop behind everything; clicking it closes.
	var bg := GlassBackdrop.new()
	add_child(bg)
	move_child(bg, 0)
	var catch := Button.new()
	catch.flat = true
	catch.set_anchors_preset(Control.PRESET_FULL_RECT)
	catch.focus_mode = Control.FOCUS_NONE
	catch.pressed.connect(_close)
	add_child(catch)


## Opens the modal for `quest_id` (call right after add_child).
func open(quest_id: String) -> void:
	_quest_id = quest_id
	_rebuild()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()


func _rebuild() -> void:
	# Drop any previous panel (rebuild after an accept/claim).
	if _center != null and is_instance_valid(_center):
		_center.queue_free()
	_body = null
	var q: QuestData = Quests.quest_by_id(_quest_id)
	if q == null:
		_close()
		return
	var line: QuestLine = Quests.questline_of(_quest_id)

	# Centered glass panel.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_center = center

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	panel.add_theme_stylebox_override("panel", UIStyle.glass_panel(0.96))
	center.add_child(panel)

	var margin := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 22)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(col)
	_body = col

	# ── Header row: questline tag + title + close ────────────────────────────
	if line != null:
		var lp: Dictionary = Quests.line_progress(line)
		var tag := UIStyle.micro_header(
			(
				"⛓ %s · %s %d/%d"
				% [tr(line.title), tr("Step"), _step_no(line), int(lp.get("total", 0))]
			),
			_accent_col(line.accent),
			13
		)
		col.add_child(tag)

	var title_row := HBoxContainer.new()
	col.add_child(title_row)
	var title := Label.new()
	title.text = tr(q.title)
	UIStyle.make_header(title, COL_AMBER, 26, 2)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.pressed.connect(_close)
	title_row.add_child(close_btn)

	# ── Giver byline ─────────────────────────────────────────────────────────
	var giver_name: String = q.giver if q.giver != "" else (line.giver if line != null else "")
	if giver_name != "":
		var giver := Label.new()
		giver.text = tr("Issued by: ") + giver_name
		giver.add_theme_color_override("font_color", COL_TEAL)
		giver.add_theme_font_size_override("font_size", 13)
		col.add_child(giver)
		# Giver standing (tier + progress toward the next).
		var gp: Dictionary = MetaProgression.giver_rep_progress(giver_name)
		var gneed: int = int(gp.get("need", 0))
		var standing := Label.new()
		if gneed <= 0:
			standing.text = tr("Standing: Tier %d (max)") % int(gp.get("tier", 0))
		else:
			standing.text = (
				tr("Standing: Tier %d  (%d / %d)")
				% [int(gp.get("tier", 0)), int(gp.get("into", 0)), gneed]
			)
		standing.add_theme_color_override("font_color", COL_DIM)
		standing.add_theme_font_size_override("font_size", 13)
		col.add_child(standing)

	# ── Lore (quest lore, else the questline intro) ──────────────────────────
	var lore_text: String = q.lore
	if lore_text == "" and line != null:
		lore_text = line.intro
	if lore_text != "":
		col.add_child(_wrap_label(tr(lore_text), COL_WHITE, 14))

	# ── Objective + reward ───────────────────────────────────────────────────
	col.add_child(UIStyle.micro_header(tr("OBJECTIVE"), COL_DIM, 12))
	var cur := Quests.progress(q.id)
	col.add_child(
		_wrap_label(
			"%s   (%d / %d)" % [tr(q.desc), clampi(cur, 0, q.obj_count), q.obj_count], COL_WHITE, 14
		)
	)
	var reward := _reward_text(q)
	if reward != "":
		col.add_child(_wrap_label(tr("Reward: ") + reward, COL_TEAL, 13))

	# ── Questline step list ──────────────────────────────────────────────────
	if line != null:
		col.add_child(UIStyle.micro_header(tr("STORY"), _accent_col(line.accent), 12))
		for step in Quests.line_steps(line):
			col.add_child(_step_row(step as QuestData))

	# ── Action button for the focused quest ──────────────────────────────────
	var st := Quests.state_of(q.id)
	var act := _action_button(q, st)
	if act != null:
		var act_row := HBoxContainer.new()
		col.add_child(act_row)
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		act_row.add_child(sp)
		act_row.add_child(act)

	UIStyle.pop_in(panel, UIStyle.Dir.DOWN, 16.0, 0.16)


# ── helpers ──────────────────────────────────────────────────────────────────
func _step_no(line: QuestLine) -> int:
	return Quests.line_step_index(line, _quest_id) + 1


func _accent_col(accent: int) -> Color:
	match accent:
		1:
			return COL_TEAL
		2:
			return COL_GREEN
		_:
			return COL_AMBER


func _wrap_label(text: String, col: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _reward_text(q: QuestData) -> String:
	var parts: Array[String] = []
	if q.reward_currency > 0:
		parts.append(tr("CR %d") % q.reward_currency)
	for it_var in q.reward_items():
		var it: Dictionary = it_var
		var idata: ItemData = ItemCatalog.get_item(String(it.get("id", "")))
		var nm: String = tr(idata.display_name) if idata != null else String(it.get("id", ""))
		parts.append(tr("%s x%d") % [nm, int(it.get("count", 1))])
	for bp in q.reward_blueprints:
		if String(bp) != "":
			parts.append(tr("Blueprint: %s") % String(bp))
	return ", ".join(parts)


## One step row: glyph + title (+ unlock hint for locked steps).
func _step_row(step: QuestData) -> Control:
	var st := Quests.state_of(step.id)
	var glyph := "🔒"
	var col := COL_DIM
	var suffix := ""
	if st == "claimed":
		glyph = "✓"
		col = COL_GREEN
	elif st == "active" or st == "completed" or st == "available":
		glyph = "▶"
		col = COL_WHITE
		suffix = "   %d/%d" % [clampi(Quests.progress(step.id), 0, step.obj_count), step.obj_count]
	else:
		suffix = "   " + Quests.unlock_hint(step)
	var row := Label.new()
	row.text = "%s  %s%s" % [glyph, tr(step.title), suffix]
	row.add_theme_color_override("font_color", col)
	row.add_theme_font_size_override("font_size", 13)
	row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Highlight the focused step.
	if step.id == _quest_id:
		row.add_theme_color_override("font_color", COL_AMBER)
	return row


## ACCEPT (available) / CLAIM (active+complete) for the focused quest, else null.
func _action_button(q: QuestData, st: String) -> Button:
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(150, 38)
	if st == "available":
		btn.text = tr("ACCEPT")
		btn.add_theme_color_override("font_color", COL_GREEN)
		var aid: String = q.id
		btn.pressed.connect(func() -> void: _do(aid, true))
		UIStyle.hover_lift(btn)
		return btn
	if (st == "active" or st == "completed") and Quests.is_complete(q):
		btn.text = tr("CLAIM")
		btn.add_theme_color_override("font_color", COL_GREEN)
		var cid: String = q.id
		btn.pressed.connect(func() -> void: _do(cid, false))
		UIStyle.hover_lift(btn)
		return btn
	return null


## ACCEPT (do_accept=true) or CLAIM the quest, then refresh the modal + tell the tab.
func _do(quest_id: String, do_accept: bool) -> void:
	if do_accept:
		Quests.accept(quest_id)
	else:
		Quests.claim(quest_id)
	changed.emit()
	_rebuild()
