extends Control
## ProgressionTab — the 7th Hub tab (TAB_PROGRESSION = 6).
## Shows Raider Level / XP, the skill tree, vendor reputation, and per-weapon mastery.
## All child nodes are built procedurally in _ready (no sub-scene required).
## Refreshed automatically via Events signals.

# ── Theme colours (match hub.gd / shop_tab.gd) ───────────────────────────────
const COL_AMBER := Color(0.91, 0.64, 0.24, 1.0)
const COL_TEAL  := Color(0.247, 0.71, 0.79, 1.0)
const COL_DIM   := Color(0.45, 0.50, 0.55, 1.0)
const COL_WHITE := Color(0.88, 0.90, 0.92, 1.0)
const COL_GREEN := Color(0.36, 0.78, 0.42, 1.0)
const COL_RED   := Color(0.85, 0.30, 0.25, 1.0)

# ── Node refs (assigned in _build_layout) ─────────────────────────────────────
var _level_label: Label           = null   # "RAIDER LEVEL 7"
var _xp_bar: ProgressBar          = null   # XP into current level / need
var _xp_label: Label              = null   # "1240 / 3500 XP  (Total: 14820)"
var _skill_points_label: Label    = null   # "Skill Points: 2"
var _milestone_label: Label       = null   # "Next milestone: L5 — +25 Stash Capacity"
var _skill_rows: VBoxContainer    = null   # one row per Settings.SKILLS key
var _skill_buy_btns: Dictionary   = {}     # key -> Button
var _skill_pip_labels: Dictionary = {}     # key -> Label showing "3 / 5"
var _power_buy_btns: Dictionary   = {}     # power id -> Button (unlock for skill points)
var _power_status_lbls: Dictionary = {}    # power id -> Label (FREE / OWNED / cost)
var _rep_tier_label: Label        = null   # "TIER 2 · 10% discount"
var _rep_bar: ProgressBar         = null
var _rep_label: Label             = null   # "450 / 800 rep to Tier 3"
var _rep_reward_label: Label      = null   # next-tier reward hint
var _mastery_rows: VBoxContainer  = null   # one row per known weapon


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	_refresh()

	# Connect Events (reconnect-safe).
	if not Events.xp_gained.is_connected(_on_xp_gained):
		Events.xp_gained.connect(_on_xp_gained)
	if not Events.raider_level_up.is_connected(_on_raider_level_up):
		Events.raider_level_up.connect(_on_raider_level_up)
	if not Events.reputation_changed.is_connected(_on_reputation_changed):
		Events.reputation_changed.connect(_on_reputation_changed)
	if not Events.weapon_mastery_changed.is_connected(_on_weapon_mastery_changed):
		Events.weapon_mastery_changed.connect(_on_weapon_mastery_changed)
	if not Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.connect(_on_currency_changed)


func _exit_tree() -> void:
	if Events.xp_gained.is_connected(_on_xp_gained):
		Events.xp_gained.disconnect(_on_xp_gained)
	if Events.raider_level_up.is_connected(_on_raider_level_up):
		Events.raider_level_up.disconnect(_on_raider_level_up)
	if Events.reputation_changed.is_connected(_on_reputation_changed):
		Events.reputation_changed.disconnect(_on_reputation_changed)
	if Events.weapon_mastery_changed.is_connected(_on_weapon_mastery_changed):
		Events.weapon_mastery_changed.disconnect(_on_weapon_mastery_changed)
	if Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.disconnect(_on_currency_changed)


# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_xp_gained(_amount: int, _source: String) -> void:
	_refresh_level()

func _on_raider_level_up(_new_level: int, _sp: int) -> void:
	_refresh_level()
	_refresh_skills()

func _on_reputation_changed(_rep: int, _tier: int) -> void:
	_refresh_rep()

func _on_weapon_mastery_changed(_weapon_id: String, _level: int) -> void:
	_rebuild_mastery_rows()

func _on_currency_changed(_amount: int) -> void:
	_refresh_skills()


# ── Layout construction ───────────────────────────────────────────────────────

