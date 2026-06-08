extends Node
## QuestDirector — offers LOCKED quests once their unlock conditions hold (Iteration 1:
## CONDITION-based offering only; weighted random-pool offering arrives in Iteration 2).
## Mirrors the ExtractionDirector/WorldEventDirector autoload pattern. Purely LOCAL +
## per-peer (it reads this peer's own MetaProgression via Quests), no networking.
##
## Registered as autoload "QuestDirector" in project.godot.
## DO NOT add class_name — the autoload name is the identifier.

func _ready() -> void:
	# Re-evaluate offers on the decisions that can satisfy an unlock condition.
	Events.player_kill.connect(_on_decision)
	Events.raid_loot_granted.connect(_on_loot)
	Events.match_won.connect(_on_match_won)
	Events.raider_level_up.connect(_on_level_up)
	Events.reputation_changed.connect(_on_rep)
	# Initial pass once the Quests autoload has scanned (deferred so order doesn't matter).
	evaluate_offers.call_deferred()

## For every LOCKED quest whose unlock conditions now hold → OFFER it (→ AVAILABLE) + toast.
func evaluate_offers() -> void:
	for q in Quests.all():
		var qd := q as QuestData
		if qd.daily:
			continue   # dailies are auto-accepted on rotation, never go through offer()
		if Quests.state_of(qd.id) != "":
			continue   # already offered/active/claimed
		if Quests.is_unlocked(qd):
			if Quests.offer(qd.id):
				Events.notify.emit(tr("New contract available: %s") % tr(qd.title), 1)

# --- triggers ----------------------------------------------------------------
func _on_decision(_enemy_id: String) -> void:
	evaluate_offers()

func _on_loot(_payload: Array, _bonus: int) -> void:
	evaluate_offers()

func _on_match_won() -> void:
	evaluate_offers()

func _on_level_up(_new_level: int, _skill_points: int) -> void:
	evaluate_offers()

func _on_rep(_rep: int, _tier: int) -> void:
	evaluate_offers()
