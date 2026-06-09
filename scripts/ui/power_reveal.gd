extends Control
class_name PowerReveal
## Non-blocking Power-Cache reveal (Vampire-Survivors-style) + the active-buff strip.
## When a cache is opened, a "lottery" reel spins through power icons on the SIDE of the screen
## and lands on the rolled power — the GAME KEEPS RUNNING (no pause, the player can still dodge).
## The buff itself is applied by the player AFTER Settings.POWER_REVEAL_TIME, so this is purely the
## visual reveal. A compact strip lists active buffs with their remaining time.
## Pure HUD: mouse_filter IGNORE, listens on the Events bus, draws in code.

const REEL_TIME := Settings.POWER_REVEAL_TIME    # spin length (matches when the buff applies)
const HOLD_TIME := 1.4                            # "ACTIVATED" flourish after the reel lands
const PANEL_W := 248.0
const PANEL_H := 116.0
const CARD := 64.0

var _player: Node = null
# Reveal state.
var _revealing := false
var _t := 0.0
var _rolled := ""
var _face := ""                # the power currently shown on the reel
var _switch_accum := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Events.power_reveal_started.connect(_on_reveal)
	Events.buff_applied.connect(func(_p, _id, _d): queue_redraw())
	Events.buff_expired.connect(func(_p, _id): queue_redraw())
	Events.local_player_spawned.connect(func(p): _player = p)
	if _player == null:
		_player = _find_local_player()

func _find_local_player() -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if p.has_method("is_multiplayer_authority") and p.is_multiplayer_authority():
			return p
	return null

func _on_reveal(power_id: String) -> void:
	_rolled = power_id
	_revealing = true
	_t = 0.0
	_switch_accum = 0.0
	_face = power_id
	queue_redraw()

func _process(delta: float) -> void:
	# The active-buff strip needs a steady redraw for its countdowns.
	if not _revealing:
		if _player != null and _player.has_method("active_buffs") \
				and not (_player.active_buffs() as Array).is_empty():
			queue_redraw()
		return
	_t += delta
	if _t < REEL_TIME:
		# Spin: switch faces fast at first, decelerating toward the end (ease-out).
		var k := clampf(_t / REEL_TIME, 0.0, 1.0)
		var interval := lerpf(0.04, 0.34, k * k)
		if _t >= REEL_TIME - 0.45:
			_face = _rolled            # lock onto the result before the reel stops
		else:
			_switch_accum += delta
			if _switch_accum >= interval:
				_switch_accum = 0.0
				_face = _random_power()
	else:
		_face = _rolled
		if _t >= REEL_TIME + HOLD_TIME:
			_revealing = false
	queue_redraw()

func _random_power() -> String:
	var keys: Array = Settings.POWERS.keys()
	return String(keys[randi() % keys.size()]) if not keys.is_empty() else _rolled

func _draw() -> void:
	var vp := get_viewport_rect().size
	if _revealing:
		_draw_reveal(vp)
	_draw_buff_strip(vp)

# --- Reveal reel (right-centre, clear of the screen-centre crosshair) ---------
func _draw_reveal(vp: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var origin := Vector2(vp.x - PANEL_W - 28.0, vp.y * 0.5 - PANEL_H * 0.5)
	var landed := _t >= REEL_TIME
	var def: Dictionary = Settings.POWERS.get(_face, {})
	var col: Color = def.get("color", Color.WHITE)
	# Panel.
	draw_rect(Rect2(origin, Vector2(PANEL_W, PANEL_H)), Color(0.03, 0.05, 0.07, 0.86), true)
	var accent: Color = col if landed else Color(0.91, 0.64, 0.24)
	draw_rect(Rect2(origin, Vector2(PANEL_W, PANEL_H)), Color(accent, 0.6 + (0.4 if landed else 0.0)), false, 2.0)
	# Header.
	var head := tr("ACTIVATED!") if landed else tr("POWER CACHE")
	draw_string(font, origin + Vector2(14.0, 22.0), head, HORIZONTAL_ALIGNMENT_LEFT, PANEL_W - 28.0, 15, accent)
	# Reel card: a dark tile + the power's ICON tinted by its colour (falls back to the initial
	# letter if the icon asset is missing). A tiny pop when it lands.
	var pop := 1.0 + (0.12 * sin(_t * 22.0) if landed else 0.0)
	var cs := CARD * pop
	var cpos := origin + Vector2(16.0, 36.0) + Vector2((CARD - cs) * 0.5, (CARD - cs) * 0.5)
	draw_rect(Rect2(cpos, Vector2(cs, cs)), Color(0.05, 0.06, 0.08, 0.9), true)
	draw_rect(Rect2(cpos, Vector2(cs, cs)), Color(col, 0.85 if landed else 0.45), false, 2.0)
	var icon := Settings.power_icon(_face)
	if icon != null:
		var pad := cs * 0.14
		draw_texture_rect(icon, Rect2(cpos + Vector2(pad, pad), Vector2(cs - pad * 2.0, cs - pad * 2.0)), false, col)
	else:
		var initial := String(def.get("name", _face)).substr(0, 1).to_upper()
		draw_string(font, cpos + Vector2(cs * 0.5 - 9.0, cs * 0.5 + 11.0), initial, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, col)
	# Name + desc (only meaningful once landed, but show the cycling name for flavour).
	var name_x := origin.x + 16.0 + CARD + 14.0
	draw_string(font, Vector2(name_x, origin.y + 58.0), String(def.get("name", _face)),
		HORIZONTAL_ALIGNMENT_LEFT, PANEL_W - CARD - 46.0, 18, Color(0.93, 0.95, 0.97))
	if landed:
		draw_string(font, Vector2(name_x, origin.y + 80.0), String(def.get("desc", "")),
			HORIZONTAL_ALIGNMENT_LEFT, PANEL_W - CARD - 46.0, 12, Color(0.78, 0.82, 0.86))

# --- Active-buff strip (left edge, under the health block) --------------------
func _draw_buff_strip(vp: Vector2) -> void:
	if _player == null or not is_instance_valid(_player) or not _player.has_method("active_buffs"):
		return
	var buffs: Array = _player.active_buffs()
	if buffs.is_empty():
		return
	var font := ThemeDB.fallback_font
	var x := 22.0
	var y := vp.y * 0.5 - float(buffs.size()) * 13.0   # vertically centred on the left edge
	for b in buffs:
		var col: Color = b.get("color", Color.WHITE)
		var secs := int(ceil(float(b.get("time_left", 0.0))))
		draw_rect(Rect2(Vector2(x, y), Vector2(176.0, 24.0)), Color(0.03, 0.05, 0.07, 0.72), true)
		draw_rect(Rect2(Vector2(x, y), Vector2(4.0, 24.0)), col, true)   # accent bar
		var icon := Settings.power_icon(String(b.get("id", "")))
		if icon != null:
			draw_texture_rect(icon, Rect2(Vector2(x + 9.0, y + 3.0), Vector2(18.0, 18.0)), false, col)
		draw_string(font, Vector2(x + 32.0, y + 17.0), String(b.get("name", "")),
			HORIZONTAL_ALIGNMENT_LEFT, 108.0, 13, Color(0.93, 0.95, 0.97))
		draw_string(font, Vector2(x + 138.0, y + 17.0), "%ds" % secs,
			HORIZONTAL_ALIGNMENT_RIGHT, 34.0, 13, col)
		y += 28.0
