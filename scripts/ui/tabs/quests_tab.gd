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
var _daily_timer_lbl: Label = null   # live "resets in HH:MM:SS" footer label
var _tick_accum: float = 0.0

# Responsive columns: each section's quest cards go into a GridContainer whose column count is
# computed from the tab width (UILayout.columns_for) so a single card never stretches full-width
# on a wide/ultrawide monitor — more columns appear as the window widens. Recomputed on `resized`.
const _CARD_W := 480.0       # target quest-card width (px)
const _MAX_COLS := 5
var _grids: Array[GridContainer] = []   # all section card-grids (for resize recompute)
var _current_grid: GridContainer = null # the grid the next _add_card() fills


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	# Reflow the card grids whenever the tab (and thus the window) resizes.
	resized.connect(_apply_columns)
	Events.quest_progress.connect(_on_quest_event_id_cur_target)
	Events.quest_completed.connect(_on_quest_event_id)
	Events.quest_unlocked.connect(_on_quest_event_id)
	Events.quest_accepted.connect(_on_quest_event_id)
	Events.giver_rep_changed.connect(_on_giver_rep_changed)
	Events.stash_changed.connect(_on_stash_changed)
	Events.dailies_rotated.connect(_on_dailies_rotated)
	# Opening the QUESTS tab is a natural moment to re-evaluate condition-based offers.
	if has_node("/root/QuestDirector"):
		get_node("/root/QuestDirector").evaluate_offers()
	_refresh()


func _exit_tree() -> void:
	if Events.quest_progress.is_connected(_on_quest_event_id_cur_target):
		Events.quest_progress.disconnect(_on_quest_event_id_cur_target)
	if Events.quest_completed.is_connected(_on_quest_event_id):
		Events.quest_completed.disconnect(_on_quest_event_id)
	if Events.quest_unlocked.is_connected(_on_quest_event_id):
		Events.quest_unlocked.disconnect(_on_quest_event_id)
	if Events.quest_accepted.is_connected(_on_quest_event_id):
		Events.quest_accepted.disconnect(_on_quest_event_id)
	if Events.giver_rep_changed.is_connected(_on_giver_rep_changed):
		Events.giver_rep_changed.disconnect(_on_giver_rep_changed)
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
	UIStyle.make_header(hdr, UIStyle.AMBER, 42, 3)
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

	# Clear all existing section nodes + the per-section grids tracked for resize.
	for child in _cards_container.get_children():
		child.queue_free()
	_grids.clear()
	_current_grid = null

	# Generic sections show STANDALONE contracts only; questline members render under their line.
	var dailies_unclaimed: Array = Quests.daily_unclaimed()
	var has_dailies: bool = not Quests.get_daily_quests().is_empty()
	var available: Array = _standalone(Quests.offered())
	var active: Array = _standalone(Quests.accepted())
	var locked: Array = _standalone(Quests.locked_teasers())
	var lines: Array = _visible_lines()
	var all_empty: bool = not has_dailies and available.is_empty() and active.is_empty() \
		and locked.is_empty() and lines.is_empty()

	_empty_label.visible = all_empty
	_cards_container.visible = not all_empty
	if all_empty:
		return

	# ── STANDING (per-giver reputation) ──────────────────────────────────────
	_build_giver_standing()

	# ── QUESTLINES (story groups: header strip + the line's current step) ────
	for line_var in lines:
		_build_questline_group(line_var as QuestLine)

	# ── AVAILABLE (offered, awaiting ACCEPT) ─────────────────────────────────
	if not available.is_empty():
		_cards_container.add_child(_build_section_header(
			tr("AVAILABLE CONTRACTS"), tr("Accept to add to your active log"), COL_GREEN))
		_begin_card_grid()
		for q_var in available:
			_add_card(q_var, "available")

	# ── ACTIVE (accepted standing contracts) ─────────────────────────────────
	if not active.is_empty():
		_cards_container.add_child(_build_section_header(
			tr("ACTIVE CONTRACTS"), tr("%d / %d active") % [Quests.active_count(), Settings.ACTIVE_QUEST_CAP], COL_AMBER))
		_begin_card_grid()
		for q_var in active:
			_add_card(q_var, "active")

	# ── DAILY (un-claimed cards + a "resets in HH:MM:SS" footer; claimed ones drop off) ──
	if has_dailies:
		_cards_container.add_child(_build_section_header(
			tr("DAILY CONTRACTS"), tr("Refreshes each day"), COL_TEAL))
		_begin_card_grid()
		for q_var in dailies_unclaimed:
			_add_card(q_var, "active")
		_current_grid = null   # the footer is a full-width strip, not a card
		_cards_container.add_child(_build_daily_footer())

	# ── LOCKED (teasers with an unlock hint — the next goals to chase) ────────
	if not locked.is_empty():
		_cards_container.add_child(_build_section_header(
			tr("LOCKED"), tr("Meet the conditions to unlock"), COL_DIM))
		_begin_card_grid()
		for q_var in locked:
			_add_card(q_var, "locked")

	# (No COMPLETED section — a claimed contract LEAVES the board.)
	# Apply the responsive column count once the tree has laid out (size.x is valid).
	_apply_columns.call_deferred()


