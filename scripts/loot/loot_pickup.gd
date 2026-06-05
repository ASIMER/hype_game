extends Area3D
class_name LootPickup
## A world pickup: holds a logical item id + count, shows the AssetRegistry model,
## and lets a nearby player press "interact" to claim it. The interact intent is
## broadcast through Events.pickup_requested (client -> server); the actual
## inventory mutation + despawn run only on the authoritative server.
##
## Collision: layer = loot (bit 4), mask = player (bit 2) so player bodies overlap us.
## Single-player works because GameState.is_local_authority_server() is true with
## no multiplayer peer.

const ITEM_PATHS := {
	"loot_scrap": "res://resources/items/scrap.tres",
	"loot_cell": "res://resources/items/energy_cell.tres",
	"rifle": "res://resources/items/rifle.tres",
}

const LAYER_LOOT := 1 << 3   # 3d_physics layer_4 "loot"
const LAYER_PLAYER := 1 << 1 # 3d_physics layer_2 "player"

@export var item_id: String = "loot_scrap"
@export var count: int = 1

# Players currently overlapping this pickup (for interact-in-range detection).
var _players_in_range: Array[Node] = []

func _ready() -> void:
	collision_layer = LAYER_LOOT
	collision_mask = LAYER_PLAYER
	monitoring = true
	add_to_group("pickups")

	var model := AssetRegistry.get_model(item_id)
	model.name = "ModelRoot"
	add_child(model)

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	Events.pickup_requested.connect(_on_pickup_requested)
	Events.loot_spawned.emit(self)

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact"):
		return
	# Find the local player in range and request a pickup. The local player is the
	# one whose Inventory UI we control; in single-player there is exactly one.
	for p in _players_in_range:
		if not is_instance_valid(p):
			continue
		if _is_local_player(p):
			_request_pickup(p)
			return

## Routes a pickup intent to wherever the authoritative logic runs.
##   - Single-player / host: emit on the local bus; the server-side handler below
##     (running on this same machine) claims the item.
##   - Client: the local handler would no-op (is_local_authority_server() is false),
##     so forward the intent to the server via RPC, tagging which peer asked.
func _request_pickup(player: Node) -> void:
	if GameState.is_local_authority_server():
		Events.pickup_requested.emit(player, self)
	else:
		_pickup_requested_rpc.rpc_id(1, player.get_multiplayer_authority())

## Server-side entry for a client's pickup intent. Resolves the requesting peer's
## Player node and feeds the existing server-authoritative handler so all the
## validation/inventory/despawn logic lives in one place.
@rpc("any_peer", "call_remote", "reliable")
func _pickup_requested_rpc(requester_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player_for_peer(requester_peer_id)
	if player == null:
		return
	# Only honor it if that player is actually overlapping this pickup, so a client
	# can't grab loot it isn't standing on.
	if not _players_in_range.has(player):
		return
	Events.pickup_requested.emit(player, self)

## Finds the spawned Player node owned by `peer_id` (its multiplayer authority).
func _find_player_for_peer(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if is_instance_valid(p) and p.get_multiplayer_authority() == peer_id:
			return p
	return null

func _on_body_entered(body: Node) -> void:
	if body.is_in_group("players") and not _players_in_range.has(body):
		_players_in_range.append(body)

func _on_body_exited(body: Node) -> void:
	_players_in_range.erase(body)

## Server-authoritative handler: validate against the player's Inventory, add the
## item, broadcast item_picked_up, and despawn. Listens to every pickup_requested
## but only acts when this is the targeted pickup and we are the authority.
func _on_pickup_requested(player: Node, pickup: Node) -> void:
	if pickup != self:
		return
	if not GameState.is_local_authority_server():
		return
	if not is_instance_valid(player):
		return
	var inv := _get_player_inventory(player)
	if inv == null:
		return
	var item := _load_item()
	if item == null:
		return
	if not inv.can_add(item, count):
		return
	var leftover: int = inv.add_item(item, count)
	var taken: int = count - leftover
	if taken <= 0:
		return
	Events.item_picked_up.emit(player, item_id, taken)
	if leftover <= 0:
		queue_free()
	else:
		count = leftover

func _load_item() -> ItemData:
	var path: String = ITEM_PATHS.get(item_id, "")
	if path == "" or not ResourceLoader.exists(path):
		push_warning("LootPickup: no ItemData for id '%s'" % item_id)
		return null
	var res := load(path)
	return res as ItemData

func _is_local_player(player: Node) -> bool:
	# Local in single-player (no peer) or when this peer owns the player.
	if not multiplayer.has_multiplayer_peer():
		return true
	return player.get_multiplayer_authority() == multiplayer.get_unique_id()

## Resolves the Inventory node hanging off a player. Prefers a child literally
## named "Inventory"; otherwise scans children for an Inventory-typed node.
func _get_player_inventory(player: Node) -> Inventory:
	var named := player.get_node_or_null("Inventory")
	if named is Inventory:
		return named
	for c in player.get_children():
		if c is Inventory:
			return c
	return null

# ----------------------------------------------------------------- spawn helper
## Spawns a LootPickup of `id`/`count` at `pos` under `parent`. Used by enemy
## death drops and the wave reward system. Returns the spawned pickup (or null).
## Call on the server; the LootSpawner (MultiplayerSpawner) replicates it to peers.
static func spawn_at(parent: Node, pos: Vector3, id: String, count: int = 1) -> LootPickup:
	if parent == null:
		return null
	var packed := load("res://scenes/items/LootPickup.tscn") as PackedScene
	if packed == null:
		return null
	var pickup := packed.instantiate() as LootPickup
	if pickup == null:
		return null
	pickup.item_id = id
	pickup.count = count
	parent.add_child(pickup)
	pickup.global_position = pos
	return pickup