func _build_layout() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left",   24)
	margin.add_theme_constant_override("margin_top",    20)
	margin.add_theme_constant_override("margin_right",  24)
	margin.add_theme_constant_override("margin_bottom", 24)
	scroll.add_child(margin)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	margin.add_child(body)

	# ── Title ─────────────────────────────────────────────────────────────────
	var title_lbl := Label.new()
	title_lbl.text = "RAIDER"
	UIStyle.make_header(title_lbl, UIStyle.AMBER, 42, 3)
	body.add_child(title_lbl)

	# ── Raider Level section ──────────────────────────────────────────────────
	body.add_child(_make_section_header("RAIDER LEVEL"))
	var lvl_panel := _make_panel()
	body.add_child(lvl_panel)
	var lvl_vbox := VBoxContainer.new()
	lvl_vbox.add_theme_constant_override("separation", 6)
	lvl_panel.add_child(lvl_vbox)

	_level_label = Label.new()
	_level_label.add_theme_font_size_override("font_size", 22)
	_level_label.add_theme_color_override("font_color", COL_AMBER)
	lvl_vbox.add_child(_level_label)

	_xp_bar = ProgressBar.new()
	_xp_bar.custom_minimum_size = Vector2(0, 14)
	_xp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_xp_bar.show_percentage = false
	_xp_bar.theme_type_variation = "FillAmber"
	lvl_vbox.add_child(_xp_bar)

	_xp_label = Label.new()
	_xp_label.add_theme_font_size_override("font_size", 13)
	_xp_label.add_theme_color_override("font_color", COL_DIM)
	lvl_vbox.add_child(_xp_label)

	_skill_points_label = Label.new()
	_skill_points_label.add_theme_font_size_override("font_size", 15)
	_skill_points_label.add_theme_color_override("font_color", COL_TEAL)
	lvl_vbox.add_child(_skill_points_label)

	_milestone_label = Label.new()
	_milestone_label.add_theme_font_size_override("font_size", 13)
	_milestone_label.add_theme_color_override("font_color", COL_DIM)
	lvl_vbox.add_child(_milestone_label)

	# ── Skill tree section ────────────────────────────────────────────────────
	body.add_child(_make_section_header("SKILL TREE"))
	var skill_panel := _make_panel()
	body.add_child(skill_panel)
	_skill_rows = VBoxContainer.new()
	_skill_rows.add_theme_constant_override("separation", 10)
	_skill_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skill_panel.add_child(_skill_rows)
	_build_skill_rows()

	# ── Vendor reputation section ─────────────────────────────────────────────
	body.add_child(_make_section_header("VENDOR REPUTATION"))
	var rep_panel := _make_panel()
	body.add_child(rep_panel)
	var rep_vbox := VBoxContainer.new()
	rep_vbox.add_theme_constant_override("separation", 6)
	rep_panel.add_child(rep_vbox)

	_rep_tier_label = Label.new()
	_rep_tier_label.add_theme_font_size_override("font_size", 18)
	_rep_tier_label.add_theme_color_override("font_color", COL_AMBER)
	rep_vbox.add_child(_rep_tier_label)

	_rep_bar = ProgressBar.new()
	_rep_bar.custom_minimum_size = Vector2(0, 14)
	_rep_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rep_bar.show_percentage = false
	_rep_bar.theme_type_variation = "FillAmber"
	rep_vbox.add_child(_rep_bar)

	_rep_label = Label.new()
	_rep_label.add_theme_font_size_override("font_size", 13)
	_rep_label.add_theme_color_override("font_color", COL_DIM)
	rep_vbox.add_child(_rep_label)

	_rep_reward_label = Label.new()
	_rep_reward_label.add_theme_font_size_override("font_size", 13)
	_rep_reward_label.add_theme_color_override("font_color", COL_TEAL)
	_rep_reward_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rep_vbox.add_child(_rep_reward_label)

	# ── Weapon mastery section ────────────────────────────────────────────────
	body.add_child(_make_section_header("WEAPON MASTERY"))
	var mastery_panel := _make_panel()
	body.add_child(mastery_panel)
	_mastery_rows = VBoxContainer.new()
	_mastery_rows.add_theme_constant_override("separation", 10)
	_mastery_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mastery_panel.add_child(_mastery_rows)
	_rebuild_mastery_rows()


