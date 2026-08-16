extends Node
class_name PlayerPadLook
## Right-stick camera look, as an EXTERNAL component.
##
## Mouse look lives in `player.gd`, which sits five lines under the 1800-line gdlint ceiling —
## so stick look could not go there. It does not need to: this writes the SAME two transforms
## the agent-harness look path already writes (body `rotation.y` for yaw, `SpringArm3D.rotation.x`
## for pitch, clamped by `Settings.CAMERA_PITCH_*`), which is the proven way to steer this
## camera from outside the controller. The component therefore costs `player.gd` a single
## attach line and owns everything else, the same shape as `PlayerHijack` and `PlayerSkills`.
##
## Purely local input: nothing here is networked, and it runs only for the authority player.
##
## STICK FEEL. A stick is not a mouse — it reports a POSITION, not a delta, so the raw value
## has to become a rate. Three things make that read well and all three are load-bearing:
##   * a response curve, so small pushes aim and full pushes turn (linear sticks feel twitchy
##     near centre and slow at the edge);
##   * per-frame integration with delta, so the turn rate is framerate-independent;
##   * an ADS multiplier, because the same sensitivity that turns fast feels uncontrollable
##     through a scope.
## The InputMap deadzone (0.2 on the look actions) handles stick slop before we ever see it.

## Degrees per second at full deflection.
const YAW_RATE := 190.0
const PITCH_RATE := 140.0
## Response exponent: 1.0 is linear, higher gives finer control near centre.
const CURVE := 2.0
## Aiming down sights slows the stick to what a scope can actually track.
const ADS_MULT := 0.45

var _player: Node3D = null
var _arm: Node3D = null


## Give `player` a stick-look component. Called once from `player.gd` _ready, like the other
## external components. Safe to call twice — the second call is a no-op.
static func attach(player: Node) -> void:
	if player == null or player.has_node("PadLook"):
		return
	var n := PlayerPadLook.new()
	n.name = "PadLook"
	player.add_child(n)


func _ready() -> void:
	_player = get_parent() as Node3D
	if _player == null:
		set_process(false)
		return
	_arm = _player.get_node_or_null("CameraPivot/SpringArm3D") as Node3D
	# Only the local player reads input, and only when a pad is actually present. The
	# connect keeps a controller plugged in mid-raid working without a restart.
	set_process(_is_mine() and not Input.get_connected_joypads().is_empty())
	if not Input.joy_connection_changed.is_connected(_on_joy_changed):
		Input.joy_connection_changed.connect(_on_joy_changed)


func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_on_joy_changed):
		Input.joy_connection_changed.disconnect(_on_joy_changed)


func _on_joy_changed(_device: int, _connected: bool) -> void:
	set_process(_is_mine() and not Input.get_connected_joypads().is_empty())


func _is_mine() -> bool:
	if _player == null:
		return false
	return not _player.has_method("is_multiplayer_authority") or _player.is_multiplayer_authority()


## Signed stick value with the response curve applied, sign preserved.
func _axis(neg: String, pos: String) -> float:
	var v: float = Input.get_axis(neg, pos)
	return signf(v) * pow(absf(v), CURVE)


func _process(delta: float) -> void:
	if _arm == null or not is_instance_valid(_player):
		return
	# A downed or input-locked player must not steer — mirrors the mouse-look gate.
	if _player.get("_input_enabled") == false:
		return
	var yaw: float = _axis("look_left", "look_right")
	var pitch: float = _axis("look_up", "look_down")
	if is_zero_approx(yaw) and is_zero_approx(pitch):
		return
	var mult: float = ADS_MULT if bool(_player.get("_ads")) else 1.0
	_player.rotation.y -= deg_to_rad(yaw * YAW_RATE * mult * delta)
	_arm.rotation.x = clampf(
		_arm.rotation.x - deg_to_rad(pitch * PITCH_RATE * mult * delta),
		Settings.CAMERA_PITCH_MIN,
		Settings.CAMERA_PITCH_MAX
	)
