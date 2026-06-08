extends Node
## Data-driven quests / contracts with a real LIFECYCLE (Iteration 1).
##
##   LOCKED → AVAILABLE → ACTIVE → COMPLETED → CLAIMED
##
## Scans `resources/quests/*.tres` (`QuestData`). A quest starts LOCKED; the `QuestDirector`
## OFFERS it (→ AVAILABLE) once its `unlock`/`prereq` conditions hold; the player manually
## ACCEPTs it (→ ACTIVE, capped at Settings.ACTIVE_QUEST_CAP); objectives advance from the
## Events bus while ACTIVE → COMPLETED; claim() grants the reward once → CLAIMED.
## State lives in MetaProgression.quest_states (persisted, per-peer). Dailies are auto
## offered+accepted (repeatable). Kill objectives are fed by Events.player_kill (per-peer,
## co-op-correct) rather than the server-only Events.entity_died.

const QUESTS_DIR := "res://resources/quests/"
const QUESTLINES_DIR := "res://resources/questlines/"

var _quests: Array = []   # QuestData
var _lines: Array = []     # QuestLine

func _ready() -> void:
	_scan()
	_scan_lines()
	# Objective hooks — advance matching ACTIVE quests as gameplay happens.
	# Kills come via player_kill (fires per-peer on the killer's machine), NOT entity_died
	# (server-only) — so a co-op client's kill quests actually advance.
	Events.player_kill.connect(_on_player_kill)
	Events.raid_loot_granted.connect(_on_raid_loot_granted)
	Events.wave_cleared.connect(_on_wave_cleared)
	Events.item_picked_up.connect(_on_item_picked_up)

func _scan() -> void:
	_quests.clear()
	var seen: Dictionary = {}
	var dir := DirAccess.open(QUESTS_DIR)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and (f.ends_with(".tres") or f.ends_with(".res")):
				_add_quest(load(QUESTS_DIR + f), seen)
			f = dir.get_next()
		dir.list_dir_end()
	# Export fallback: DirAccess can't enumerate a PCK dir → load the generated index.
	for p in ResourceIndex.QUESTS:
		_add_quest(load(p), seen)

func _add_quest(res: Resource, seen: Dictionary) -> void:
	if res is QuestData and (res as QuestData).id != "" and not seen.has((res as QuestData).id):
		seen[(res as QuestData).id] = true
		_quests.append(res)

## Scans resources/questlines/ (same dual DirAccess + ResourceIndex fallback as _scan).
func _scan_lines() -> void:
	_lines.clear()
	var seen: Dictionary = {}
	var dir := DirAccess.open(QUESTLINES_DIR)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and (f.ends_with(".tres") or f.ends_with(".res")):
				_add_line(load(QUESTLINES_DIR + f), seen)
			f = dir.get_next()
		dir.list_dir_end()
	for p in ResourceIndex.QUESTLINES:
		if ResourceLoader.exists(p):
			_add_line(load(p), seen)

func _add_line(res: Resource, seen: Dictionary) -> void:
	if res is QuestLine and (res as QuestLine).id != "" and not seen.has((res as QuestLine).id):
		seen[(res as QuestLine).id] = true
		_lines.append(res)

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
	return state_of(id) == "claimed" or id in MetaProgression.completed_quests

## Lifecycle state of a quest id: "" (LOCKED) | "available" | "active" | "completed" | "claimed".
func state_of(id: String) -> String:
	return MetaProgression.quest_state(id)

# ---------------------------------------------------------------- lifecycle transitions
## LOCKED → AVAILABLE (called by the QuestDirector when is_unlocked()). Idempotent.
func offer(id: String) -> bool:
	if state_of(id) != "":
		return false
	MetaProgression.set_quest_state(id, "available")
	Events.quest_unlocked.emit(id)
	return true

## AVAILABLE → ACTIVE on manual accept, gated by the active-quest cap (dailies are exempt).
## Returns false (with a toast) if the cap is hit so the UI can surface why.
func accept(id: String) -> bool:
	var q := quest_by_id(id)
	if q == null or state_of(id) != "available":
		return false
	if active_count() >= Settings.ACTIVE_QUEST_CAP:
		Events.notify.emit(tr("Active contract limit reached (%d)") % Settings.ACTIVE_QUEST_CAP, 2)
		return false
	MetaProgression.set_quest_state(id, "active")
	Events.quest_accepted.emit(id)
	return true

