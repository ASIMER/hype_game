extends CanvasLayer
class_name PingSystem
## Apex-style contextual PING system. The LOCAL player presses `ping` (middle mouse) →
## we raycast from the camera and classify what it hit (enemy / loot / extraction /
## world point), then call NetworkManager.broadcast_ping(kind, world_pos, target_path).
## EVERY peer (incl. the pinger, via call_local) then receives Events.ping_placed and
## spawns a world-anchored screen marker that the whole squad sees.
##
## A DOWNED player can still ping — we deliberately do NOT gate on alive/downed.
##
## Pure-local rendering driven by the networked ping_placed broadcast. No new netcode.
## Headless-safe: guards on a missing camera/viewport and simply never draws.
##
## INSTANCING: the lead instances PingSystem.tscn (root = this script, named "PingSystem")
## once under main.gd's UILayer. It needs no configuration; it finds the local player via
## Events.local_player_spawned (and a fallback scan of the "players" group).

# --- ping kinds (frozen contract — see Events.ping_placed / NetworkManager.broadcast_ping)
const KIND_GENERIC := 0      # go here
const KIND_ENEMY := 1
const KIND_LOOT := 2
const KIND_EXTRACTION := 3
const KIND_HELP := 4         # help / danger
const KIND_THANKS := 5
const KIND_REGROUP := 6

# How long a marker lives (seconds). Enemy/help linger a little longer.
const TTL_DEFAULT := 8.0
const TTL_LONG := 12.0
# Most we keep on screen at once; oldest drops when exceeded.
const MAX_MARKERS := 12
# Raycast reach for classifying the ping target.
const PING_RANGE := 120.0
# Camera collision_mask: world(layer1=1) | enemy(layer3=4) | loot(layer4=8) | extraction(layer5=16).
const PING_MASK := 1 | 4 | 8 | 16

# One live marker.
class Marker:
	var peer_id: int = 0
	var kind: int = 0
	var world_pos: Vector3 = Vector3.ZERO
	var target: Node3D = null       # resolved from target_path if it pointed at a live node
	var t: float = 0.0              # remaining lifetime
	var ttl: float = TTL_DEFAULT
	var label: String = ""

var _player: Node3D = null
var _camera: Camera3D = null
var _markers: Array[Marker] = []
var _draw_ctrl: Control = null

func _ready() -> void:
	layer = 6   # above the hit-marker (5), below the map (80) / pause menus
	process_mode = Node.PROCESS_MODE_ALWAYS

	_draw_ctrl = Control.new()
	_draw_ctrl.name = "Draw"
	_draw_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_draw_ctrl.draw.connect(_on_draw)
	add_child(_draw_ctrl)

	if not Events.local_player_spawned.is_connected(_on_local_player_spawned):
		Events.local_player_spawned.connect(_on_local_player_spawned)
	if not Events.ping_placed.is_connected(_on_ping_placed):
		Events.ping_placed.connect(_on_ping_placed)

	_bind_existing_player()

# --- local-player binding ---------------------------------------------------

func _on_local_player_spawned(player: Node) -> void:
	set_local_player(player)

func set_local_player(p: Node) -> void:
	_player = p as Node3D
	_camera = null
	if _player != null:
		_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D

func _bind_existing_player() -> void:
	for p in get_tree().get_nodes_in_group("players"):
		if p is Node3D and _is_local(p):
			set_local_player(p)
			return

func _is_local(player: Node) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	if not player.has_method("get_multiplayer_authority"):
		return true
	return player.get_multiplayer_authority() == multiplayer.get_unique_id()

func _resolve_camera() -> Camera3D:
	# Re-resolve lazily — the player may have spawned before we cached, or the cached
	# camera may have been freed on respawn.
	if is_instance_valid(_camera):
		return _camera
	if not is_instance_valid(_player):
		_bind_existing_player()
	if is_instance_valid(_player):
		_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if is_instance_valid(_camera):
		return _camera
	# Last resort: any current Camera3D in the viewport.
	var vp := get_viewport()
	if vp != null:
		return vp.get_camera_3d()
	return null

# --- input: place a ping ----------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ping"):
		_place_ping_from_camera()
		# Don't consume — a middle-click might be wanted elsewhere; harmless either way.

