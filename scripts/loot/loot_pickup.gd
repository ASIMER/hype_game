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
	"loot_medkit": "res://resources/items/medkit.tres",
	"loot_grenade": "res://resources/items/grenade.tres",
	"loot_ammo": "res://resources/items/ammo_box.tres",
	"loot_plastic": "res://resources/items/plastic.tres",
	"loot_chemicals": "res://resources/items/chemicals.tres",
	"loot_circuit": "res://resources/items/circuit.tres",
	"loot_artifact": "res://resources/items/artifact.tres",
	"loot_data_chip": "res://resources/items/data_chip.tres",
	# Batch A utility grenades + deployable gadgets.
	"loot_grenade_smoke": "res://resources/items/grenade_smoke.tres",
	"loot_grenade_emp": "res://resources/items/grenade_emp.tres",
	"loot_grenade_decoy": "res://resources/items/grenade_decoy.tres",
	"loot_grenade_incendiary": "res://resources/items/grenade_incendiary.tres",
	"loot_grenade_cryo": "res://resources/items/grenade_cryo.tres",
	"gadget_turret": "res://resources/items/gadget_turret.tres",
	"gadget_dome": "res://resources/items/gadget_dome.tres",
	"gadget_sensor": "res://resources/items/gadget_sensor.tres",
}

const LAYER_LOOT := 1 << 3  # 3d_physics layer_4 "loot"
const LAYER_PLAYER := 1 << 1  # 3d_physics layer_2 "player"

# Server-side distance gate for a CLIENT's pickup request (the detection Area3D is a
# 1.2 m sphere; a touch more is lenient for the model's hover offset + sync jitter).
const PICKUP_RANGE := 2.2

@export var item_id: String = "loot_scrap"
@export var count: int = 1

# World position to place at on _ready (set by the spawn_function path). The
# MultiplayerSpawner returns the node BEFORE it's in the tree, so global_position is
# applied in _ready from this instead of right after add_child.
var _spawn_pos: Vector3 = Vector3.ZERO
var _has_spawn_pos: bool = false

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
	add_to_group(Groups.PICKUPS)

	# Merged static model: one MeshInstance3D per pickup instead of ~4 part draws —
	# the map carries ~100 pickups, so this saves a few hundred draw calls.
	var model := AssetRegistry.get_model_merged(item_id)
	model.name = "ModelRoot"
	add_child(model)
	_model_root = model
	model.position.y = HOVER
	_apply_loot_glow()

	if _has_spawn_pos:
		global_position = _spawn_pos

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
	var rarity: int
	var col: Color
	if item_id == "power_cache":
		# Power caches always glow brightly (gold) with a tall pillar so they're findable.
		rarity = 2
		col = Color(0.98, 0.80, 0.30)
	else:
		var item: ItemData = ItemCatalog.get_item(item_id)
		if item == null:
			return
		rarity = item.rarity
		if rarity < 1:
			return  # common loot stays unlit to avoid light spam
		col = item.rarity_color()
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
	# Validate by DISTANCE, not by the server-side Area3D overlap. A remote (client)
	# player's body on the server is moved by its MultiplayerSynchronizer, so its
	# overlap with this pickup's Area3D is unreliable — `_players_in_range` frequently
	# misses it and the client could never pick anything up. A distance gate is
	# deterministic and still stops a client grabbing loot it isn't standing on.
	if player is Node3D:
		var d: float = (player as Node3D).global_position.distance_to(global_position)
		if d > PICKUP_RANGE:
			return
	Events.pickup_requested.emit(player, self)