## Keeps only standalone (non-questline) quests from an array.
func _standalone(arr: Array) -> Array:
	var out: Array = []
	for q_var in arr:
		var q := q_var as QuestData
		if q != null and q.questline == "":
			out.append(q)
	return out

## Questlines that have anything worth showing (a current step that isn't a far-off lock with
## no progress yet shows as a teaser; fully-claimed lines collapse to a single done header).
func _visible_lines() -> Array:
	return Quests.questlines()

## Renders a questline as a tinted header strip ("⛓ TITLE — Step X/Y · giver") + its CURRENT
## step card (available→ACCEPT / active→progress+CLAIM / locked→teaser). Full step list = modal.
func _build_questline_group(line: QuestLine) -> void:
	if line == null:
		return
	var lp: Dictionary = Quests.line_progress(line)
	var total: int = int(lp.get("total", 0))
	var done: int = int(lp.get("done", 0))
	var current_id: String = String(lp.get("current_id", ""))
	var accent: Color = _accent_col(line.accent)
	var sub: String
	if current_id == "":
		sub = tr("Questline complete")
	else:
		sub = "%s %d / %d · %s" % [tr("Step"), done + 1, total, line.giver]
	_cards_container.add_child(_build_section_header("⛓ " + tr(line.title), sub, accent))
	if current_id == "":
		return
	var step: QuestData = Quests.quest_by_id(current_id)
	if step == null:
		return
	_begin_card_grid()
	var st := Quests.state_of(current_id)
	var mode := "locked"
	if st == "available":
		mode = "available"
	elif st == "active" or st == "completed":
		mode = "active"
	_add_card(step, mode)


func _accent_col(accent: int) -> Color:
	match accent:
		1: return COL_TEAL
		2: return COL_GREEN
		_: return COL_AMBER


## "Daily contracts reset in HH:MM:SS · X / Y done today" — ticks live via _process.
func _build_daily_footer() -> Control:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.glass_panel(0.5))
	var mc := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		mc.add_theme_constant_override(m, 8)
	pc.add_child(mc)
	var lbl := Label.new()
	lbl.add_theme_color_override("font_color", COL_DIM)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mc.add_child(lbl)
	_daily_timer_lbl = lbl
	_update_daily_timer()
	return pc


func _update_daily_timer() -> void:
	if _daily_timer_lbl == null or not is_instance_valid(_daily_timer_lbl):
		return
	var done: int = Quests.daily_claimed_count()
	var total: int = Quests.get_daily_quests().size()
	_daily_timer_lbl.text = tr("Daily contracts reset in %s") % _fmt_hms(Quests.seconds_until_daily_reset()) \
		+ "   ·   " + tr("%d / %d done today") % [done, total]


func _fmt_hms(secs: int) -> String:
	var h := secs / 3600
	var m := (secs % 3600) / 60
	var s := secs % 60
	return "%02d:%02d:%02d" % [h, m, s]