## Raycast from the camera, classify the hit, and broadcast it to the squad.
func _place_ping_from_camera() -> void:
	var cam := _resolve_camera()
	if cam == null:
		return
	var space := cam.get_world_3d().direct_space_state
	if space == null:
		return
	var origin := cam.global_position
	var dir := -cam.global_transform.basis.z
	var to := origin + dir * PING_RANGE

	var q := PhysicsRayQueryParameters3D.create(origin, to)
	q.collision_mask = PING_MASK
	q.collide_with_bodies = true
	q.collide_with_areas = true
	# Exclude the local player's body so we never ping ourselves.
	if is_instance_valid(_player) and _player is CollisionObject3D:
		q.exclude = [(_player as CollisionObject3D).get_rid()]

	var hit := space.intersect_ray(q)
	var kind := KIND_GENERIC
	var world_pos := to
	var target_path := NodePath()

	if hit:
		world_pos = hit.get("position", to)
		var collider: Object = hit.get("collider", null)
		var node := collider as Node
		var classified: Array = _classify(node)
		kind = int(classified[0])
		var anchor: Node = classified[1]
		if anchor != null and anchor is Node3D:
			target_path = (anchor as Node3D).get_path()
			# Anchor the marker on the node's centre, not the raw hit point.
			world_pos = (anchor as Node3D).global_position

	NetworkManager.broadcast_ping(kind, world_pos, target_path)

## Walk up from the hit node to find an enemy / pickup / extraction owner.
## Returns [kind:int, anchor_node:Node|null]. anchor_node is the owning gameplay node
## (so the marker can follow a moving enemy); null for a static world point.
func _classify(node: Node) -> Array:
	var n := node
	while n != null:
		if n.is_in_group("enemies"):
			return [KIND_ENEMY, n]
		if n.is_in_group("pickups") or n.is_in_group("loot"):
			return [KIND_LOOT, n]
		if n.is_in_group("extraction"):
			return [KIND_EXTRACTION, n]
		n = n.get_parent()
	return [KIND_GENERIC, null]

# --- receive a (networked or local) ping ------------------------------------

func _on_ping_placed(peer_id: int, kind: int, world_pos: Vector3, target_path: NodePath) -> void:
	var m := Marker.new()
	m.peer_id = peer_id
	m.kind = kind
	m.world_pos = world_pos
	m.ttl = TTL_LONG if (kind == KIND_ENEMY or kind == KIND_HELP) else TTL_DEFAULT
	m.t = m.ttl
	# Resolve a follow-target if the ping carried one (enemy/loot can move/despawn).
	if not target_path.is_empty():
		var node := get_node_or_null(target_path)
		if node is Node3D:
			m.target = node as Node3D
	m.label = _label_for(peer_id, kind)

	_markers.append(m)
	# Cap: drop the oldest.
	while _markers.size() > MAX_MARKERS:
		_markers.pop_front()

	if _draw_ctrl:
		_draw_ctrl.queue_redraw()

func _label_for(peer_id: int, kind: int) -> String:
	var who := _peer_name(peer_id)
	var what := _kind_text(kind)
	if who.is_empty():
		return what
	return "%s: %s" % [who, what]

func _peer_name(peer_id: int) -> String:
	var p: Variant = GameState.peers.get(peer_id, null)
	if p is Dictionary:
		return str((p as Dictionary).get("name", ""))
	return ""

func _kind_text(kind: int) -> String:
	match kind:
		KIND_ENEMY: return tr("Enemy")
		KIND_LOOT: return tr("Loot — dibs!")
		KIND_EXTRACTION: return tr("Extraction")
		KIND_HELP: return tr("Help!")
		KIND_THANKS: return tr("Thanks")
		KIND_REGROUP: return tr("Regroup")
		_: return tr("Going here")

func _color_for(kind: int) -> Color:
	match kind:
		KIND_ENEMY: return Color(1.0, 0.28, 0.28)
		KIND_LOOT: return Color(1.0, 0.82, 0.25)
		KIND_EXTRACTION: return Color(0.3, 1.0, 0.5)
		KIND_HELP: return Color(1.0, 0.55, 0.15)
		KIND_REGROUP: return Color(0.55, 0.75, 1.0)
		KIND_THANKS: return Color(0.7, 0.9, 1.0)
		_: return Color(1.0, 1.0, 1.0)

# --- per-frame -------------------------------------------------------------

