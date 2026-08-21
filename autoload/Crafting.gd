extends Node
## Data-driven crafting + blueprint gating. Scans `resources/recipes/*.tres`
## (`CraftRecipe`) at startup, like ItemCatalog. A recipe is craftable when its
## blueprint is known (or empty), the Stash holds its inputs, and you can afford its
## currency cost. Also owns the per-item RECYCLE yields and blueprint purchasing.

const RECIPES_DIR := "res://resources/recipes/"

## Per-item recycle yield: item id -> Array[{id,count}] of base materials returned.
## Items not listed fall back to scrap worth ~1/3 of their value (see recycle()).
const RECYCLE := {
	"loot_cell": [{"id": "loot_scrap", "count": 2}],
	"loot_circuit": [{"id": "loot_scrap", "count": 1}, {"id": "loot_plastic", "count": 2}],
	"loot_chemicals": [{"id": "loot_plastic", "count": 2}],
	"loot_artifact": [{"id": "loot_circuit", "count": 1}, {"id": "loot_cell", "count": 2}],
	"loot_data_chip": [{"id": "loot_circuit", "count": 2}, {"id": "loot_chemicals", "count": 1}],
	"rifle": [{"id": "loot_scrap", "count": 3}, {"id": "loot_circuit", "count": 1}],
}

var _recipes: Array = []  # CraftRecipe


func _ready() -> void:
	_scan()


func _scan() -> void:
	_recipes.clear()
	var seen: Dictionary = {}
	var dir := DirAccess.open(RECIPES_DIR)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and (f.ends_with(".tres") or f.ends_with(".res")):
				_add_recipe(load(RECIPES_DIR + f), seen)
			f = dir.get_next()
		dir.list_dir_end()
	# Export fallback: DirAccess can't enumerate a PCK dir → load the generated index.
	for p in ResourceIndex.RECIPES:
		_add_recipe(load(p), seen)


func _add_recipe(res: Resource, seen: Dictionary) -> void:
	if (
		res is CraftRecipe
		and (res as CraftRecipe).id != ""
		and not seen.has((res as CraftRecipe).id)
	):
		seen[(res as CraftRecipe).id] = true
		_recipes.append(res)


# ---------------------------------------------------------------- queries
func all_recipes() -> Array:
	return _recipes


func recipe_by_id(id: String) -> CraftRecipe:
	for r in _recipes:
		if (r as CraftRecipe).id == id:
			return r
	return null


## True when the recipe's blueprint is known (or it needs none).
func recipe_unlocked(r: CraftRecipe) -> bool:
	return r.blueprint == "" or MetaProgression.is_blueprint_known(r.blueprint)


## True when unlocked + inputs present in the stash + currency affordable.
func can_craft(r: CraftRecipe) -> bool:
	if r == null or not recipe_unlocked(r):
		return false
	if r.cost > 0 and MetaProgression.currency < r.cost:
		return false
	for inp in r.inputs():
		if not Stash.has(inp["id"], inp["count"]):
			return false
	return true


## item id -> blueprint id, for every recipe that's learned by extracting an item
## (the RaidManager extraction hook reads this).
func learn_items() -> Dictionary:
	var out: Dictionary = {}
	for r in _recipes:
		var cr := r as CraftRecipe
		if cr.learn_item != "" and cr.blueprint != "":
			out[cr.learn_item] = cr.blueprint
	return out


# ---------------------------------------------------------------- actions
## Crafts the recipe: consumes inputs (+ currency), adds the output to the stash.
func craft(r: CraftRecipe) -> bool:
	if not can_craft(r):
		return false
	for inp in r.inputs():
		Stash.remove(inp["id"], inp["count"])
	if r.cost > 0:
		MetaProgression.spend(r.cost)
	Stash.add(r.output_id, maxi(1, r.output_count))
	Events.crafted.emit(r.id, r.output_id)
	return true


## Recycle ONE of item_id into its constituent materials. Returns the granted
## {id,count} stacks (empty if the stash had none).
func recycle(item_id: String) -> Array:
	if Stash.remove(item_id, 1) <= 0:
		return []
	var yield_arr: Array = RECYCLE.get(item_id, [])
	if yield_arr.is_empty():
		# Fallback: scrap worth roughly a third of the item's value (scrap value = 5).
		var n := maxi(1, int(round(ItemCatalog.value_of(item_id) / 15.0)))
		yield_arr = [{"id": "loot_scrap", "count": n}]
	for m in yield_arr:
		Stash.add(String(m["id"]), int(m["count"]))
	return yield_arr


## Buy a blueprint with currency (shop). Returns true if newly learned.
func buy_blueprint(bp: String, price: int) -> bool:
	if bp == "" or MetaProgression.is_blueprint_known(bp):
		return false
	if not MetaProgression.spend(price):
		return false
	MetaProgression.learn_blueprint(bp)
	return true
