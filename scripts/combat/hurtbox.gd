extends Area3D
class_name Hurtbox
## Area3D placed on an entity that can be hit. It locates the sibling Health
## component and exposes apply_hit() so weapons (hitscan or projectile) can deal
## damage without knowing the entity's internals.
##
## Put the Hurtbox on physics layer "hurtbox" (7) so weapon raycasts can mask it.

@export var health_path: NodePath = ^"../Health"
@export var damage_multiplier: float = 1.0   # e.g. 2.0 for a headshot hurtbox

var _health: Health

func _ready() -> void:
	_health = get_node_or_null(health_path) as Health

## Called by a weapon when this hurtbox is hit. Damage is only applied on the
## owning entity's authority to keep state consistent in multiplayer.
func apply_hit(amount: float, source: Node = null) -> void:
	if _health == null:
		_health = get_node_or_null(health_path) as Health
	if _health == null:
		return
	var owner_node := _health.get_parent()
	if owner_node and owner_node.has_method("is_multiplayer_authority"):
		if not owner_node.is_multiplayer_authority():
			# Forward the hit to the authority instead of applying locally.
			_request_authority_hit.rpc_id(owner_node.get_multiplayer_authority(), amount)
			return
	_health.take_damage(amount * damage_multiplier, source)

@rpc("any_peer", "call_remote", "reliable")
func _request_authority_hit(amount: float) -> void:
	var owner_node := _health.get_parent()
	if owner_node and not owner_node.is_multiplayer_authority():
		return
	_health.take_damage(amount * damage_multiplier, null)
