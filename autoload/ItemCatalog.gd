extends Node
## id -> ItemData catalog. Scans `resources/items/*.tres` at startup so loot, the
## stash, the loadout, and crafting all resolve items by id from ONE place (replacing
## the ad-hoc loot_pickup.ITEM_PATHS). Content just drops new .tres files in the dir.

const ITEMS_DIR := "res://resources/items/"
const ATTACHMENTS_DIR := "res://resources/attachments/"   # AttachmentData extends ItemData

var _by_id: Dictionary = {}   # id -> ItemData

func _ready() -> void:
	_scan()

func _scan() -> void:
	_by_id.clear()
	_scan_dir(ITEMS_DIR, ResourceIndex.ITEMS)
	_scan_dir(ATTACHMENTS_DIR, ResourceIndex.ATTACHMENTS)

## Loads every ItemData from `path` (editor live scan) AND from the generated `index`
## (exported builds, where DirAccess can't enumerate a PCK directory). Deduped by id,
## so running both in the editor is harmless (load() is cached).
func _scan_dir(path: String, index: PackedStringArray) -> void:
	var dir := DirAccess.open(path)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and (f.ends_with(".tres") or f.ends_with(".res")):
				_add_item(load(path + f))
			f = dir.get_next()
		dir.list_dir_end()
	for p in index:
		_add_item(load(p))

func _add_item(res: Resource) -> void:
	if res is ItemData and (res as ItemData).id != "":
		_by_id[(res as ItemData).id] = res

func has(id: String) -> bool:
	return _by_id.has(id)

func get_item(id: String) -> ItemData:
	return _by_id.get(id, null)

func value_of(id: String) -> int:
	var it: ItemData = _by_id.get(id, null)
	return it.value if it else 0

func all_ids() -> Array:
	return _by_id.keys()

func all_items() -> Array:
	return _by_id.values()

## Catalog ids whose ItemData.kind matches `kind` (e.g. consumables for the bring-list).
func ids_of_kind(kind: int) -> Array:
	var out: Array = []
	for id in _by_id:
		if (_by_id[id] as ItemData).kind == kind:
			out.append(id)
	return out

## Catalog ids whose ItemData.rarity is within [min_r, max_r] (inclusive). Used by the
## risk-tier loot tables to roll tier-appropriate drops (Rarity: 0 COMMON … 4 LEGENDARY).
func ids_of_rarity(min_r: int, max_r: int = 4) -> Array:
	var out: Array = []
	for id in _by_id:
		var r: int = (_by_id[id] as ItemData).rarity
		if r >= min_r and r <= max_r:
			out.append(id)
	return out
