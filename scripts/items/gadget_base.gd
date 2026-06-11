extends Node3D
class_name GadgetBase
## Base class for a deployed gadget (auto-turret / shield dome / motion sensor). A gadget is
## a Node3D placed in the world by a player; it lives for `_lifetime` seconds then frees
## itself and fires Events.gadget_expired.
##
## SPAWN CONTRACT (the lead wires a MultiplayerSpawner with `spawn_function = _spawn_gadget`):
## `_spawn_gadget(data)` runs on EVERY peer with the REPLICATED `data` so each builds an
## identical gadget. `data = { "type": String, "pos": Vector3, "yaw": float, "owner_peer":
## int }`. It instances the matching scene (TYPE_SCENES path map), stashes pos/yaw for
## application in `_ready` (global_position can't be set before entering the tree, exactly
## like LootPickup._spawn_loot), sets owner_peer, and RETURNS the node (the spawner parents
## it). Subclasses do NOT override it — they set `_gadget_type`/`_lifetime` and implement
## `_gadget_ready()` + `_gadget_tick(delta)`.
##
## Lifetime is delta-accumulated in _physics_process (NEVER get_tree().create_timer — that
## ignores the solo pause; the same discipline as the enemy/world-event timers).

const TYPE_SCENES := {
	"gadget_turret": "res://scenes/items/GadgetTurret.tscn",
	"gadget_dome": "res://scenes/items/GadgetDome.tscn",
	"gadget_sensor": "res://scenes/items/GadgetSensor.tscn",
}

## Peer id of the player that placed this gadget (set by the spawner, replicated via data).
var owner_peer: int = 0

## Logical type id (subclass sets this in its _ready before super, used by the expiry signal).
var _gadget_type: String = ""
## Seconds this gadget lives before auto-freeing (subclass sets this).
var _lifetime: float = 10.0
var _life: float = 0.0

# Deferred placement (set by _spawn_gadget; applied in _ready — see contract above).
var _spawn_pos: Vector3 = Vector3.ZERO
var _spawn_yaw: float = 0.0
var _has_spawn: bool = false


func _ready() -> void:
	if _has_spawn:
		global_position = _spawn_pos
		rotation.y = _spawn_yaw
	_gadget_ready()


## Subclass hook — runs at the end of _ready (after placement is applied). Build visuals,
## join groups, cache nodes here.
func _gadget_ready() -> void:
	pass


func _physics_process(delta: float) -> void:
	_life += delta
	if _life >= _lifetime:
		Events.gadget_expired.emit(_gadget_type, global_position)
		queue_free()
		return
	_gadget_tick(delta)


## Subclass hook — per-physics-frame logic (server damage, visuals). Runs on every peer; the
## subclass gates its authoritative parts with _server().
func _gadget_tick(_delta: float) -> void:
	pass


## True on the machine that owns the authoritative simulation (host or single-player).
func _server() -> bool:
	return GameState.is_local_authority_server()


# ----------------------------------------------------------------- spawn function
## The MultiplayerSpawner.spawn_function: runs on EVERY peer with the replicated `data`, so
## each builds an identical gadget. Returns the node; the spawner parents it under its
## spawn_path. Static so the spawner can call it without an existing instance.
static func _spawn_gadget(data: Dictionary) -> Node:
	var type := String(data.get("type", ""))
	var path: String = TYPE_SCENES.get(type, "")
	if path == "" or not ResourceLoader.exists(path):
		push_warning("GadgetBase: no scene for gadget type '%s'" % type)
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var node := packed.instantiate() as GadgetBase
	if node == null:
		return null
	node.owner_peer = int(data.get("owner_peer", 0))
	node._spawn_pos = data.get("pos", Vector3.ZERO)
	node._spawn_yaw = float(data.get("yaw", 0.0))
	node._has_spawn = true
	return node
