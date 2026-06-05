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
	Events.local_player_spawned.connect(func(p): _player = p as Node3D)
	Events.extraction_window_changed.connect(_on_window_changed)


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


func _process(delta: float) -> void:
	_pulse += delta
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	draw_circle(c, RADIUS, Color(0.03, 0.05, 0.07, 0.8))
	draw_arc(c, RADIUS, 0.0, TAU, 48, Color(0.5, 0.7, 0.85, 0.9), 2.5)
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
	# Player (centre, facing up).
	draw_circle(c, 3.5, Color(0.4, 0.8, 1.0))


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
