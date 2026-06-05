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
}

var currency: int = 0
var unlocked: Array[String] = []           # purchasable weapon ids that have been bought
var upgrades: Dictionary = {}              # key -> level (int)
var loadout: Array[String] = ["rifle", "pistol"]

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
	GameState.difficulty = int(cfg.get_value("meta", "difficulty", GameState.Difficulty.NORMAL))
