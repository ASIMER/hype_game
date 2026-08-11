extends Control
## OFFSCREEN WORLD-EVENT CHEVRONS + a sonar sting (M6.8) — "something is happening AND
## I know where, even when it is behind me".
##
## Every ACTIVE mid-raid world event that projects OFF-screen (or sits behind the
## camera) gets an edge-clamped double chevron » in its signal color plus a range
## readout. An event that IS on screen draws nothing — the diegetic beacon pillar
## (scripts/fx/event_beacons.gd) already carries it. A freshly started event pings the
## sonar (AudioManager "extract_beep") and flashes its chevron white for FLASH_TIME.
##
## Data, in the map_ui pattern: Events.world_event_started/ended seed a kind→entry
## cache (NetworkManager relays BOTH to co-op clients), and the "world_events" group
## refreshes positions live every frame — so a moving mini-boss keeps its chevron glued
## to it, and a kind with no physical node (surge / contested POI) still shows.
##
## The event NAME is deliberately absent: hud.gd already banners "⚠ SIEGE — 412m" the
## moment it starts, so the chevron carries what the banner cannot — a PERSISTENT
## bearing and a live range.
##
## Pure-local render, zero netcode, headless-inert. The camera is re-resolved from the
## viewport every frame: it is null between deploy and the first player spawn.
##
## The world→screen edge math mirrors scripts/ui/ping_system.gd (unproject_position +
## is_position_behind + a ray-vs-rect intersection) — the same approach
## teammate_markers.gd uses for its off-screen arrows.
##
## INSTANCING: hud.gd _ready, next to the other lane widgets —
##   add_child((load("res://scripts/ui/event_chevrons.gd") as GDScript).new())

# kind → signal color. Mirrors scripts/fx/event_beacons.gd EVENT_COLORS (and the
# map/minimap legend hues); re-declared locally so this widget stays self-contained.
const EVENT_COLORS := {
	0: Color(0.95, 0.75, 0.25),  # supply cache — amber
	1: Color(0.95, 0.30, 0.95),  # mini-boss — magenta
	2: Color(0.30, 0.80, 0.95),  # contested POI — cyan
	3: Color(1.0, 0.45, 0.10),  # surge — orange
	4: Color(1.0, 0.35, 0.35),  # siege — red
}
const FALLBACK_COLOR := Color(1.0, 0.8, 0.3)

## Never clutter the frame: at most this many chevrons, freshest-then-nearest.
const MAX_CHEVRONS := 3
## Seconds a just-started event stays whitened/swollen after the sonar ping.
const FLASH_TIME := 2.0
## Inset that keeps a chevron AND its range label fully on screen at any aspect.
const EDGE_MARGIN := 46.0
const CHEVRON_LEN := 15.0
const CHEVRON_HALF := 11.0
const CHEVRON_WIDTH := 3.5
const LABEL_SIZE := 12
const SONAR_SFX := "extract_beep"

var _headless := false
var _t := 0.0
# kind(int) -> { "pos": Vector3, "flash": float }
var _events: Dictionary = {}
# kind(int) -> true for events that ENDED but whose node still lingers in the group (a
# cracked SupplyCache hangs around ~3 s for its flash, and queue_free()'d nodes stay
# grouped until the frame ends) — without this the group refresh re-adopts them and the
# chevron ghosts back after the payoff. Cleared when that kind starts again.
var _ended: Dictionary = {}
# Whether anything was active last frame — lets us stop redrawing once idle, but still
# issue the ONE redraw that clears the last chevron.
var _was_active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# NOTE: must be the AND_OFFSETS variant — the plain anchors preset leaves a
	# code-built root 0×0 under the HUD CanvasLayer and everything draws offscreen
	# (the credits-screen / hotbar lesson, live-debugged).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_headless = DisplayServer.get_name() == "headless"

	Events.world_event_started.connect(_on_world_event_started)
	Events.world_event_ended.connect(_on_world_event_ended)
	# A new raid / a resolved raid must never inherit stale markers.
	Events.match_started.connect(_clear)
	Events.match_won.connect(_clear)
	Events.match_lost.connect(_clear)

	if _headless:
		set_process(false)


