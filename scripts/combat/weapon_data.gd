extends Resource
class_name WeaponData
## Pure-data definition of one weapon. Saved as .tres under resources/weapons/.
## No scene/node references so it is safe to load from the controller, HUD, and
## loot tables alike. The Weapon node consumes these per-shot via fire_with().

@export var id: String = "rifle"  # logical id, also AssetRegistry model key
@export var display_name: String = "Rifle"
@export var damage: float = 12.0  # per pellet
@export var fire_rate: float = 8.0  # shots per second (cooldown = 1/fire_rate)
@export var auto: bool = true  # true: held-to-fire, false: one shot per press
@export var pellets: int = 1  # rays per shot (shotgun fires many)
@export var spread_deg: float = 0.5  # cone half-angle in degrees per ray
@export var recoil: float = 1.0  # kick magnitude (read by the player camera)
@export var mag_size: int = 30
@export var reserve_max: int = 180
@export var reload_time: float = 2.0
@export var ads_fov: float = 42.0  # zoomed FOV when aiming this weapon
@export var range: float = 80.0  # hitscan max distance
@export var crit_mult: float = 2.0  # extra multiplier applied on weak-point hits
# Audible-noise radius multiplier; suppressor lowers it. 1.0 = baseline NOISE_GUNFIRE.
@export var noise_mult: float = 1.0
# Elemental ammo (Machine Chemistry Phase 6): "" = plain rounds, else "shock"|"burn"|"slow".
# Set by an equipped elemental mag (AttachmentData.element); each landed hit routes the
# KIND to the server, which derives every number from Settings.CHEM_AMMO_*.
@export var element: String = ""
## --- Feel / juice (cosmetic) ---
## View-model kickback magnitude per shot (0 = use `recoil`). The held gun punches back+up then
## springs to rest. Set higher for heavy guns (shotgun/DMR), lower for SMG.
@export var kick: float = 0.0
## Muzzle FX size multiplier (flash / smoke / shell). 1.0 = baseline; shotgun big, SMG small.
@export var muzzle_scale: float = 1.0
## Weapon sound class for per-class gunfire audio (pitch/weight): "pistol"|"rifle"|"smg"|
## "shotgun"|"dmr". Empty → derived from id.
@export var sound_class: String = ""


## Effective view-model kick (falls back to recoil when kick is 0).
func kick_amount() -> float:
	return kick if kick > 0.0 else recoil