func _process(delta: float) -> void:
	if _daily_timer_lbl == null or not is_instance_valid(_daily_timer_lbl):
		return
	_tick_accum += delta
	if _tick_accum >= 1.0:
		_tick_accum = 0.0
		_update_daily_timer()


## Per-giver reputation strip: one row per known contact (name + tier badge + rep progress bar).
func _build_giver_standing() -> void:
	var givers: Array[String] = []
	for l in Quests.questlines():
		var g1: String = (l as QuestLine).giver
		if g1 != "" and not (g1 in givers):
			givers.append(g1)
	for q in Quests.all():
		var g2: String = (q as QuestData).giver
		if g2 != "" and not (g2 in givers):
			givers.append(g2)
	if givers.is_empty():
		return
	_cards_container.add_child(_build_section_header(
		tr("STANDING"), tr("Reputation with your contacts"), COL_TEAL))
	for g in givers:
		_cards_container.add_child(_giver_row(g))


func _giver_row(giver: String) -> PanelContainer:
	var prog: Dictionary = MetaProgression.giver_rep_progress(giver)
	var tier: int = int(prog.get("tier", 0))
	var into: int = int(prog.get("into", 0))
	var need: int = int(prog.get("need", 0))
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	var mc := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		mc.add_theme_constant_override(m, 8)
	mc.add_child(hb)
	pc.add_child(mc)
	var name_lbl := Label.new()
	name_lbl.text = giver
	name_lbl.add_theme_color_override("font_color", COL_AMBER)
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_lbl.custom_minimum_size = Vector2(180, 0)
	hb.add_child(name_lbl)
	hb.add_child(_chip(tr("TIER %d") % tier, COL_TEAL))
	var bar := ProgressBar.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.custom_minimum_size = Vector2(0, 10)
	bar.show_percentage = false
	bar.theme_type_variation = "FillAmber"
	if need <= 0:
		bar.min_value = 0; bar.max_value = 1; bar.value = 1   # max tier
	else:
		bar.min_value = 0; bar.max_value = need; bar.value = clampi(into, 0, need)
	hb.add_child(bar)
	var amt := Label.new()
	amt.text = (tr("MAX") if need <= 0 else "%d / %d" % [into, need])
	amt.add_theme_color_override("font_color", COL_DIM)
	amt.add_theme_font_size_override("font_size", 12)
	hb.add_child(amt)
	return pc


func _add_card(q_var: Variant, mode: String) -> void:
	var q := q_var as QuestData
	if q == null:
		return
	var target: Node = _current_grid if _current_grid != null else _cards_container
	target.add_child(_build_card(q, mode))


## Column count that fits the current tab width (minus the inner margins + scrollbar).
func _columns_now() -> int:
	return UILayout.columns_for(size.x - 56.0, _CARD_W, 12.0, _MAX_COLS)


## Start a fresh responsive card-grid under _cards_container; subsequent _add_card() fills it.
func _begin_card_grid() -> void:
	var grid := GridContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	grid.columns = _columns_now()
	_cards_container.add_child(grid)
	_grids.append(grid)
	_current_grid = grid


## Re-apply the responsive column count to every section grid (on resize / after a rebuild).
func _apply_columns() -> void:
	var cols: int = _columns_now()
	for g in _grids:
		if is_instance_valid(g):
			g.columns = cols


## Builds a glass-header section strip with an optional sub-note beneath it.
func _build_section_header(title: String, note: String, accent: Color) -> VBoxContainer:
	var sec := VBoxContainer.new()
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sec.add_theme_constant_override("separation", 2)

	var hdr_pc := PanelContainer.new()
	hdr_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_pc.add_theme_stylebox_override("panel", UIStyle.header_panel(accent))
	sec.add_child(hdr_pc)

	var lbl := UIStyle.micro_header(title, accent, 15)
	hdr_pc.add_child(lbl)

	if note != "":
		var note_lbl := Label.new()
		note_lbl.text = note
		note_lbl.add_theme_font_size_override("font_size", 12)
		note_lbl.add_theme_color_override("font_color", COL_DIM)
		sec.add_child(note_lbl)

	return sec