# --- event bookkeeping ------------------------------------------------------


func _on_world_event_started(kind: int, world_pos: Vector3, _label: String) -> void:
	_ended.erase(kind)
	_events[kind] = {"pos": world_pos, "flash": FLASH_TIME}
	if not _headless:
		AudioManager.play_skill(SONAR_SFX)


func _on_world_event_ended(kind: int, _success: bool) -> void:
	_events.erase(kind)
	_ended[kind] = true


func _clear() -> void:
	_events.clear()
	_ended.clear()
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	_refresh_from_group()
	for kind in _events:
		var entry: Dictionary = _events[kind]
		var flash: float = float(entry["flash"])
		if flash > 0.0:
			entry["flash"] = maxf(0.0, flash - delta)

	var active: bool = not _events.is_empty()
	if active or _was_active:
		queue_redraw()
	_was_active = active


## Live positions from the "world_events" group (the map_ui contract): a Node3D's
## global_position wins, else the `event_pos` meta. A grouped node we never saw a
## started-signal for is adopted silently — covers a late join and a re-entered raid.
func _refresh_from_group() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group(Groups.WORLD_EVENTS):
		if not node.has_meta("event_kind"):
			continue
		var pos: Vector3
		if node is Node3D:
			pos = (node as Node3D).global_position
		elif node.has_meta("event_pos"):
			pos = node.get_meta("event_pos") as Vector3
		else:
			continue
		var kind: int = int(node.get_meta("event_kind"))
		if _ended.has(kind):
			continue
		var known: Variant = _events.get(kind, null)
		if known is Dictionary:
			(known as Dictionary)["pos"] = pos
		else:
			_events[kind] = {"pos": pos, "flash": 0.0}


# --- drawing ----------------------------------------------------------------


func _draw() -> void:
	if _events.is_empty():
		return
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	var screen: Vector2 = size
	if screen.x <= 0.0 or screen.y <= 0.0:
		return

	var center := screen * 0.5
	var margin := Vector2(EDGE_MARGIN, EDGE_MARGIN)
	var rect := Rect2(margin, screen - margin * 2.0)
	var eye: Vector3 = cam.global_position

	var offscreen: Array[Dictionary] = []
	for kind in _events:
		var entry: Dictionary = _events[kind]
		var wpos: Vector3 = entry["pos"]
		var behind := cam.is_position_behind(wpos)
		var sp := cam.unproject_position(wpos)
		if not behind and rect.has_point(sp):
			continue  # on screen — the beacon pillar reads it for us
		var dir := sp - center
		if behind:
			# unproject mirrors points behind the lens; flip so the chevron points back.
			dir = -dir
		if dir.length() < 0.001:
			dir = Vector2(0.0, -1.0)
		var candidate := {
			"dir": dir.normalized(),
			"dist": eye.distance_to(wpos),
			"flash": float(entry["flash"]),
			"color": EVENT_COLORS.get(int(kind), FALLBACK_COLOR),
		}
		offscreen.append(candidate)

	offscreen.sort_custom(_freshest_then_nearest)
	var shown: int = mini(offscreen.size(), MAX_CHEVRONS)
	for i in range(shown):
		var s: Dictionary = offscreen[i]
		var dir: Vector2 = s["dir"]
		var col: Color = s["color"]
		var edge := _edge_point(center, dir, rect)
		_draw_chevron(edge, dir, col, float(s["flash"]), float(s["dist"]))


## A just-started (flashing) event always beats a nearer old one, so the MAX_CHEVRONS
## cap can never swallow the very thing the sonar just announced.
func _freshest_then_nearest(a: Dictionary, b: Dictionary) -> bool:
	var fresh_a: bool = float(a["flash"]) > 0.0
	var fresh_b: bool = float(b["flash"]) > 0.0
	if fresh_a != fresh_b:
		return fresh_a
	return float(a["dist"]) < float(b["dist"])


