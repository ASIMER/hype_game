extends Control
## M5.1 RAID CONTRACTS — deploy-time «выбор 1 из 3»: a few seconds after the
## match starts, three rolled contract cards appear (F1/F2/F3, 15 s auto-skip —
## taking none is a legal choice). The picked contract lives for THIS raid only,
## shows a compact progress chip under the minimap column, and pays credits the
## moment it completes (meta currency — kept even if the raid is later lost).
##
## LOCAL-ONLY by design (like the levelup offer): each peer rolls and tracks its
## own contract, no netcode. Templates draw from live raid signals; the biome
## hunt classifies the KILLER's position via WorldBounds.biome_at. Headless-safe.

const OFFER_DELAY := 4.0  # s after match start before the cards pop
const PICK_TIME := 15.0
const CARD_W := 224.0
const CARD_H := 104.0
const CARD_GAP := 14.0
const CARD_BOTTOM := -300.0
const KEY_LABELS := ["F1", "F2", "F3"]

# Template ids; rolled params are filled in _roll_contracts().
const TEMPLATES := ["hunt", "wave", "biome_hunt", "hoarder"]

var _headless := false
var _offer_open := false
var _pick_left := 0.0
var _offer: Array = []  # 3 dicts {id,title,desc,target,reward,biome}
var _active: Dictionary = {}  # picked contract (+ "progress")
var _done := false
var _offer_box: Control = null
var _cards: Array = []
var _timer_label: Label = null
var _chip: PanelContainer = null
var _chip_label: Label = null
var _poll_t: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# AND_OFFSETS — the plain anchors preset leaves this root 0×0 under the HUD
	# CanvasLayer (the levelup-offer lesson; children would render offscreen).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_headless = DisplayServer.get_name() == "headless"
	Events.match_started.connect(_on_match_started)
	Events.match_won.connect(_close_all)
	Events.match_lost.connect(_close_all)
	Events.player_kill.connect(_on_player_kill)
	Events.wave_started.connect(_on_wave_started)


func _process(delta: float) -> void:
	if _headless:
		return
	if GameState.phase != GameState.Phase.IN_MATCH:
		if _offer_open or (_chip != null and _chip.visible):
			_close_all()
		return
	if _offer_open:
		_pick_left -= delta
		if _timer_label != null:
			_timer_label.text = "%ds" % int(ceil(_pick_left))
		if _pick_left <= 0.0:
			_dismiss_offer()
	# Hoarder needs a slow inventory poll; cheap for the others too.
	_poll_t -= delta
	if _poll_t <= 0.0:
		_poll_t = 1.0
		_poll_progress()


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
	_pick(idx)
	get_viewport().set_input_as_handled()


# ── Lifecycle ───────────────────────────────────────────────────────────────
func _on_match_started() -> void:
	_active = {}
	_done = false
	_close_all()
	if _headless:
		return
	var t := get_tree().create_timer(OFFER_DELAY)
	t.timeout.connect(_show_offer)


func _show_offer() -> void:
	if _headless or GameState.phase != GameState.Phase.IN_MATCH or _offer_open:
		return
	_offer = _roll_contracts()
	if _offer_box == null:
		_build_offer_box()
	for i in _cards.size():
		var card: Dictionary = _cards[i]
		var c: Dictionary = _offer[i] if i < _offer.size() else {}
		(card["name"] as Label).text = String(c.get("title", ""))
		(card["desc"] as Label).text = String(c.get("desc", ""))
		(card["reward"] as Label).text = tr("+%d CR") % int(c.get("reward", 0))
	_offer_open = true
	_pick_left = PICK_TIME
	_offer_box.visible = true
	UIStyle.pop_in(_offer_box, UIStyle.Dir.UP, 16.0, 0.18)
	AudioManager.ui_panel(true)
	Events.notify.emit(tr("RAID CONTRACT on offer — F1/F2/F3 (optional)"), 0)


func _pick(idx: int) -> void:
	if idx < 0 or idx >= _offer.size():
		return
	_active = (_offer[idx] as Dictionary).duplicate()
	_active["progress"] = 0
	_dismiss_offer()
	_ensure_chip()
	_refresh_chip()
	Events.notify.emit(tr("CONTRACT ACCEPTED: %s") % String(_active.get("title", "")), 1)


