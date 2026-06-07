extends Control
class_name Compass
## Horizontal compass strip across the TOP centre. Tick marks + N/E/S/W letters scroll
## with the local player's heading (player.rotation.y). Extraction zones (group
## "extraction") are projected onto the strip by bearing as green markers, clamped to
## the edges with an off-screen arrow when behind/beside the player. Dark sci-fi theme.

const STRIP_W := 360.0
const STRIP_H := 26.0
const TOP := 12.0
const FOV := deg_to_rad(120.0)     # angular span shown across the strip width
const TICK_COL := Color(UIStyle.TEXT.r, UIStyle.TEXT.g, UIStyle.TEXT.b, 0.55)
const CARD_COL := Color(UIStyle.TEXT.r, UIStyle.TEXT.g, UIStyle.TEXT.b, 0.95)
const AMBER := UIStyle.AMBER                         # centre marker
const EXTRACT_COL := Color(0.3, 1.0, 0.5)           # green

var _player: Node3D = null

# Cardinal directions as world bearings (0 = -Z forward/North, CW positive).
const CARDINALS := [
	{"label": "N", "bearing": 0.0},
	{"label": "E", "bearing": PI * 0.5},
	{"label": "S", "bearing": PI},
	{"label": "W", "bearing": -PI * 0.5},
]


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -STRIP_W * 0.5
	offset_right = STRIP_W * 0.5
	offset_top = TOP
	offset_bottom = TOP + STRIP_H
	Events.local_player_spawned.connect(_bind_player)
	if _player == null:
		_bind_player(_find_local_player())


func _bind_player(p: Node) -> void:
	_player = p as Node3D


func _find_local_player() -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if p.has_method("is_multiplayer_authority") and p.is_multiplayer_authority():
			return p
	return null


func _process(_delta: float) -> void:
	queue_redraw()


## Maps a world bearing to an x offset on the strip given the player's heading.
## Returns x in [0, STRIP_W]; rel is the signed angular delta (for clamping).
func _bearing_to_x(world_bearing: float, heading: float) -> Dictionary:
	var rel := wrapf(world_bearing - heading, -PI, PI)
	var x := STRIP_W * 0.5 + (rel / (FOV * 0.5)) * (STRIP_W * 0.5)
	return {"x": x, "rel": rel}


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var cx := STRIP_W * 0.5
	# Backing strip: glass-toned bg + amber accent border + thin light inner edge.
	draw_rect(Rect2(0, 0, STRIP_W, STRIP_H),
		Color(UIStyle.GLASS_BG.r, UIStyle.GLASS_BG.g, UIStyle.GLASS_BG.b, 0.82), true)
	draw_rect(Rect2(0, 0, STRIP_W, STRIP_H),
		Color(AMBER.r, AMBER.g, AMBER.b, 0.45), false, 1.0)
	draw_rect(Rect2(1, 1, STRIP_W - 2, STRIP_H - 2), UIStyle.BORDER_LT, false, 0.5)
	# Centre marker (the heading you're facing).
	draw_line(Vector2(cx, 0), Vector2(cx, STRIP_H), AMBER, 1.5)
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 4, 0), Vector2(cx + 4, 0), Vector2(cx, 5)]), AMBER)

	if not is_instance_valid(_player):
		return
	var heading := _player.rotation.y

	# Degree ticks every 15deg, taller every 45deg.
	var step := deg_to_rad(15.0)
	var b := -PI
	while b < PI:
		var info := _bearing_to_x(b, heading)
		var x: float = info["x"]
		if x >= 0.0 and x <= STRIP_W:
			var major := absf(fmod(b + TAU, deg_to_rad(45.0))) < 0.01 \
				or absf(fmod(b + TAU, deg_to_rad(45.0)) - deg_to_rad(45.0)) < 0.01
			var h := 9.0 if major else 5.0
			draw_line(Vector2(x, STRIP_H - h), Vector2(x, STRIP_H), TICK_COL, 1.0)
		b += step

	# Cardinal letters.
	for card in CARDINALS:
		var info := _bearing_to_x(card["bearing"], heading)
		var x: float = info["x"]
		if x >= 4.0 and x <= STRIP_W - 4.0:
			draw_string(font, Vector2(x - 5.0, STRIP_H - 11.0),
				card["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, CARD_COL)

	# Extraction zone markers.
	for z in get_tree().get_nodes_in_group("extraction"):
		if not (z is Node3D):
			continue
		var pos := (z as Node3D).global_position
		var to := pos - _player.global_position
		var world_bearing := atan2(to.x, -to.z)
		var info := _bearing_to_x(world_bearing, heading)
		var rel: float = info["rel"]
		var x: float = clampf(info["x"], 6.0, STRIP_W - 6.0)
		var y := 6.0
		# On-strip downward triangle marker.
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - 5, y - 4), Vector2(x + 5, y - 4), Vector2(x, y + 4)]), EXTRACT_COL)
		# Off-screen: a sideways arrow at the clamped edge.
		if absf(rel) > FOV * 0.5:
			var dir := 1.0 if rel > 0.0 else -1.0
			var ax := x + dir * 8.0
			draw_colored_polygon(PackedVector2Array([
				Vector2(ax, y - 4), Vector2(ax, y + 4),
				Vector2(ax + dir * 5.0, y)]), EXTRACT_COL)
