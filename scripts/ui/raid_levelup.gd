extends Control
## In-raid levelup loop (the Vampire-Survivors beat): the LOCAL player's kills fill an XP bar just
## above the skill hotbar, and every fill opens a 3-card offer of TIMED power buffs picked with
## F1/F2/F3. The raid NEVER pauses for it — the mouse is captured in-raid, so the cards carry ZERO
## mouse interaction and selection is keyboard-only (_unhandled_key_input); an offer left alone for
## PICK_TIME auto-takes card 1 so it can't linger through a firefight. A levelup earned while an
## offer is already up is queued and shown right after the pick.
##
## Local-only, no netcode: it counts Events.player_kill (already the per-peer, server-attributed
## kill channel) and applies the pick straight to the local-authority player via `apply_power` —
## the same path the power-cache reveal uses, so it is correct in co-op by construction.
## Render-only + headless-safe: with no display it still counts kills/levels but builds nothing.

# Level N (starting at 1) needs KILLS_BASE + KILLS_PER_LEVEL * N kills — a gentle ramp so the
# first offer lands inside the opening wave and later ones pace with the wave sizes.
const KILLS_BASE := 4
const KILLS_PER_LEVEL := 2
const PICK_TIME := 12.0  # s before the offer auto-takes card 1
const OFFER_COUNT := 3
const FALLBACK_POWER := "berserk"  # pads the offer when the unlocked pool is smaller than 3
const KEY_LABELS := ["F1", "F2", "F3"]

# Bottom-centre lane, in offsets from the bottom edge. The XP bar sits ABOVE the skill hotbar
# (-72..-12) AND above the EXTRACTING block (which grows up to ≈-127) — hence -164, not -132.
const BAR_W := 360.0
const BAR_H := 8.0
const BAR_TOP := -164.0
const BAR_BOTTOM := -140.0
const CARD_W := 208.0
const CARD_H := 96.0
const CARD_GAP := 14.0
const CARD_BOTTOM := -176.0  # cards stack just above the bar

var _headless := false
var _level := 1
var _kills := 0  # kills banked toward the NEXT level
var _pending := 0  # levelups earned while an offer was already open
var _offer_open := false
var _offer_ids: Array = []
var _pick_left := 0.0
var _bar_box: Control = null
var _bar: ProgressBar = null
var _level_label: Label = null
var _offer_box: Control = null
var _timer_label: Label = null
var _cards: Array = []  # per-card {panel, key, name, icon, desc}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# NOTE: must be the AND_OFFSETS variant — the plain preset left this root at
	# 0×0 under the HUD CanvasLayer, which collapsed every bottom-anchored child
	# to the screen's top-left (the credits-screen lesson, live-debugged).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_headless = DisplayServer.get_name() == "headless"
	Events.player_kill.connect(_on_player_kill)
	Events.match_started.connect(_on_match_started)
	Events.match_won.connect(_hide_all)
	Events.match_lost.connect(_hide_all)
	if _headless:
		return
	_build_bar()
	_build_offer()
	_refresh_bar()
	_hide_all()


func _process(delta: float) -> void:
	if _headless:
		return
	# The widget belongs to a live raid only (results screen / hub must never show it).
	if GameState.phase != GameState.Phase.IN_MATCH:
		if _bar_box.visible or _offer_box.visible:
			_hide_all()
		return
	if not _offer_open:
		return
	_pick_left -= delta
	if _pick_left <= 0.0:
		_choose(0)
		return
	_timer_label.text = "%ds" % int(ceil(_pick_left))


## Keyboard-only selection: the raid captures the mouse, so the cards are never clickable.
func _unhandled_key_input(event: InputEvent) -> void:
	if _headless or not _offer_open:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var idx := -1
	match key.keycode:
		KEY_F1:
			idx = 0
		KEY_F2:
			idx = 1
		KEY_F3:
			idx = 2
	if idx < 0:
		return
	_choose(idx)
	get_viewport().set_input_as_handled()


# ── XP / levels ─────────────────────────────────────────────────────────────


func _on_player_kill(_enemy_id: String) -> void:
	if GameState.phase != GameState.Phase.IN_MATCH:
		return
	_kills += 1
	var need := _kills_needed()
	if _kills >= need:
		_kills -= need  # remainder carries into the next level
		_level += 1
		_pending += 1
	_refresh_bar()
	if _pending > 0 and not _offer_open and not _headless:
		_open_offer()


func _kills_needed() -> int:
	return KILLS_BASE + KILLS_PER_LEVEL * _level


