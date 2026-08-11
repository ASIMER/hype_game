extends Node  # gdlint: ignore=max-public-methods
# (41 public methods IS this profile's API surface — accepted god file, docs/AUDIT.md §1;
# the 40-method lint ceiling still applies to every other file.)
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
	"player_health":
	{
		"name": "Reinforced Frame",
		"desc": "+8% max health per level",
		"max_level": 5,
		"base_cost": 250,
		"effect": 0.08,
		"icon": "res://assets/ui/icons/upgrades/player_health.svg",
		"color": Color(0.45, 0.86, 0.50)
	},
	"reload_speed":
	{
		"name": "Quick Hands",
		"desc": "-7% reload time per level",
		"max_level": 5,
		"base_cost": 250,
		"effect": 0.07,
		"icon": "res://assets/ui/icons/upgrades/reload_speed.svg",
		"color": Color(0.96, 0.74, 0.30)
	},
	"stamina":
	{
		"name": "Conditioning",
		"desc": "+10% stamina per level",
		"max_level": 5,
		"base_cost": 200,
		"effect": 0.10,
		"icon": "res://assets/ui/icons/upgrades/stamina.svg",
		"color": Color(0.34, 0.80, 0.92)
	},
	"weapon_damage":
	{
		"name": "Calibrated Barrels",
		"desc": "+6% weapon damage per level",
		"max_level": 5,
		"base_cost": 350,
		"effect": 0.06,
		"icon": "res://assets/ui/icons/upgrades/weapon_damage.svg",
		"color": Color(0.96, 0.50, 0.28)
	},
	"stash_capacity":
	{
		"name": "Stash Expansion",
		"desc": "+25 stash weight capacity per level",
		"max_level": 6,
		"base_cost": 300,
		"effect": 25.0,
		"icon": "res://assets/ui/icons/upgrades/stash_capacity.svg",
		"color": Color(0.32, 0.74, 0.78)
	},
}

## Cached upgrade-icon textures (loaded once; null if missing/headless). Drawn tinted by the
## upgrade's accent colour in the WORKSHOP upgrade rows. Mirrors Settings.power_icon().
static var _upgrade_icon_cache: Dictionary = {}


static func upgrade_icon(key: String) -> Texture2D:
	if _upgrade_icon_cache.has(key):
		return _upgrade_icon_cache[key]
	var path: String = String(UPGRADES.get(key, {}).get("icon", ""))
	var tex: Texture2D = null
	if path != "" and ResourceLoader.exists(path):
		var res := load(path)
		if res is Texture2D:
			tex = res
	_upgrade_icon_cache[key] = tex
	return tex


# Permanent PER-WEAPON perk catalog (bought in the Gunsmith; never lost). Applied in
# weapon_controller._load_weapons. effect is per level; key meaning per the field used.
#   key -> { name, desc, max_level, base_cost, field, effect }
# field: damage_mult_add | recoil_mult_sub | reload_mult_sub | mag_add (per level)
const WEAPON_PERKS := {
	"mastery":
	{
		"name": "Mastery",
		"desc": "+5% damage / level",
		"max_level": 5,
		"base_cost": 300,
		"field": "damage",
		"effect": 0.05
	},
	"recoil_ctrl":
	{
		"name": "Recoil Control",
		"desc": "-8% recoil / level",
		"max_level": 4,
		"base_cost": 250,
		"field": "recoil",
		"effect": 0.08
	},
	"fast_hands":
	{
		"name": "Fast Hands",
		"desc": "-6% reload / level",
		"max_level": 4,
		"base_cost": 250,
		"field": "reload",
		"effect": 0.06
	},
	"ext_feed":
	{
		"name": "Extended Feed",
		"desc": "+3 mag / level",
		"max_level": 4,
		"base_cost": 300,
		"field": "mag",
		"effect": 3.0
	},
}
const STASH_BASE_CAPACITY := 75.0  # weight; + Stash Expansion upgrade

