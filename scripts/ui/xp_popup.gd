extends Control
## Floating "+N XP" popups in the bottom-right corner, just above the ammo readout — the
## in-raid half of the progression feedback loop (roadmap M4.5). Every XP award the
## Progression autoload reports gets a visible beat instead of only surfacing on the
## post-raid summary screen.
##
## Render-only and per-peer LOCAL: it listens to Events.xp_gained (which fires on the
## machine that EARNED the xp, so a co-op client sees its own take) and owns nothing but
## Labels. Bursts from the same source inside BATCH_WINDOW_MS merge into ONE growing
## popup, so a multi-kill reads as "+75 XP" rather than three stacked identical lines.
##
## Self-positions with anchors+offsets (the minimap/killfeed discipline) and applies the
## same ultrawide HUD inset, so it stays clear of the corner on very wide displays.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>` — every Dictionary/Array
## read gets an explicit type.

const MAX_POPUPS := 6  # oldest is dropped past this
const LIFE := 1.15  # seconds of rise+fade before the label frees itself
const RISE := 46.0  # pixels travelled upward over LIFE
const STACK_STEP := 22.0  # each concurrent popup starts this much higher
const BATCH_WINDOW_MS := 120  # same-source awards inside this merge into one popup
const BIG_XP := 50  # amount at/above which the popup goes amber instead of teal
const WIDTH := 204.0
const BOX_H := 100.0
const RIGHT := 16.0  # gap from the right screen edge
# Box TOP sits this far above the bottom edge. The corner below is SPOKEN FOR: the ammo
# block runs to ~90 px and hud.gd's 4-line key-hint sheet to ~154 px (it only dims after
# 75 s, it never hides outside the storm) — so the lowest popup starts at 170.
const BOTTOM := 270.0
const LINE_H := 22.0
const FONT_SIZE := UIStyle.FONT_H2

# Each entry: { "label": Label, "amount": int, "source": String, "tween": Tween }
var _active: Array = []
# Batching bookkeeping: when the previous award landed and what it was for.
var _last_ms: int = 0
var _last_source: String = ""

# Authored (base) offsets, cached once so the ultrawide inset is idempotent.
var _base_off_l: float = 0.0
var _base_off_t: float = 0.0
var _base_off_r: float = 0.0
var _base_off_b: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A dedicated server has no screen — stay completely inert (no nodes, no signals).
	if DisplayServer.get_name() == "headless":
		return
	# Fixed-size box pinned to the bottom-right corner (robust at any resolution).
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -(WIDTH + RIGHT)
	offset_right = -RIGHT
	offset_top = -BOTTOM
	offset_bottom = -BOTTOM + BOX_H
	_base_off_l = offset_left
	_base_off_t = offset_top
	_base_off_r = offset_right
	_base_off_b = offset_bottom
	_apply_hud_inset()
	if not Events.ui_layout_changed.is_connected(_apply_hud_inset):
		Events.ui_layout_changed.connect(_apply_hud_inset)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_apply_hud_inset):
		vp.size_changed.connect(_apply_hud_inset)
	Events.xp_gained.connect(_on_xp_gained)
	Events.match_started.connect(_clear)


## Pull the popup column in from the bottom-right corner toward center (ultrawide
## comfort). Recomputed from the cached BASE offsets so repeated calls never accumulate.
func _apply_hud_inset() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var ex: float = UILayout.edge_px(vp.x)
	var ty: float = UILayout.top_px(vp.y)
	# RIGHT edge → shift LEFT by ex; BOTTOM edge → shift UP by ty (offsets are negative).
	offset_left = _base_off_l - ex
	offset_right = _base_off_r - ex
	offset_top = _base_off_t - ty
	offset_bottom = _base_off_b - ty


func _on_xp_gained(amount: int, source: String) -> void:
	if amount <= 0:
		return
	var now: int = Time.get_ticks_msec()
	if _merge_into_last(now, amount, source):
		_last_ms = now
		return
	_spawn(amount, source)
	_last_ms = now
	_last_source = source


## Fold a fresh award into the newest popup when it lands in the same batch window from
## the same source (the multi-kill case). Returns false when a new popup is needed.
func _merge_into_last(now: int, amount: int, source: String) -> bool:
	if _active.is_empty() or source != _last_source:
		return false
	if now - _last_ms > BATCH_WINDOW_MS:
		return false
	var last: Dictionary = _active.back()
	var l: Label = last["label"]
	if l == null or not is_instance_valid(l) or String(last["source"]) != source:
		return false
	last["amount"] = int(last["amount"]) + amount
	_refresh(last)
	_animate(last)  # restart the rise+fade so the merged total gets its full read
	return true


func _spawn(amount: int, source: String) -> void:
	while _active.size() >= MAX_POPUPS:
		var oldest: Dictionary = _active.pop_front()
		_free_entry(oldest)
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	l.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	l.size = Vector2(WIDTH, LINE_H)
	# Newest starts at the bottom of the box; each still-live popup lifts it a step so a
	# same-frame burst doesn't draw on top of itself.
	l.position = Vector2(0.0, BOX_H - LINE_H - float(_active.size()) * STACK_STEP)
	add_child(l)
	var entry: Dictionary = {"label": l, "amount": amount, "source": source, "tween": null}
	_active.append(entry)
	_refresh(entry)
	_animate(entry)


## Repaint an entry's text + colour from its (possibly merged) amount.
func _refresh(entry: Dictionary) -> void:
	var l: Label = entry["label"]
	if l == null or not is_instance_valid(l):
		return
	var amount: int = int(entry["amount"])
	var source: String = String(entry["source"])
	# No tr() here by design: the payload is a raw number plus a source ID.
	var text: String = "+%d XP" % amount
	if source != "" and source != "kill":
		text += " · %s" % source
	l.text = text
	var col: Color = UIStyle.AMBER if amount >= BIG_XP else UIStyle.TEAL
	l.add_theme_color_override("font_color", col)


## (Re)start the rise+fade. Killing any in-flight tween first is what makes a merged
## popup restart cleanly instead of racing two tweens on the same label.
func _animate(entry: Dictionary) -> void:
	var l: Label = entry["label"]
	if l == null or not is_instance_valid(l):
		return
	var old: Tween = entry["tween"]
	if old != null and old.is_valid():
		old.kill()
	l.modulate.a = 1.0
	var tw := l.create_tween()
	tw.set_parallel(true)
	(
		tw
		. tween_property(l, "position:y", l.position.y - RISE, LIFE)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_OUT)
	)
	tw.tween_property(l, "modulate:a", 0.0, LIFE).set_trans(Tween.TRANS_SINE).set_ease(
		Tween.EASE_IN
	)
	tw.finished.connect(_retire.bind(entry))
	entry["tween"] = tw


func _retire(entry: Dictionary) -> void:
	_active.erase(entry)
	_free_entry(entry)


func _free_entry(entry: Dictionary) -> void:
	var tw: Tween = entry["tween"]
	if tw != null and tw.is_valid():
		tw.kill()
	entry["tween"] = null
	var l: Label = entry["label"]
	if l != null and is_instance_valid(l):
		l.queue_free()


## Wipe the column between raids so leftovers never bleed into the next match.
func _clear() -> void:
	for e in _active:
		var entry: Dictionary = e
		_free_entry(entry)
	_active.clear()
	_last_ms = 0
	_last_source = ""