## The double chevron » pinned to the screen edge, pointing at the event, range beneath.
## `flash` (seconds left) whitens, swells and pulses it right after the sonar ping.
func _draw_chevron(p: Vector2, dir: Vector2, base: Color, flash: float, dist: float) -> void:
	var f: float = clampf(flash / FLASH_TIME, 0.0, 1.0)
	var pulse: float = 0.5 + 0.5 * sin(_t * 6.0)
	var col: Color = base.lerp(Color(1.0, 1.0, 1.0), f * (0.3 + 0.35 * pulse))
	var alpha: float = 0.8 + 0.2 * f
	var swell: float = 1.0 + 0.35 * f
	var side := Vector2(-dir.y, dir.x)

	# Two stacked arrow heads (the trailing one smaller + dimmer) read as a chevron,
	# distinct from the SOLID triangles the ping / teammate arrows use.
	for i in range(2):
		var back: float = float(i) * CHEVRON_LEN * 0.62 * swell
		var half: float = (CHEVRON_HALF - float(i) * 2.0) * swell
		var reach: float = (CHEVRON_LEN - float(i) * 2.0) * swell
		var tip := p + dir * (reach - back)
		var line := PackedVector2Array(
			[tip - dir * reach + side * half, tip, tip - dir * reach - side * half]
		)
		var a: float = alpha if i == 0 else alpha * 0.45
		# Dark backing stroke first — chevrons must survive a bright sky.
		draw_polyline(line, Color(0.0, 0.0, 0.0, a * 0.55), CHEVRON_WIDTH * swell + 2.0, true)
		draw_polyline(line, Color(col.r, col.g, col.b, a), CHEVRON_WIDTH * swell, true)

	_draw_range(p - dir * (17.0 * swell), Color(col.r, col.g, col.b, alpha), dist)


## Range readout, placed INWARD of the chevron (so it reads at any screen edge) and
## clamped into the viewport so it never clips at any aspect ratio.
## Reuses the EXISTING "%d m" locale key (settings_menu) — no new CSV row needed.
func _draw_range(p: Vector2, col: Color, dist: float) -> void:
	var font := _font()
	if font == null:
		return
	var text: String = tr("%d m") % int(round(dist))
	var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE).x
	var lp := p - Vector2(tw * 0.5, -float(LABEL_SIZE) * 0.5)
	lp.x = clampf(lp.x, 4.0, maxf(4.0, size.x - tw - 4.0))
	lp.y = clampf(lp.y, float(LABEL_SIZE) + 2.0, maxf(float(LABEL_SIZE) + 2.0, size.y - 4.0))
	var shadow := Color(0.0, 0.0, 0.0, col.a * 0.7)
	draw_string(font, lp + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, shadow)
	draw_string(font, lp, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, col)


## The themed body face when a theme is in play, else Godot's fallback (headless/tests).
func _font() -> Font:
	var themed := get_theme_default_font()
	if themed != null:
		return themed
	return ThemeDB.fallback_font


## Where a ray from `center` along `dir` first crosses the clamp rect — pins the chevron
## to the nearest screen edge. Mirrors ping_system.gd / teammate_markers.gd.
func _edge_point(center: Vector2, dir: Vector2, rect: Rect2) -> Vector2:
	var tmin := INF
	if absf(dir.x) > 0.0001:
		var xs: Array[float] = [rect.position.x, rect.position.x + rect.size.x]
		for ex in xs:
			var t: float = (ex - center.x) / dir.x
			if t > 0.0:
				var y: float = center.y + dir.y * t
				if y >= rect.position.y - 0.5 and y <= rect.position.y + rect.size.y + 0.5:
					tmin = minf(tmin, t)
	if absf(dir.y) > 0.0001:
		var ys: Array[float] = [rect.position.y, rect.position.y + rect.size.y]
		for ey in ys:
			var t: float = (ey - center.y) / dir.y
			if t > 0.0:
				var x: float = center.x + dir.x * t
				if x >= rect.position.x - 0.5 and x <= rect.position.x + rect.size.x + 0.5:
					tmin = minf(tmin, t)
	if tmin == INF:
		tmin = 0.0
	return center + dir * tmin
