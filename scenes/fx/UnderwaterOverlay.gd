extends CanvasLayer
## Full-screen underwater post-processing for the LOCAL player. A high-layer ColorRect
## running shaders/underwater.gdshader (blue-green tint + screen wobble + vignette); its
## `strength` ramps 0 -> 1 as the local player goes DRY -> WADING (slight) -> SUBMERGED
## (full). Purely cosmetic + LOCAL: it only reacts to the local authority player's
## Events.water_state_changed, so a remote peer submerging never tints your screen.
##
## Instanced in-raid by main.gd (non-headless), like the HUD / HitMarker.

const SHADER_PATH := "res://shaders/underwater.gdshader"

# Strength targets per state (0 DRY, 1 WADING, 2 SUBMERGED — matches the Events comment).
const STRENGTH_DRY := 0.0
const STRENGTH_WADING := 0.28
const STRENGTH_SUBMERGED := 1.0
const RAMP_SPEED := 4.0   # how fast strength eases toward the target (per second)

var _rect: ColorRect = null
var _mat: ShaderMaterial = null
var _local_player: Node = null
var _target_strength: float = 0.0
var _strength: float = 0.0


func _ready() -> void:
	layer = 90   # above the world, below pause menus / hard UI
	process_mode = Node.PROCESS_MODE_ALWAYS

	_rect = ColorRect.new()
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never eat input
	var shader := load(SHADER_PATH)
	if shader is Shader:
		_mat = ShaderMaterial.new()
		_mat.shader = shader
		_mat.set_shader_parameter("strength", 0.0)
		_rect.material = _mat
	add_child(_rect)

	visible = false   # start hidden

	# Bind the local player so we can confirm authority on each state change.
	Events.local_player_spawned.connect(_on_local_player_spawned)
	Events.water_state_changed.connect(_on_water_state_changed)


func _on_local_player_spawned(player: Node) -> void:
	_local_player = player


## React ONLY to the local authority player. water_state_changed is emitted only by an
## authority player inside its own _physics_process, so on a client this fires solely for
## the locally-owned player — but we still gate on the bound local player + authority so a
## remote peer can never tint this screen.
func _on_water_state_changed(state: int, _world_pos: Vector3) -> void:
	if _local_player == null or not is_instance_valid(_local_player):
		return
	if _local_player.has_method("is_multiplayer_authority") and not _local_player.is_multiplayer_authority():
		return
	match state:
		2:
			_target_strength = STRENGTH_SUBMERGED
		1:
			_target_strength = STRENGTH_WADING
		_:
			_target_strength = STRENGTH_DRY


func _process(delta: float) -> void:
	if _mat == null:
		return
	if absf(_strength - _target_strength) < 0.001:
		_strength = _target_strength
	else:
		_strength = move_toward(_strength, _target_strength, RAMP_SPEED * delta)
	_mat.set_shader_parameter("strength", _strength)
	# Only render when there's something to show (cheap when dry).
	visible = _strength > 0.001