var currency: int = 0
var unlocked: Array[String] = []  # purchasable weapon ids that have been bought
var upgrades: Dictionary = {}  # key -> level (int)
var loadout: Array[String] = ["rifle", "pistol"]
## Consumables to BRING into the next raid (drawn from the Stash, at risk on death):
## item id -> count, e.g. { "loot_medkit": 2, "loot_grenade": 3 }. Empty = free run.
var bring: Dictionary = {}
## Crafting blueprints learned (by extracting a schematic, buying, or a quest reward).
var unlocked_blueprints: Array[String] = []
## Quest progress: quest id -> current count. completed_quests: ids whose reward was claimed.
var quest_progress: Dictionary = {}
var completed_quests: Array[String] = []
## Iteration-1 quest lifecycle: quest id -> "available"|"active"|"completed"|"claimed".
## ABSENT = LOCKED (default). Replaces the old implicit "everything active".
var quest_states: Dictionary = {}
## Decision-tracking backbone: enemy archetype id -> cumulative PERSONAL kills (the headline
## counter unlock conditions key off). Cumulative successful extractions live alongside.
var kills_by_type: Dictionary = {}
var extractions_total: int = 0
## Per-giver reputation (Iter 3): giver NPC name -> cumulative rep. Tiers via Settings.GIVER_REP_TIERS.
var giver_rep: Dictionary = {}
## Equipped (AT-RISK) attachments: weapon_id -> { slot -> attachment_id }.
var equipped_attachments: Dictionary = {}
## Permanent per-weapon perks: weapon_id -> { perk_key -> level }.
var weapon_perks: Dictionary = {}
## Character customization: permanently UNLOCKED cosmetic part ids (the free defaults are
## always available) + the currently EQUIPPED variant per category (head/torso/arms/legs/
## paint). Replicated to other peers from the player at spawn so co-op shows your look.
var unlocked_cosmetics: Array[String] = []
# First-raid onboarding hint sequence completed (per profile; see onboarding_hints.gd).
var onboarding_done := false
# First HUNTER (nemesis) teaching card shown (per profile; hud.gd shows it once).
var nemesis_intro_done := false
var equipped_cosmetics: Dictionary = {}
## Worn gear (AT-RISK): slot (Settings.GEAR_SLOTS) -> armor item id. Empty slot = none.
var equipped_gear: Dictionary = {}
## Armor durability pool: item id -> remaining float. An ABSENT id reads as full
## (its ArmorData.durability_max). NOTE: keyed by item id, so two identical vests in
## the stash share ONE durability pool — acceptable since gear is max_stack 1 and lost
## gear comes back fresh (reconcile_gear erases the entry when the piece leaves the stash).
var armor_durability: Dictionary = {}
## Insurance (unix-time pattern, like the dailies): item ids covered THIS raid, and
## pending returns ([{id, return_at}]) awaiting their timer after a death.
var insured_current: Array = []
var insured_pending: Array = []
## Daily contracts rotation state.
var last_daily_date: String = ""
var daily_quest_ids: Array[String] = []

# --- Batch 3 progression (per-peer LOCAL; driven by autoload Progression) ----
## Account XP + Raider Level. xp = cumulative lifetime XP; raider_level derived but
## stored so spent skill points stay independent; skill_points = unspent; skills = key→level.
var xp: int = 0
var raider_level: int = 1
var skill_points: int = 0
var skills: Dictionary = {}
## Vendor reputation (cumulative) — drives the rep tier (shop unlocks + discount).
var vendor_rep: int = 0
## Per-weapon mastery: weapon_id -> { "xp": int, "level": int } (use-driven).
var weapon_mastery: Dictionary = {}
## Raider-Level milestones already granted (the milestone LEVELS, e.g. [3,5]) so each is
## applied exactly once; plus the accumulated permanent stash bonus from "stash" milestones.
var milestones_claimed: Array = []
var milestone_stash_bonus: float = 0.0
## Power-cache buffs unlocked with skill points (the non-free ones). Free powers always roll.
var unlocked_powers: Array = []

## Set once if a save from a NEWER game version was loaded this session (so the
## version-mismatch toast fires at most once per file per session).
var _warned_newer := false


func _ready() -> void:
	load_profile()