## Wipe the run-local progress — powers and levels are per-raid, like harvested skills.
func _on_match_started() -> void:
	_level = 1
	_kills = 0
	_pending = 0
	_offer_ids.clear()
	if _headless:
		return
	_refresh_bar()
	_hide_all()


func _refresh_bar() -> void:
	if _headless or _bar == null:
		return
	_bar.max_value = float(maxi(1, _kills_needed()))
	_bar.value = float(_kills)
	_level_label.text = tr("LVL %d") % _level
	# Adaptive HUD (the hotbar rule): an empty bar at raid start is dead weight — it
	# appears with the first kill.
	var live: bool = GameState.phase == GameState.Phase.IN_MATCH
	_bar_box.visible = live and (_kills > 0 or _level > 1)


func _hide_all() -> void:
	_offer_open = false
	if _bar_box != null:
		_bar_box.visible = false
	if _offer_box != null:
		_offer_box.visible = false


# ── Offer ───────────────────────────────────────────────────────────────────


func _open_offer() -> void:
	_pending -= 1
	_offer_ids = _roll_offer()
	_offer_open = true
	_pick_left = PICK_TIME
	_paint_cards()
	_timer_label.text = "%ds" % int(ceil(_pick_left))
	_offer_box.visible = true
	UIStyle.pop_in(_offer_box, UIStyle.Dir.UP, 16.0, 0.18)
	AudioManager.ui_panel(true)


## Three UNIQUE power ids from this peer's unlocked pool (padded with the free starter power
## when the pool is smaller than the offer).
func _roll_offer() -> Array:
	var pool: Array = []
	if MetaProgression.has_method("available_powers"):
		pool = (MetaProgression.available_powers() as Array).duplicate()
	pool.shuffle()
	var out: Array = []
	for id in pool:
		var sid := String(id)
		if not out.has(sid):
			out.append(sid)
		if out.size() >= OFFER_COUNT:
			break
	while out.size() < OFFER_COUNT:
		out.append(FALLBACK_POWER)
	return out


func _paint_cards() -> void:
	for i in _cards.size():
		var card: Dictionary = _cards[i]
		var pid: String = FALLBACK_POWER
		if i < _offer_ids.size():
			pid = String(_offer_ids[i])
		var def: Dictionary = Settings.POWERS.get(pid, {})
		var accent: Color = def.get("color", UIStyle.TEAL)
		var panel: Panel = card["panel"]
		panel.add_theme_stylebox_override("panel", _card_style(accent))
		var key: Label = card["key"]
		key.add_theme_stylebox_override("normal", UIStyle.chip(accent, 0.22))
		key.add_theme_color_override("font_color", accent)
		var title: Label = card["name"]
		title.text = _pretty(pid)
		title.add_theme_color_override("font_color", accent.lerp(UIStyle.WHITE, 0.45))
		var desc: Label = card["desc"]
		desc.text = String(def.get("desc", ""))
		var icon: TextureRect = card["icon"]
		icon.texture = Settings.power_icon(pid)
		icon.modulate = accent
		icon.visible = icon.texture != null


## Take card `idx` (or card 1 on timeout): apply the buff on the local player, then close —
## a levelup banked while the offer was up opens immediately after.
func _choose(idx: int) -> void:
	if not _offer_open:
		return
	_offer_open = false
	var pid: String = FALLBACK_POWER
	if idx >= 0 and idx < _offer_ids.size():
		pid = String(_offer_ids[idx])
	if _offer_box != null:
		_offer_box.visible = false
	var player := _local_player()
	if player != null and player.has_method("apply_power"):
		player.apply_power(pid)
	AudioManager.ui_panel(false)
	Events.notify.emit(tr("POWER UP: %s") % tr(_pretty(pid)), 1)
	if _pending > 0:
		_open_offer()


func _local_player() -> Node:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p.has_method("is_multiplayer_authority") and p.is_multiplayer_authority():
			return p
	return null


## Display name for a power: the catalog name, else the id read as words ("rapid_fire" → "Rapid
## Fire") so an id with no catalog entry still shows something human.
func _pretty(power_id: String) -> String:
	var def: Dictionary = Settings.POWERS.get(power_id, {})
	var pretty: String = String(def.get("name", ""))
	if pretty != "":
		return pretty
	return power_id.capitalize()


# ── Build ───────────────────────────────────────────────────────────────────


