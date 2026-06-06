extends Control
class_name DynamicCrosshair
## Dynamic spread crosshair drawn in code: four ticks that widen with movement and
## firing recoil and tighten when still or aiming (ADS). Turns red when an enemy is
## under the reticle. Pure HUD feedback — listens to the Events bus + the local player.

var _spread: float = 8.0
var _recoil: float = 0.0
var _ads: bool = false
var _player: Node3D = null
var _camera: Camera3D = null
var _controller: Node = null      # WeaponController under the bound player (for the real cone)
var _on_enemy: bool = false

const BASE_SPREAD := 6.0
const MOVE_SPREAD := 12.0
const TICK_LEN := 6.0
const TICK_W := 2.0

# Degrees → pixels mapping for the REAL fire cone (current_spread_deg). The gap is
# the minimum tick offset plus a per-degree widening, so a tight 0.6° rifle reads
# as a near-centered reticle and a moving/sprinting/shotgun cone opens up clearly.
const MIN_GAP := 4.0          # px gap at ~0° spread (ADS pinpoint)
const PX_PER_DEG := 7.0       # px added per degree of effective spread


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Events.local_player_spawned.connect(_bind_player)
	Events.ads_changed.connect(func(_p, a): _ads = a)
	Events.weapon_fired.connect(func(_s, _id): _recoil = minf(_recoil + 4.0, 16.0))
	if _player == null:
		_bind_player(_find_local_player())


func _bind_player(p: Node) -> void:
	_player = p as Node3D
	_controller = null
	if _player:
		_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
		_controller = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D/WeaponController")


func _find_local_player() -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if p.has_method("is_multiplayer_authority") and p.is_multiplayer_authority():
			return p
	return null


func _process(delta: float) -> void:
	_recoil = maxf(0.0, _recoil - delta * 28.0)
	var target: float
	# Prefer the REAL effective cone from the weapon controller (base × stance ×
	# movement × ADS) mapped to pixels; the recoil bump rides on top. If the
	# controller isn't reachable (not bound yet / not the local player), fall back
	# to the old movement-based estimate so the reticle never breaks.
	if _controller != null and _controller.has_method("current_spread_deg"):
		var deg: float = float(_controller.current_spread_deg())
		target = MIN_GAP + deg * PX_PER_DEG + _recoil
	else:
		var moving := 0.0
		if is_instance_valid(_player):
			var v: Vector3 = _player.velocity
			moving = clampf(Vector2(v.x, v.z).length() / maxf(Settings.PLAYER_MOVE_SPEED, 0.1), 0.0, 1.0)
		target = BASE_SPREAD + moving * MOVE_SPREAD + _recoil
		if _ads:
			target = 2.0
	_spread = lerpf(_spread, target, clampf(delta * 12.0, 0.0, 1.0))
	_update_on_enemy()
	queue_redraw()


func _update_on_enemy() -> void:
	_on_enemy = false
	if not is_instance_valid(_camera):
		return
	var from := _camera.global_position
	var to := from - _camera.global_transform.basis.z * 120.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 0b1000100   # enemy(3) + hurtbox(7)
	q.collide_with_areas = true
	var hit := _camera.get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		var c: Node = hit["collider"]
		while c != null:
			if c.is_in_group("enemies"):
				_on_enemy = true
				return
			c = c.get_parent()


func _draw() -> void:
	var c := size * 0.5
	var col := Color(1.0, 0.32, 0.3, 0.95) if _on_enemy else Color(1, 1, 1, 0.9)
	var s := _spread
	draw_line(c + Vector2(s, 0), c + Vector2(s + TICK_LEN, 0), col, TICK_W)
	draw_line(c - Vector2(s, 0), c - Vector2(s + TICK_LEN, 0), col, TICK_W)
	draw_line(c + Vector2(0, s), c + Vector2(0, s + TICK_LEN), col, TICK_W)
	draw_line(c - Vector2(0, s), c - Vector2(0, s + TICK_LEN), col, TICK_W)
	if _ads:
		draw_circle(c, 1.6, col)
