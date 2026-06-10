extends Control
class_name DamageIndicator
## Local-player damage feedback. Two layers, both drawn in code (full-rect overlay):
##   (a) Directional damage arcs — when the local player is hit, a red wedge points
##       toward the attacker, placed by the horizontal bearing from the player to the
##       source RELATIVE to camera yaw. Each arc fades over ~1s.
##   (b) Low-HP vignette — red screen-edge glow whose alpha rises as health drops
##       below ~35%, pulsing subtly. Dark sci-fi theme (danger red #d84540).

const DANGER := Color(0.847, 0.271, 0.251)  # #d84540 — low-HP edge vignette
const BLOOD := Color(0.74, 0.08, 0.06)      # directional blood arc (deep red)
const ARC_TTL := 1.8
const ARC_INNER := 64.0
const ARC_OUTER := 150.0
# Wedge half-width + peak alpha scale with the damage amount (UX: weak hit = narrow
# & dim, heavy hit = wide & bright). ARC_DMG_FULL is the damage that maps to a full arc.
const ARC_HALF_MIN := deg_to_rad(20.0)
const ARC_HALF_MAX := deg_to_rad(44.0)
const ARC_ALPHA_MIN := 0.70
const ARC_ALPHA_MAX := 1.0
const ARC_DMG_FULL := 25.0
const LOW_HP_RATIO := 0.35

var _player: Node3D = null
var _camera: Camera3D = null
var _hp_ratio: float = 1.0
var _pulse: float = 0.0

# Each arc: { "angle": float (screen radians, 0 = up/forward), "t": float }
var _arcs: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Events.local_player_spawned.connect(_bind_player)
	Events.damage_dealt.connect(_on_damage_dealt)
	Events.player_health_changed.connect(_on_health_changed)
	if _player == null:
		_bind_player(_find_local_player())


func _bind_player(p: Node) -> void:
	_player = p as Node3D
	if _player:
		_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D")


func _find_local_player() -> Node:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p.has_method("is_multiplayer_authority") and p.is_multiplayer_authority():
			return p
	return null


func _is_local(n: Node) -> bool:
	return n != null and (n == _player or _player == null)


func _on_health_changed(player: Node, current: float, max_health: float) -> void:
	if _player != null and player != _player:
		return
	_hp_ratio = clampf(current / maxf(max_health, 0.001), 0.0, 1.0)


func _on_damage_dealt(target: Node, amount: float, source: Node) -> void:
	if not _is_local(target):
		return
	# Only draw a directional arc when we actually KNOW the direction. Ambiguous /
	# sourceless damage (AoE, source=null) is left to the centred hurt-flash so we
	# never point a confident blood arrow the wrong way.
	if not (is_instance_valid(_player) and source is Node3D):
		return
	# Bearing from the player to the attacker, on the horizontal plane, made relative
	# to where the camera is looking so the wedge points correctly on screen.
	var to_src: Vector3 = (source as Node3D).global_position - _player.global_position
	var world_bearing := atan2(to_src.x, -to_src.z)   # 0 = -Z (forward), CW
	var cam_yaw := _player.rotation.y
	if is_instance_valid(_camera):
		cam_yaw = _camera.global_rotation.y
	var angle := wrapf(world_bearing - cam_yaw, -PI, PI)
	_arcs.append({"angle": angle, "t": ARC_TTL, "amt": maxf(amount, 0.0)})
	if _arcs.size() > 8:
		_arcs.pop_front()


func _process(delta: float) -> void:
	var dirty := false
	for a in _arcs:
		a["t"] -= delta
		dirty = true
	if not _arcs.is_empty():
		_arcs = _arcs.filter(func(a): return a["t"] > 0.0)
	if _hp_ratio < LOW_HP_RATIO:
		_pulse += delta
		dirty = true
	if dirty:
		queue_redraw()


func _draw() -> void:
	# This Control is added to the HUD by script (no scene layout), so its own size
	# can stay (0,0) — drive everything off the actual viewport size so the centre and
	# edges are always correct.
	var vp := get_viewport_rect().size
	var c := vp * 0.5
	# (b) Low-HP vignette: red border that thickens/brightens as HP falls.
	if _hp_ratio < LOW_HP_RATIO:
		var sev := clampf((LOW_HP_RATIO - _hp_ratio) / LOW_HP_RATIO, 0.0, 1.0)
		var pulse := 0.85 + 0.15 * sin(_pulse * 6.0)
		var base_a := sev * 0.5 * pulse
		var band := lerpf(40.0, 140.0, sev)
		# Layered translucent rectangles along each edge approximate an inward fade.
		var steps := 6
		for i in steps:
			var f := float(i) / float(steps)
			var a := base_a * (1.0 - f)
			var col := Color(DANGER.r, DANGER.g, DANGER.b, a)
			var t := band * (1.0 - f)
			draw_rect(Rect2(0, 0, vp.x, t), col, true)                       # top
			draw_rect(Rect2(0, vp.y - t, vp.x, t), col, true)               # bottom
			draw_rect(Rect2(0, 0, t, vp.y), col, true)                       # left
			draw_rect(Rect2(vp.x - t, 0, t, vp.y), col, true)              # right
	# (a) Directional blood arcs — a filled wedge pointing at the attacker, brightest
	# at the outer rim and feathering to transparent inward.
	for a in _arcs:
		var fade: float = clampf(a["t"] / ARC_TTL, 0.0, 1.0)
		var dmg_f: float = clampf(float(a.get("amt", 10.0)) / ARC_DMG_FULL, 0.15, 1.0)
		var half: float = lerpf(ARC_HALF_MIN, ARC_HALF_MAX, dmg_f)
		var peak: float = lerpf(ARC_ALPHA_MIN, ARC_ALPHA_MAX, dmg_f) * fade
		# Screen angle: 0 rad = straight up. Godot draw angles measure from +X CW (y down).
		var screen_ang: float = (a["angle"] as float) - PI * 0.5
		# Spread outward slightly as it fades, like a smear.
		var ro: float = ARC_OUTER + (1.0 - fade) * 22.0
		_draw_blood_wedge(c, screen_ang, half, ARC_INNER, ro, peak)


## Fills an annular sector (the blood arc) as a fan of convex quads — bright/opaque
## at the outer rim, transparent at the inner rim — so it reads as a gradient smear
## pointing toward `screen_ang`. A crisp outer-rim stroke sharpens the direction.
## (Per-quad fill is used instead of one concave polygon, which can mis-triangulate.)
func _draw_blood_wedge(c: Vector2, screen_ang: float, half: float, ri: float, ro: float, alpha: float) -> void:
	if alpha <= 0.001:
		return
	var steps := 18
	var col_out := Color(BLOOD.r, BLOOD.g, BLOOD.b, alpha)
	var col_in := Color(BLOOD.r, BLOOD.g, BLOOD.b, 0.0)
	for i in steps:
		var a0: float = screen_ang - half + (2.0 * half) * (float(i) / steps)
		var a1: float = screen_ang - half + (2.0 * half) * (float(i + 1) / steps)
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		var quad := PackedVector2Array([c + d0 * ri, c + d0 * ro, c + d1 * ro, c + d1 * ri])
		var cols := PackedColorArray([col_in, col_out, col_out, col_in])
		draw_polygon(quad, cols)
	# Crisp bright rim along the outer edge for a clear directional read.
	var rim := Color(1.0, 0.25, 0.18, alpha)
	draw_arc(c, ro, screen_ang - half, screen_ang + half, steps, rim, 3.0, true)
