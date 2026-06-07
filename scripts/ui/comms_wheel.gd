extends CanvasLayer
class_name CommsWheel
## Apex-style radial COMMS WHEEL of quick squad messages. HOLD `comms_wheel` (Z) to
## open a radial menu; the mouse selects the nearest wedge; RELEASE fires the matching
## ping via NetworkManager.broadcast_ping(kind, world_pos, target_path). The world_pos
## is a point in front of the player (or the player's own position for Help/Regroup) so
## the squad sees a contextual marker — the PingSystem renders it for everyone.
##
## This is multiplayer, so it does NOT pause the game; it's just an overlay. The wheel
## Control's mouse_filter is STOP while open, IGNORE while hidden. A downed player can
## still open the wheel and comm (no alive/downed gate).
##
## INSTANCING: the lead instances CommsWheel.tscn (root = this script, named "CommsWheel")
## once under main.gd's UILayer. No configuration needed; it finds the local player via
## Events.local_player_spawned (+ a fallback scan of the "players" group).
##
## Headless-safe: guards on a missing viewport/player.

# Each option: { "label": String, "kind": int, "at_player": bool, "color": Color }.
# at_player → the marker sits on the local player (Help / Regroup / Need Ammo);
# otherwise it sits ~6 m in front along the camera aim.
const OPTIONS := [
	{ "label": "Going Here", "kind": 0, "at_player": false, "color": Color(1, 1, 1) },
	{ "label": "Enemy",      "kind": 1, "at_player": false, "color": Color(1.0, 0.28, 0.28) },
	{ "label": "Need Ammo",  "kind": 4, "at_player": true,  "color": Color(1.0, 0.78, 0.3) },
	{ "label": "Help!",      "kind": 4, "at_player": true,  "color": Color(1.0, 0.55, 0.15) },
	{ "label": "Regroup",    "kind": 6, "at_player": true,  "color": Color(0.55, 0.75, 1.0) },
	{ "label": "Thanks",     "kind": 5, "at_player": false, "color": Color(0.7, 0.9, 1.0) },
]

const RADIUS := 150.0          # wheel radius (px)
const INNER := 52.0            # dead-zone radius (no selection inside)
const FRONT_DIST := 6.0        # how far ahead "Going Here"/"Enemy" markers land (m)

var _player: Node3D = null
var _camera: Camera3D = null
var _open := false
var _selected := -1
var _wheel: Control = null

func _ready() -> void:
	layer = 7   # above the ping markers (6), below the map/pause
	process_mode = Node.PROCESS_MODE_ALWAYS

	_wheel = Control.new()
	_wheel.name = "Wheel"
	_wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE   # IGNORE while hidden
	_wheel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wheel.draw.connect(_on_draw)
	add_child(_wheel)
	visible = false

	if not Events.local_player_spawned.is_connected(_on_local_player_spawned):
		Events.local_player_spawned.connect(_on_local_player_spawned)
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
	if is_instance_valid(_camera):
		return _camera
	if not is_instance_valid(_player):
		_bind_existing_player()
	if is_instance_valid(_player):
		_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if is_instance_valid(_camera):
		return _camera
	var vp := get_viewport()
	if vp != null:
		return vp.get_camera_3d()
	return null

# --- open/close on hold -----------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("comms_wheel"):
		_open_wheel()
		get_viewport().set_input_as_handled()
	elif event.is_action_released("comms_wheel"):
		_close_wheel(true)
		get_viewport().set_input_as_handled()

func _open_wheel() -> void:
	if _open:
		return
	_open = true
	visible = true
	_selected = -1
	_wheel.mouse_filter = Control.MOUSE_FILTER_STOP
	if _wheel:
		_wheel.queue_redraw()

## close + (optionally) fire the selected option's ping.
func _close_wheel(fire: bool) -> void:
	if not _open:
		return
	_open = false
	visible = false
	_wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if fire and _selected >= 0 and _selected < OPTIONS.size():
		_fire_option(_selected)
	_selected = -1

