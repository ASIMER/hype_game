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
	"loot_scrap":      "res://resources/items/scrap.tres",
	"loot_cell":       "res://resources/items/energy_cell.tres",
	"rifle":           "res://resources/items/rifle.tres",
	"loot_medkit":     "res://resources/items/medkit.tres",
	"loot_grenade":    "res://resources/items/grenade.tres",
	"loot_ammo":       "res://resources/items/ammo_box.tres",
	"loot_plastic":    "res://resources/items/plastic.tres",
	"loot_chemicals":  "res://resources/items/chemicals.tres",
	"loot_circuit":    "res://resources/items/circuit.tres",
	"loot_artifact":   "res://resources/items/artifact.tres",
	"loot_data_chip":  "res://resources/items/data_chip.tres",
}

const LAYER_LOOT := 1 << 3   # 3d_physics layer_4 "loot"
const LAYER_PLAYER := 1 << 1 # 3d_physics layer_2 "player"

@export var item_id: String = "loot_scrap"
@export var count: int = 1

# Players currently overlapping this pickup (for interact-in-range detection).
var _players_in_range: Array[Node] = []

# Idle presentation: the model hovers, spins, and (by rarity) glows.
const SPIN_SPEED := 1.0
const BOB_AMP := 0.1
const BOB_SPEED := 2.0
const HOVER := 0.22
var _model_root: Node3D = null
var _bob_t: float = 0.0

func _ready() -> void:
	collision_layer = LAYER_LOOT
	collision_mask = LAYER_PLAYER
	monitoring = true
	add_to_group("pickups")

	var model := AssetRegistry.get_model(item_id)
	model.name = "ModelRoot"
	add_child(model)
	_model_root = model
	model.position.y = HOVER
	_apply_loot_glow()

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	Events.pickup_requested.connect(_on_pickup_requested)
	Events.loot_spawned.emit(self)

## Idle spin + bob (visual only, runs on every peer — no authority gate).
func _process(delta: float) -> void:
	if _model_root == null:
		return
	_bob_t += delta
	_model_root.rotation.y += SPIN_SPEED * delta
	_model_root.position.y = HOVER + sin(_bob_t * BOB_SPEED) * BOB_AMP

## A rarity-coloured glow: an OmniLight for UNCOMMON+, plus a soft light pillar for
## RARE+ so valuable drops read across the arena.
func _apply_loot_glow() -> void:
	var item: ItemData = ItemCatalog.get_item(item_id)
	if item == null:
		return
	var rarity: int = item.rarity
	if rarity < 1:
		return   # common loot stays unlit to avoid light spam
	var col: Color = item.rarity_color()
	var light := OmniLight3D.new()
	light.light_color = col
	light.light_energy = 1.4
	light.omni_range = 2.6
	light.shadow_enabled = false
	light.position = Vector3(0, HOVER + 0.2, 0)
	add_child(light)
	if rarity >= 2:
		var beam := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.04
		cyl.bottom_radius = 0.12
		cyl.height = 3.0
		beam.mesh = cyl
		beam.position = Vector3(0, 1.5, 0)
		var bm := StandardMaterial3D.new()
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		bm.cull_mode = BaseMaterial3D.CULL_DISABLED
		bm.albedo_color = Color(col.r, col.g, col.b, 0.12)
		beam.material_override = bm
		add_child(beam)

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
	# Prefer ItemCatalog autoload (scans all *.tres automatically) when available.
	if Engine.has_singleton("ItemCatalog"):
		var catalog := Engine.get_singleton("ItemCatalog")
		if catalog.has_method("get_item"):
			var cat_item := catalog.get_item(item_id) as ItemData
			if cat_item != null:
				return cat_item
	# Fallback: direct path lookup for ids registered in ITEM_PATHS.
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
	# `true` = force a readable unique name; REQUIRED when `parent` is watched by a
	# MultiplayerSpawner (Net/Loot) — without it the auto-spawn rejects the node.
	parent.add_child(pickup, true)
	pickup.global_position = pos
	return pickup