## Claims a completed quest's reward exactly once → CLAIMED. Re-runs the offer pass so a
## chain's next step can unlock immediately. Returns true on success.
func claim(id: String) -> bool:
	var q := quest_by_id(id)
	if q == null or is_claimed(id) or not is_complete(q):
		return false
	var st := state_of(id)
	if st != "active" and st != "completed":
		return false
	if not (id in MetaProgression.completed_quests):
		MetaProgression.completed_quests.append(id)
	# --- Base rewards (currency / items / blueprints) ---
	if q.reward_currency > 0:
		MetaProgression.earn(q.reward_currency)
	for it in q.reward_items():
		Stash.add(String(it["id"]), int(it["count"]))
	for bp in q.reward_blueprints:
		MetaProgression.learn_blueprint(String(bp))
	# --- Rich rewards (Iter 3): xp / vendor-rep / skill points / cosmetics / giver rep ---
	var line := questline_of(id)
	var giver := q.giver
	if giver == "" and line != null:
		giver = line.giver
	if q.reward_xp > 0:
		MetaProgression.add_xp(q.reward_xp, "quest")
	if q.reward_rep > 0:
		MetaProgression.grant_rep(q.reward_rep)
	if q.reward_skill_points > 0:
		MetaProgression.skill_points += q.reward_skill_points
	var unlocked_cos: Array = []
	for cos in q.reward_cosmetics:
		if MetaProgression.unlock_cosmetic_free(String(cos)):
			unlocked_cos.append(String(cos))
	var grep: int = q.reward_giver_rep + Settings.GIVER_REP_BASELINE_ON_CLAIM
	if giver != "":
		MetaProgression.grant_giver_rep(giver, grep)
	MetaProgression.set_quest_state(id, "claimed")   # persists (incl. skill_points)
	# Questline completion (all steps claimed)?
	var ql_complete := false
	var line_title := ""
	if line != null:
		line_title = line.title
		var lp := line_progress(line)
		ql_complete = int(lp.get("total", 0)) > 0 and int(lp.get("done", 0)) >= int(lp.get("total", 0))
	# Reward bundle for the popup overlay.
	Events.quest_reward_granted.emit(id, {
		"currency": q.reward_currency, "items": q.reward_items(), "blueprints": Array(q.reward_blueprints),
		"xp": q.reward_xp, "rep": q.reward_rep, "skill_points": q.reward_skill_points,
		"giver": giver, "giver_rep": (grep if giver != "" else 0), "cosmetics": unlocked_cos,
		"questline_complete": ql_complete, "line_title": line_title,
	})
	# A newly-claimed prereq may unlock the next link in a chain.
	if has_node("/root/QuestDirector"):
		get_node("/root/QuestDirector").evaluate_offers()
	return true

## Number of non-daily contracts currently ACTIVE (accepted, incl. completed-not-claimed).
func active_count() -> int:
	var n := 0
	for q in _quests:
		var qd := q as QuestData
		if not qd.daily and (state_of(qd.id) == "active" or state_of(qd.id) == "completed"):
			n += 1
	return n

# ---------------------------------------------------------------- list helpers (UI)
## Offered, not-yet-accepted contracts (the AVAILABLE section).
func offered() -> Array:
	return _by_state(["available"], false)

## Number of non-daily contracts currently AVAILABLE (offered, awaiting accept) — board cap.
func available_count() -> int:
	var n := 0
	for q in _quests:
		var qd := q as QuestData
		if not qd.daily and state_of(qd.id) == "available":
			n += 1
	return n

## Accepted contracts incl. completed-not-claimed (the ACTIVE section), non-daily.
func accepted() -> Array:
	return _by_state(["active", "completed"], false)

## Recently claimed contracts (the COMPLETED history), non-daily.
func claimed_list() -> Array:
	return _by_state(["claimed"], false)

