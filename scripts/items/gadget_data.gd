extends ItemData
class_name GadgetData
## A deployable gadget — a CONSUMABLE that, when used, places a world device (auto-turret /
## shield dome / motion sensor) instead of applying an instant effect. It EXTENDS ItemData,
## so it lives in the Stash / loadout / loot like any bring-list consumable (icon/weight/
## value/rarity), is committed-at-deploy and LOST-on-death like the rest of the bring-list.
## Saved as .tres under resources/items/ (keep `kind = 2` = Kind.CONSUMABLE).
##
## The placement itself is wired by the lead (player use -> Events.gadget_placed -> the
## MultiplayerSpawner's spawn_function -> GadgetBase._spawn_gadget). This data only carries
## WHICH gadget + WHICH scene to spawn.

## Logical gadget id (== this item's `id`); also the AssetRegistry / ENEMY-less model key.
@export var gadget_id: String = ""
## res:// path of the gadget scene to instance on placement.
@export var scene_path: String = ""
