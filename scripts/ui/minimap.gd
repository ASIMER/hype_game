extends Control
class_name Minimap
## Top-down radar/compass (player-relative, heading up). Blips: enemies (red),
## extraction zones (green, group "extraction"), the player (centre). Pure HUD.

const RADIUS := 78.0
const RANGE := 65.0   # world metres mapped to the radar edge

var _player: Node3D = null
# Per-zone extraction-window state cached from Events.extraction_window_changed:
#   zone(Node) -> { "open": bool, "remaining": float }
var _zone_windows: Dictionary = {}
# Drives the OPEN-zone pulse.
var _pulse: float = 0.0

# --- World-event / surge state ----------------------------------------------
# kind (int) -> { "label": String, "pos": Vector3, "active": bool, "ratio": float }
var _event_cache: Dictionary = {}
# Sensor-blackout surge: true while environmental_surge_changed(true, 1) is active.
var _sensor_blackout: bool = false

# Authored (base) offsets, cached once so the ultrawide inset is idempotent.
var _base_off_l: float = 0.0
var _base_off_t: float = 0.0
var _base_off_r: float = 0.0
var _base_off_b: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Pin a fixed-size box to the top-right corner via anchors+offsets (robust at any
	# resolution).
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 0.0
	offset_left = -(RADIUS * 2.0) - 16.0
	offset_top = 16.0
	offset_right = -16.0
	offset_bottom = (RADIUS * 2.0) + 16.0
	# Cache base offsets, then apply the ultrawide-comfort inset (R+T edge).
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
	Events.local_player_spawned.connect(func(p): _player = p as Node3D)
	Events.extraction_window_changed.connect(_on_window_changed)
	Events.world_event_started.connect(_on_world_event_started)
	Events.world_event_ended.connect(_on_world_event_ended)
	Events.world_event_progress.connect(_on_world_event_progress)
	Events.environmental_surge_changed.connect(_on_surge_changed)


## Pull the radar box in from the top-right corner toward center (ultrawide comfort).
## Recomputed from the cached BASE offsets so repeated calls never accumulate; at
## margin 0 (ex=ty=0) the offsets are byte-identical to the authored values.
func _apply_hud_inset() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var ex: float = UILayout.edge_px(vp.x)
	var ty: float = UILayout.top_px(vp.y)
	# RIGHT edge → shift the whole box LEFT by ex (both horizontal offsets).
	offset_left = _base_off_l - ex
	offset_right = _base_off_r - ex
	# TOP edge → shift the whole box DOWN by ty (both vertical offsets).
	offset_top = _base_off_t + ty
	offset_bottom = _base_off_b + ty


func _on_window_changed(zone: Node, open: bool, remaining: float) -> void:
	if zone == null:
		return
	_zone_windows[zone] = { "open": open, "remaining": remaining }


## Extraction-window state for a zone — cached Events value first, then a defensive
## zone query (another lane adds is_open()/window_remaining()), else open by default.
func _window_for(zone: Node) -> Dictionary:
	var cached: Variant = _zone_windows.get(zone, null)
	if cached != null:
		return cached as Dictionary
	var is_open_val: bool = true
	if zone != null and zone.has_method("is_open"):
		is_open_val = bool(zone.call("is_open"))
	var remaining_val: float = 0.0
	if zone != null and zone.has_method("window_remaining"):
		remaining_val = float(zone.call("window_remaining"))
	return { "open": is_open_val, "remaining": remaining_val }


func _on_world_event_started(kind: int, world_pos: Vector3, label: String) -> void:
	_event_cache[kind] = { "label": label, "pos": world_pos, "active": true, "ratio": -1.0 }

func _on_world_event_ended(kind: int, _success: bool) -> void:
	if _event_cache.has(kind):
		(_event_cache[kind] as Dictionary)["active"] = false

func _on_world_event_progress(kind: int, ratio: float) -> void:
	if _event_cache.has(kind):
		(_event_cache[kind] as Dictionary)["ratio"] = ratio

func _on_surge_changed(active: bool, kind: int) -> void:
	# kind 1 = sensor-blackout; kind 0 = enemy-surge (no minimap effect).
	if kind == 1:
		_sensor_blackout = active

## Returns 0..1 fill ratio for a world-event node, or -1 if not available.
func _event_ratio(node: Node) -> float:
	if node.has_method("event_ratio"):
		return float(node.call("event_ratio"))
	if node.has_meta("_director_ref"):
		var d: Variant = node.get_meta("_director_ref")
		if d != null and is_instance_valid(d as Object) and (d as Object).has_method("marker_event_ratio"):
			return float((d as Object).call("marker_event_ratio", node))
	return -1.0

func _process(delta: float) -> void:
	_pulse += delta
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	draw_circle(c, RADIUS, Color(0.03, 0.05, 0.07, 0.8))
	draw_arc(c, RADIUS, 0.0, TAU, 48, Color(0.5, 0.7, 0.85, 0.9), 2.5)

	# Sensor-blackout surge: scramble the minimap with a "SIGNAL LOST" overlay and return.
	if _sensor_blackout:
		_draw_blackout(c)
		return

	# North tick (compass): rotates with player heading.
	if not is_instance_valid(_player):
		return
	var yaw := _player.rotation.y
	# crosshair lines
	draw_line(c - Vector2(0, RADIUS), c + Vector2(0, RADIUS), Color(1, 1, 1, 0.08), 1.0)
	draw_line(c - Vector2(RADIUS, 0), c + Vector2(RADIUS, 0), Color(1, 1, 1, 0.08), 1.0)
	# North marker
	var north := _to_radar(Vector3(0, 0, -1) * RANGE, _player.global_position, yaw)
	draw_string(ThemeDB.fallback_font, c + north.normalized() * (RADIUS - 12.0) - Vector2(5, -6),
		"N", HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color(0.7, 0.8, 0.9, 0.8))
	# Extraction zones — OPEN ones pulse green, CLOSED ones are dim grey, each with a
	# thin countdown ring when a window timer is known.
	for z in get_tree().get_nodes_in_group("extraction"):
		if z is Node3D:
			var pos := _to_radar((z as Node3D).global_position, _player.global_position, yaw)
			var w: Dictionary = _window_for(z)
			var is_open_z: bool = bool(w.get("open", true))
			var remaining: float = float(w.get("remaining", 0.0))
			var col: Color
			var r: float = 4.0
			if is_open_z:
				var t: float = 0.5 + 0.5 * sin(_pulse * 4.0)
				col = Color(0.3, 1.0, 0.5, 0.6 + 0.4 * t)
				r = 4.0 + 1.5 * t
			else:
				col = Color(0.55, 0.6, 0.62, 0.7)
			_blip(c, pos, col, r)
			# Countdown ring: a short arc whose sweep shrinks as the window runs out
			# (assumes a nominal 30s window for the visual; purely cosmetic).
			if remaining > 0.0:
				var frac: float = clampf(remaining / 30.0, 0.0, 1.0)
				draw_arc(c + pos, r + 2.5, -PI * 0.5, -PI * 0.5 + TAU * frac, 16, col, 1.5)
	# Enemies.
	for e in get_tree().get_nodes_in_group("enemies"):
		if e is Node3D:
			_blip(c, _to_radar((e as Node3D).global_position, _player.global_position, yaw),
				Color(1.0, 0.3, 0.3), 3.0)
	# World-event blips (supply cache / miniboss / contested / surge).
	_draw_event_blips(c, yaw)
	# Player (centre, facing up).
	draw_circle(c, 3.5, Color(0.4, 0.8, 1.0))


## Draws the sensor-blackout "SIGNAL LOST" overlay over the minimap disc.
func _draw_blackout(c: Vector2) -> void:
	# Noisy fill inside the circle: draw scattered dark-green dots for a static look.
	# We use a deterministic pattern driven by _pulse so it appears to shift each frame.
	var seed_base: int = int(_pulse * 8.0) & 0xFFFF
	for i in range(60):
		var ang: float = (float(i) + float(seed_base & 0xF) * 0.13) * 2.399
		var rad_frac: float = fmod(float(i * 7 + seed_base) * 0.041, 1.0)
		var pt: Vector2 = c + Vector2(cos(ang), sin(ang)) * rad_frac * (RADIUS - 4.0)
		var brightness: float = 0.15 + 0.25 * fmod(float(i + seed_base) * 0.173, 1.0)
		draw_circle(pt, 1.5, Color(0.1, brightness, 0.1, 0.7))
	# "SIGNAL LOST" text centred in the disc.
	var font: Font = ThemeDB.fallback_font
	draw_string(font, c + Vector2(-38.0, -6.0), "SIGNAL", HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
		Color(0.35, 1.0, 0.35, 0.9))
	draw_string(font, c + Vector2(-28.0, 10.0), "LOST", HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
		Color(0.35, 1.0, 0.35, 0.9))

# Event kind → radar blip color.
const _EVENT_BLIP_COLORS := [
	Color(0.95, 0.75, 0.25, 0.95),  # 0 supply_cache — amber
	Color(0.95, 0.30, 0.95, 0.95),  # 1 miniboss — magenta
	Color(0.30, 0.80, 0.95, 0.95),  # 2 contested_poi — cyan
	Color(1.00, 0.45, 0.10, 0.95),  # 3 surge — orange
]

## Draws world-event blips on the minimap, clamped to the rim when out of range.
func _draw_event_blips(c: Vector2, yaw: float) -> void:
	if not is_instance_valid(_player):
		return
	var ppos: Vector3 = _player.global_position
	var drawn_kinds: Dictionary = {}

	for node in get_tree().get_nodes_in_group("world_events"):
		if not node.has_meta("event_kind"):
			continue
		var kind: int = int(node.get_meta("event_kind"))
		var wpos: Vector3
		if node is Node3D:
			wpos = (node as Node3D).global_position
		elif node.has_meta("event_pos"):
			wpos = node.get_meta("event_pos") as Vector3
		else:
			continue
		var ratio: float = _event_ratio(node)
		if ratio < 0.0:
			var cached: Variant = _event_cache.get(kind, null)
			if cached != null:
				ratio = float((cached as Dictionary).get("ratio", -1.0))
		_draw_single_event_blip(c, kind, wpos, ppos, yaw, ratio)
		drawn_kinds[kind] = true

	# Signal-only fallback.
	for kind_key in _event_cache.keys():
		var kind: int = int(kind_key)
		if drawn_kinds.has(kind):
			continue
		var cached: Dictionary = _event_cache[kind] as Dictionary
		if not bool(cached.get("active", false)):
			continue
		var wpos: Vector3 = cached.get("pos", Vector3.ZERO) as Vector3
		var ratio: float = float(cached.get("ratio", -1.0))
		_draw_single_event_blip(c, kind, wpos, ppos, yaw, ratio)

func _draw_single_event_blip(c: Vector2, kind: int, wpos: Vector3, ppos: Vector3,
		yaw: float, ratio: float) -> void:
	var col: Color = _EVENT_BLIP_COLORS[clampi(kind, 0, _EVENT_BLIP_COLORS.size() - 1)]
	var offset: Vector2 = _to_radar(wpos, ppos, yaw)
	var blip_r: float = 4.5 + 1.0 * (0.5 + 0.5 * sin(_pulse * 3.2))
	_blip(c, offset, col, blip_r)
	# Ratio fill ring for cache / contested kinds.
	if ratio >= 0.0 and kind in [0, 2]:
		var start_a: float = -PI * 0.5
		var end_a: float = start_a + TAU * clampf(ratio, 0.0, 1.0)
		draw_arc(c + offset, blip_r + 2.5, start_a, end_a, 14,
			Color(col.r, col.g, col.b, 0.55), 2.0)

## World position -> radar offset (player-relative, heading up, clamped to the rim).
func _to_radar(wpos: Vector3, ppos: Vector3, yaw: float) -> Vector2:
	var dx := wpos.x - ppos.x
	var dz := wpos.z - ppos.z
	var lx := dx * cos(yaw) - dz * sin(yaw)
	var lf := -dx * sin(yaw) - dz * cos(yaw)   # forward component
	var screen := Vector2(lx, -lf) / RANGE * RADIUS
	if screen.length() > RADIUS - 3.0:
		screen = screen.normalized() * (RADIUS - 3.0)
	return screen


func _blip(center: Vector2, offset: Vector2, color: Color, r: float) -> void:
	draw_circle(center + offset, r, color)