func _build_bar() -> void:
	_bar_box = _bottom_box(BAR_W, BAR_TOP, BAR_BOTTOM)
	add_child(_bar_box)
	_level_label = UIStyle.micro_header("", UIStyle.TEAL, 13)
	_level_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # already tr()'d
	_level_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_level_label.offset_bottom = 16.0
	_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_level_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_level_label.add_theme_constant_override("outline_size", 3)
	_level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_box.add_child(_level_label)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_bar.offset_top = -BAR_H
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_theme_stylebox_override("background", _bar_bg())
	_bar.add_theme_stylebox_override("fill", UIStyle.glow_fill(UIStyle.TEAL))
	_bar_box.add_child(_bar)


func _build_offer() -> void:
	var total := float(OFFER_COUNT) * CARD_W + float(OFFER_COUNT - 1) * CARD_GAP
	_offer_box = _bottom_box(total, CARD_BOTTOM - CARD_H, CARD_BOTTOM)
	add_child(_offer_box)
	# Header strip sits just ABOVE the card row (negative offsets — Controls don't clip children).
	var head := UIStyle.micro_header("LEVEL UP — PICK ONE", UIStyle.AMBER, 15)
	head.set_anchors_preset(Control.PRESET_TOP_WIDE)
	head.offset_top = -26.0
	head.offset_bottom = -4.0
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	head.add_theme_constant_override("outline_size", 3)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offer_box.add_child(head)
	_timer_label = UIStyle.caption("", UIStyle.DIM)
	_timer_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_timer_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_timer_label.offset_top = -26.0
	_timer_label.offset_bottom = -4.0
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_timer_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_timer_label.add_theme_constant_override("outline_size", 3)
	_timer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offer_box.add_child(_timer_label)
	for i in OFFER_COUNT:
		_cards.append(_make_card(i))


## A fixed-size box pinned to the bottom centre (the hotbar pattern — robust at any aspect).
func _bottom_box(width: float, top: float, bottom: float) -> Control:
	var box := Control.new()
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = -width / 2.0
	box.offset_right = width / 2.0
	box.offset_top = top
	box.offset_bottom = bottom
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return box


func _make_card(i: int) -> Dictionary:
	var x := float(i) * (CARD_W + CARD_GAP)
	var panel := Panel.new()
	panel.offset_left = x
	panel.offset_top = 0.0
	panel.offset_right = x + CARD_W
	panel.offset_bottom = CARD_H
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _card_style(UIStyle.TEAL))
	_offer_box.add_child(panel)
	var key := Label.new()
	key.text = KEY_LABELS[i] if i < KEY_LABELS.size() else ""
	key.add_theme_font_override("font", UIStyle.header_font(2))
	key.add_theme_font_size_override("font_size", 14)
	key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	key.set_anchors_preset(Control.PRESET_TOP_LEFT)
	key.offset_left = 10.0
	key.offset_top = 8.0
	key.offset_right = 52.0
	key.offset_bottom = 32.0
	key.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(key)
	var title := Label.new()
	UIStyle.make_header(title, UIStyle.WHITE, 17, 1)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_left = 60.0
	title.offset_top = 7.0
	title.offset_right = -10.0
	title.offset_bottom = 33.0
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(title)
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.set_anchors_preset(Control.PRESET_TOP_LEFT)
	icon.offset_left = 12.0
	icon.offset_top = 40.0
	icon.offset_right = 52.0
	icon.offset_bottom = 80.0
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)
	var desc := UIStyle.caption("", UIStyle.TEXT)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.set_anchors_preset(Control.PRESET_FULL_RECT)
	desc.offset_left = 60.0
	desc.offset_top = 38.0
	desc.offset_right = -10.0
	desc.offset_bottom = -8.0
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(desc)
	return {"panel": panel, "key": key, "name": title, "icon": icon, "desc": desc}


## The shared glass card, re-bordered in the power's signature colour (the accent language the
## hotbar slots use) so the three offers read as three different things at a glance.
func _card_style(accent: Color) -> StyleBoxFlat:
	var sb := UIStyle.glass_panel(0.90)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.85)
	sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.22)
	sb.shadow_size = 7
	return sb


## Slim XP-bar trough. UIStyle.glass_panel can't serve here: its content margins (12 px) would
## swallow an 8 px fill — so this is the palette applied to a margin-less box.
func _bar_bg() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UIStyle.GLASS_BG.r, UIStyle.GLASS_BG.g, UIStyle.GLASS_BG.b, 0.75)
	sb.set_border_width_all(1)
	sb.border_color = UIStyle.BORDER_LT
	sb.set_corner_radius_all(3)
	return sb
