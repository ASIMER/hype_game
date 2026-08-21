extends ItemData
class_name AttachmentData
## A weapon attachment — a physical, AT-RISK mod (scope / mag / barrel / grip) that
## modifies a weapon's stats while equipped. It EXTENDS ItemData, so it lives in the
## Stash like any loot (icon/weight/value/rarity), is found/crafted/bought, and is
## committed-at-deploy / kept-on-extract / LOST-on-death like the consumable bring-list.
## Saved as .tres under resources/attachments/ (set `kind = 4` = Kind.ATTACHMENT).
##
## Stat mods are applied in weapon_controller._load_weapons() AFTER the difficulty +
## permanent-upgrade mults, on the duplicated WeaponData (so the cached .tres is safe).

## Equip slot — at most one attachment per slot per weapon.
@export var slot: String = "optic"  # optic | mag | barrel | grip
## Weapon ids this fits; empty = fits all weapons.
@export var compatible_weapons: PackedStringArray = PackedStringArray()

# --- Stat modifiers (multiplicative unless _add) ---
@export var damage_mult: float = 1.0
@export var fire_rate_mult: float = 1.0
@export var recoil_mult: float = 1.0  # <1 = less kick
@export var spread_mult: float = 1.0  # <1 = tighter
@export var reload_mult: float = 1.0  # <1 = faster
@export var ads_fov_mult: float = 1.0  # <1 = more zoom
@export var range_mult: float = 1.0
@export var mag_add: int = 0
@export var reserve_add: int = 0
@export var crit_add: float = 0.0
@export var noise_mult: float = 1.0  # <1 = quieter (suppressor); composable
## Elemental ammo (Chemistry Phase 6): "" = none, else "shock"|"burn"|"slow" — the mag
## turns every landed hit into a machine-chemistry tag (last equipped element wins).
@export var element: String = ""


## Applies this attachment's mods to a (duplicated) WeaponData in place.
func apply_to(w: WeaponData) -> void:
	w.damage *= damage_mult
	w.fire_rate = maxf(0.1, w.fire_rate * fire_rate_mult)
	w.recoil = maxf(0.0, w.recoil * recoil_mult)
	w.spread_deg = maxf(0.0, w.spread_deg * spread_mult)
	w.reload_time = maxf(0.1, w.reload_time * reload_mult)
	w.ads_fov = clampf(w.ads_fov * ads_fov_mult, 5.0, 179.0)
	w.range = maxf(1.0, w.range * range_mult)
	w.mag_size = maxi(1, w.mag_size + mag_add)
	w.reserve_max = maxi(0, w.reserve_max + reserve_add)
	w.crit_mult = maxf(1.0, w.crit_mult + crit_add)
	if "noise_mult" in w:
		w.noise_mult *= noise_mult
	if element != "" and "element" in w:
		w.element = element


## True when this attachment fits the given weapon id.
func fits(weapon_id: String) -> bool:
	return compatible_weapons.is_empty() or weapon_id in compatible_weapons