## Builds a self-contained card for a quest, laid out per `mode`:
##   "available" — desc + reward + ACCEPT button (+ NEW chip)
##   "active"    — desc + progress bar + reward + CLAIM/IN PROGRESS
##   "locked"    — title + lore + "🔒 Unlock by: …" hint (teaser; no progress)
##   "completed" — dim title + reward + CLAIMED tag
func _build_card(q: QuestData, mode: String = "active") -> PanelContainer:
	var complete: bool = Quests.is_complete(q)
	var cur: int = Quests.progress(q.id)
	var locked: bool = mode == "locked"
	var claimed: bool = mode == "completed"

	# ── Card panel ───────────────────────────────────────────────────────────
	var card := PanelContainer.new()
	card.name = "Quest_" + q.id
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var card_sb: StyleBoxFlat = UIStyle.glass_panel()
	card_sb.border_width_left = 3
	if mode == "available":
		card_sb.border_color = COL_GREEN
	elif complete and mode == "active":
		card_sb.border_color = COL_GREEN
	elif locked:
		card_sb.border_color = COL_DIM
	else:
		card_sb.border_color = UIStyle.BORDER_LT
	card.add_theme_stylebox_override("panel", card_sb)
	if locked or claimed:
		card.modulate = Color(1, 1, 1, 0.78)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	# ── Title row (title + a state chip) ─────────────────────────────────────
	var title_row := HBoxContainer.new()
	title_row.name = "TitleRow"
	title_row.add_theme_constant_override("separation", 8)
	vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.name = "Title"
	title_lbl.text = ("🔒 " if locked else "") + tr(q.title)
	title_lbl.add_theme_color_override("font_color", COL_DIM if locked else COL_AMBER)
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)

	if q.daily:
		title_row.add_child(_chip("DAILY", COL_TEAL))
	elif mode == "available":
		title_row.add_child(_chip(tr("NEW"), COL_GREEN))
	elif claimed:
		title_row.add_child(_chip(tr("CLAIMED"), COL_TEAL))

	# DETAILS button → opens the rich lore/giver/step modal.
	var details_btn := Button.new()
	details_btn.text = "ⓘ"
	details_btn.focus_mode = Control.FOCUS_NONE
	details_btn.custom_minimum_size = Vector2(34, 30)
	details_btn.tooltip_text = tr("Details")
	var detail_id: String = q.id
	details_btn.pressed.connect(func() -> void: _open_detail(detail_id))
	title_row.add_child(details_btn)

	# ── Giver byline ─────────────────────────────────────────────────────────
	if q.giver != "":
		var giver_lbl := Label.new()
		giver_lbl.text = "— " + q.giver
		giver_lbl.add_theme_color_override("font_color", COL_TEAL)
		giver_lbl.add_theme_font_size_override("font_size", 12)
		vbox.add_child(giver_lbl)

	# ── Description / lore ───────────────────────────────────────────────────
	var body_text: String = q.desc
	if locked and q.lore != "":
		body_text = q.lore
	if body_text != "":
		var desc_lbl := Label.new()
		desc_lbl.name = "Desc"
		desc_lbl.text = tr(body_text)
		desc_lbl.add_theme_color_override("font_color", COL_DIM)
		desc_lbl.add_theme_font_size_override("font_size", 13)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(desc_lbl)

	# ── Locked teaser: the unlock hint, no progress bar ──────────────────────
	if locked:
		var hint := Label.new()
		hint.name = "UnlockHint"
		hint.text = Quests.unlock_hint(q)
		hint.add_theme_color_override("font_color", COL_RED)
		hint.add_theme_font_size_override("font_size", 13)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(hint)

	# ── Progress bar + counter (ACTIVE only) ─────────────────────────────────
	if mode == "active":
		var prog_row := HBoxContainer.new()
		prog_row.add_theme_constant_override("separation", 10)
		vbox.add_child(prog_row)
		var bar := ProgressBar.new()
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.custom_minimum_size = Vector2(0, 12)
		bar.min_value = 0.0
		bar.max_value = float(maxi(1, q.obj_count))
		bar.value = float(clampi(cur, 0, q.obj_count))
		bar.show_percentage = false
		bar.theme_type_variation = "FillAmber"
		prog_row.add_child(bar)
		var counter_lbl := Label.new()
		counter_lbl.text = tr("%d / %d") % [clampi(cur, 0, q.obj_count), q.obj_count]
		counter_lbl.add_theme_color_override("font_color", COL_GREEN if complete else COL_WHITE)
		counter_lbl.add_theme_font_size_override("font_size", 13)
		counter_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		prog_row.add_child(counter_lbl)

	# ── Reward line ──────────────────────────────────────────────────────────
	var reward_parts: Array[String] = []
	if q.reward_currency > 0:
		reward_parts.append(tr("CR %d") % q.reward_currency)
	for it_var in q.reward_items():
		var it: Dictionary = it_var as Dictionary
		var item_id: String = String(it.get("id", ""))
		var item_count: int = int(it.get("count", 1))
		var item_data: ItemData = ItemCatalog.get_item(item_id)
		var item_name: String = tr(item_data.display_name) if item_data != null else item_id
		reward_parts.append(tr("%s x%d") % [item_name, item_count])
	for bp in q.reward_blueprints:
		if String(bp) != "":
			reward_parts.append(tr("Blueprint: %s") % String(bp))
	if not reward_parts.is_empty():
		var reward_lbl := Label.new()
		reward_lbl.name = "Reward"
		reward_lbl.text = tr("Reward: ") + ", ".join(reward_parts)
		reward_lbl.add_theme_color_override("font_color", COL_TEAL)
		reward_lbl.add_theme_font_size_override("font_size", 13)
		reward_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		reward_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(reward_lbl)

	# ── Action button (ACCEPT / CLAIM / IN PROGRESS) ─────────────────────────
	if mode == "available" or mode == "active":
		var btn_row := HBoxContainer.new()
		vbox.add_child(btn_row)
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn_row.add_child(spacer)
		var btn := Button.new()
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(140, 36)
		var quest_id: String = q.id
		if mode == "available":
			btn.text = tr("ACCEPT")
			btn.add_theme_color_override("font_color", COL_GREEN)
			btn.pressed.connect(func() -> void: _on_accept_pressed(quest_id))
			UIStyle.hover_lift(btn)
		elif complete:
			btn.text = tr("CLAIM")
			btn.add_theme_color_override("font_color", COL_GREEN)
			btn.pressed.connect(func() -> void: _on_claim_pressed(quest_id))
			UIStyle.hover_lift(btn)
		else:
			btn.text = tr("IN PROGRESS")
			btn.disabled = true
			btn.add_theme_color_override("font_color", COL_DIM)
		btn_row.add_child(btn)

	return card


