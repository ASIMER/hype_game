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
	"loot_scrap":              55,
	"loot_plastic":            40,
	"loot_cell":               25,
	"loot_ammo":               18,
	"loot_medkit":             12,
	"loot_chemicals":          10,
	"loot_circuit":             8,
	"loot_grenade":             6,
	"rifle":                    5,
	"loot_artifact":            3,
	"loot_data_chip":           1,
	# Attachments: uncommon drops; rarities match their item rarity.
	"att_red_dot":              3,
	"att_holo_sight":           2,
	"att_light_mag":            3,
	"att_drum_mag":             1,
	"att_suppressor":           1,
	"att_long_barrel":          2,
	"att_quickdraw_grip":       2,
	"att_heavy_grip":           3,
	# Schematics: rare blueprint drops from any enemy.
	"schematic_circuit_pack":   2,
	"schematic_stim":           1,
	"schematic_grenade_mk2":    1,
	"schematic_drum_mag":       1,
	"schematic_suppressor":     1,
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
