extends Node3D
class_name DamageNumbersLayer
## Self-installing damage-number renderer. Add ONE instance of
## scenes/fx/DamageNumbersLayer.tscn anywhere in the world; it connects to
## Events.damage_number in _ready and spawns a floating DamageNumber at each hit
## position under itself. Purely visual/local — never networked. Null-safe: if
## the DamageNumber scene is missing it silently does nothing.

const _DAMAGE_NUMBER_SCENE := "res://scenes/fx/DamageNumber.tscn"
## Slight per-spawn lateral jitter so stacked hits don't perfectly overlap.
const _JITTER := 0.25
## Pool size (PERF): a shotgun volley from 4 players is ~32 simultaneous numbers;
## overflow steals the oldest (a 0.7s-old number vanishing early is invisible).
const _POOL := 32

var _scene: PackedScene
var _pool: Array[DamageNumber] = []
var _next: int = 0


func _ready() -> void:
	if ResourceLoader.exists(_DAMAGE_NUMBER_SCENE):
		_scene = load(_DAMAGE_NUMBER_SCENE)
	# Pre-instantiate the whole pool parked (PERF: zero Label3D churn under fire).
	if _scene != null:
		for _i in range(_POOL):
			var inst := _scene.instantiate() as DamageNumber
			if inst == null:
				break
			inst.pooled = true
			add_child(inst)
			inst.visible = false
			inst.set_process(false)
			_pool.append(inst)
	# Events is an autoload, always present; connect once.
	if not Events.damage_number.is_connected(_on_damage_number):
		Events.damage_number.connect(_on_damage_number)


func _on_damage_number(world_pos: Vector3, amount: float, is_crit: bool) -> void:
	if _pool.is_empty():
		return
	# Ring allocation: the slot is either parked or the oldest in-flight number.
	var inst := _pool[_next]
	_next = (_next + 1) % _pool.size()
	var jitter := Vector3(
		randf_range(-_JITTER, _JITTER), randf_range(0.0, _JITTER), randf_range(-_JITTER, _JITTER)
	)
	inst.global_position = world_pos + Vector3.UP * 0.4 + jitter
	inst.setup(amount, is_crit)
	inst.restart_at_position()