## Small rounded state chip label.
func _chip(text: String, col: Color) -> Label:
	var chip := Label.new()
	chip.text = text
	chip.add_theme_font_size_override("font_size", 11)
	chip.add_theme_color_override("font_color", col)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return chip


# ---------------------------------------------------------------- event handlers
func _on_quest_event_id_cur_target(_id: String, _cur: int, _target: int) -> void:
	_refresh()


func _on_quest_event_id(_id: String) -> void:
	_refresh()


func _on_stash_changed() -> void:
	_refresh()


func _on_dailies_rotated() -> void:
	_refresh()


func _on_giver_rep_changed(_giver: String, _rep: int, _tier: int) -> void:
	_refresh()


## Opens the rich detail modal for a quest, hosted on the nearest CanvasLayer so it overlays
## the whole Hub. Refreshes the tab when an ACCEPT/CLAIM happens inside the modal.
func _open_detail(quest_id: String) -> void:
	var modal := QuestDetail.new()
	_modal_host().add_child(modal)
	modal.open(quest_id)
	modal.changed.connect(_refresh)


func _modal_host() -> Node:
	var n: Node = self
	while n != null:
		if n is CanvasLayer:
			return n
		n = n.get_parent()
	return self


func _on_accept_pressed(quest_id: String) -> void:
	Quests.accept(quest_id)
	_refresh()


func _on_claim_pressed(quest_id: String) -> void:
	Quests.claim(quest_id)
	_refresh()
