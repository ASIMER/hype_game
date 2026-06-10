extends Resource
class_name CraftRecipe
## One crafting recipe, saved as a .tres in `resources/recipes/` and scanned by the
## `Crafting` autoload. Inputs/outputs reference ItemData ids (ItemCatalog). A recipe
## is craftable when its `blueprint` is known (or empty) AND the Stash holds the inputs
## AND the player can afford `cost`. Inputs use parallel arrays so they edit cleanly in
## the Godot inspector.

@export var id: String = ""
@export var display_name: String = ""
@export var output_id: String = ""  # ItemData id produced
@export var output_count: int = 1
@export var input_ids: PackedStringArray = PackedStringArray()
@export var input_counts: PackedInt32Array = PackedInt32Array()
@export var cost: int = 0  # optional currency cost on top of materials
@export var blueprint: String = ""  # blueprint id required ("" = always available)
@export var learn_item: String = ""  # extracting this item id learns `blueprint`
@export var category: String = "Consumables"  # UI grouping label


## Inputs as an array of { "id": String, "count": int } dicts.
func inputs() -> Array:
	var out: Array = []
	for i in input_ids.size():
		var c: int = input_counts[i] if i < input_counts.size() else 1
		out.append({"id": String(input_ids[i]), "count": maxi(1, c)})
	return out
