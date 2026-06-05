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
	_scan_dir(ITEMS_DIR)
	_scan_dir(ATTACHMENTS_DIR)

func _scan_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and (f.ends_with(".tres") or f.ends_with(".res")):
			var res := load(path + f)
			if res is ItemData and (res as ItemData).id != "":
				_by_id[(res as ItemData).id] = res
		f = dir.get_next()
	dir.list_dir_end()

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
