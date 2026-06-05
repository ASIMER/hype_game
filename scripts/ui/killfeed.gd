extends Control
class_name Killfeed
## Top-LEFT vertical stack of short, fading event lines (newest on top, max ~5, each
## fades after ~4s). Derived purely from the Events bus — waves, pickups, kills, and
## generic notifications. Dark sci-fi theme.

const MAX_LINES := 5
const TTL := 4.0
const FADE := 0.8          # last seconds spent fading out
const LINE_H := 20.0
const FONT_SIZE := 14
const TOP := 16.0
const LEFT := 16.0
const WIDTH := 280.0

const COL_INFO := Color(0.847, 0.871, 0.894)  # white-ish #d8dee4
const COL_GOOD := Color(0.247, 0.714, 0.788)  # teal #3fb6c9
const COL_BAD := Color(0.847, 0.271, 0.251)   # red #d84540
const COL_WAVE := Color(0.91, 0.64, 0.24)     # amber #e8a33d
const COL_DIM := Color(0.55, 0.6, 0.66)       # dim grey

# Each line: { "text": String, "color": Color, "t": float }
var _lines: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	offset_left = LEFT
	offset_top = TOP
	offset_right = LEFT + WIDTH
	offset_bottom = TOP + LINE_H * MAX_LINES
	Events.wave_started.connect(func(w, _c): _push("WAVE %d" % w, COL_WAVE))
	Events.wave_cleared.connect(func(w): _push("WAVE %d CLEARED" % w, COL_GOOD))
	Events.item_picked_up.connect(_on_pickup)
	Events.entity_died.connect(_on_entity_died)
	Events.notify.connect(_on_notify)


func _push(text: String, color: Color) -> void:
	_lines.push_front({"text": text, "color": color, "t": TTL})
	while _lines.size() > MAX_LINES:
		_lines.pop_back()
	queue_redraw()


func _on_pickup(_player: Node, item_id: String, count: int) -> void:
	var name := item_id.capitalize()
	if count > 1:
		_push("+ %s x%d" % [name, count], COL_INFO)
	else:
		_push("+ %s" % name, COL_INFO)


func _on_entity_died(entity: Node, _killer: Node) -> void:
	if entity != null and entity.is_in_group("enemies"):
		var label := "Enemy"
		if entity is Node and entity.name != "":
			label = String(entity.name)
		_push("%s destroyed" % label, COL_DIM)


func _on_notify(text: String, kind: int) -> void:
	var col := COL_INFO
	match kind:
		1: col = COL_GOOD
		2: col = COL_BAD
		3: col = COL_WAVE
		_: col = COL_INFO
	_push(text, col)


func _process(delta: float) -> void:
	if _lines.is_empty():
		return
	for l in _lines:
		l["t"] -= delta
	_lines = _lines.filter(func(l): return l["t"] > 0.0)
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var y := LINE_H
	for l in _lines:
		var t: float = l["t"]
		var alpha := 1.0 if t > FADE else clampf(t / FADE, 0.0, 1.0)
		var base: Color = l["color"]
		var col := Color(base.r, base.g, base.b, base.a * alpha)
		draw_string(font, Vector2(0.0, y), l["text"],
			HORIZONTAL_ALIGNMENT_LEFT, WIDTH, FONT_SIZE, col)
		y += LINE_H
