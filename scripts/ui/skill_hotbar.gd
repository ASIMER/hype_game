extends Control
## Bottom-center skill hotbar (Mutant Harvest): up to 5 slots, each showing the skill's 2D icon
## (tinted its signature colour on a dark backing so it reads), the hotkey digit, the level, and a
## draining cooldown cover with the remaining SECONDS counting down on top. Fills as the local
## player harvests body-part skills. Reads the local player's replicated `skills` {skill_id: level}
## + the Skills component's slot_order()/cooldown_frac()/cooldown_remaining(). Render-only.
## Self-positions as a fixed bottom-centre box (the minimap pattern — a FULL_RECT wrapper under a
## CanvasLayer collapses to zero size); slots are children at fixed local offsets.

const KEYS := ["1", "2", "3", "4", "5"]
const SLOT := 60.0
const GAP := 8.0
const _ICON_DIR := "res://assets/ui/icons/skills/%s.svg"

var _player: Node = null
var _slots: Array = []  # per-slot {panel,iconbg,icon,cd,key,lvl,cdtext,skill_id}
var _passive: Label = null  # live passive/set bonus readout above the slots


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := float(Settings.SKILL_MAX_SLOTS)
	var w := n * SLOT + (n - 1.0) * GAP
	# Pin a fixed-size box to the bottom-centre via anchors+offsets (robust at any resolution).
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -w / 2.0
	offset_right = w / 2.0
	offset_top = -SLOT - 12.0
	offset_bottom = -12.0
	for i in Settings.SKILL_MAX_SLOTS:
		_slots.append(_make_slot(i))
	# Passive/set readout — sits just above the slot row so the build's bonuses are VISIBLE.
	_passive = Label.new()
	_passive.add_theme_font_size_override("font_size", 13)
	_passive.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
	_passive.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_passive.add_theme_constant_override("outline_size", 3)
	_passive.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_passive.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_passive.offset_top = -20.0
	_passive.offset_bottom = -2.0
	_passive.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_passive.visible = false
	add_child(_passive)
	Events.local_player_spawned.connect(_on_player)
	Events.skill_changed.connect(_rebuild)
	_rebuild()


func _on_player(p: Node) -> void:
	_player = p
	_rebuild()


func _process(_delta: float) -> void:
	if not _resolve_player():
		return
	var sk: Node = _player.get_node_or_null("Skills")
	if sk == null or not sk.has_method("cooldown_frac"):
		return
	for s in _slots:
		var sid: String = String(s["skill_id"])
		if sid == "":
			s["cd"].visible = false
			s["cdtext"].visible = false
			continue
		var f: float = sk.cooldown_frac(sid)
		s["cd"].visible = f > 0.0
		s["cd"].offset_bottom = SLOT * f  # cover the top f fraction (drains to 0 when ready)
		var rem: float = 0.0
		if sk.has_method("cooldown_remaining"):
			rem = float(sk.cooldown_remaining(sid))
		if rem > 0.0:
			s["cdtext"].visible = true
			s["cdtext"].text = "%d" % int(ceil(rem))  # whole seconds left
		else:
			s["cdtext"].visible = false
	_update_passive(sk)


## Show the live limb-passive / set-bonus totals above the slots (hidden when zero).
func _update_passive(sk: Node) -> void:
	if _passive == null or not sk.has_method("passive_totals"):
		return
	var t: Dictionary = sk.passive_totals()
	var dmg: int = int(round(float(t.get("damage", 0.0)) * 100.0))
	var tough: int = int(round(float(t.get("toughness", 0.0)) * 100.0))
	if dmg <= 0 and tough <= 0:
		_passive.visible = false
		return
	var parts: Array = []
	if dmg > 0:
		parts.append("+%d%% DMG" % dmg)
	if tough > 0:
		parts.append("+%d%% TGH" % tough)
	_passive.text = "  ".join(parts)
	_passive.visible = true


## Find/refresh the local-authority player (the signal may have fired before _ready).
func _resolve_player() -> bool:
	if _player != null and is_instance_valid(_player):
		return true
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p.has_method("is_multiplayer_authority") and p.is_multiplayer_authority():
			_player = p
			return true
	return false


