extends ItemData
class_name ArmorData
## A wearable armor / pack piece — an AT-RISK survival item (helmet / vest / backpack)
## equipped in one of Settings.GEAR_SLOTS. It EXTENDS ItemData, so it lives in the Stash
## like any loot (icon/weight/value/rarity), is found/bought, and is committed-at-deploy /
## kept-on-extract / LOST-on-death like the consumable bring-list and attachments.
## Saved as .tres under resources/items/ (set `kind = 5` = Kind.ARMOR).
##
## Helmets/vests reduce incoming damage while intact, draining `durability_max` as they
## absorb hits (the consumer is MetaProgression.equipped_armor_pieces()). Backpacks instead
## raise the inventory weight cap (`carry_bonus`) at a movement cost (`speed_mult`); they
## carry no mitigation and are indestructible (`durability_max = 0`).

## Equip slot — one of Settings.GEAR_SLOTS ("helmet" | "vest" | "backpack").
@export var slot: String = "vest"
## Fraction of incoming damage blocked while the piece is intact (0..1; 0 for backpacks).
## The total across equipped pieces is clamped to Settings.ARMOR_MITIGATION_CAP by the
## damage consumer.
@export var mitigation: float = 0.0
## Health pool the piece spends as it absorbs damage; 0 = indestructible (backpacks).
@export var durability_max: float = 100.0
## Inventory weight-cap bonus granted while equipped (backpacks).
@export var carry_bonus: float = 0.0
## Movement-speed multiplier while equipped (a heavy pack is < 1.0).
@export var speed_mult: float = 1.0
