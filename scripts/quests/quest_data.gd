extends Resource
class_name QuestData
## One quest / contract, saved as a .tres in `resources/quests/` and scanned by the
## `Quests` autoload. An objective advances from gameplay Events; when it reaches
## `obj_count` the quest is complete and its reward can be CLAIMed (once).
##
## obj_type:
##   "kill"         — kill obj_count enemies (obj_target = enemy_id, "" = any)
##   "extract"      — extract obj_count times
##   "extract_item" — extract a total of obj_count of item obj_target
##   "reach_wave"   — clear wave >= obj_count in a single run
##   "pickup"       — pick up obj_count of item obj_target ("" = any)

@export var id: String = ""
@export var title: String = ""
@export_multiline var desc: String = ""
## Daily contracts rotate into a small pool each real day and reset their progress
## (so they're repeatable). Standing (non-daily) contracts are one-and-done.
@export var daily: bool = false
@export var obj_type: String = "kill"
@export var obj_target: String = ""             # enemy/item id ("" = any, where applicable)
@export var obj_count: int = 1
@export var reward_currency: int = 0
@export var reward_item_ids: PackedStringArray = PackedStringArray()
@export var reward_item_counts: PackedInt32Array = PackedInt32Array()
@export var reward_blueprints: PackedStringArray = PackedStringArray()

## --- Iteration 1: lifecycle / unlock conditions / chain + lore (all OPTIONAL) ---
## AND-list of unlock condition clauses, each "<stat><op><value>" (op ∈ >= > <= < == !=).
## Empty = AVAILABLE from the start. Parsed (NOT eval). Stats the evaluator understands:
##   kills_by_type.<enemy_id>, mobs_total, raider_level, vendor_rep, currency, xp,
##   weapon_mastery.<weapon_id>, extractions, quest_claimed.<quest_id>
## Example: PackedStringArray("kills_by_type.robot_grunt>=10")
@export var unlock: PackedStringArray = PackedStringArray()
## Quest ids that must be CLAIMED before this one can be offered (chain links; AND-ed with unlock).
@export var prereq: PackedStringArray = PackedStringArray()
## Flavor (shown in the UI detail modal). Falls back to the questline `intro` if empty.
@export_multiline var lore: String = ""
@export var giver: String = ""

## --- Iteration 2: questline grouping + random-pool offering ---
## Back-reference to the owning QuestLine.id ("" = standalone contract). The line's
## `quest_ids` is the source of truth for step order; this is for O(1) grouping.
@export var questline: String = ""
## Random-pool eligibility/weight. 0 = NEVER random-offered (only the ungated / condition /
## prereq paths). >0 = eligible for the QuestDirector's per-raid weighted random offer.
@export var offer_weight: int = 0

## Reward items as an array of { "id": String, "count": int } dicts.
func reward_items() -> Array:
	var out: Array = []
	for i in reward_item_ids.size():
		var c: int = reward_item_counts[i] if i < reward_item_counts.size() else 1
		out.append({ "id": String(reward_item_ids[i]), "count": maxi(1, c) })
	return out