## Semantic-version compare: returns -1 if a<b, 0 if equal, 1 if a>b. Splits on
## ".", compares ints positionally; missing parts count as 0. Non-numeric parts
## are treated as 0.
func _cmp_version(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	var n: int = maxi(pa.size(), pb.size())
	for i in n:
		var ai := int(pa[i]) if i < pa.size() else 0
		var bi := int(pb[i]) if i < pb.size() else 0
		if ai < bi:
			return -1
		if ai > bi:
			return 1
	return 0


## Compat hook for older saves; currently a no-op (fields default cleanly). Extend
## here when a future build changes a field's shape.
func _migrate(_cfg: ConfigFile, _from_version: String) -> void:
	pass


## Defensively coerce a loaded value into a Dictionary-of-Dictionary (weapon -> inner
## map). Non-dict at the top falls back to {}; any inner value that isn't a Dictionary
## is dropped (that weapon only) so one bad entry can't abort the whole load.
func _load_nested_dict(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var out: Dictionary = {}
	for k in raw as Dictionary:
		var inner: Variant = raw[k]
		if inner is Dictionary:
			out[String(k)] = (inner as Dictionary).duplicate()
	return out


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


# ---------------------------------------------------------------- cosmetics
## A cosmetic variant is available if it's a FREE starter (cost 0) or has been unlocked.
func is_cosmetic_unlocked(variant_id: String) -> bool:
	return ProceduralPlayer.cost_of(variant_id) == 0 or variant_id in unlocked_cosmetics


func cosmetic_cost(variant_id: String) -> int:
	return ProceduralPlayer.cost_of(variant_id)


## Buy + unlock a cosmetic variant (spends currency). Returns true if newly unlocked.
## Stamp the first-raid onboarding sequence as seen (persisted immediately).
func mark_onboarding_done() -> void:
	if onboarding_done:
		return
	onboarding_done = true
	save_profile()


## Stamp the first-hunter teaching card as seen (persisted immediately).
func mark_nemesis_intro_done() -> void:
	if nemesis_intro_done:
		return
	nemesis_intro_done = true
	save_profile()


func unlock_cosmetic(variant_id: String) -> bool:
	if is_cosmetic_unlocked(variant_id):
		return false
	if ProceduralPlayer.category_of(variant_id) == "":
		return false
	if not spend(ProceduralPlayer.cost_of(variant_id)):
		return false
	unlocked_cosmetics.append(variant_id)
	save_profile()
	Events.cosmetics_changed.emit()
	return true


## Grant a cosmetic WITHOUT spending currency (quest / giver-tier reward, incl. quest-exclusive
## cost = -1 paints). Returns true if newly unlocked.
func unlock_cosmetic_free(variant_id: String) -> bool:
	if variant_id == "" or ProceduralPlayer.category_of(variant_id) == "":
		return false
	if variant_id in unlocked_cosmetics or ProceduralPlayer.cost_of(variant_id) == 0:
		return false  # already owned / a free starter
	unlocked_cosmetics.append(variant_id)
	save_profile()
	Events.cosmetics_changed.emit()
	return true


func get_equipped_cosmetic(category: String) -> String:
	var picked: String = String(equipped_cosmetics.get(category, ""))
	if picked != "" and ProceduralPlayer.category_of(picked) == category:
		return picked
	return String(ProceduralPlayer.defaults().get(category, ""))


## Equip an UNLOCKED variant in its category. No-op if locked.
func set_equipped_cosmetic(variant_id: String) -> void:
	var cat := ProceduralPlayer.category_of(variant_id)
	if cat == "" or not is_cosmetic_unlocked(variant_id):
		return
	equipped_cosmetics[cat] = variant_id
	save_profile()
	Events.cosmetics_changed.emit()


## The full equipped look {head,torso,arms,legs,paint} — handed to the player at spawn
## and replicated to other peers. Missing/locked categories fall back to the free default.
func get_cosmetics() -> Dictionary:
	var out := ProceduralPlayer.defaults()
	for cat in ProceduralPlayer.CATEGORIES:
		out[cat] = get_equipped_cosmetic(cat)
	return out


# ---------------------------------------------------------------- gear (at-risk armor)
func get_equipped_gear() -> Dictionary:
	return equipped_gear.duplicate()


## Equip an armor item in a slot (empty id = unequip). Validates the slot and that the
## item is an ArmorData declaring that slot. Emits gear_changed + persists.
func set_equipped_gear(slot: String, id: String) -> void:
	if slot not in Settings.GEAR_SLOTS:
		return
	if id == "":
		equipped_gear.erase(slot)
	else:
		var item := ItemCatalog.get_item(id)
		if not (item is ArmorData) or (item as ArmorData).slot != slot:
			return
		equipped_gear[slot] = id
	save_profile()
	Events.gear_changed.emit()


## Per-item armor durability resolver: absent id → that item's durability_max (i.e.
## FULL, never persisted until it takes a hit); an unknown/non-armor id → 0.
func durability_of(id: String) -> float:
	if armor_durability.has(id):
		return float(armor_durability[id])
	var item := ItemCatalog.get_item(id)
	if item is ArmorData:
		return (item as ArmorData).durability_max
	return 0.0


## Maximum durability for an armor id (0 for unknown / indestructible packs).
func armor_durability_max(id: String) -> float:
	var item := ItemCatalog.get_item(id)
	return (item as ArmorData).durability_max if item is ArmorData else 0.0


## Set an armor piece's remaining durability (clamped 0..max). Emits armor_changed
## (broken = value <= 0) + persists.
func set_armor_durability(id: String, value: float) -> void:
	var mx := armor_durability_max(id)
	var v := clampf(value, 0.0, mx)
	armor_durability[id] = v
	save_profile()
	Events.armor_changed.emit(id, v, v <= 0.0)


## Drain `amount` of durability from an armor piece (damage absorbed).
func drain_armor(id: String, amount: float) -> void:
	if amount <= 0.0:
		return
	set_armor_durability(id, durability_of(id) - amount)


func is_armor_broken(id: String) -> bool:
	return durability_of(id) <= 0.0


## Currency to fully repair a piece: ceili(value * ARMOR_REPAIR_COST_FRAC * missing_frac).
## 0 when full or indestructible (durability_max 0).
func repair_cost(id: String) -> int:
	var item := ItemCatalog.get_item(id)
	if not (item is ArmorData):
		return 0
	var mx := (item as ArmorData).durability_max
	if mx <= 0.0:
		return 0
	var missing_frac := 1.0 - durability_of(id) / mx
	if missing_frac <= 0.0:
		return 0
	return ceili(item.value * Settings.ARMOR_REPAIR_COST_FRAC * missing_frac)


## Repair a piece to full if affordable + actually damaged. Returns true on success.
func repair_armor(id: String) -> bool:
	var cost := repair_cost(id)
	if cost <= 0 or not spend(cost):
		return false
	var mx := armor_durability_max(id)
	armor_durability[id] = mx
	save_profile()
	Events.armor_changed.emit(id, mx, false)
	return true


## Drop any equipped gear whose item is no longer in the Stash (lost on a failed raid),
## erasing its durability entry so it returns FRESH next time. Called when the Hub opens
## (lead wires this next to reconcile_attachments — see hub.gd). Returns true if changed.
func reconcile_gear() -> bool:
	var changed := false
	for slot in equipped_gear.keys():
		var id := String(equipped_gear[slot])
		if Stash.count_of(id) <= 0:
			equipped_gear.erase(slot)
			armor_durability.erase(id)
			changed = true
	if changed:
		save_profile()
	return changed


## Sum of carry-weight bonuses from equipped backpacks (read by the player at deploy).
func gear_carry_bonus() -> float:
	var total := 0.0
	for slot in equipped_gear:
		var item := ItemCatalog.get_item(String(equipped_gear[slot]))
		if item is ArmorData:
			total += (item as ArmorData).carry_bonus
	return total


## Product of movement-speed multipliers from equipped gear (heavy pack < 1.0).
func gear_speed_mult() -> float:
	var mult := 1.0
	for slot in equipped_gear:
		var item := ItemCatalog.get_item(String(equipped_gear[slot]))
		if item is ArmorData:
			mult *= (item as ArmorData).speed_mult
	return mult


## One Dictionary per equipped armor piece — the damage-mitigation consumer. Broken
## pieces are still listed (broken = true) so the consumer can decide to ignore them.
##   { id, slot, mitigation, durability, durability_max, broken }
func equipped_armor_pieces() -> Array:
	var out: Array = []
	for slot in equipped_gear:
		var id := String(equipped_gear[slot])
		var item := ItemCatalog.get_item(id)
		if not (item is ArmorData):
			continue
		var armor := item as ArmorData
		(
			out
			. append(
				{
					"id": id,
					"slot": armor.slot,
					"mitigation": armor.mitigation,
					"durability": durability_of(id),
					"durability_max": armor.durability_max,
					"broken": is_armor_broken(id),
				}
			)
		)
	return out


# ---------------------------------------------------------------- insurance
## Currency to insure an item for one raid: ceili(value * INSURANCE_COST_FRAC).
func insurance_cost(id: String) -> int:
	var item := ItemCatalog.get_item(id)
	return ceili(item.value * Settings.INSURANCE_COST_FRAC) if item != null else 0


func is_insured(id: String) -> bool:
	return id in insured_current


## Insure an item for the next raid (one entry per id). Returns true on success.
func insure_item(id: String) -> bool:
	if id == "" or is_insured(id):
		return false
	if not spend(insurance_cost(id)):
		return false
	insured_current.append(id)
	save_profile()
	Events.insurance_changed.emit()
	return true


## On death (gear lost): convert each insured item into a pending return that matures
## after INSURANCE_RETURN_MINUTES. Clears current coverage. Emits insurance_changed.
func convert_insured_to_pending() -> void:
	if insured_current.is_empty():
		return
	var return_at := (
		Time.get_unix_time_from_system() + int(Settings.INSURANCE_RETURN_MINUTES * 60.0)
	)
	for id in insured_current:
		insured_pending.append({"id": String(id), "return_at": return_at})
	insured_current.clear()
	save_profile()
	Events.insurance_changed.emit()


## On a successful extract: the gear survived, so the coverage is simply spent (no return).
func clear_insurance_on_extract() -> void:
	if insured_current.is_empty():
		return
	insured_current.clear()
	save_profile()
	Events.insurance_changed.emit()


## Deposit any matured pending insurance back into the Stash. Returns the claimed ids.
func claim_matured_insurance() -> Array:
	var now := Time.get_unix_time_from_system()
	var claimed: Array = []
	var still_pending: Array = []
	for entry in insured_pending:
		if int((entry as Dictionary).get("return_at", 0)) <= now:
			var id := String((entry as Dictionary).get("id", ""))
			if id != "":
				Stash.add(id, 1)
				claimed.append(id)
		else:
			still_pending.append(entry)
	if not claimed.is_empty():
		insured_pending = still_pending
		save_profile()
		Events.insurance_changed.emit()
	return claimed


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


# ---------------------------------------------------------------- quest lifecycle / decisions
## Lifecycle state for a quest id ("" = LOCKED, the default for an un-offered quest).
func quest_state(id: String) -> String:
	return String(quest_states.get(id, ""))


## Persists a quest's lifecycle state (Quests autoload drives this). "" clears it (→ LOCKED).
func set_quest_state(id: String, s: String) -> void:
	if s == "":
		quest_states.erase(id)
	else:
		quest_states[id] = s
	save_profile()


## Records one personal kill of `enemy_id` (the decision counter unlock conditions read).
## NOT auto-saved here — callers batch the save (it fires once per kill, very hot).
func record_kill_type(enemy_id: String) -> void:
	if enemy_id == "":
		return
	kills_by_type[enemy_id] = int(kills_by_type.get(enemy_id, 0)) + 1


## Cumulative personal kills of one archetype, or the grand total across all archetypes.
func kills_of(enemy_id: String) -> int:
	return int(kills_by_type.get(enemy_id, 0))


func total_mob_kills() -> int:
	var n := 0
	for k in kills_by_type:
		n += int(kills_by_type[k])
	return n


## Bumps the cumulative successful-extraction counter (decision stat). Saved by the caller.
func inc_extractions() -> void:
	extractions_total += 1


# ---------------------------------------------------------------- per-giver reputation (Iter 3)
func giver_rep_of(giver: String) -> int:
	return int(giver_rep.get(giver, 0))


## Tier index for a giver (mirrors rep_tier over Settings.GIVER_REP_TIERS).
func giver_rep_tier(giver: String) -> int:
	var rep := giver_rep_of(giver)
	var t := 0
	for i in Settings.GIVER_REP_TIERS.size():
		if rep >= int(Settings.GIVER_REP_TIERS[i]):
			t = i
	return t


## { tier, into, need } toward the next giver tier (need 0 = max).
func giver_rep_progress(giver: String) -> Dictionary:
	var t := giver_rep_tier(giver)
	var base := int(Settings.GIVER_REP_TIERS[t])
	var nxt := t + 1
	if nxt >= Settings.GIVER_REP_TIERS.size():
		return {"tier": t, "into": 0, "need": 0}
	var ceiling := int(Settings.GIVER_REP_TIERS[nxt])
	return {"tier": t, "into": giver_rep_of(giver) - base, "need": ceiling - base}


## Award reputation toward a giver; grants per-tier rewards on tier-up. Emits giver_rep_changed.
func grant_giver_rep(giver: String, amount: int) -> void:
	if giver == "" or amount <= 0:
		return
	var before := giver_rep_tier(giver)
	giver_rep[giver] = giver_rep_of(giver) + amount
	var after := giver_rep_tier(giver)
	if after > before:
		for tier in range(before + 1, after + 1):
			var rw: Dictionary = Settings.GIVER_REP_TIER_REWARDS.get(tier, {})
			var cur := int(rw.get("currency", 0))
			if cur > 0:
				earn(cur)
			var cos := String(rw.get("cosmetic", ""))
			if cos != "":
				unlock_cosmetic_free(cos)
	save_profile()
	Events.giver_rep_changed.emit(giver, giver_rep_of(giver), after)


# ---------------------------------------------------------------- stash capacity
func stash_capacity() -> float:
	return (
		STASH_BASE_CAPACITY
		+ upgrade_level("stash_capacity") * float(UPGRADES["stash_capacity"]["effect"])
		+ milestone_stash_bonus
	)


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


# ---------------------------------------------------------------- Raider Level / XP
## XP needed to advance FROM `level` to level+1 (level >= 1).
func xp_to_advance(level: int) -> int:
	return int(round(Settings.XP_CURVE_BASE * pow(Settings.XP_CURVE_GROWTH, maxi(0, level - 1))))


## Cumulative XP required to BE at `level` (level 1 = 0).
func _total_xp_for_level(level: int) -> int:
	var t := 0
	for n in range(1, level):
		t += xp_to_advance(n)
	return t


## Award account XP (from kills/extract/events/loot). Rolls level-ups, granting skill
## points, and persists. Emits xp_gained always + raider_level_up on a level change.
func add_xp(amount: int, source: String = "") -> void:
	if amount <= 0:
		return
	xp += amount
	Events.xp_gained.emit(amount, source)
	var new_level := 1
	while xp >= _total_xp_for_level(new_level + 1):
		new_level += 1
	if new_level > raider_level:
		skill_points += (new_level - raider_level) * Settings.SKILL_POINTS_PER_LEVEL
		raider_level = new_level
		_apply_milestones()
		Events.raider_level_up.emit(raider_level, skill_points)
	save_profile()


## Grant any Raider-Level milestone whose level we've now reached but not yet claimed.
## Idempotent (tracked in milestones_claimed). Gives leveling a permanent point — a free
## weapon / stash bump / currency — WITHOUT an Arc-Raiders-style tech tree. Called on
## level-up + once on load (so an interrupted/older save back-fills cleanly).
func _apply_milestones() -> void:
	for lvl in Settings.RAIDER_MILESTONES:
		if int(lvl) > raider_level or int(lvl) in milestones_claimed:
			continue
		var m: Dictionary = Settings.RAIDER_MILESTONES[lvl]
		match String(m.get("kind", "")):
			"unlock_weapon":
				var wid := String(m.get("value", ""))
				if wid != "" and wid not in unlocked and wid not in FREE_WEAPONS:
					unlocked.append(wid)
			"stash":
				milestone_stash_bonus += float(m.get("value", 0))
			"currency":
				currency += int(m.get("value", 0))
				Events.currency_changed.emit(currency)
		milestones_claimed.append(int(lvl))
		Events.notify.emit(
			tr("Raider L%d: %s") % [int(lvl), tr(String(m.get("label", "reward")))], 1
		)


## The next unclaimed milestone (for the RAIDER tab), or {} if all are claimed.
func next_milestone() -> Dictionary:
	var best_lvl: int = -1
	for lvl in Settings.RAIDER_MILESTONES:
		var li := int(lvl)
		if li not in milestones_claimed and (best_lvl < 0 or li < best_lvl):
			best_lvl = li
	if best_lvl < 0:
		return {}
	var m: Dictionary = (Settings.RAIDER_MILESTONES[best_lvl] as Dictionary).duplicate()
	m["level"] = best_lvl
	return m


## UI helper: { level, into (xp into current level), need (xp to next), total }.
func level_progress() -> Dictionary:
	var base := _total_xp_for_level(raider_level)
	return {
		"level": raider_level,
		"into": xp - base,
		"need": xp_to_advance(raider_level),
		"total": xp,
	}


# ---------------------------------------------------------------- skills
func skill_level(key: String) -> int:
	return int(skills.get(key, 0))


func skill_max(key: String) -> int:
	return int(Settings.SKILLS.get(key, {}).get("max", 0))


## Spend one skill point on `key` (if available + not maxed). Returns true on success.
func buy_skill(key: String) -> bool:
	if not Settings.SKILLS.has(key):
		return false
	if skill_points <= 0 or skill_level(key) >= skill_max(key):
		return false
	skill_points -= 1
	skills[key] = skill_level(key) + 1
	save_profile()
	return true


## Combined multiplicative factor a skill contributes to its player_mods field.
func _skill_factor(key: String) -> float:
	var per := float(Settings.SKILLS.get(key, {}).get("per", 0.0))
	return 1.0 + per * skill_level(key)


# ---------------------------------------------------------------- power caches
## True if power `id` can roll from a cache (free powers always, others once unlocked).
func is_power_unlocked(id: String) -> bool:
	var def: Dictionary = Settings.POWERS.get(id, {})
	if def.is_empty():
		return false
	if bool(def.get("free", false)):
		return true
	return unlocked_powers.has(id)


## Spend skill points to unlock a non-free power. Returns true on success.
func unlock_power(id: String) -> bool:
	var def: Dictionary = Settings.POWERS.get(id, {})
	if def.is_empty() or bool(def.get("free", false)) or unlocked_powers.has(id):
		return false
	var cost: int = int(def.get("cost", 1))
	if skill_points < cost:
		return false
	skill_points -= cost
	unlocked_powers.append(id)
	save_profile()
	return true


## Ids of every power that can currently roll from a cache (free ∪ unlocked).
func available_powers() -> Array:
	var out: Array = []
	for id in Settings.POWERS:
		if is_power_unlocked(String(id)):
			out.append(String(id))
	return out


# ---------------------------------------------------------------- vendor reputation
## The rep tier for the current vendor_rep (index into REP_TIER_THRESHOLDS).
func rep_tier() -> int:
	var t := 0
	for i in Settings.REP_TIER_THRESHOLDS.size():
		if vendor_rep >= int(Settings.REP_TIER_THRESHOLDS[i]):
			t = i
	return t


## Rep toward the NEXT tier: { tier, into, need } (need 0 = max tier).
func rep_progress() -> Dictionary:
	var t := rep_tier()
	var base := int(Settings.REP_TIER_THRESHOLDS[t])
	var nxt := t + 1
	if nxt >= Settings.REP_TIER_THRESHOLDS.size():
		return {"tier": t, "into": 0, "need": 0}
	var ceiling := int(Settings.REP_TIER_THRESHOLDS[nxt])
	return {"tier": t, "into": vendor_rep - base, "need": ceiling - base}


## Award reputation; on crossing a tier, grant its reward (currency + blueprint). Emits
## reputation_changed. (earn()/learn_blueprint() each persist.)
func grant_rep(amount: int) -> void:
	if amount <= 0:
		return
	var before := rep_tier()
	vendor_rep += amount
	var after := rep_tier()
	if after > before:
		for tier in range(before + 1, after + 1):
			var rw: Dictionary = Settings.REP_TIER_REWARDS.get(tier, {})
			var cur := int(rw.get("currency", 0))
			if cur > 0:
				earn(cur)
			var bp := String(rw.get("blueprint", ""))
			if bp != "":
				learn_blueprint(bp)
	save_profile()
	Events.reputation_changed.emit(vendor_rep, after)


## Shop price discount fraction from the current rep tier (0.0 … 0.20).
func rep_discount() -> float:
	return float(Settings.REP_TIER_DISCOUNT.get(rep_tier(), 0.0))


# ---------------------------------------------------------------- weapon mastery
func weapon_mastery_level(weapon_id: String) -> int:
	return int((weapon_mastery.get(weapon_id, {}) as Dictionary).get("level", 0))


func weapon_mastery_xp(weapon_id: String) -> int:
	return int((weapon_mastery.get(weapon_id, {}) as Dictionary).get("xp", 0))


## Mastery XP to advance FROM `level` to level+1.
func mastery_to_advance(level: int) -> int:
	return int(round(Settings.WEAPON_MASTERY_BASE * float(level + 1)))


## Add mastery XP to a weapon (from kills/use). Rolls level-ups (capped at MAX),
## persists, emits weapon_mastery_changed on a level change.
func add_weapon_mastery(weapon_id: String, amount: int) -> void:
	if weapon_id == "" or amount <= 0:
		return
	var m: Dictionary = (weapon_mastery.get(weapon_id, {}) as Dictionary).duplicate()
	var lvl := int(m.get("level", 0))
	var mxp := int(m.get("xp", 0)) + amount
	var leveled := false
	while lvl < Settings.WEAPON_MASTERY_MAX and mxp >= mastery_to_advance(lvl):
		mxp -= mastery_to_advance(lvl)
		lvl += 1
		leveled = true
	m["xp"] = mxp
	m["level"] = lvl
	weapon_mastery[weapon_id] = m
	save_profile()
	if leveled:
		Events.weapon_mastery_changed.emit(weapon_id, lvl)


# ---------------------------------------------------------------- effects
## Stat multipliers from the current upgrade levels + Batch-3 account skills (folded
## multiplicatively), read at match start by the player (health/stamina) and weapon
## controller (damage/reload). reload_mult < 1 means faster reloads. loot_mult scales
## the extraction reward (applied in RaidManager).
func player_mods() -> Dictionary:
	return {
		"health_mult":
		(
			(1.0 + UPGRADES["player_health"]["effect"] * upgrade_level("player_health"))
			* _skill_factor("vitality")
		),
		"reload_mult": 1.0 - UPGRADES["reload_speed"]["effect"] * upgrade_level("reload_speed"),
		"stamina_mult":
		(
			(1.0 + UPGRADES["stamina"]["effect"] * upgrade_level("stamina"))
			* _skill_factor("endurance")
		),
		"damage_mult":
		(
			(1.0 + UPGRADES["weapon_damage"]["effect"] * upgrade_level("weapon_damage"))
			* _skill_factor("gunner")
		),
		"loot_mult": _skill_factor("scavenger"),
	}


# ---------------------------------------------------------------- persistence
func save_profile() -> void:
	if Settings.ephemeral_save:
		return  # --no-save test run: progression is not persisted
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", Settings.GAME_VERSION)
	cfg.set_value("meta", "onboarding_done", onboarding_done)
	cfg.set_value("meta", "nemesis_intro_done", nemesis_intro_done)
	cfg.set_value("meta", "currency", currency)
	cfg.set_value("meta", "unlocked", unlocked)
	cfg.set_value("meta", "upgrades", upgrades)
	cfg.set_value("meta", "loadout", loadout)
	cfg.set_value("meta", "bring", bring)
	cfg.set_value("meta", "blueprints", unlocked_blueprints)
	cfg.set_value("meta", "quest_progress", quest_progress)
	cfg.set_value("meta", "completed_quests", completed_quests)
	cfg.set_value("meta", "quest_states", quest_states)
	cfg.set_value("meta", "kills_by_type", kills_by_type)
	cfg.set_value("meta", "extractions_total", extractions_total)
	cfg.set_value("meta", "giver_rep", giver_rep)
	cfg.set_value("meta", "equipped_attachments", equipped_attachments)
	cfg.set_value("meta", "weapon_perks", weapon_perks)
	cfg.set_value("meta", "unlocked_cosmetics", unlocked_cosmetics)
	cfg.set_value("meta", "equipped_cosmetics", equipped_cosmetics)
	cfg.set_value("meta", "equipped_gear", equipped_gear)
	cfg.set_value("meta", "armor_durability", armor_durability)
	cfg.set_value("meta", "insured_current", insured_current)
	cfg.set_value("meta", "insured_pending", insured_pending)
	cfg.set_value("meta", "last_daily_date", last_daily_date)
	cfg.set_value("meta", "daily_quest_ids", daily_quest_ids)
	cfg.set_value("meta", "difficulty", GameState.difficulty)
	# Batch 3 progression.
	cfg.set_value("meta", "xp", xp)
	cfg.set_value("meta", "raider_level", raider_level)
	cfg.set_value("meta", "skill_points", skill_points)
	cfg.set_value("meta", "skills", skills)
	cfg.set_value("meta", "vendor_rep", vendor_rep)
	cfg.set_value("meta", "weapon_mastery", weapon_mastery)
	cfg.set_value("meta", "milestones_claimed", milestones_claimed)
	cfg.set_value("meta", "milestone_stash_bonus", milestone_stash_bonus)
	cfg.set_value("meta", "unlocked_powers", unlocked_powers)
	cfg.save(_save_path())


func load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_save_path()) != OK:
		return
	# Version resilience: a missing stamp = legacy pre-versioning save (compatible).
	# A NEWER save than this build → warn once but still load every field we can.
	var save_ver := String(cfg.get_value("meta", "save_version", ""))
	if save_ver != "" and _cmp_version(save_ver, Settings.GAME_VERSION) > 0:
		if not _warned_newer:
			_warned_newer = true
			push_warning(
				(
					"[MetaProgression] profile.cfg is from a newer game version (v%s > v%s) — loading what we can."
					% [save_ver, Settings.GAME_VERSION]
				)
			)
			Events.notify.emit(
				"Save is from a newer game version (v%s) — loading what we can." % save_ver, 2
			)
	else:
		_migrate(cfg, save_ver)
	onboarding_done = bool(cfg.get_value("meta", "onboarding_done", false))
	nemesis_intro_done = bool(cfg.get_value("meta", "nemesis_intro_done", false))
	currency = int(cfg.get_value("meta", "currency", 0))
	var raw_unlocked: Array = cfg.get_value("meta", "unlocked", [])
	unlocked.clear()
	for id in raw_unlocked:
		unlocked.append(String(id))
	var raw_upgrades: Variant = cfg.get_value("meta", "upgrades", {})
	upgrades = raw_upgrades if raw_upgrades is Dictionary else {}
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
	var raw_qp: Variant = cfg.get_value("meta", "quest_progress", {})
	quest_progress = raw_qp if raw_qp is Dictionary else {}
	var raw_cq: Array = cfg.get_value("meta", "completed_quests", [])
	completed_quests.clear()
	for qid in raw_cq:
		completed_quests.append(String(qid))
	# Iteration-1 quest lifecycle + decision stats (defensively coerced; defaults for old saves).
	var raw_qs: Variant = cfg.get_value("meta", "quest_states", {})
	quest_states = {}
	if raw_qs is Dictionary:
		for k in raw_qs as Dictionary:
			quest_states[String(k)] = String((raw_qs as Dictionary)[k])
	var raw_kbt: Variant = cfg.get_value("meta", "kills_by_type", {})
	kills_by_type = {}
	if raw_kbt is Dictionary:
		for k in raw_kbt as Dictionary:
			kills_by_type[String(k)] = int((raw_kbt as Dictionary)[k])
	extractions_total = int(cfg.get_value("meta", "extractions_total", 0))
	var raw_gr: Variant = cfg.get_value("meta", "giver_rep", {})
	giver_rep = {}
	if raw_gr is Dictionary:
		for k in raw_gr as Dictionary:
			giver_rep[String(k)] = int((raw_gr as Dictionary)[k])
	# MIGRATION (never wipe): a save that predates the lifecycle has no quest_states — derive
	# them from legacy data so old contracts don't vanish. Claimed → "claimed"; anything with
	# recorded progress → "active"; everything else stays LOCKED until the director offers it.
	if (
		quest_states.is_empty()
		and (not completed_quests.is_empty() or not quest_progress.is_empty())
	):
		for cqid in completed_quests:
			quest_states[String(cqid)] = "claimed"
		for pqid in quest_progress:
			var pid := String(pqid)
			if not quest_states.has(pid) and int(quest_progress[pqid]) > 0:
				quest_states[pid] = "active"
	# Nested weapon->{slot/perk->value} dicts: validate the outer + each inner so a
	# malformed/newer-shaped value defaults that weapon only, never crashing the load.
	equipped_attachments = _load_nested_dict(cfg.get_value("meta", "equipped_attachments", {}))
	weapon_perks = _load_nested_dict(cfg.get_value("meta", "weapon_perks", {}))
	# Cosmetics: unlocked variant ids + equipped-per-category (defensively coerced; unknown
	# ids are dropped, and get_equipped_cosmetic() falls back to the free default).
	var raw_uc: Array = cfg.get_value("meta", "unlocked_cosmetics", [])
	unlocked_cosmetics.clear()
	for cid in raw_uc:
		unlocked_cosmetics.append(String(cid))
	equipped_cosmetics.clear()
	var raw_ec: Variant = cfg.get_value("meta", "equipped_cosmetics", {})
	if raw_ec is Dictionary:
		for cat in raw_ec as Dictionary:
			equipped_cosmetics[String(cat)] = String((raw_ec as Dictionary)[cat])
	# Gear + armor durability (defensively coerced; unknown slots dropped). Pre-batch-B
	# saves have none → empty defaults; lost gear is reconciled away on the next Hub open.
	equipped_gear = {}
	var raw_eg: Variant = cfg.get_value("meta", "equipped_gear", {})
	if raw_eg is Dictionary:
		for slot in raw_eg as Dictionary:
			if String(slot) in Settings.GEAR_SLOTS:
				equipped_gear[String(slot)] = String((raw_eg as Dictionary)[slot])
	armor_durability = {}
	var raw_ad: Variant = cfg.get_value("meta", "armor_durability", {})
	if raw_ad is Dictionary:
		for k in raw_ad as Dictionary:
			armor_durability[String(k)] = float((raw_ad as Dictionary)[k])
	# Insurance: covered ids (deduped) + pending returns ([{id, return_at}]).
	insured_current = []
	var raw_ic: Variant = cfg.get_value("meta", "insured_current", [])
	if raw_ic is Array:
		for iid in raw_ic as Array:
			var sid := String(iid)
			if sid != "" and sid not in insured_current:
				insured_current.append(sid)
	insured_pending = []
	var raw_ip: Variant = cfg.get_value("meta", "insured_pending", [])
	if raw_ip is Array:
		for entry in raw_ip as Array:
			if entry is Dictionary and (entry as Dictionary).has("id"):
				(
					insured_pending
					. append(
						{
							"id": String((entry as Dictionary)["id"]),
							"return_at": int((entry as Dictionary).get("return_at", 0)),
						}
					)
				)
	last_daily_date = String(cfg.get_value("meta", "last_daily_date", ""))
	var raw_dq: Array = cfg.get_value("meta", "daily_quest_ids", [])
	daily_quest_ids.clear()
	for did in raw_dq:
		daily_quest_ids.append(String(did))
	GameState.difficulty = int(cfg.get_value("meta", "difficulty", GameState.Difficulty.NORMAL))
	# Batch 3 progression (default cleanly for pre-0.3.0 saves).
	xp = int(cfg.get_value("meta", "xp", 0))
	raider_level = maxi(1, int(cfg.get_value("meta", "raider_level", 1)))
	skill_points = int(cfg.get_value("meta", "skill_points", 0))
	var raw_skills: Variant = cfg.get_value("meta", "skills", {})
	skills = raw_skills if raw_skills is Dictionary else {}
	vendor_rep = int(cfg.get_value("meta", "vendor_rep", 0))
	# weapon_mastery is weapon_id -> { xp, level } (inner dicts) — _load_nested_dict validates.
	weapon_mastery = _load_nested_dict(cfg.get_value("meta", "weapon_mastery", {}))
	var raw_ms: Array = cfg.get_value("meta", "milestones_claimed", [])
	milestones_claimed.clear()
	for ml in raw_ms:
		milestones_claimed.append(int(ml))
	milestone_stash_bonus = float(cfg.get_value("meta", "milestone_stash_bonus", 0.0))
	var raw_up: Array = cfg.get_value("meta", "unlocked_powers", [])
	unlocked_powers.clear()
	for pid in raw_up:
		if Settings.POWERS.has(String(pid)):
			unlocked_powers.append(String(pid))
	# Back-fill any milestone the saved level qualifies for but predates this feature.
	_apply_milestones()
