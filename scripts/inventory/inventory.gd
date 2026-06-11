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

signal changed

@export var cols: int = Settings.INVENTORY_COLS
@export var rows: int = Settings.INVENTORY_ROWS
@export var max_weight: float = Settings.INVENTORY_MAX_WEIGHT

# Each entry: { "item": ItemData, "count": int }
var stacks: Array[Dictionary] = []

# Secure pouch: item id -> secured count. A subset flag OVER the same stacks
# (securing does not move items between containers, it FLAGS units of an id as
# death-proof). Server-authoritative like `stacks`; travels in the owner mirror.
# Always clamped to live stack counts via _clamp_secure() on any count change.
var secure: Dictionary = {}


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


## Effective weight ceiling = the base `max_weight` + the owning player's replicated
## backpack `carry_bonus` (a float on the parent player node, foundation-committed).
## EVERY capacity comparison must go through this — never read `max_weight` raw — so
## a bigger pack lifts the cap everywhere. Server-safe: carry_bonus replicates to the
## server, which is where pickups validate.
func weight_capacity() -> float:
	var p := get_parent()
	if p != null and "carry_bonus" in p:
		return max_weight + float(p.get("carry_bonus"))
	return max_weight


func total_value() -> int:
	var v := 0
	for s in stacks:
		v += (s["item"] as ItemData).value * s["count"]
	return v


## Total live count of an item id across all of its stacks (0 if absent).
func count_of(id: String) -> int:
	var n := 0
	for s in stacks:
		if (s["item"] as ItemData).id == id:
			n += int(s["count"])
	return n


func can_add(item: ItemData, count: int) -> bool:
	if item == null or count <= 0:
		return false
	if total_weight() + item.weight * count > weight_capacity():
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
	var cap := weight_capacity()
	while remaining > 0:
		if total_weight() + item.weight > cap:
			break
		if used_cells() + item.grid_w * item.grid_h > capacity_cells():
			break
		var put: int = mini(item.max_stack, remaining)
		# Respect weight while filling the new stack.
		while put > 1 and total_weight() + item.weight * put > cap:
			put -= 1
		stacks.append({"item": item, "count": put})
		remaining -= put
	if remaining != count:
		_notify()
	return remaining


## Splits `amount` off the first stack of `item_id` (count > amount) into a NEW
## stack of the same item, so the inventory shows two separate stacks. Server-side
## logic (the owner-mirror serializes per-stack, so the split survives replication).
## Returns true if a split happened. No-op if amount<=0 or no splittable stack.
func split_stack(item_id: String, amount: int) -> bool:
	if amount <= 0:
		return false
	for i in stacks.size():
		var s := stacks[i]
		if (s["item"] as ItemData).id == item_id and int(s["count"]) > amount:
			var it: ItemData = s["item"]
			# A new cell is needed for the split-off stack.
			if used_cells() + it.grid_w * it.grid_h > capacity_cells():
				return false
			s["count"] = int(s["count"]) - amount
			stacks.insert(i + 1, {"item": it, "count": amount})
			_notify()
			return true
	return false


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
			stacks.sort_custom(
				func(a, b):
					return (
						(a["item"] as ItemData).display_name.naturalnocasecmp_to(
							(b["item"] as ItemData).display_name
						)
						< 0
					)
			)
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
	secure.clear()
	_notify()


# ------------------------------------------------------------- secure pouch
# Items flagged secure survive DEATH (the lead's death hook deposits secure_stacks()).
# Securing FLAGS the whole current stack of an id — it does not move items. The flag
# is server-authoritative, clamped to live counts (_clamp_secure), and travels in the
# owner mirror so a client's `secure` is always what the last mirror said.


## Owner/client entry point to (un)secure an item id. Server/owner-local applies
## directly; a remote client routes the request to the server, which re-validates
## that the sender owns this inventory before applying.
func request_secure(id: String, on: bool) -> void:
	if not multiplayer.has_multiplayer_peer() or NetworkManager.is_offline:
		_apply_secure(id, on)
		return
	if multiplayer.is_server():
		_apply_secure(id, on)
		return
	_secure_request_rpc.rpc_id(1, id, on)


