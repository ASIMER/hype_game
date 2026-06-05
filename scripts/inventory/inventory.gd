extends Node
class_name Inventory
## Grid inventory with weight + slot constraints. Pure logic Node attached to a
## player. UI (InventoryUI.tscn) renders from this; networking replicates the
## authoritative server copy. Emits Events.inventory_changed on mutation.
##
## CONTRACT (depended on by loot/pickup + UI workstreams):
##   func can_add(item: ItemData, count: int) -> bool
##   func add_item(item: ItemData, count: int) -> int   # returns leftover not added
##   func remove_item(id: String, count: int) -> int    # returns amount removed
##   func total_weight() -> float ; func total_value() -> int
##   var stacks: Array[Dictionary]  # [{ item: ItemData, count: int }]

signal changed()

@export var cols: int = Settings.INVENTORY_COLS
@export var rows: int = Settings.INVENTORY_ROWS
@export var max_weight: float = Settings.INVENTORY_MAX_WEIGHT

# Each entry: { "item": ItemData, "count": int }
var stacks: Array[Dictionary] = []

func capacity_cells() -> int:
	return cols * rows

func used_cells() -> int:
	var n := 0
	for s in stacks:
		var it: ItemData = s["item"]
		n += it.grid_w * it.grid_h
	return n

func total_weight() -> float:
	var w := 0.0
	for s in stacks:
		w += (s["item"] as ItemData).weight * s["count"]
	return w

func total_value() -> int:
	var v := 0
	for s in stacks:
		v += (s["item"] as ItemData).value * s["count"]
	return v

func can_add(item: ItemData, count: int) -> bool:
	if item == null or count <= 0:
		return false
	if total_weight() + item.weight * count > max_weight:
		return false
	# Fits into an existing stack?
	if item.is_stackable():
		for s in stacks:
			if (s["item"] as ItemData).id == item.id and s["count"] < item.max_stack:
				return true
	# Needs a new cell footprint.
	return used_cells() + item.grid_w * item.grid_h <= capacity_cells()

## Adds up to `count`; returns the leftover that did not fit.
func add_item(item: ItemData, count: int) -> int:
	if item == null or count <= 0:
		return count
	var remaining := count
	if item.is_stackable():
		for s in stacks:
			if remaining <= 0:
				break
			if (s["item"] as ItemData).id == item.id:
				var space: int = item.max_stack - s["count"]
				if space > 0:
					var moved: int = mini(space, remaining)
					s["count"] += moved
					remaining -= moved
	while remaining > 0:
		if total_weight() + item.weight > max_weight:
			break
		if used_cells() + item.grid_w * item.grid_h > capacity_cells():
			break
		var put: int = mini(item.max_stack, remaining)
		# Respect weight while filling the new stack.
		while put > 1 and total_weight() + item.weight * put > max_weight:
			put -= 1
		stacks.append({ "item": item, "count": put })
		remaining -= put
	if remaining != count:
		_notify()
	return remaining

## Removes up to `count` of an item id; returns amount actually removed.
func remove_item(id: String, count: int) -> int:
	var removed := 0
	for i in range(stacks.size() - 1, -1, -1):
		if removed >= count:
			break
		var s := stacks[i]
		if (s["item"] as ItemData).id == id:
			var take: int = mini(s["count"], count - removed)
			s["count"] -= take
			removed += take
			if s["count"] <= 0:
				stacks.remove_at(i)
	if removed > 0:
		_notify()
	return removed

## Sorts the stacks array in place by the given mode and notifies listeners.
## mode = "name" | "weight" | "value" | "rarity". Unknown modes no-op.
## "weight"/"value"/"rarity" sort descending (heaviest / most valuable / rarest
## first); "name" sorts A→Z. Ties fall back to display name for stable ordering.
func sort_stacks(mode: String) -> void:
	match mode:
		"name":
			stacks.sort_custom(func(a, b):
				return (a["item"] as ItemData).display_name.naturalnocasecmp_to((b["item"] as ItemData).display_name) < 0)
		"weight":
			stacks.sort_custom(_cmp_desc.bind(func(it: ItemData) -> float: return it.weight))
		"value":
			stacks.sort_custom(_cmp_desc.bind(func(it: ItemData) -> float: return float(it.value)))
		"rarity":
			stacks.sort_custom(_cmp_desc.bind(func(it: ItemData) -> float: return float(it.rarity)))
		_:
			return
	_notify()

## Descending comparator on a numeric key extracted from each stack's item, with
## display name as a stable tie-breaker.
func _cmp_desc(a: Dictionary, b: Dictionary, key: Callable) -> bool:
	var ia := a["item"] as ItemData
	var ib := b["item"] as ItemData
	var ka: float = key.call(ia)
	var kb: float = key.call(ib)
	if ka == kb:
		return ia.display_name.naturalnocasecmp_to(ib.display_name) < 0
	return ka > kb

## Returns the subset of stacks whose item kind matches `kind` (an
## ItemData.Kind). Pass kind < 0 to get a copy of all stacks. Read-only helper
## for the UI's filter tabs — does not mutate `stacks`.
func filter_by_kind(kind: int) -> Array[Dictionary]:
	if kind < 0:
		return stacks.duplicate()
	var out: Array[Dictionary] = []
	for s in stacks:
		if (s["item"] as ItemData).kind == kind:
			out.append(s)
	return out

func clear() -> void:
	stacks.clear()
	_notify()

func _notify() -> void:
	changed.emit()
	Events.inventory_changed.emit(self)