# --- selection (per-frame from the mouse) -----------------------------------

func _process(_delta: float) -> void:
	if not _open or _wheel == null:
		return
	var center := _wheel.size * 0.5
	var mp := _wheel.get_local_mouse_position()
	var v := mp - center
	var prev := _selected
	if v.length() < INNER:
		_selected = -1
	else:
		# atan2 with screen-down y: 0 at top, increasing clockwise.
		var ang := atan2(v.x, -v.y)
		if ang < 0.0:
			ang += TAU
		var n := OPTIONS.size()
		_selected = int(round(ang / TAU * float(n))) % n
	if _selected != prev:
		_wheel.queue_redraw()

# --- fire the chosen comm ---------------------------------------------------

func _fire_option(idx: int) -> void:
	var opt: Dictionary = OPTIONS[idx]
	var kind := int(opt.get("kind", 0))
	var at_player := bool(opt.get("at_player", false))
	var world_pos := _comm_world_pos(at_player)
	NetworkManager.broadcast_ping(kind, world_pos, NodePath())

## Where the comm's marker lands: on the local player (Help/Regroup/Ammo) or ~FRONT_DIST
## metres ahead along the camera aim (Going Here / Enemy). Falls back to the player
## position, then origin, if no camera/player is bound.
func _comm_world_pos(at_player: bool) -> Vector3:
	var base := Vector3.ZERO
	if is_instance_valid(_player):
		base = _player.global_position + Vector3.UP * 1.0
	if at_player:
		return base
	var cam := _resolve_camera()
	if cam != null:
		var dir := -cam.global_transform.basis.z
		return cam.global_position + dir * FRONT_DIST
	return base

# --- drawing ---------------------------------------------------------------

func _on_draw() -> void:
	if _wheel == null or not _open:
		return
	var screen: Vector2 = _wheel.size
	if screen.x <= 0.0 or screen.y <= 0.0:
		return
	var font := ThemeDB.fallback_font
	var center := screen * 0.5

	# Dim backdrop so the wheel reads over the world.
	_wheel.draw_rect(Rect2(Vector2.ZERO, screen), Color(0.0, 0.0, 0.0, 0.28), true)
	# Hub ring.
	_wheel.draw_arc(center, RADIUS, 0.0, TAU, 64, Color(0.6, 0.75, 0.85, 0.5), 2.0, true)
	_wheel.draw_circle(center, INNER, Color(0.05, 0.08, 0.11, 0.7))
	_wheel.draw_arc(center, INNER, 0.0, TAU, 40, Color(0.5, 0.65, 0.78, 0.5), 1.5, true)

	var n := OPTIONS.size()
	for i in range(n):
		var opt: Dictionary = OPTIONS[i]
		var col: Color = opt.get("color", Color.WHITE)
		var ang := float(i) / float(n) * TAU            # 0 = up, clockwise
		var d := Vector2(sin(ang), -cos(ang))
		var slot := center + d * (RADIUS * 0.66)
		var picked := (i == _selected)
		var r: float = 26.0 if picked else 20.0
		var bg: Color = Color(col.r, col.g, col.b, 0.95) if picked else Color(col.r * 0.5, col.g * 0.5, col.b * 0.5, 0.7)
		_wheel.draw_circle(slot, r, bg)
		_wheel.draw_arc(slot, r, 0.0, TAU, 24, Color(col.r, col.g, col.b, 0.95), 2.0, true)
		# Label centered under the slot.
		var label: String = tr(str(opt.get("label", "")))
		var fs: int = 14 if picked else 12
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var lp := slot + Vector2(-tw * 0.5, r + 14.0)
		var tcol: Color = Color(1, 1, 1, 1.0) if picked else Color(0.85, 0.9, 0.95, 0.85)
		_wheel.draw_string(font, lp + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.6))
		_wheel.draw_string(font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, tcol)

	# Center hint.
	var hint := tr("COMMS")
	var hw := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	_wheel.draw_string(font, center + Vector2(-hw * 0.5, 4.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.82, 0.92, 0.8))
