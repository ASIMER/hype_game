extends Node
class_name LootSpawner
## Small server-side helper that drops loot into the world. Thin wrapper over
## LootPickup.spawn_at so enemy-death and wave-reward systems have one obvious
## entry point. All methods are static; nothing here needs to be in the tree.
##
## Loot goes under the Arena's "Net/Loot" node (replicated by the LootSpawner
## MultiplayerSpawner). Callers pass that node as `loot_root`.

# Weighted drop table for generic enemy kills: id -> relative weight.
const ENEMY_DROP_TABLE := {
	"loot_scrap": 60,
	"loot_cell": 30,
	"rifle": 10,
}

## Spawns one explicit pickup. Returns the pickup (or null). Server only.
static func drop(loot_root: Node, pos: Vector3, id: String, count: int = 1) -> LootPickup:
	if not GameState.is_local_authority_server():
		return null
	return LootPickup.spawn_at(loot_root, pos, id, count)

## Rolls the enemy drop table and spawns the result near `pos`. Returns the
## pickup, or null if nothing dropped / not authority. Server only.
static func drop_for_enemy(loot_root: Node, pos: Vector3) -> LootPickup:
	if not GameState.is_local_authority_server():
		return null
	var id := _roll(ENEMY_DROP_TABLE)
	if id == "":
		return null
	var count := 1
	if id == "loot_scrap":
		count = randi_range(1, 4)
	elif id == "loot_cell":
		count = randi_range(1, 2)
	# Scatter slightly so stacked corpses don't overlap pickups exactly.
	var jitter := Vector3(randf_range(-0.6, 0.6), 0.0, randf_range(-0.6, 0.6))
	return LootPickup.spawn_at(loot_root, pos + jitter, id, count)

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
