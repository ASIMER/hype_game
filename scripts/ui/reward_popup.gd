extends CanvasLayer
class_name RewardPopup
## Celebratory reward popup (Iteration 3). A persistent overlay (instanced once by main.gd)
## that self-shows on Events.quest_reward_granted, listing every granted reward — currency,
## items (with icons), XP, vendor-rep, skill points, giver standing, and quest-exclusive
## cosmetics — with a "CONTRACT COMPLETE" / "QUESTLINE COMPLETE" header. Built in code per the
## project's glass UI conventions (GlassBackdrop + glass panel + pop_in). Close on click/Esc.

const COL_AMBER := UIStyle.AMBER
const COL_TEAL  := UIStyle.TEAL
const COL_GREEN := UIStyle.GREEN
const COL_WHITE := UIStyle.WHITE
const COL_DIM   := UIStyle.DIM

var _root: Control = null
var _holder: CenterContainer = null


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)
	var bg := GlassBackdrop.new()
	_root.add_child(bg)
	_root.move_child(bg, 0)
	var catch := Button.new()
	catch.flat = true
	catch.set_anchors_preset(Control.PRESET_FULL_RECT)
	catch.focus_mode = Control.FOCUS_NONE
	catch.pressed.connect(_close)
	_root.add_child(catch)
	_holder = CenterContainer.new()
	_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_holder)
	Events.quest_reward_granted.connect(_on_reward)


func _unhandled_input(event: InputEvent) -> void:
	if _root.visible and event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()


func _close() -> void:
	_root.visible = false
	for c in _holder.get_children():
		c.queue_free()


func _on_reward(_quest_id: String, rewards: Dictionary) -> void:
	for c in _holder.get_children():
		c.queue_free()

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(440, 0)
	var sb := UIStyle.glass_panel(0.97)
	sb.border_width_top = 3
	sb.border_color = COL_AMBER
	panel.add_theme_stylebox_override("panel", sb)
	_holder.add_child(panel)

	var margin := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 24)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(col)

	# Header.
	var ql_done: bool = bool(rewards.get("questline_complete", false))
	var hdr := Label.new()
	if ql_done:
		hdr.text = tr("QUESTLINE COMPLETE")
	else:
		hdr.text = tr("CONTRACT COMPLETE")
	UIStyle.make_header(hdr, COL_GREEN if ql_done else COL_AMBER, 24, 3)
	col.add_child(hdr)
	if ql_done and String(rewards.get("line_title", "")) != "":
		col.add_child(_line(tr(String(rewards.get("line_title", ""))), COL_TEAL, 15))

	col.add_child(_sep())
	col.add_child(UIStyle.micro_header(tr("REWARDS"), COL_DIM, 12))

	# Reward rows.
	var currency: int = int(rewards.get("currency", 0))
	if currency > 0:
		col.add_child(_row(null, tr("+%d CR") % currency, COL_AMBER))
	for it_var in (rewards.get("items", []) as Array):
		var it: Dictionary = it_var
		var iid: String = String(it.get("id", ""))
		var idata: ItemData = ItemCatalog.get_item(iid)
		var nm: String = tr(idata.display_name) if idata != null else iid
		col.add_child(_row(AssetRegistry.get_icon(iid), "%s  x%d" % [nm, int(it.get("count", 1))], COL_WHITE))
	for bp_var in (rewards.get("blueprints", []) as Array):
		col.add_child(_row(null, tr("Blueprint: %s") % String(bp_var), COL_TEAL))
	var xp: int = int(rewards.get("xp", 0))
	if xp > 0:
		col.add_child(_row(null, tr("+%d XP") % xp, COL_TEAL))
	var rep: int = int(rewards.get("rep", 0))
	if rep > 0:
		col.add_child(_row(null, tr("+%d Reputation") % rep, COL_TEAL))
	var sp: int = int(rewards.get("skill_points", 0))
	if sp > 0:
		col.add_child(_row(null, tr("+%d Skill Point") % sp, COL_GREEN))
	var giver: String = String(rewards.get("giver", ""))
	var grep: int = int(rewards.get("giver_rep", 0))
	if giver != "" and grep > 0:
		col.add_child(_row(null, tr("+%d standing · %s") % [grep, giver], COL_TEAL))
	for cos_var in (rewards.get("cosmetics", []) as Array):
		var cid: String = String(cos_var)
		col.add_child(_cosmetic_row(cid))

	# Dismiss button.
	col.add_child(_sep())
	var btn_row := HBoxContainer.new()
	col.add_child(btn_row)
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(sp2)
	var ok := Button.new()
	ok.text = tr("NICE")
	ok.focus_mode = Control.FOCUS_NONE
	ok.custom_minimum_size = Vector2(120, 36)
	ok.add_theme_color_override("font_color", COL_GREEN)
	ok.pressed.connect(_close)
	UIStyle.hover_lift(ok)
	btn_row.add_child(ok)

	_root.visible = true
	UIStyle.pop_in(panel, UIStyle.Dir.DOWN, 18.0, 0.18)


# ── helpers ──────────────────────────────────────────────────────────────────
func _row(icon: Texture2D, text: String, col: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	if icon != null:
		var tr_icon := TextureRect.new()
		tr_icon.texture = icon
		tr_icon.custom_minimum_size = Vector2(28, 28)
		tr_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(tr_icon)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	return row

## Exclusive-cosmetic row: a colour swatch (paint primary) + "★ Cosmetic unlocked: <name>".
func _cosmetic_row(cid: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(24, 24)
	swatch.color = COL_AMBER
	if ProceduralPlayer.PAINTS.has(cid):
		swatch.color = (ProceduralPlayer.PAINTS[cid] as Dictionary).get("primary", COL_AMBER)
	row.add_child(swatch)
	var lbl := Label.new()
	lbl.text = "★ " + (tr("Cosmetic unlocked: %s") % ProceduralPlayer.name_of(cid))
	lbl.add_theme_color_override("font_color", COL_AMBER)
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	return row

func _line(text: String, col: Color, size: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", size)
	return lbl

func _sep() -> HSeparator:
	return HSeparator.new()
