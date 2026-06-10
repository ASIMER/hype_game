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

const COL_INFO := UIStyle.TEXT   # white-ish
const COL_GOOD := UIStyle.TEAL   # teal
const COL_BAD  := UIStyle.RED    # red
const COL_WAVE := UIStyle.AMBER  # amber
const COL_DIM  := UIStyle.DIM    # dim grey

# Each line: { "text": String, "color": Color, "t": float }
var _lines: Array = []

# Authored (base) offsets, cached once so the ultrawide inset is idempotent.
var _base_off_l: float = 0.0
var _base_off_t: float = 0.0
var _base_off_r: float = 0.0
var _base_off_b: float = 0.0

# Extra top offset so the killfeed clears the (also top-left) diagnostics overlay
# (stats_overlay.gd) when it is showing. Recomputed from the persisted stats config,
# applied from the cached base each layout pass so it never accumulates.
var _stats_clearance: float = 0.0


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
	# Cache base offsets, then apply the ultrawide-comfort inset (L+T edge).
	_base_off_l = offset_left
	_base_off_t = offset_top
	_base_off_r = offset_right
	_base_off_b = offset_bottom
	_refresh_stats_clearance()
	_apply_hud_inset()
	if not Events.ui_layout_changed.is_connected(_apply_hud_inset):
		Events.ui_layout_changed.connect(_apply_hud_inset)
	# Re-clear the diagnostics overlay whenever it is toggled / its mode changes.
	if not Events.stats_overlay_changed.is_connected(_on_stats_overlay_changed):
		Events.stats_overlay_changed.connect(_on_stats_overlay_changed)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_apply_hud_inset):
		vp.size_changed.connect(_apply_hud_inset)
	Events.wave_started.connect(func(w, _c): _push(tr("WAVE %d") % w, COL_WAVE))
	Events.wave_cleared.connect(func(w): _push(tr("WAVE %d CLEARED") % w, COL_GOOD))
	Events.item_picked_up.connect(_on_pickup)
	Events.entity_died.connect(_on_entity_died)
	Events.notify.connect(_on_notify)


## Pull the killfeed in from the top-left corner toward center (ultrawide comfort).
## Recomputed from cached BASE offsets so repeated calls never accumulate; at margin 0
## (ex=ty=0) the offsets are byte-identical to the authored values.
func _apply_hud_inset() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var ex: float = UILayout.edge_px(vp.x)
	var ty: float = UILayout.top_px(vp.y)
	# LEFT edge → shift the whole box RIGHT by ex (both horizontal offsets).
	offset_left = _base_off_l + ex
	offset_right = _base_off_r + ex
	# TOP edge → shift the whole box DOWN by ty (both vertical offsets) PLUS the
	# clearance for the top-left diagnostics overlay when it is showing.
	offset_top = _base_off_t + ty + _stats_clearance
	offset_bottom = _base_off_b + ty + _stats_clearance


## Compute how far DOWN the killfeed must sit to clear the top-left stats overlay.
## Detailed panel (numeric/graphs) is tall → +220; just the FPS line → +30; off → 0.
func _refresh_stats_clearance() -> void:
	var show_fps: bool = bool(SettingsManager.get_value("show_fps"))
	var show_detailed: bool = bool(SettingsManager.get_value("show_detailed_stats"))
	_set_stats_clearance(show_fps, show_detailed)


func _set_stats_clearance(show_fps: bool, show_detailed: bool) -> void:
	if show_detailed:
		_stats_clearance = 220.0
	elif show_fps:
		_stats_clearance = 30.0
	else:
		_stats_clearance = 0.0


func _on_stats_overlay_changed(show_fps: bool, show_detailed: bool, _mode: int) -> void:
	_set_stats_clearance(show_fps, show_detailed)
	_apply_hud_inset()


func _push(text: String, color: Color) -> void:
	_lines.push_front({"text": text, "color": color, "t": TTL})
	while _lines.size() > MAX_LINES:
		_lines.pop_back()
	queue_redraw()


func _on_pickup(_player: Node, item_id: String, count: int) -> void:
	var name := item_id.capitalize()
	if count > 1:
		_push(tr("+ %s x%d") % [name, count], COL_INFO)
	else:
		_push(tr("+ %s") % name, COL_INFO)


func _on_entity_died(entity: Node, _killer: Node) -> void:
	if entity != null and entity.is_in_group(Groups.ENEMIES):
		var label := tr("Enemy")
		if entity is Node and entity.name != "":
			label = String(entity.name)
		_push(tr("%s destroyed") % label, COL_DIM)


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
		# Subtle glass chip background behind each line.
		var bg_col := Color(UIStyle.GLASS_BG.r, UIStyle.GLASS_BG.g, UIStyle.GLASS_BG.b, 0.55 * alpha)
		draw_rect(Rect2(Vector2(-4.0, y - LINE_H + 3.0), Vector2(WIDTH + 8.0, LINE_H - 2.0)), bg_col, true)
		# Thin accent border matching the line's accent color.
		var border_col := Color(base.r, base.g, base.b, 0.28 * alpha)
		draw_rect(Rect2(Vector2(-4.0, y - LINE_H + 3.0), Vector2(2.0, LINE_H - 2.0)), border_col, true)
		draw_string(font, Vector2(0.0, y), l["text"],
			HORIZONTAL_ALIGNMENT_LEFT, WIDTH, FONT_SIZE, col)
		y += LINE_H
