extends Node
class_name LootSpawner
## Small server-side helper that drops loot into the world. Thin wrapper over
## LootPickup.spawn_at so enemy-death and wave-reward systems have one obvious
## entry point. All methods are static; nothing here needs to be in the tree.
##
## Loot goes under the Arena's "Net/Loot" node (replicated by the LootSpawner
## MultiplayerSpawner). Callers pass that node as `loot_root`.

# Weighted drop table for generic enemy kills: id -> relative weight.
# Common materials sit at 40-60; consumables 10-20; valuables 3-6; legendary 1.
const ENEMY_DROP_TABLE := {
	"loot_scrap": 55,
	"loot_plastic": 40,
	"loot_cell": 25,
	"loot_ammo": 18,
	"loot_medkit": 12,
	"loot_chemicals": 10,
	"loot_circuit": 8,
	"loot_grenade": 6,
	"rifle": 5,
	"loot_artifact": 3,
	"loot_data_chip": 1,
	# Attachments: uncommon drops; rarities match their item rarity.
	"att_red_dot": 3,
	"att_holo_sight": 2,
	"att_light_mag": 3,
	"att_drum_mag": 1,
	"att_suppressor": 1,
	"att_long_barrel": 2,
	"att_quickdraw_grip": 2,
	"att_heavy_grip": 3,
	# Schematics: rare blueprint drops from any enemy.
	"schematic_circuit_pack": 2,
	"schematic_stim": 1,
	"schematic_grenade_mk2": 1,
	"schematic_drum_mag": 1,
	"schematic_suppressor": 1,
}


## Spawns one explicit pickup. Returns the pickup (or null). Server only.
static func drop(loot_root: Node, pos: Vector3, id: String, count: int = 1) -> LootPickup:
	if not GameState.is_local_authority_server():
		return null
	return LootPickup.spawn_at(loot_root, pos, id, count)


## Rolls the enemy drop table and spawns the result near `pos`. Returns the
## pickup, or null if nothing dropped / not authority. Server only.
##
## `tier` defaults to 0 (auto). When 0, `tier_at(pos)` determines the risk tier
## from the nearest POI so callers don't need to track it themselves. Pass an
## explicit tier (1–3) to override (e.g. from a caller that already knows it).
## Tier 1 uses the legacy ENEMY_DROP_TABLE for backward compatibility; tier 2–3
## escalates by drawing from LootTables so higher-risk zones give better drops.
##
## `enemy` (optional, default null) is the dying enemy node. When supplied, an EXTRA
## independent annex-key roll (LootTables.roll_key_drop) runs for elites/minibosses and,
## on success, spawns a biome-matched key as a SECOND pickup. Passing null keeps the old
## behaviour (normal drop only) so existing call sites stand unchanged.
static func drop_for_enemy(
	loot_root: Node, pos: Vector3, tier: int = 0, enemy: Node = null
) -> LootPickup:
	if not GameState.is_local_authority_server():
		return null
	# Independent annex-key roll for elites/minibosses (extra drop, never replaces the
	# normal one). Spawned through the same LootPickup.spawn_at path as every other id.
	var key_id: String = LootTables.roll_key_drop(enemy, pos)
	if key_id != "":
		var key_jitter := Vector3(randf_range(-0.6, 0.6), 0.0, randf_range(-0.6, 0.6))
		LootPickup.spawn_at(loot_root, pos + key_jitter, key_id, 1)
	# Independent AMMO-shard roll — machines shed usable rounds (the "ran dry with
	# no counterplay" fix). Walk-up resupply, never replaces the normal drop.
	if randf() < Settings.AMMO_DROP_CHANCE:
		var ammo_jitter := Vector3(randf_range(-0.8, 0.8), 0.0, randf_range(-0.8, 0.8))
		LootPickup.spawn_at(loot_root, pos + ammo_jitter, "loot_ammo_shard", 1)
	# Resolve auto tier.
	var resolved_tier: int = tier if tier >= 1 else tier_at(pos)
	var id: String = ""
	if resolved_tier <= 1:
		# Legacy weighted table — keeps tier-1 behaviour identical to before.
		id = _roll(ENEMY_DROP_TABLE)
	else:
		# For tier 2–3 try the catalog-driven table first; fall back to legacy if
		# the catalog returns nothing (e.g. headless import scan, empty catalog).
		id = LootTables.roll_for_enemy(resolved_tier)
		if id == "":
			id = _roll(ENEMY_DROP_TABLE)
	if id == "":
		return null
	var count: int = 1
	match id:
		"loot_scrap":
			count = randi_range(1, 4)
		"loot_plastic":
			count = randi_range(1, 3)
		"loot_cell":
			count = randi_range(1, 2)
		"loot_ammo":
			count = randi_range(1, 2)
		"loot_chemicals":
			count = randi_range(1, 2)
	# Scatter slightly so stacked corpses don't overlap pickups exactly.
	var jitter := Vector3(randf_range(-0.6, 0.6), 0.0, randf_range(-0.6, 0.6))
	return LootPickup.spawn_at(loot_root, pos + jitter, id, count)


## Returns the risk tier (1–3) for a world position by finding the nearest POI
## centre in the arena. Falls back to 1 when the arena isn't in the scene tree
## (headless import checks, offline unit tests, early frames before _ready).
static func tier_at(world_pos: Vector3) -> int:
	var scene_tree: SceneTree = Engine.get_main_loop() as SceneTree
	if scene_tree == null:
		return 1
	var arenas: Array = scene_tree.get_nodes_in_group(Groups.ARENA)
	if arenas.is_empty():
		return 1
	var arena: Node = arenas[0]
	if not arena.has_method("get_poi_points") or not arena.has_method("get_poi_tier"):
		return 1
	var poi_points: Array = arena.get_poi_points()
	if poi_points.is_empty():
		return 1
	var best_idx: int = 0
	var best_dist: float = INF
	for i in range(poi_points.size()):
		var d: float = (poi_points[i] as Vector3).distance_to(world_pos)
		if d < best_dist:
			best_dist = d
			best_idx = i
	return arena.get_poi_tier(best_idx)


static func _roll(table: Dictionary) -> String:
	var total := 0
	for k in table:
		total += int(table[k])
	if total <= 0:
		return ""
	var pick := randi_range(1, total)
	var acc := 0
	for k in table:
		acc += int(table[k])
		if pick <= acc:
			return k
	return ""
