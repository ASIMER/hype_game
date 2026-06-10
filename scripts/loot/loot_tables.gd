extends RefCounted
class_name LootTables
## Static helpers that produce item-id rolls for risk-tier world loot and enemy
## drops. The single source of truth for "what falls where / what enemies drop".
##
## All functions are STATIC — no node needed; callers just write:
##   LootTables.roll_by_tier(2)
##
## Dependencies (autoloads): Settings, ItemCatalog.
## Dependency (class_name): ItemData  — only for the Kind enum, no instantiation.
##
## EXCLUDED from world-loot rolls: WEAPON + KEY kinds (guns / schematics are not
## scattered as ground clutter). ATTACHMENT, MATERIAL, CONSUMABLE are kept.
##
## ANNEX KEYS are the one deliberate exception to "KEY is never rolled as clutter":
## roll_key_drop() hands a biome-matched annex key to ELITE / MINIBOSS deaths only,
## as an EXTRA independent roll on top of the normal drop (it never goes through the
## clutter tables / _filter_world_loot). Key ids + drop chance are frozen in Settings
## (LOCKED_ROOM_POIS / KEY_DROP_CHANCE); the miniboss enemy_ids are MINIBOSS_IDS below.

# Per-biome miniboss enemy_ids (batch D). These always carry the annex-key roll,
# matching Settings.MINIBOSS_BY_BIOME (which holds scene paths; enemies expose the
# enemy_id string, so the contract is duplicated here as ids).
const MINIBOSS_IDS: Array[String] = [
	"robot_snow_golem",
	"robot_dune_warden",
	"robot_oni_chief",
]

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


## Returns a random item id appropriate for a WORLD loot cache at `tier` (1–3).
## Rarity band comes from Settings.RISK_TIER_LOOT[tier]; inverse-rarity weighting
## keeps common items frequent even at high tiers, but rare/epic items do appear.
## Returns "" when the catalog has no qualifying candidates (caller must guard).
static func roll_by_tier(tier: int) -> String:
	var band: Array = Settings.RISK_TIER_LOOT.get(tier, [0, 1])
	var min_r: int = int(band[0])
	var max_r: int = int(band[1])
	var candidates: Array = ItemCatalog.ids_of_rarity(min_r, max_r)
	candidates = _filter_world_loot(candidates)
	return _weighted_roll(candidates)


## Returns a random item id for an ENEMY death drop, scaled to `tier` (1–3).
## Tier 1 draws from the common band; higher tiers escalate the rarity floor.
## Excludes WEAPON and KEY items (same ground-clutter rule as world loot).
## Returns "" when the catalog yields no candidates (caller must guard).
static func roll_for_enemy(tier: int) -> String:
	# Enemy tiers map to a slightly lower rarity band than world-cache (combat
	# reward vs deliberate exploration reward).
	var band: Array
	match tier:
		1:
			band = [0, 1]  # COMMON–UNCOMMON — same as world tier 1
		2:
			band = [0, 2]  # COMMON–RARE (broad, but commoner items still dominate)
		3:
			band = [1, 3]  # UNCOMMON–EPIC — escalated reward in hot zones
		_:
			band = [0, 1]
	var min_r: int = int(band[0])
	var max_r: int = int(band[1])
	var candidates: Array = ItemCatalog.ids_of_rarity(min_r, max_r)
	candidates = _filter_world_loot(candidates)
	return _weighted_roll(candidates)


## EXTRA drop roll for an annex key on an ELITE / MINIBOSS death, biome-matched to
## `pos`. Returns the key item id to spawn (e.g. "key_lodge"), or "" for no key.
## This is INDEPENDENT of the normal enemy drop — the caller spawns both. Pass the
## dying enemy NODE so we can read its modifiers/enemy_id; a null/plain enemy → "".
##
## Detection (carrier?): the enemy is a key carrier if it is an ELITE (a non-empty
## `modifiers` array, else a "_mod" token in its node name — batch D name-encoding)
## OR a MINIBOSS (its `enemy_id` is in MINIBOSS_IDS). Only then do we roll the
## independent randf() < Settings.KEY_DROP_CHANCE. Runtime RNG is intentional here
## (enemy drops are not part of the world-build determinism — see header note).
static func roll_key_drop(enemy: Node, pos: Vector3) -> String:
	if enemy == null:
		return ""
	if not _is_key_carrier(enemy):
		return ""
	if randf() >= Settings.KEY_DROP_CHANCE:
		return ""
	return _key_for_biome(WorldBounds.biome_at(pos.x, pos.z))


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


## True when a dying enemy should roll an annex key: an ELITE (modifier-bearing) or a
## per-biome MINIBOSS. Prefers the reachable `modifiers` array; falls back to the
## "_mod" node-name token (the array is empty before _ready, but a death is post-spawn).
static func _is_key_carrier(enemy: Node) -> bool:
	var mods: Variant = enemy.get("modifiers")
	if mods is Array and not (mods as Array).is_empty():
		return true
	if String(enemy.name).contains("_mod"):
		return true
	var eid: Variant = enemy.get("enemy_id")
	return eid is String and MINIBOSS_IDS.has(eid)


## Map a biome (WorldBounds.biome_at) to its annex-key id. Snow/rain map to their own
## sealed-room key; urban → the tower key. DESERT has NO locked room of its own, so its
## elites carry the neighbouring URBAN tower key (key_tower) — deliberate, not a fallthrough.
static func _key_for_biome(biome: String) -> String:
	match biome:
		"snow":
			return "key_lodge"
		"rain":
			return "key_temple"
		"desert":
			return "key_tower"  # no desert annex — carry the adjacent urban tower key
		_:
			return "key_tower"  # urban (and any unknown) → tower key


## Remove WEAPON and KEY kinds from a candidate list (no guns/schematics as clutter).
static func _filter_world_loot(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		var item: ItemData = ItemCatalog.get_item(id)
		if item == null:
			continue
		if item.kind == ItemData.Kind.WEAPON or item.kind == ItemData.Kind.KEY:
			continue
		out.append(id)
	return out


## Weighted random pick from a list of item ids. Weight = max(1, 6 - rarity) so
## lower-rarity items are proportionally more likely (COMMON=5, UNCOMMON=4, RARE=3,
## EPIC=2, LEGENDARY=1). Returns "" if the list is empty.
static func _weighted_roll(ids: Array) -> String:
	if ids.is_empty():
		return ""
	var total: int = 0
	for id in ids:
		total += _id_weight(id)
	if total <= 0:
		return ""
	var pick: int = randi_range(1, total)
	var acc: int = 0
	for id in ids:
		acc += _id_weight(id)
		if pick <= acc:
			return id
	return ""


## Inverse-rarity weight for a single item id.
static func _id_weight(id: String) -> int:
	var item: ItemData = ItemCatalog.get_item(id)
	if item == null:
		return 1
	return max(1, 6 - int(item.rarity))