func _dismiss_offer() -> void:
	_offer_open = false
	if _offer_box != null:
		_offer_box.visible = false
	AudioManager.ui_panel(false)


func _close_all() -> void:
	_dismiss_offer()
	if _chip != null:
		_chip.visible = false


# ── Templates / rolling ─────────────────────────────────────────────────────
func _roll_contracts() -> Array:
	var pool: Array = TEMPLATES.duplicate()
	# M5.5 meta-content: progression UNLOCKS richer contracts — the pool grows
	# with raider level instead of staying static forever.
	if MetaProgression.raider_level >= 5:
		pool.append("marathon")
	pool.shuffle()
	var out: Array = []
	for tid in pool:
		if out.size() >= 3:
			break
		out.append(_make_contract(String(tid)))
	return out


func _make_contract(tid: String) -> Dictionary:
	match tid:
		"hunt":
			return {
				"id": "hunt",
				"title": tr("MACHINE CULL"),
				"desc": tr("Destroy 8 machines this raid"),
				"target": 8,
				"reward": 150,
			}
		"wave":
			return {
				"id": "wave",
				"title": tr("HOLD THE LINE"),
				"desc": tr("Survive to wave 3"),
				"target": 3,
				"reward": 120,
			}
		"biome_hunt":
			var biomes: Array[String] = ["snow", "desert", "rain"]
			var b: String = biomes[randi() % biomes.size()]
			return {
				"id": "biome_hunt",
				"title": tr("FAR PATROL"),
				"desc": tr("Destroy 5 machines in the %s region") % tr(b.to_upper()),
				"target": 5,
				"reward": 180,
				"biome": b,
			}
		"marathon":
			return {
				"id": "wave",
				"title": tr("MARATHON"),
				"desc": tr("Survive to wave 4"),
				"target": 4,
				"reward": 260,
			}
		_:
			return {
				"id": "hoarder",
				"title": tr("DEEP POCKETS"),
				"desc": tr("Carry 6 items at once"),
				"target": 6,
				"reward": 100,
			}


# ── Tracking ────────────────────────────────────────────────────────────────
func _on_player_kill(_enemy_id: String) -> void:
	if _done or _active.is_empty():
		return
	var cid: String = String(_active.get("id", ""))
	if cid == "hunt":
		_bump(1)
	elif cid == "biome_hunt":
		var pl := _local_player()
		if pl is Node3D:
			var p: Vector3 = (pl as Node3D).global_position
			if WorldBounds.biome_at(p.x, p.z) == String(_active.get("biome", "")):
				_bump(1)


func _on_wave_started(wave: int) -> void:
	if _done or String(_active.get("id", "")) != "wave":
		return
	_active["progress"] = maxi(int(_active.get("progress", 0)), wave)
	if wave >= int(_active.get("target", 3)):
		_complete()
	else:
		_refresh_chip()


func _poll_progress() -> void:
	if _done or String(_active.get("id", "")) != "hoarder":
		return
	var pl := _local_player()
	if pl == null:
		return
	var inv: Node = pl.get_node_or_null("Inventory")
	if inv == null or not ("stacks" in inv):
		return
	var n: int = (inv.get("stacks") as Array).size()
	_active["progress"] = maxi(int(_active.get("progress", 0)), n)
	if n >= int(_active.get("target", 6)):
		_complete()
	else:
		_refresh_chip()


func _bump(by: int) -> void:
	_active["progress"] = int(_active.get("progress", 0)) + by
	if int(_active["progress"]) >= int(_active.get("target", 1)):
		_complete()
	else:
		_refresh_chip()


func _complete() -> void:
	if _done:
		return
	_done = true
	var reward: int = int(_active.get("reward", 0))
	MetaProgression.earn(reward)
	MetaProgression.count_usage("contracts_done")  # M7.8 usage telemetry
	Events.notify.emit(
		tr("✔ CONTRACT COMPLETE: %s — +%d CR") % [String(_active.get("title", "")), reward], 1
	)
	AudioManager.play_skill("extract_done")
	_refresh_chip()
	if _chip != null:
		var tw := _chip.create_tween()
		tw.tween_interval(4.0)
		tw.tween_property(_chip, "modulate:a", 0.0, 0.8)


