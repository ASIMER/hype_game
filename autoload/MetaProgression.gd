extends Node
## Persistent between-run meta-progression (Arc-Raiders-workshop style). Tracks the
## player's currency (earned by extracting loot), which weapons are unlocked, how far
## each permanent upgrade is levelled, and the deploy loadout. Saved to
## user://profile.cfg so it survives across sessions/runs.
##
## This is LOCAL profile state (single-player / the host's own progression) — it is
## NOT networked. The Workshop UI reads/writes it; the player + weapon controller read
## player_mods()/get_loadout() at match start to apply its effects.

# Per-instance profile path (Settings.user_path) so parallel game instances never
# race/clobber the shared profile.cfg. Single instance → user://profile.cfg.
func _save_path() -> String:
	return Settings.user_path("profile", "cfg")

# Weapons that are always available (no purchase). The rest must be unlocked.
const FREE_WEAPONS := ["rifle", "pistol"]
# Unlock cost per purchasable weapon id.
const WEAPON_COSTS := {
	"smg": 600,
	"shotgun": 800,
	"dmr": 1200,
}
const MAX_LOADOUT := 3

# Permanent upgrade catalog. Each level multiplies a player/weapon stat; cost grows
# with level. effect_per_level is applied as (1 +/- effect*level) in player_mods().
#   key            -> { name, desc, max_level, base_cost, effect (per level) }
const UPGRADES := {
	"player_health": { "name": "Reinforced Frame", "desc": "+8% max health per level",
		"max_level": 5, "base_cost": 250, "effect": 0.08 },
	"reload_speed":  { "name": "Quick Hands", "desc": "-7% reload time per level",
		"max_level": 5, "base_cost": 250, "effect": 0.07 },
	"stamina":       { "name": "Conditioning", "desc": "+10% stamina per level",
		"max_level": 5, "base_cost": 200, "effect": 0.10 },
	"weapon_damage": { "name": "Calibrated Barrels", "desc": "+6% weapon damage per level",
		"max_level": 5, "base_cost": 350, "effect": 0.06 },
	"stash_capacity": { "name": "Stash Expansion", "desc": "+25 stash weight capacity per level",
		"max_level": 6, "base_cost": 300, "effect": 25.0 },
}

# Permanent PER-WEAPON perk catalog (bought in the Gunsmith; never lost). Applied in
# weapon_controller._load_weapons. effect is per level; key meaning per the field used.
#   key -> { name, desc, max_level, base_cost, field, effect }
# field: damage_mult_add | recoil_mult_sub | reload_mult_sub | mag_add (per level)
const WEAPON_PERKS := {
	"mastery":     { "name": "Mastery", "desc": "+5% damage / level", "max_level": 5, "base_cost": 300, "field": "damage", "effect": 0.05 },
	"recoil_ctrl": { "name": "Recoil Control", "desc": "-8% recoil / level", "max_level": 4, "base_cost": 250, "field": "recoil", "effect": 0.08 },
	"fast_hands":  { "name": "Fast Hands", "desc": "-6% reload / level", "max_level": 4, "base_cost": 250, "field": "reload", "effect": 0.06 },
	"ext_feed":    { "name": "Extended Feed", "desc": "+3 mag / level", "max_level": 4, "base_cost": 300, "field": "mag", "effect": 3.0 },
}
const STASH_BASE_CAPACITY := 75.0   # weight; + Stash Expansion upgrade

var currency: int = 0
var unlocked: Array[String] = []           # purchasable weapon ids that have been bought
var upgrades: Dictionary = {}              # key -> level (int)
var loadout: Array[String] = ["rifle", "pistol"]
## Consumables to BRING into the next raid (drawn from the Stash, at risk on death):
## item id -> count, e.g. { "loot_medkit": 2, "loot_grenade": 3 }. Empty = free run.
var bring: Dictionary = {}
## Crafting blueprints learned (by extracting a schematic, buying, or a quest reward).
var unlocked_blueprints: Array[String] = []
## Quest progress: quest id -> current count. completed_quests: ids whose reward was claimed.
var quest_progress: Dictionary = {}
var completed_quests: Array[String] = []
## Equipped (AT-RISK) attachments: weapon_id -> { slot -> attachment_id }.
var equipped_attachments: Dictionary = {}
## Permanent per-weapon perks: weapon_id -> { perk_key -> level }.
var weapon_perks: Dictionary = {}
## Daily contracts rotation state.
var last_daily_date: String = ""
var daily_quest_ids: Array[String] = []

func _ready() -> void:
	load_profile()

# ---------------------------------------------------------------- currency
func earn(amount: int) -> void:
	if amount <= 0:
		return
	currency += amount
	Events.currency_changed.emit(currency)
	save_profile()