func _rebuild(_a = null, _b = null) -> void:
	var order: Array = []
	var skills: Dictionary = {}
	if _resolve_player():
		skills = _player.get("skills") if "skills" in _player else {}
		var sk: Node = _player.get_node_or_null("Skills")
		if sk != null and sk.has_method("slot_order"):
			order = sk.slot_order()
	for i in _slots.size():
		var s: Dictionary = _slots[i]
		if i < order.size():
			var sid: String = String(order[i])
			var col: Color = Settings.skill_def(sid)["color"]
			s["skill_id"] = sid
			s["icon"].texture = _load_icon(sid)
			s["icon"].modulate = col
			s["icon"].visible = true
			s["lvl"].text = "%d" % int(skills.get(sid, 1))
			s["panel"].add_theme_stylebox_override("panel", _slot_style(col, true))
			s["iconbg"].add_theme_stylebox_override("panel", _icon_bg_style(col))
		else:
			s["skill_id"] = ""
			s["icon"].texture = null
			s["icon"].visible = false
			s["lvl"].text = ""
			s["cd"].visible = false
			s["cdtext"].visible = false
			s["panel"].add_theme_stylebox_override("panel", _slot_style(UIStyle.DIM, false))
			s["iconbg"].add_theme_stylebox_override("panel", _icon_bg_style(UIStyle.DIM))


func _load_icon(skill_id: String) -> Texture2D:
	var path: String = _ICON_DIR % skill_id
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _slot_style(col: Color, filled: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.82 if filled else 0.45)
	sb.set_border_width_all(2)
	sb.border_color = Color(col.r, col.g, col.b, 1.0 if filled else 0.45)
	sb.set_corner_radius_all(5)
	return sb


## Dark rounded inner backing (faintly tinted) so the tinted-white icon silhouette pops — without
## it the pale icon on the translucent panel read as a vague "white blob".
func _icon_bg_style(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02 + col.r * 0.04, 0.03 + col.g * 0.04, 0.05 + col.b * 0.04, 0.94)
	sb.set_corner_radius_all(6)
	return sb


func _make_slot(i: int) -> Dictionary:
	var panel := Panel.new()
	# Fixed position within the hotbar box (top-left local origin).
	panel.offset_left = float(i) * (SLOT + GAP)
	panel.offset_top = 0.0
	panel.offset_right = float(i) * (SLOT + GAP) + SLOT
	panel.offset_bottom = SLOT
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _slot_style(UIStyle.DIM, false))
	add_child(panel)
	var iconbg := Panel.new()
	iconbg.set_anchors_preset(Control.PRESET_FULL_RECT)
	iconbg.offset_left = 4.0
	iconbg.offset_top = 4.0
	iconbg.offset_right = -4.0
	iconbg.offset_bottom = -4.0
	iconbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	iconbg.add_theme_stylebox_override("panel", _icon_bg_style(UIStyle.DIM))
	panel.add_child(iconbg)
	var icon := TextureRect.new()
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 7.0
	icon.offset_top = 5.0
	icon.offset_right = -7.0
	icon.offset_bottom = -13.0
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)
	var cd := ColorRect.new()
	cd.color = Color(0.0, 0.0, 0.0, 0.55)
	cd.set_anchors_preset(Control.PRESET_TOP_WIDE)
	cd.offset_bottom = 0.0
	cd.visible = false
	cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(cd)
	var key := Label.new()
	key.text = KEYS[i] if i < KEYS.size() else ""
	key.add_theme_font_size_override("font_size", 14)
	key.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	key.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	key.add_theme_constant_override("outline_size", 3)
	key.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	key.offset_left = -18.0
	key.offset_top = -20.0
	key.offset_right = -3.0
	key.offset_bottom = -2.0
	key.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(key)
	var lvl := Label.new()
	lvl.add_theme_font_size_override("font_size", 12)
	lvl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
	lvl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lvl.add_theme_constant_override("outline_size", 3)
	lvl.set_anchors_preset(Control.PRESET_TOP_LEFT)
	lvl.offset_left = 3.0
	lvl.offset_top = 1.0
	lvl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lvl)
	# Remaining-seconds countdown, centred ON TOP of the drain cover.
	var cdtext := Label.new()
	cdtext.add_theme_font_size_override("font_size", 22)
	cdtext.add_theme_color_override("font_color", Color(1, 1, 1, 0.96))
	cdtext.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	cdtext.add_theme_constant_override("outline_size", 4)
	cdtext.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cdtext.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cdtext.set_anchors_preset(Control.PRESET_FULL_RECT)
	cdtext.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cdtext.visible = false
	panel.add_child(cdtext)
	return {
		"panel": panel,
		"iconbg": iconbg,
		"icon": icon,
		"cd": cd,
		"key": key,
		"lvl": lvl,
		"cdtext": cdtext,
		"skill_id": "",
	}
