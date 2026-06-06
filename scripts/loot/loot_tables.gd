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
			band = [0, 1]   # COMMON–UNCOMMON — same as world tier 1
		2:
			band = [0, 2]   # COMMON–RARE (broad, but commoner items still dominate)
		3:
			band = [1, 3]   # UNCOMMON–EPIC — escalated reward in hot zones
		_:
			band = [0, 1]
	var min_r: int = int(band[0])
	var max_r: int = int(band[1])
	var candidates: Array = ItemCatalog.ids_of_rarity(min_r, max_r)
	candidates = _filter_world_loot(candidates)
	return _weighted_roll(candidates)


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

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