## Finds the spawned Player node owned by `peer_id` (its multiplayer authority).
func _find_player_for_peer(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if is_instance_valid(p) and p.get_multiplayer_authority() == peer_id:
			return p
	return null


func _on_body_entered(body: Node) -> void:
	if body.is_in_group(Groups.PLAYERS) and not _players_in_range.has(body):
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
	# Power cache: NOT inventory loot — consume it and trigger the opener's non-blocking
	# reveal (the buff applies on THEIR client after the reveal animation finishes).
	if item_id == "power_cache":
		if player.has_method("begin_power_open"):
			player.begin_power_open.rpc_id(player.get_multiplayer_authority())
		Events.power_cache_opened.emit(player, self)
		queue_free()
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
	# Prefer the ItemCatalog AUTOLOAD (scans every resources/items/*.tres). NOTE: it is a
	# scene-tree autoload, NOT an Engine singleton — `Engine.has_singleton("ItemCatalog")`
	# is ALWAYS false, which silently sent every lookup to the tiny ITEM_PATHS fallback so
	# only its 11 hardcoded ids could ever be picked up. Reach it via /root instead.
	var catalog: Node = (
		get_tree().root.get_node_or_null("ItemCatalog") if get_tree() != null else null
	)
	if catalog != null and catalog.has_method("get_item"):
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
## SNAP a spawn position onto the first layer-1 surface below it (pickups are static
## Area3D — they never fall, so loot spawned above a roof edge / container gap / a
## flyer's death point floated unreachably forever). Runs ON THE SERVER before the
## position travels as replicated spawn data, so every peer builds the same snapped
## pickup. Falls back to the pure terrain height when no collider is below (or when
## physics isn't reachable, e.g. unit tests).
static func snap_to_surface(reference: Node, pos: Vector3) -> Vector3:
	if reference == null or not reference.is_inside_tree():
		return pos
	var world: World3D = (
		reference.get_viewport().find_world_3d() if reference.get_viewport() else null
	)
	if world == null or world.direct_space_state == null:
		return Vector3(pos.x, ProceduralTerrain.height_at(pos.x, pos.z), pos.z)
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.5, pos + Vector3.DOWN * 80.0)
	q.collision_mask = 1
	var hit: Dictionary = world.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return Vector3(pos.x, ProceduralTerrain.height_at(pos.x, pos.z), pos.z)
	return hit["position"]


## Spawns a LootPickup of `id`/`count` at `pos` under `parent`. Used by enemy
## death drops and the wave reward system. Returns the spawned pickup (or null).
## Call on the server; the LootSpawner (MultiplayerSpawner) replicates it to peers.
## `snap` grounds the position on the first surface below (see snap_to_surface).
static func spawn_at(
	parent: Node, pos: Vector3, id: String, count: int = 1, snap: bool = true
) -> LootPickup:
	if parent == null:
		return null
	if snap:
		pos = snap_to_surface(parent, pos)
	# Preferred path: route through the Net/LootSpawner's custom spawn_function so the
	# id/count/pos travel as REPLICATED spawn data (clients build the correct pickup).
	# `parent` is the Net/Loot node; the spawner is its sibling Net/LootSpawner.
	var spawner := _find_loot_spawner(parent)
	if spawner != null and spawner.spawn_function.is_valid():
		var data := {"id": id, "count": count, "pos": pos}
		return spawner.spawn(data) as LootPickup
	# Fallback (no spawner / function unset, e.g. unit tests): direct add_child.
	var pickup := _instantiate_self()
	if pickup == null:
		return null
	pickup.item_id = id
	pickup.count = count
	# `true` = force a readable unique name; REQUIRED when `parent` is watched by a
	# MultiplayerSpawner (Net/Loot) — without it the auto-spawn rejects the node.
	parent.add_child(pickup, true)
	pickup.global_position = pos
	return pickup


## Lazily-cached self scene. Deliberately load(), NOT preload: this script is attached
## to LootPickup.tscn itself, and a class-level preload of your own scene is a
## script<->scene dependency cycle.
static var _packed_self: PackedScene = null


static func _instantiate_self() -> LootPickup:
	if _packed_self == null:
		_packed_self = load("res://scenes/items/LootPickup.tscn") as PackedScene
	if _packed_self == null:
		return null
	return _packed_self.instantiate() as LootPickup


## The MultiplayerSpawner.spawn_function: runs on EVERY peer with the replicated
## `data` ({id,count,pos}), so each builds an identical pickup. Returns the node; the
## spawner parents it under its spawn_path (Net/Loot).
static func _spawn_loot(data: Dictionary) -> Node:
	var pickup := _instantiate_self()
	if pickup == null:
		return null
	pickup.item_id = String(data.get("id", "loot_scrap"))
	pickup.count = int(data.get("count", 1))
	pickup._spawn_pos = data.get("pos", Vector3.ZERO)
	pickup._has_spawn_pos = true
	return pickup


## Net/Loot (the spawn_path target) has the LootSpawner as a sibling under Net/.
static func _find_loot_spawner(loot_root: Node) -> MultiplayerSpawner:
	if loot_root == null:
		return null
	var net := loot_root.get_parent()
	if net == null:
		return null
	return net.get_node_or_null("LootSpawner") as MultiplayerSpawner