# ── UI bits ─────────────────────────────────────────────────────────────────
func _ensure_chip() -> void:
	if _chip != null or _headless:
		return
	_chip = PanelContainer.new()
	_chip.add_theme_stylebox_override("panel", UIStyle.chip(UIStyle.AMBER, 0.2))
	_chip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_chip.offset_left = -278.0
	_chip.offset_right = -14.0
	_chip.offset_top = 356.0
	_chip.offset_bottom = 380.0
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip_label = Label.new()
	_chip_label.add_theme_font_size_override("font_size", 12)
	_chip_label.add_theme_color_override("font_color", Color(0.98, 0.82, 0.45))
	_chip.add_child(_chip_label)
	add_child(_chip)


func _refresh_chip() -> void:
	if _chip == null or _chip_label == null or _active.is_empty():
		return
	_chip.visible = true
	_chip.modulate.a = 1.0
	var mark: String = "✔ " if _done else "◈ "
	_chip_label.text = (
		"%s%s  %d/%d"
		% [
			mark,
			String(_active.get("title", "")),
			int(_active.get("progress", 0)),
			int(_active.get("target", 1)),
		]
	)


func _build_offer_box() -> void:
	var total := 3.0 * CARD_W + 2.0 * CARD_GAP
	_offer_box = Control.new()
	_offer_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offer_box.anchor_left = 0.5
	_offer_box.anchor_right = 0.5
	_offer_box.anchor_top = 1.0
	_offer_box.anchor_bottom = 1.0
	_offer_box.offset_left = -total * 0.5
	_offer_box.offset_right = total * 0.5
	_offer_box.offset_top = CARD_BOTTOM - CARD_H
	_offer_box.offset_bottom = CARD_BOTTOM
	add_child(_offer_box)
	var head := UIStyle.micro_header("RAID CONTRACT — PICK OR IGNORE", UIStyle.AMBER, 15)
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
	_timer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offer_box.add_child(_timer_label)
	for i in 3:
		_cards.append(_make_card(i))


func _make_card(i: int) -> Dictionary:
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", UIStyle.glass_panel(0.88))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.position = Vector2(float(i) * (CARD_W + CARD_GAP), 0.0)
	panel.size = Vector2(CARD_W, CARD_H)
	_offer_box.add_child(panel)
	var key := Label.new()
	key.text = KEY_LABELS[i]
	key.position = Vector2(10.0, 8.0)
	key.add_theme_font_size_override("font_size", 13)
	key.add_theme_color_override("font_color", UIStyle.AMBER)
	key.add_theme_stylebox_override("normal", UIStyle.chip(UIStyle.AMBER, 0.22))
	panel.add_child(key)
	var name_l := Label.new()
	name_l.position = Vector2(52.0, 8.0)
	name_l.size = Vector2(CARD_W - 60.0, 20.0)
	name_l.add_theme_font_size_override("font_size", 14)
	name_l.add_theme_color_override("font_color", Color(0.95, 0.9, 0.75))
	panel.add_child(name_l)
	var desc := Label.new()
	desc.position = Vector2(12.0, 36.0)
	desc.size = Vector2(CARD_W - 24.0, 44.0)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 12)
	desc.add_theme_color_override("font_color", UIStyle.DIM)
	panel.add_child(desc)
	var reward := Label.new()
	reward.position = Vector2(12.0, CARD_H - 24.0)
	reward.size = Vector2(CARD_W - 24.0, 18.0)
	reward.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	reward.add_theme_font_size_override("font_size", 13)
	reward.add_theme_color_override("font_color", UIStyle.TEAL)
	panel.add_child(reward)
	return {"panel": panel, "name": name_l, "desc": desc, "reward": reward}


func _local_player() -> Node:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p.has_method("is_multiplayer_authority") and p.is_multiplayer_authority():
			return p
	return null
