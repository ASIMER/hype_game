extends Resource
class_name ItemData
## Data definition for a stackable/equippable item. Saved as .tres under
## resources/items/. Pure data — no scene/node references — so it is safe to
## reference from inventory logic, loot tables, and UI alike.

enum Kind { MATERIAL, WEAPON, CONSUMABLE, KEY, ATTACHMENT }
enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }

@export var id: String = ""              # logical id, also AssetRegistry key
@export var display_name: String = ""
@export var kind: Kind = Kind.MATERIAL
@export var rarity: Rarity = Rarity.COMMON  # tier — drives UI accent color
@export var weight: float = 1.0          # per unit, for inventory weight cap
@export var max_stack: int = 20
@export var grid_w: int = 1              # footprint in inventory grid cells
@export var grid_h: int = 1
@export_multiline var description: String = ""
@export var value: int = 1               # extraction reward / score

func is_stackable() -> bool:
	return max_stack > 1

## Accent color for this item's rarity tier. Used for slot borders and tooltip
## name coloring. gray / green / blue / purple / gold.
func rarity_color() -> Color:
	match rarity:
		Rarity.UNCOMMON:
			return Color(0.4, 0.85, 0.4)    # green
		Rarity.RARE:
			return Color(0.35, 0.6, 1.0)    # blue
		Rarity.EPIC:
			return Color(0.7, 0.45, 0.95)   # purple
		Rarity.LEGENDARY:
			return Color(1.0, 0.78, 0.25)   # amber/gold
		_:
			return Color(0.62, 0.62, 0.66)  # common — gray

## Human-readable rarity tier name (for tooltips).
func rarity_name() -> String:
	return Rarity.keys()[rarity].capitalize()
