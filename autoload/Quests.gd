extends Node
## Data-driven quests / contracts. Scans `resources/quests/*.tres` (`QuestData`),
## tracks progress in `MetaProgression.quest_progress` (persisted, per-instance), and
## advances objectives from the Events bus. A completed quest's reward is granted once
## via claim(). Quest state survives restarts and stays per-player in co-op.

const QUESTS_DIR := "res://resources/quests/"

var _quests: Array = []   # QuestData

func _ready() -> void:
	_scan()
	# Objective hooks — advance matching quests as gameplay happens.
	Events.entity_died.connect(_on_entity_died)
	Events.raid_loot_granted.connect(_on_raid_loot_granted)
	Events.wave_cleared.connect(_on_wave_cleared)
	Events.item_picked_up.connect(_on_item_picked_up)

func _scan() -> void:
	_quests.clear()
	var dir := DirAccess.open(QUESTS_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and (f.ends_with(".tres") or f.ends_with(".res")):
			var res := load(QUESTS_DIR + f)
			if res is QuestData and (res as QuestData).id != "":
				_quests.append(res)
		f = dir.get_next()
	dir.list_dir_end()

# ---------------------------------------------------------------- queries
func all() -> Array:
	return _quests

func quest_by_id(id: String) -> QuestData:
	for q in _quests:
		if (q as QuestData).id == id:
			return q
	return null

func progress(id: String) -> int:
	return int(MetaProgression.quest_progress.get(id, 0))

func is_complete(q: QuestData) -> bool:
	return q != null and progress(q.id) >= q.obj_count

func is_claimed(id: String) -> bool:
	return id in MetaProgression.completed_quests

## Quests not yet claimed (claimed ones drop off the board).
func active() -> Array:
	var out: Array = []
	for q in _quests:
		if not is_claimed((q as QuestData).id):
			out.append(q)
	return out

# ---------------------------------------------------------------- daily contracts
const DAILY_COUNT := 3

func _is_daily(q: QuestData) -> bool:
	return q != null and q.daily

func _today() -> String:
	var d := Time.get_date_dict_from_system()
	return "%04d-%02d-%02d" % [d.get("year", 0), d.get("month", 0), d.get("day", 0)]

## Today's rotating daily contracts (rotates + resets progress on a new day).
func get_daily_quests() -> Array:
	if MetaProgression.last_daily_date != _today():
		_rotate_dailies()
	var out: Array = []
	for id in MetaProgression.daily_quest_ids:
		var q := quest_by_id(String(id))
		if q:
			out.append(q)
	return out

func _rotate_dailies() -> void:
	var pool: Array = []
	for q in _quests:
		if _is_daily(q as QuestData):
			pool.append(q)
	pool.shuffle()
	var ids: Array[String] = []
	for i in mini(DAILY_COUNT, pool.size()):
		ids.append((pool[i] as QuestData).id)
	# Fresh each day: clear progress + claimed so dailies are repeatable.
	for id in ids:
		MetaProgression.quest_progress.erase(id)
		MetaProgression.completed_quests.erase(id)
	MetaProgression.daily_quest_ids = ids
	MetaProgression.last_daily_date = _today()
	MetaProgression.save_profile()
	Events.dailies_rotated.emit()

## Standing (non-daily) active contracts — the QUESTS tab shows these below the dailies.
func standing() -> Array:
	var out: Array = []
	for q in active():
		if not _is_daily(q as QuestData):
			out.append(q)
	return out

# ---------------------------------------------------------------- mutation
func _advance(q: QuestData, by: int) -> void:
	if by <= 0 or is_claimed(q.id) or is_complete(q):
		return
	var cur := mini(q.obj_count, progress(q.id) + by)
	MetaProgression.quest_progress[q.id] = cur
	MetaProgression.save_profile()
	Events.quest_progress.emit(q.id, cur, q.obj_count)
	if cur >= q.obj_count:
		Events.quest_completed.emit(q.id)

## Sets progress to at least `value` (used by one-shot objectives like reach_wave).
func _set_at_least(q: QuestData, value: int) -> void:
	if value > progress(q.id):
		_advance(q, value - progress(q.id))

## Claims a completed quest's reward exactly once. Returns true on success.
func claim(id: String) -> bool:
	var q := quest_by_id(id)
	if q == null or is_claimed(id) or not is_complete(q):
		return false
	MetaProgression.completed_quests.append(id)
	if q.reward_currency > 0:
		MetaProgression.earn(q.reward_currency)
	for it in q.reward_items():
		Stash.add(String(it["id"]), int(it["count"]))
	for bp in q.reward_blueprints:
		MetaProgression.learn_blueprint(String(bp))
	MetaProgression.save_profile()
	return true

# ---------------------------------------------------------------- event hooks
func _on_entity_died(entity: Node, _killer: Node) -> void:
	if entity == null or not entity.is_in_group("enemies"):
		return
	var eid := String(entity.get("enemy_id")) if "enemy_id" in entity else ""
	for q in _quests:
		var qd := q as QuestData
		if qd.obj_type == "kill" and (qd.obj_target == "" or qd.obj_target == eid):
			_advance(qd, 1)

func _on_raid_loot_granted(payload: Array, _bonus: int) -> void:
	for q in _quests:
		var qd := q as QuestData
		if qd.obj_type == "extract":
			_advance(qd, 1)
		elif qd.obj_type == "extract_item":
			for e in payload:
				if String(e["id"]) == qd.obj_target:
					_advance(qd, int(e["count"]))

func _on_wave_cleared(wave_number: int) -> void:
	for q in _quests:
		var qd := q as QuestData
		if qd.obj_type == "reach_wave":
			_set_at_least(qd, wave_number)

func _on_item_picked_up(_player: Node, item_id: String, count: int) -> void:
	for q in _quests:
		var qd := q as QuestData
		if qd.obj_type == "pickup" and (qd.obj_target == "" or qd.obj_target == item_id):
			_advance(qd, count)