## Builds one row per Settings.SKILLS entry. Rows are static; only pip/button
## state updates on refresh (no rebuild needed).
func _build_skill_rows() -> void:
	_skill_buy_btns.clear()
	_skill_pip_labels.clear()
	for child in _skill_rows.get_children():
		child.queue_free()

	for key in Settings.SKILLS:
		var info: Dictionary = Settings.SKILLS[key]
		var row := HBoxContainer.new()
		row.name = "Skill_" + String(key)
		row.add_theme_constant_override("separation", 10)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_skill_rows.add_child(row)

		# Name + description (left, expands).
		var text_col := VBoxContainer.new()
		text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text_col)

		var name_lbl := Label.new()
		name_lbl.text = tr(String(info.get("name", key)))
		name_lbl.add_theme_color_override("font_color", COL_WHITE)
		name_lbl.add_theme_font_size_override("font_size", 15)
		text_col.add_child(name_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = tr(String(info.get("desc", "")))
		desc_lbl.add_theme_color_override("font_color", COL_DIM)
		desc_lbl.add_theme_font_size_override("font_size", 12)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text_col.add_child(desc_lbl)

		# Level pips label "x / max" (right-aligned).
		var pip_lbl := Label.new()
		pip_lbl.name = "Pips"
		pip_lbl.add_theme_color_override("font_color", COL_AMBER)
		pip_lbl.add_theme_font_size_override("font_size", 14)
		pip_lbl.custom_minimum_size = Vector2(52, 0)
		pip_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		pip_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(pip_lbl)
		_skill_pip_labels[key] = pip_lbl

		# BUY button.
		var buy_btn := Button.new()
		buy_btn.name = "BuyBtn"
		buy_btn.text = "BUY"
		buy_btn.custom_minimum_size = Vector2(68, 30)
		buy_btn.focus_mode = Control.FOCUS_NONE
		buy_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var k := String(key)  # capture for lambda
		buy_btn.pressed.connect(func() -> void: _on_buy_skill(k))
		UIStyle.hover_lift(buy_btn)
		row.add_child(buy_btn)
		_skill_buy_btns[key] = buy_btn

	_build_power_rows()


## Power-cache buffs you UNLOCK with skill points (free ones always roll; these add to the pool
## a map cache can grant). Appended under the skill rows so it shares the skill-point economy.
func _build_power_rows() -> void:
	_power_buy_btns.clear()
	_power_status_lbls.clear()

	var head := Label.new()
	head.text = tr("POWER CACHES (unlock to roll)")
	head.add_theme_color_override("font_color", COL_AMBER)
	head.add_theme_font_size_override("font_size", 13)
	_skill_rows.add_child(head)

	for pid in Settings.POWERS:
		var info: Dictionary = Settings.POWERS[pid]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_skill_rows.add_child(row)

		var text_col := VBoxContainer.new()
		text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text_col)
		var name_lbl := Label.new()
		name_lbl.text = tr(String(info.get("name", pid)))
		name_lbl.add_theme_color_override("font_color", info.get("color", COL_WHITE))
		name_lbl.add_theme_font_size_override("font_size", 14)
		text_col.add_child(name_lbl)
		var desc_lbl := Label.new()
		desc_lbl.text = tr(String(info.get("desc", "")))
		desc_lbl.add_theme_color_override("font_color", COL_DIM)
		desc_lbl.add_theme_font_size_override("font_size", 12)
		text_col.add_child(desc_lbl)

		var status := Label.new()
		status.custom_minimum_size = Vector2(56, 0)
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(status)
		_power_status_lbls[String(pid)] = status

		var btn := Button.new()
		btn.text = "UNLOCK"
		btn.custom_minimum_size = Vector2(78, 30)
		btn.focus_mode = Control.FOCUS_NONE
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var pk := String(pid)
		btn.pressed.connect(func() -> void: _on_unlock_power(pk))
		UIStyle.hover_lift(btn)
		row.add_child(btn)
		_power_buy_btns[String(pid)] = btn


func _on_unlock_power(pid: String) -> void:
	MetaProgression.unlock_power(pid)
	_refresh_level()
	_refresh_skills()


func _refresh_powers() -> void:
	for pid in _power_buy_btns:
		var info: Dictionary = Settings.POWERS.get(pid, {})
		var free: bool = bool(info.get("free", false))
		var owned: bool = MetaProgression.is_power_unlocked(String(pid))
		var cost: int = int(info.get("cost", 1))
		var status: Label = _power_status_lbls.get(pid)
		if status != null:
			if free:
				status.text = tr("FREE"); status.add_theme_color_override("font_color", COL_GREEN)
			elif owned:
				status.text = tr("OWNED"); status.add_theme_color_override("font_color", COL_GREEN)
			else:
				status.text = tr("%d SP") % cost; status.add_theme_color_override("font_color", COL_AMBER)
		var btn: Button = _power_buy_btns.get(pid)
		if btn != null:
			btn.visible = not free and not owned
			btn.disabled = MetaProgression.skill_points < cost


