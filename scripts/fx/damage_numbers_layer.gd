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

var _scene: PackedScene


func _ready() -> void:
	if ResourceLoader.exists(_DAMAGE_NUMBER_SCENE):
		_scene = load(_DAMAGE_NUMBER_SCENE)
	# Events is an autoload, always present; connect once.
	if not Events.damage_number.is_connected(_on_damage_number):
		Events.damage_number.connect(_on_damage_number)


func _on_damage_number(world_pos: Vector3, amount: float, is_crit: bool) -> void:
	if _scene == null:
		return
	var inst := _scene.instantiate()
	if inst == null:
		return
	add_child(inst)
	if inst is Node3D:
		var jitter := Vector3(
			randf_range(-_JITTER, _JITTER),
			randf_range(0.0, _JITTER),
			randf_range(-_JITTER, _JITTER)
		)
		(inst as Node3D).global_position = world_pos + Vector3.UP * 0.4 + jitter
	if inst is DamageNumber:
		(inst as DamageNumber).setup(amount, is_crit)