func _process(delta: float) -> void:
	if _markers.is_empty():
		return
	var changed := false
	var i := _markers.size() - 1
	while i >= 0:
		var m: Marker = _markers[i]
		m.t -= delta
		# Keep the world position glued to a live follow-target.
		if is_instance_valid(m.target):
			m.world_pos = m.target.global_position
		if m.t <= 0.0:
			_markers.remove_at(i)
		i -= 1
	changed = true
	if changed and _draw_ctrl:
		_draw_ctrl.queue_redraw()

# --- drawing ---------------------------------------------------------------

func _on_draw() -> void:
	if _draw_ctrl == null or _markers.is_empty():
		return
	var cam := _resolve_camera()
	if cam == null:
		return
	var font := ThemeDB.fallback_font
	var screen: Vector2 = _draw_ctrl.size
	if screen.x <= 0.0 or screen.y <= 0.0:
		return
	var center := screen * 0.5
	# Margin to keep edge arrows fully on-screen.
	var margin := 28.0
	var rect := Rect2(Vector2(margin, margin), screen - Vector2(margin, margin) * 2.0)

	for m in _markers:
		var col := _color_for(m.kind)
		# Fade out over the final second of life.
		var alpha := clampf(m.t, 0.0, 1.0)
		col.a = alpha if alpha < 1.0 else 1.0

		var behind := cam.is_position_behind(m.world_pos)
		var sp := cam.unproject_position(m.world_pos)
		var on_screen := (not behind) and rect.has_point(sp)

		if on_screen:
			_draw_marker(font, sp, col, m.label, m.kind)
		else:
			# Off-screen (or behind) → directional arrow from the center toward it.
			var dir := sp - center
			if behind:
				# Behind the camera: unproject flips the direction; invert it.
				dir = -dir
			if dir.length() < 0.001:
				dir = Vector2(0, -1)
			var edge := _edge_point(center, dir.normalized(), rect)
			_draw_edge_arrow(edge, dir.normalized(), col)

## A diamond + ring + label at the projected screen point.
func _draw_marker(font: Font, p: Vector2, col: Color, label: String, _kind: int) -> void:
	var d := 9.0
	var pts := PackedVector2Array([
		p + Vector2(0, -d), p + Vector2(d, 0), p + Vector2(0, d), p + Vector2(-d, 0),
	])
	# Soft halo ring.
	_draw_ctrl.draw_arc(p, d + 5.0, 0.0, TAU, 20, Color(col.r, col.g, col.b, col.a * 0.5), 2.0, true)
	_draw_ctrl.draw_colored_polygon(pts, Color(col.r, col.g, col.b, col.a * 0.9))
	# Outline for contrast on bright backgrounds.
	pts.append(pts[0])
	_draw_ctrl.draw_polyline(pts, Color(0, 0, 0, col.a * 0.6), 1.5, true)
	# Label, centered above the marker with a subtle shadow.
	if label != "":
		var fs := 13
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var lp := p + Vector2(-tw * 0.5, -d - 8.0)
		_draw_ctrl.draw_string(font, lp + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, col.a * 0.7))
		_draw_ctrl.draw_string(font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col.r, col.g, col.b, col.a))

## A triangle arrow pinned to the screen edge, pointing toward the off-screen ping.
func _draw_edge_arrow(p: Vector2, dir: Vector2, col: Color) -> void:
	var side := Vector2(-dir.y, dir.x)
	var tip := p + dir * 12.0
	var a := p - dir * 6.0 + side * 8.0
	var b := p - dir * 6.0 - side * 8.0
	_draw_ctrl.draw_colored_polygon(PackedVector2Array([tip, a, b]), Color(col.r, col.g, col.b, col.a))
	_draw_ctrl.draw_polyline(PackedVector2Array([tip, a, b, tip]), Color(0, 0, 0, col.a * 0.6), 1.5, true)

## Where a ray from `center` in `dir` first crosses the clamp rect — used to pin the
## off-screen arrow to the nearest screen edge.
func _edge_point(center: Vector2, dir: Vector2, rect: Rect2) -> Vector2:
	var tmin := INF
	# Vertical edges (x = left/right).
	if absf(dir.x) > 0.0001:
		var xs: Array[float] = [rect.position.x, rect.position.x + rect.size.x]
		for ex in xs:
			var t: float = (ex - center.x) / dir.x
			if t > 0.0:
				var y: float = center.y + dir.y * t
				if y >= rect.position.y - 0.5 and y <= rect.position.y + rect.size.y + 0.5:
					tmin = minf(tmin, t)
	# Horizontal edges (y = top/bottom).
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