## LOCKED non-daily contracts shown as TEASERS (with an unlock hint) so the player sees
## the next goal. Excludes ones already unlockable (those become AVAILABLE via the director).
func locked_teasers() -> Array:
	var out: Array = []
	for q in _quests:
		var qd := q as QuestData
		if qd.daily:
			continue
		if state_of(qd.id) == "" and not is_unlocked(qd):
			out.append(qd)
	return out

func _by_state(states: Array, include_daily: bool) -> Array:
	var out: Array = []
	for q in _quests:
		var qd := q as QuestData
		if qd.daily != include_daily:
			continue
		if state_of(qd.id) in states:
			out.append(qd)
	return out

## Legacy alias: all non-daily contracts that aren't claimed (kept for back-compat).
func active() -> Array:
	return accepted()

func standing() -> Array:
	var out: Array = []
	for q in _quests:
		if not (q as QuestData).daily and not is_claimed((q as QuestData).id):
			out.append(q)
	return out

# ---------------------------------------------------------------- questlines (Iter 2)
## A quest is "gated" if it has explicit unlock clauses or prereqs (offered on conditions,
## not from the random pool).
func has_gate(q: QuestData) -> bool:
	return q != null and (not q.unlock.is_empty() or not q.prereq.is_empty())

func questlines() -> Array:
	return _lines

func line_by_id(id: String) -> QuestLine:
	for l in _lines:
		if (l as QuestLine).id == id:
			return l
	return null

## The QuestLine that contains `quest_id`, or null (standalone).
func questline_of(quest_id: String) -> QuestLine:
	var q := quest_by_id(quest_id)
	if q != null and q.questline != "":
		return line_by_id(q.questline)
	for l in _lines:
		if quest_id in (l as QuestLine).quest_ids:
			return l
	return null

## Ordered QuestData steps of a line (skips ids with no resource).
func line_steps(line: QuestLine) -> Array:
	var out: Array = []
	if line == null:
		return out
	for sid in line.quest_ids:
		var q := quest_by_id(String(sid))
		if q != null:
			out.append(q)
	return out

func line_step_index(line: QuestLine, quest_id: String) -> int:
	if line == null:
		return -1
	for i in line.quest_ids.size():
		if String(line.quest_ids[i]) == quest_id:
			return i
	return -1

## { done: claimed steps, total: step count, current_id: first non-claimed step ("" = all done) }.
func line_progress(line: QuestLine) -> Dictionary:
	var done := 0
	var current := ""
	if line != null:
		for sid in line.quest_ids:
			if is_claimed(String(sid)):
				done += 1
			elif current == "":
				current = String(sid)
	return { "done": done, "total": (line.quest_ids.size() if line != null else 0), "current_id": current }

## Weighted-eligible random-pool quests: LOCKED, offer_weight>0, prereqs claimed (is_unlocked).
func random_pool() -> Array:
	var out: Array = []
	for q in _quests:
		var qd := q as QuestData
		if qd.offer_weight > 0 and state_of(qd.id) == "" and is_unlocked(qd):
			out.append(qd)
	return out

# ---------------------------------------------------------------- unlock conditions
## A LOCKED quest is unlockable when EVERY prereq is claimed AND every unlock clause holds.
func is_unlocked(q: QuestData) -> bool:
	if q == null:
		return false
	for pre in q.prereq:
		if not is_claimed(String(pre)):
			return false
	for clause in q.unlock:
		if not _eval_clause(String(clause)):
			return false
	return true

## Parses one "<stat><op><value>" clause (op ∈ >= <= == != > <). No eval — purely parsed.
## Unknown stat → fail-safe false.
func _eval_clause(s: String) -> bool:
	var clause := s.strip_edges()
	if clause == "":
		return true
	var ops: Array[String] = [">=", "<=", "==", "!=", ">", "<"]
	for op: String in ops:
		var idx := clause.find(op)
		if idx <= 0:
			continue
		var key := clause.substr(0, idx).strip_edges()
		var rhs := clause.substr(idx + op.length()).strip_edges()
		var want := rhs.to_float()
		var have := _stat(key)
		if is_nan(have):
			return false   # unknown stat → never satisfied
		match op:
			">=": return have >= want
			"<=": return have <= want
			"==": return is_equal_approx(have, want)
			"!=": return not is_equal_approx(have, want)
			">":  return have > want
			"<":  return have < want
	return false