## Rebuilds mastery rows from the current loadout of known/unlocked weapons.
func _rebuild_mastery_rows() -> void:
	if _mastery_rows == null:
		return
	for child in _mastery_rows.get_children():
		child.queue_free()

	# Show mastery for all known weapons: FREE_WEAPONS + unlocked purchasable ones.
	var known_weapons: Array = MetaProgression.FREE_WEAPONS.duplicate()
	for wid in MetaProgression.unlocked:
		if wid not in known_weapons:
			known_weapons.append(wid)

	for wid in known_weapons:
		var w_id: String = String(wid)
		var lvl: int     = MetaProgression.weapon_mastery_level(w_id)
		var mxp: int     = MetaProgression.weapon_mastery_xp(w_id)
		var need: int    = MetaProgression.mastery_to_advance(lvl) if lvl < Settings.WEAPON_MASTERY_MAX else 0

		var row := HBoxContainer.new()
		row.name = "Mastery_" + w_id
		row.add_theme_constant_override("separation", 10)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mastery_rows.add_child(row)

		# Icon cell (40×40).
		var icon_cell: Panel = _icon_cell(w_id, 40)
		icon_cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(icon_cell)

		# Weapon name + mastery bar.
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 4)
		row.add_child(col)

		# Name row: "RIFLE  Lv 3 / 10"
		var name_row := HBoxContainer.new()
		name_row.add_theme_constant_override("separation", 8)
		col.add_child(name_row)

		var nm_lbl := Label.new()
		nm_lbl.text = tr(w_id.to_upper())
		nm_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm_lbl.add_theme_color_override("font_color", COL_WHITE)
		nm_lbl.add_theme_font_size_override("font_size", 14)
		name_row.add_child(nm_lbl)

		var lvl_lbl := Label.new()
		if lvl >= Settings.WEAPON_MASTERY_MAX:
			lvl_lbl.text = tr("MAX (%d)") % lvl
			lvl_lbl.add_theme_color_override("font_color", COL_GREEN)
		else:
			lvl_lbl.text = tr("Lv %d / %d") % [lvl, Settings.WEAPON_MASTERY_MAX]
			lvl_lbl.add_theme_color_override("font_color", COL_AMBER)
		lvl_lbl.add_theme_font_size_override("font_size", 13)
		name_row.add_child(lvl_lbl)

		# XP bar.
		var mbar := ProgressBar.new()
		mbar.custom_minimum_size = Vector2(0, 10)
		mbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mbar.show_percentage = false
		mbar.theme_type_variation = "FillAmber"
		if lvl >= Settings.WEAPON_MASTERY_MAX or need <= 0:
			mbar.max_value = 1.0
			mbar.value     = 1.0
		else:
			mbar.max_value = float(need)
			mbar.value     = float(mxp)
		col.add_child(mbar)

		# XP sub-label + the current "veteran" handling bonus from this level.
		var xp_lbl := Label.new()
		xp_lbl.add_theme_font_size_override("font_size", 11)
		xp_lbl.add_theme_color_override("font_color", COL_DIM)
		var bonus_txt := ""
		if lvl > 0:
			bonus_txt = "   ·   -%d%% recoil, -%d%% spread, -%d%% reload" % [
				int(round(Settings.WEAPON_MASTERY_RECOIL_PER * lvl * 100.0)),
				int(round(Settings.WEAPON_MASTERY_SPREAD_PER * lvl * 100.0)),
				int(round(Settings.WEAPON_MASTERY_RELOAD_PER * lvl * 100.0))]
		if lvl >= Settings.WEAPON_MASTERY_MAX:
			xp_lbl.text = tr("Mastery complete") + bonus_txt
		else:
			xp_lbl.text = (tr("%d / %d xp") % [mxp, need]) + bonus_txt
		col.add_child(xp_lbl)


# ── Refresh ───────────────────────────────────────────────────────────────────

func _refresh() -> void:
	_refresh_level()
	_refresh_skills()
	_refresh_rep()
	_rebuild_mastery_rows()


func _refresh_level() -> void:
	var prog: Dictionary = MetaProgression.level_progress()
	var lvl: int  = int(prog.get("level", 1))
	var into: int = int(prog.get("into", 0))
	var need: int = int(prog.get("need", 1))
	var total: int = int(prog.get("total", 0))

	if _level_label != null:
		_level_label.text = tr("RAIDER LEVEL %d") % lvl
	if _xp_bar != null:
		_xp_bar.max_value = float(maxi(1, need))
		_xp_bar.value     = float(into)
	if _xp_label != null:
		_xp_label.text = tr("%d / %d XP  (Total: %d)") % [into, need, total]
	if _skill_points_label != null:
		var sp: int = MetaProgression.skill_points
		if sp > 0:
			_skill_points_label.text = tr("Skill Points Available: %d") % sp
			_skill_points_label.visible = true
		else:
			_skill_points_label.text = ""
			_skill_points_label.visible = false
	if _milestone_label != null:
		var ms: Dictionary = MetaProgression.next_milestone()
		if ms.is_empty():
			_milestone_label.text = tr("All Raider milestones earned.")
		else:
			_milestone_label.text = tr("Next milestone — Level %d: %s") % [int(ms.get("level", 0)), tr(String(ms.get("label", "")))]