@rpc("any_peer", "call_remote", "reliable")
func _secure_request_rpc(id: String, on: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != _owner_peer():
		return  # only the inventory's owner may flag its own items
	_apply_secure(id, on)


## SERVER-side validate + apply. on=true flags the WHOLE current stack of `id`
## (requires the item present, per-unit weight <= SECURE_MAX_WEIGHT, and fewer than
## SECURE_SLOTS distinct ids already secured). on=false clears the flag. Mirrors +
## emits secure_changed on any change.
func _apply_secure(id: String, on: bool) -> void:
	if on:
		var live := count_of(id)
		if live <= 0:
			return
		if secure.has(id):
			# Already secured — just re-pin to the current stack count.
			if int(secure[id]) == live:
				return
			secure[id] = live
		else:
			if secure.size() >= Settings.SECURE_SLOTS:
				return
			var unit_weight := _unit_weight(id)
			if unit_weight > Settings.SECURE_MAX_WEIGHT:
				return
			secure[id] = live
	else:
		if not secure.has(id):
			return
		secure.erase(id)
	Events.secure_changed.emit(secure)
	_push_to_owner()


## Per-unit weight of an id from any stack holding it (0.0 if absent).
func _unit_weight(id: String) -> float:
	for s in stacks:
		var it := s["item"] as ItemData
		if it.id == id:
			return it.weight
	return 0.0


## Currently-secured items as [{id, count}], each count clamped to the live stack
## total. The death hook deposits exactly this (so a shrunk/looted stack can never
## over-deposit). Skips ids that are flagged but no longer held.
func secure_stacks() -> Array:
	var out: Array = []
	for id in secure.keys():
		var live := count_of(String(id))
		if live <= 0:
			continue
		out.append({"id": String(id), "count": mini(int(secure[id]), live)})
	return out


func _notify() -> void:
	_clamp_secure()
	changed.emit()
	Events.inventory_changed.emit(self)
	_push_to_owner()


## Re-pins every secure flag to its id's live stack count: drops flags for ids no
## longer present and shrinks a flag whose stack fell below it. Called on every
## mutation (via _notify) so secure[] can never claim more than is actually held.
func _clamp_secure() -> void:
	if secure.is_empty():
		return
	var dirty := false
	for id in secure.keys():
		var live := count_of(id)
		if live <= 0:
			secure.erase(id)
			dirty = true
		elif int(secure[id]) > live:
			secure[id] = live
			dirty = true
	if dirty:
		Events.secure_changed.emit(secure)


# --------------------------------------------------- co-op replication to owner
# The inventory is server-authoritative but NOT auto-replicated (stacks hold ItemData
# refs). So after any server-side change, mirror the serialized contents to the OWNING
# client, which rebuilds its local copy — otherwise a client never SEES the loot it
# picked up (and split/give/trade would have nothing to act on).
func _owner_peer() -> int:
	var pn := get_parent()
	if pn == null:
		return 1
	var oid := str(pn.name).to_int()
	return oid if oid > 0 else 1


func _serialize() -> Array:
	var out: Array = []
	for s in stacks:
		out.append({"id": (s["item"] as ItemData).id, "count": int(s["count"])})
	return out


func _push_to_owner() -> void:
	if not multiplayer.has_multiplayer_peer() or NetworkManager.is_offline:
		return
	if not multiplayer.is_server():
		return
	var owner := _owner_peer()
	if owner == 1:
		return  # the host's own inventory is already local
	_apply_remote.rpc_id(owner, _serialize(), secure.duplicate())


@rpc("any_peer", "call_remote", "reliable")
func _apply_remote(data: Array, secure_data: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return  # only the server mirrors inventories
	stacks.clear()
	for e in data:
		var it: ItemData = ItemCatalog.get_item(String(e["id"]))
		if it != null:
			stacks.append({"item": it, "count": int(e["count"])})
	secure = secure_data.duplicate()
	changed.emit()
	Events.inventory_changed.emit(self)
	Events.secure_changed.emit(secure)
