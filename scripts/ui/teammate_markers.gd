extends CanvasLayer
class_name TeammateMarkers
## Co-op teammate on-screen indicators. For each OTHER player: a subtle always-on nameplate
## above their head when on-screen (green chevron + nickname, alpha fading with distance), or a
## green screen-edge arrow when off-screen. Downed teammates read AMBER so a buddy who needs a
## revive is easy to find. Pure-local rendering; single-player draws nothing. Headless-safe.
##
## INSTANCING: main.gd instances this once under UILayer (like PingSystem). Binds the local
## player's camera via Events.local_player_spawned + a fallback scan.

var _player: Node3D = null
var _camera: Camera3D = null
var _draw_ctrl: Control = null


func _ready() -> void:
	layer = 6  # same band as PingSystem (above hit-marker, below the map)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_draw_ctrl = Control.new()
	_draw_ctrl.name = "Draw"
	_draw_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_draw_ctrl.draw.connect(_on_draw)
	add_child(_draw_ctrl)
	if not Events.local_player_spawned.is_connected(_on_local_player_spawned):
		Events.local_player_spawned.connect(_on_local_player_spawned)
	_bind_existing_player()


func _process(_delta: float) -> void:
	_draw_ctrl.queue_redraw()


# --- local-player binding (mirrors PingSystem) ------------------------------
func _on_local_player_spawned(player: Node) -> void:
	_player = player as Node3D
	_camera = null


func _bind_existing_player() -> void:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p is Node3D and _is_local(p):
			_player = p as Node3D
			return


func _is_local(player: Node) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	if not player.has_method("get_multiplayer_authority"):
		return true
	return player.get_multiplayer_authority() == multiplayer.get_unique_id()


func _resolve_camera() -> Camera3D:
	if is_instance_valid(_camera):
		return _camera
	if not is_instance_valid(_player):
		_bind_existing_player()
	if is_instance_valid(_player):
		_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	return _camera


# --- draw -------------------------------------------------------------------
func _on_draw() -> void:
	var cam := _resolve_camera()
	if cam == null or not is_instance_valid(_player):
		return
	var screen: Vector2 = _draw_ctrl.size
	if screen.x <= 0.0 or screen.y <= 0.0:
		return
	var font := ThemeDB.fallback_font
	var center := screen * 0.5
	var margin := 28.0
	var rect := Rect2(Vector2(margin, margin), screen - Vector2(margin, margin) * 2.0)
	var ppos: Vector3 = _player.global_position

	for t in TeammateUtil.list(get_tree()):
		var tnode: Node3D = t["node"]
		if not is_instance_valid(tnode):
			continue
		var col: Color = TeammateUtil.TEAM_DOWN if bool(t["downed"]) else TeammateUtil.TEAM_GREEN
		var head: Vector3 = tnode.global_position + Vector3.UP * TeammateUtil.HEAD_OFFSET
		var behind := cam.is_position_behind(head)
		var sp := cam.unproject_position(head)
		var on_screen := (not behind) and rect.has_point(sp)
		if on_screen:
			# Distance-faded so a nearby squad doesn't clutter the view (near≈0.85 → far≈0.35).
			var dist: float = ppos.distance_to(tnode.global_position)
			var a: float = clampf(0.9 - dist / 90.0, 0.35, 0.85)
			_draw_nameplate(
				font, sp, String(t["name"]), Color(col.r, col.g, col.b, a), bool(t["downed"])
			)
		else:
			var dir := sp - center
			if behind:
				dir = -dir
			if dir.length() < 0.001:
				dir = Vector2(0, -1)
			var edge := _edge_point(center, dir.normalized(), rect)
			_draw_edge_arrow(edge, dir.normalized(), Color(col.r, col.g, col.b, 0.85))


## A small downward chevron + the nickname above the teammate's head (subtle, outlined).
func _draw_nameplate(font: Font, p: Vector2, label: String, col: Color, downed: bool) -> void:
	# Chevron ▽ pointing down at the head.
	_draw_ctrl.draw_colored_polygon(
		PackedVector2Array([p + Vector2(-5, -10), p + Vector2(5, -10), p + Vector2(0, -3)]), col
	)
	_draw_ctrl.draw_polyline(
		PackedVector2Array(
			[p + Vector2(-5, -10), p + Vector2(5, -10), p + Vector2(0, -3), p + Vector2(-5, -10)]
		),
		Color(0, 0, 0, col.a * 0.6),
		1.0,
		true
	)
	var name_text := label
	if downed:
		name_text = label + "  ⚑"  # downed flag
	var fs := 12
	var tw := font.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var lp := p + Vector2(-tw * 0.5, -14.0)
	_draw_ctrl.draw_string(
		font,
		lp + Vector2(1, 1),
		name_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		fs,
		Color(0, 0, 0, col.a * 0.7)
	)
	_draw_ctrl.draw_string(font, lp, name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw_edge_arrow(p: Vector2, dir: Vector2, col: Color) -> void:
	var side := Vector2(-dir.y, dir.x)
	var tip := p + dir * 12.0
	var a := p - dir * 6.0 + side * 8.0
	var b := p - dir * 6.0 - side * 8.0
	_draw_ctrl.draw_colored_polygon(PackedVector2Array([tip, a, b]), col)
	_draw_ctrl.draw_polyline(
		PackedVector2Array([tip, a, b, tip]), Color(0, 0, 0, col.a * 0.6), 1.5, true
	)


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
