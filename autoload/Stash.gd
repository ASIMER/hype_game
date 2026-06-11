extends Node
## The player's PERSISTENT item stash — what survives BETWEEN matches. Items you
## extract from a raid land here; dying loses everything you brought + found (it is
## never deposited). This is the "why" of extraction and the "where" loot persists.
##
## Stored as compact { "id": String, "count": int } entries (ItemData resolved via
## ItemCatalog) and saved per-instance via Settings.user_path("stash","cfg") — so each
## co-op player keeps its OWN stash on its OWN machine. Weapons are NOT here (they are
## permanent unlocks in MetaProgression); the stash holds materials / consumables /
## valuables — the at-risk economy.

var items: Array = []  # [{ "id": String, "count": int }]

## Set once if a save from a NEWER game version was loaded this session (guards the
## version-mismatch toast so it fires at most once per file per session).
var _warned_newer := false


func _ready() -> void:
	load_stash()


## Semantic-version compare: -1 if a<b, 0 if equal, 1 if a>b. Splits on ".",
## compares ints positionally; missing/non-numeric parts count as 0.
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


# ---------------------------------------------------------------- queries
func count_of(id: String) -> int:
	for e in items:
		if e["id"] == id:
			return int(e["count"])
	return 0


func has(id: String, n: int = 1) -> bool:
	return count_of(id) >= n


func total_value() -> int:
	var v := 0
	for e in items:
		v += ItemCatalog.value_of(e["id"]) * int(e["count"])
	return v


## Total carried weight (ItemData.weight × count). The stash has a hard capacity
## (MetaProgression.stash_capacity, upgradeable) — extracting over it triggers the
## Manage-Your-Haul beat (see RaidManager._deposit).
func total_weight() -> float:
	var w := 0.0
	for e in items:
		var it: ItemData = ItemCatalog.get_item(e["id"])
		if it:
			w += it.weight * int(e["count"])
	return w


func capacity() -> float:
	return MetaProgression.stash_capacity()


func free_weight() -> float:
	return capacity() - total_weight()


## Weight of a set of {id,count} stacks (e.g. an incoming haul).
func weight_of_stacks(stacks: Array) -> float:
	var w := 0.0
	for s in stacks:
		var id := (
			String(s.get("id", ""))
			if s.has("id")
			else String((s.get("item") as ItemData).id) if s.get("item") else ""
		)
		var it: ItemData = ItemCatalog.get_item(id)
		if it:
			w += it.weight * int(s.get("count", 0))
	return w


func is_empty() -> bool:
	return items.is_empty()


# ---------------------------------------------------------------- mutations
## Add n of an id (merges into the existing entry). Persists + emits stash_changed.
func add(id: String, n: int = 1) -> void:
	if n <= 0:
		return
	_add_silent(id, n)
	_changed()


## Add many stacks at once (e.g. an extracted inventory). Each entry may be
## { id, count } or { item: ItemData, count }.
func add_stacks(stacks: Array) -> void:
	var any := false
	for s in stacks:
		var id := ""
		if s.has("id"):
			id = String(s["id"])
		elif s.has("item") and s["item"] != null:
			id = String((s["item"] as ItemData).id)
		var n := int(s.get("count", 0))
		if id != "" and n > 0:
			_add_silent(id, n)
			any = true
	if any:
		_changed()


func _add_silent(id: String, n: int) -> void:
	for e in items:
		if e["id"] == id:
			e["count"] = int(e["count"]) + n
			return
	items.append({"id": id, "count": n})


## Remove up to n of an id; returns the amount actually removed. Persists + emits.
func remove(id: String, n: int = 1) -> int:
	for i in items.size():
		if items[i]["id"] == id:
			var take := mini(int(items[i]["count"]), n)
			items[i]["count"] = int(items[i]["count"]) - take
			if items[i]["count"] <= 0:
				items.remove_at(i)
			if take > 0:
				_changed()
			return take
	return 0


func clear() -> void:
	items.clear()
	_changed()


func _changed() -> void:
	save_stash()
	Events.stash_changed.emit()


# ---------------------------------------------------------------- persistence
func _path() -> String:
	return Settings.user_path("stash", "cfg")


func save_stash() -> void:
	if Settings.ephemeral_save:
		return  # --no-save test run: stash is not persisted
	var cfg := ConfigFile.new()
	cfg.set_value("stash", "save_version", Settings.GAME_VERSION)
	cfg.set_value("stash", "items", items)
	cfg.save(_path())


func load_stash() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_path()) != OK:
		return
	# Version resilience: missing stamp = legacy save (compatible). A NEWER save than
	# this build → warn once, then still load every well-formed entry below.
	var save_ver := String(cfg.get_value("stash", "save_version", ""))
	if save_ver != "" and _cmp_version(save_ver, Settings.GAME_VERSION) > 0:
		if not _warned_newer:
			_warned_newer = true
			push_warning(
				(
					"[Stash] stash.cfg is from a newer game version (v%s > v%s) — loading what we can."
					% [save_ver, Settings.GAME_VERSION]
				)
			)
			Events.notify.emit(
				"Save is from a newer game version (v%s) — loading what we can." % save_ver, 2
			)
	var raw: Variant = cfg.get_value("stash", "items", [])
	items.clear()
	if not (raw is Array):
		return
	# Skip/repair malformed entries (wrong type, missing id, bad count) so a single bad
	# stack can't abort the whole load.
	for e in raw as Array:
		if not (e is Dictionary) or not e.has("id"):
			continue
		var n := int(e.get("count", 1))
		if n <= 0:
			continue
		items.append({"id": String(e["id"]), "count": n})