func _refresh_skills() -> void:
	for key in _skill_buy_btns:
		var lvl: int   = MetaProgression.skill_level(String(key))
		var max_l: int = MetaProgression.skill_max(String(key))
		var maxed: bool = (lvl >= max_l)

		var pip_lbl: Label = _skill_pip_labels.get(key)
		if pip_lbl != null:
			pip_lbl.text = tr("%d / %d") % [lvl, max_l]
			if maxed:
				pip_lbl.add_theme_color_override("font_color", COL_GREEN)
			else:
				pip_lbl.add_theme_color_override("font_color", COL_AMBER)

		var btn: Button = _skill_buy_btns.get(key)
		if btn != null:
			if maxed:
				btn.text     = tr("MAX")
				btn.disabled = true
			else:
				btn.text     = tr("BUY")
				btn.disabled = (MetaProgression.skill_points <= 0)
	_refresh_powers()


func _refresh_rep() -> void:
	var tier: int = MetaProgression.rep_tier()
	var prog: Dictionary = MetaProgression.rep_progress()
	var into: int = int(prog.get("into", 0))
	var need: int = int(prog.get("need", 0))
	var disc: float = MetaProgression.rep_discount()
	var disc_pct: int = int(round(disc * 100.0))

	if _rep_tier_label != null:
		if disc_pct > 0:
			_rep_tier_label.text = tr("TIER %d  ·  %d%% shop discount") % [tier, disc_pct]
		else:
			_rep_tier_label.text = tr("TIER %d  ·  No discount yet") % tier

	if _rep_bar != null:
		if need <= 0:
			# Max tier: fill bar.
			_rep_bar.max_value = 1.0
			_rep_bar.value     = 1.0
		else:
			_rep_bar.max_value = float(need)
			_rep_bar.value     = float(into)

	if _rep_label != null:
		if need <= 0:
			_rep_label.text = tr("Maximum tier reached!")
			_rep_label.add_theme_color_override("font_color", COL_GREEN)
		else:
			_rep_label.text = tr("%d / %d rep to Tier %d") % [into, need, tier + 1]
			_rep_label.add_theme_color_override("font_color", COL_DIM)

	if _rep_reward_label != null:
		var next_tier: int = tier + 1
		var reward: Dictionary = Settings.REP_TIER_REWARDS.get(next_tier, {})
		if reward.is_empty() or need <= 0:
			_rep_reward_label.text = ""
			_rep_reward_label.visible = false
		else:
			var parts: Array[String] = []
			var cur_rw: int = int(reward.get("currency", 0))
			if cur_rw > 0:
				parts.append(tr("CR %d") % cur_rw)
			var bp_rw: String = String(reward.get("blueprint", ""))
			if bp_rw != "":
				parts.append(tr("Blueprint: %s") % bp_rw)
			if parts.is_empty():
				_rep_reward_label.text = ""
				_rep_reward_label.visible = false
			else:
				_rep_reward_label.text = tr("Next tier reward: ") + ", ".join(parts)
				_rep_reward_label.visible = true


# ── Button handlers ───────────────────────────────────────────────────────────

func _on_buy_skill(key: String) -> void:
	MetaProgression.buy_skill(key)
	# Skills and level both refresh via Events.raider_level_up / currency_changed,
	# but buy_skill doesn't emit those — refresh manually.
	_refresh_level()
	_refresh_skills()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	return pc


func _make_section_header(title: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.TEAL))
	pc.add_child(UIStyle.micro_header(title, UIStyle.TEAL, 15))
	return pc


## Small icon cell for weapon mastery rows (cell_size × cell_size).
func _icon_cell(id: String, cell_size: int) -> Panel:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(cell_size, cell_size)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.92)
	sb.set_border_width_all(2)
	var item: ItemData = ItemCatalog.get_item(id)
	sb.border_color = item.rarity_color() if item != null else COL_TEAL
	sb.set_corner_radius_all(4)
	slot.add_theme_stylebox_override("panel", sb)
	var icon: Texture2D = AssetRegistry.get_icon(id)
	if icon != null:
		var tex := TextureRect.new()
		tex.texture = icon
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex.offset_left = 6;  tex.offset_top = 6
		tex.offset_right = -6; tex.offset_bottom = -6
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tex)
	else:
		var box := ColorRect.new()
		box.color = AssetRegistry.get_color(id)
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 8;  box.offset_top = 8
		box.offset_right = -8; box.offset_bottom = -8
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(box)
	return slot