## Resolves a stat key to a number. NAN = unknown key (clause fails safe).
func _stat(key: String) -> float:
	if key.begins_with("kills_by_type."):
		return float(MetaProgression.kills_of(key.substr(14)))
	if key.begins_with("weapon_mastery."):
		return float(MetaProgression.weapon_mastery_level(key.substr(15)))
	if key.begins_with("quest_claimed."):
		return 1.0 if is_claimed(key.substr(14)) else 0.0
	if key.begins_with("giver_rep."):
		return float(MetaProgression.giver_rep_of(key.substr(10)))
	match key:
		"mobs_total": return float(MetaProgression.total_mob_kills())
		"raider_level": return float(MetaProgression.raider_level)
		"vendor_rep": return float(MetaProgression.vendor_rep)
		"currency": return float(MetaProgression.currency)
		"xp": return float(MetaProgression.xp)
		"extractions": return float(MetaProgression.extractions_total)
	return NAN

## Human-readable "Unlock by: …" hint for the LOCKED teaser card.
func unlock_hint(q: QuestData) -> String:
	var parts: Array[String] = []
	for pre in q.prereq:
		var pq := quest_by_id(String(pre))
		parts.append(tr("complete \"%s\"") % (tr(pq.title) if pq != null else String(pre)))
	for clause in q.unlock:
		parts.append(_clause_text(String(clause)))
	return tr("Unlock by: ") + ", ".join(parts) if not parts.is_empty() else tr("Unlock by progressing")

func _clause_text(clause: String) -> String:
	# "kills_by_type.robot_grunt>=10" → "kill 10 robot grunt"
	if clause.begins_with("kills_by_type."):
		var rest := clause.substr(14)
		for op: String in [">=", ">", "==", "<=", "<"]:
			var idx := rest.find(op)
			if idx > 0:
				var eid := rest.substr(0, idx)
				var n := rest.substr(idx + op.length())
				return tr("kill %s %s") % [n, eid.replace("robot_", "").replace("_", " ")]
	return clause

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
	# Fresh each day: clear progress + claimed and AUTO-ACCEPT (dailies are repeatable, so
	# they skip the offer/accept gate and go straight to ACTIVE).
	for id in ids:
		MetaProgression.quest_progress.erase(id)
		MetaProgression.completed_quests.erase(id)
		MetaProgression.quest_states[id] = "active"
	MetaProgression.daily_quest_ids = ids
	MetaProgression.last_daily_date = _today()
	MetaProgression.save_profile()
	Events.dailies_rotated.emit()

# ---------------------------------------------------------------- mutation
## Advances an ACTIVE quest (or an active daily). LOCKED/AVAILABLE/CLAIMED quests don't move.
func _advance(q: QuestData, by: int) -> void:
	if by <= 0 or is_complete(q):
		return
	var st := state_of(q.id)
	if st != "active":   # dailies are set to "active" on rotation, so they pass too
		return
	var cur := mini(q.obj_count, progress(q.id) + by)
	MetaProgression.quest_progress[q.id] = cur
	MetaProgression.save_profile()
	Events.quest_progress.emit(q.id, cur, q.obj_count)
	if cur >= q.obj_count:
		MetaProgression.set_quest_state(q.id, "completed")
		Events.quest_completed.emit(q.id)

## Sets progress to at least `value` (used by one-shot objectives like reach_wave).
func _set_at_least(q: QuestData, value: int) -> void:
	if value > progress(q.id):
		_advance(q, value - progress(q.id))

# ---------------------------------------------------------------- event hooks
func _on_player_kill(enemy_id: String) -> void:
	for q in _quests:
		var qd := q as QuestData
		if qd.obj_type == "kill" and (qd.obj_target == "" or qd.obj_target == enemy_id):
			_advance(qd, 1)

func _on_raid_loot_granted(payload: Array, _bonus: int) -> void:
	# Decision stat: every extraction counts toward the cumulative total.
	MetaProgression.inc_extractions()
	MetaProgression.save_profile()
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