## Spend currency if affordable; returns true on success.
func spend(amount: int) -> bool:
	if amount < 0 or currency < amount:
		return false
	currency -= amount
	Events.currency_changed.emit(currency)
	return true

# ---------------------------------------------------------------- weapons
func is_unlocked(weapon_id: String) -> bool:
	return weapon_id in FREE_WEAPONS or weapon_id in unlocked

func weapon_cost(weapon_id: String) -> int:
	return int(WEAPON_COSTS.get(weapon_id, 0))

## Attempts to buy+unlock a weapon. Returns true if newly unlocked.
func unlock_weapon(weapon_id: String) -> bool:
	if is_unlocked(weapon_id):
		return false
	if not WEAPON_COSTS.has(weapon_id):
		return false
	if not spend(weapon_cost(weapon_id)):
		return false
	unlocked.append(weapon_id)
	save_profile()
	return true

# ---------------------------------------------------------------- upgrades
func upgrade_level(key: String) -> int:
	return int(upgrades.get(key, 0))

func upgrade_max(key: String) -> int:
	return int(UPGRADES.get(key, {}).get("max_level", 0))

## Cost to buy the NEXT level of an upgrade (base_cost * (next_level)). Returns -1 if maxed.
func upgrade_cost(key: String) -> int:
	if not UPGRADES.has(key):
		return -1
	var lvl := upgrade_level(key)
	if lvl >= upgrade_max(key):
		return -1
	return int(UPGRADES[key]["base_cost"]) * (lvl + 1)

## Buys the next level of an upgrade if affordable + not maxed. Returns true on success.
func buy_upgrade(key: String) -> bool:
	var cost := upgrade_cost(key)
	if cost < 0:
		return false
	if not spend(cost):
		return false
	upgrades[key] = upgrade_level(key) + 1
	save_profile()
	return true

# ---------------------------------------------------------------- loadout
## The selected deploy weapons, filtered to those still unlocked (defensive). Falls
## back to the free weapons if empty.
func get_loadout() -> Array:
	var out: Array = []
	for id in loadout:
		if is_unlocked(id):
			out.append(id)
	if out.is_empty():
		out = FREE_WEAPONS.duplicate()
	return out

func set_loadout(ids: Array) -> void:
	var clean: Array[String] = []
	for id in ids:
		var sid := String(id)
		if is_unlocked(sid) and sid not in clean and clean.size() < MAX_LOADOUT:
			clean.append(sid)
	if clean.is_empty():
		clean.assign(FREE_WEAPONS)
	loadout = clean
	save_profile()

## The consumable bring-list for the next raid (item id -> count). Sanitized to
## positive counts. set_bring persists it.
func get_bring() -> Dictionary:
	return bring.duplicate()

func set_bring(b: Dictionary) -> void:
	var clean: Dictionary = {}
	for id in b:
		var n := int(b[id])
		if n > 0:
			clean[String(id)] = n
	bring = clean
	save_profile()

# ---------------------------------------------------------------- blueprints
func is_blueprint_known(bp: String) -> bool:
	return bp in unlocked_blueprints

## Permanently learn a crafting blueprint (idempotent). Emits blueprint_learned.
func learn_blueprint(bp: String) -> void:
	if bp == "" or bp in unlocked_blueprints:
		return
	unlocked_blueprints.append(bp)
	save_profile()
	Events.blueprint_learned.emit(bp)

# ---------------------------------------------------------------- stash capacity
func stash_capacity() -> float:
	return STASH_BASE_CAPACITY + upgrade_level("stash_capacity") * float(UPGRADES["stash_capacity"]["effect"])

# ---------------------------------------------------------------- attachments (at-risk)
func get_equipped(weapon_id: String) -> Dictionary:
	return (equipped_attachments.get(weapon_id, {}) as Dictionary).duplicate()

func equip_attachment(weapon_id: String, slot: String, att_id: String) -> void:
	var slots: Dictionary = equipped_attachments.get(weapon_id, {})
	slots[slot] = att_id
	equipped_attachments[weapon_id] = slots
	save_profile()
	Events.attachment_changed.emit(weapon_id)

func unequip_attachment(weapon_id: String, slot: String) -> void:
	var slots: Dictionary = equipped_attachments.get(weapon_id, {})
	if slots.has(slot):
		slots.erase(slot)
		if slots.is_empty():
			equipped_attachments.erase(weapon_id)
		else:
			equipped_attachments[weapon_id] = slots
		save_profile()
		Events.attachment_changed.emit(weapon_id)

## Drop any equipped attachment whose item is no longer in the Stash (lost on a failed
## raid). Called when the Hub opens. Returns true if anything changed.
func reconcile_attachments() -> bool:
	var changed := false
	for wid in equipped_attachments.keys():
		var slots: Dictionary = equipped_attachments[wid]
		for s in slots.keys():
			if Stash.count_of(String(slots[s])) <= 0:
				slots.erase(s)
				changed = true
		if slots.is_empty():
			equipped_attachments.erase(wid)
		else:
			equipped_attachments[wid] = slots
	if changed:
		save_profile()
	return changed

# ---------------------------------------------------------------- weapon perks (permanent)
func weapon_perk_level(weapon_id: String, perk: String) -> int:
	return int((weapon_perks.get(weapon_id, {}) as Dictionary).get(perk, 0))

func weapon_perk_cost(weapon_id: String, perk: String) -> int:
	if not WEAPON_PERKS.has(perk):
		return -1
	var lvl := weapon_perk_level(weapon_id, perk)
	if lvl >= int(WEAPON_PERKS[perk]["max_level"]):
		return -1
	return int(WEAPON_PERKS[perk]["base_cost"]) * (lvl + 1)

func buy_weapon_perk(weapon_id: String, perk: String) -> bool:
	var cost := weapon_perk_cost(weapon_id, perk)
	if cost < 0 or not spend(cost):
		return false
	var perks: Dictionary = weapon_perks.get(weapon_id, {})
	perks[perk] = weapon_perk_level(weapon_id, perk) + 1
	weapon_perks[weapon_id] = perks
	save_profile()
	Events.weapon_perk_changed.emit(weapon_id)
	return true

# ---------------------------------------------------------------- effects
## Stat multipliers from the current upgrade levels, read at match start by the
## player (health/stamina) and weapon controller (damage/reload). reload_mult < 1
## means faster reloads.
func player_mods() -> Dictionary:
	return {
		"health_mult": 1.0 + UPGRADES["player_health"]["effect"] * upgrade_level("player_health"),
		"reload_mult": 1.0 - UPGRADES["reload_speed"]["effect"] * upgrade_level("reload_speed"),
		"stamina_mult": 1.0 + UPGRADES["stamina"]["effect"] * upgrade_level("stamina"),
		"damage_mult": 1.0 + UPGRADES["weapon_damage"]["effect"] * upgrade_level("weapon_damage"),
	}

# ---------------------------------------------------------------- persistence
func save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "currency", currency)
	cfg.set_value("meta", "unlocked", unlocked)
	cfg.set_value("meta", "upgrades", upgrades)
	cfg.set_value("meta", "loadout", loadout)
	cfg.set_value("meta", "bring", bring)
	cfg.set_value("meta", "blueprints", unlocked_blueprints)
	cfg.set_value("meta", "quest_progress", quest_progress)
	cfg.set_value("meta", "completed_quests", completed_quests)
	cfg.set_value("meta", "equipped_attachments", equipped_attachments)
	cfg.set_value("meta", "weapon_perks", weapon_perks)
	cfg.set_value("meta", "last_daily_date", last_daily_date)
	cfg.set_value("meta", "daily_quest_ids", daily_quest_ids)
	cfg.set_value("meta", "difficulty", GameState.difficulty)
	cfg.save(_save_path())

func load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_save_path()) != OK:
		return
	currency = int(cfg.get_value("meta", "currency", 0))
	var raw_unlocked: Array = cfg.get_value("meta", "unlocked", [])
	unlocked.clear()
	for id in raw_unlocked:
		unlocked.append(String(id))
	upgrades = cfg.get_value("meta", "upgrades", {})
	var raw_loadout: Array = cfg.get_value("meta", "loadout", ["rifle", "pistol"])
	loadout.clear()
	for id in raw_loadout:
		loadout.append(String(id))
	var raw_bring: Dictionary = cfg.get_value("meta", "bring", {})
	bring = {}
	for id in raw_bring:
		bring[String(id)] = int(raw_bring[id])
	var raw_bp: Array = cfg.get_value("meta", "blueprints", [])
	unlocked_blueprints.clear()
	for bp in raw_bp:
		unlocked_blueprints.append(String(bp))
	quest_progress = cfg.get_value("meta", "quest_progress", {})
	var raw_cq: Array = cfg.get_value("meta", "completed_quests", [])
	completed_quests.clear()
	for qid in raw_cq:
		completed_quests.append(String(qid))
	equipped_attachments = cfg.get_value("meta", "equipped_attachments", {})
	weapon_perks = cfg.get_value("meta", "weapon_perks", {})
	last_daily_date = String(cfg.get_value("meta", "last_daily_date", ""))
	var raw_dq: Array = cfg.get_value("meta", "daily_quest_ids", [])
	daily_quest_ids.clear()
	for did in raw_dq:
		daily_quest_ids.append(String(did))
	GameState.difficulty = int(cfg.get_value("meta", "difficulty", GameState.Difficulty.NORMAL))
