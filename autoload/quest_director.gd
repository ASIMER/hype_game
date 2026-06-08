extends Node
## QuestDirector — offers LOCKED quests once their unlock conditions hold (Iteration 1:
## CONDITION-based offering only; weighted random-pool offering arrives in Iteration 2).
## Mirrors the ExtractionDirector/WorldEventDirector autoload pattern. Purely LOCAL +
## per-peer (it reads this peer's own MetaProgression via Quests), no networking.
##
## Registered as autoload "QuestDirector" in project.godot.
## DO NOT add class_name — the autoload name is the identifier.

## Reset once per raid so a multi-extract raid only rolls a random offer one time.
var _rolled_this_raid: bool = false

func _ready() -> void:
	# Re-evaluate condition offers on the decisions that can satisfy an unlock condition.
	Events.player_kill.connect(_on_decision)
	Events.raid_loot_granted.connect(_on_loot)
	Events.match_won.connect(_on_match_won)
	Events.raider_level_up.connect(_on_level_up)
	Events.reputation_changed.connect(_on_rep)
	Events.match_started.connect(_on_match_started)
	# Initial pass once the Quests autoload has scanned (deferred so order doesn't matter).
	evaluate_offers.call_deferred()

## CONDITION pass: offer every LOCKED quest whose conditions now hold — EXCEPT ungated random-
## pool quests (offer_weight>0, no gate), which wait for the per-raid weighted roll.
func evaluate_offers() -> void:
	for q in Quests.all():
		var qd := q as QuestData
		if qd.daily:
			continue   # dailies are auto-accepted on rotation, never go through offer()
		if Quests.state_of(qd.id) != "":
			continue   # already offered/active/claimed
		if not Quests.is_unlocked(qd):
			continue
		# Bucket guard: a pure random-pool quest (weighted, no gate) is skipped here.
		if qd.offer_weight > 0 and not Quests.has_gate(qd):
			continue
		if Quests.offer(qd.id):
			_toast_offer(qd.title)

## RANDOM pass: offer up to RANDOM_OFFER_PER_RAID weighted contracts from the eligible pool,
## respecting the AVAILABLE board cap. Called once per successful raid.
func roll_random_offer() -> void:
	for _i in range(maxi(0, Settings.RANDOM_OFFER_PER_RAID)):
		if Quests.available_count() >= Settings.AVAILABLE_OFFER_CAP:
			return
		var pool: Array = Quests.random_pool()
		if pool.is_empty():
			return
		var total := 0
		for q in pool:
			total += maxi(1, (q as QuestData).offer_weight)
		var pick := randi() % total
		var acc := 0
		var chosen: QuestData = null
		for q in pool:
			acc += maxi(1, (q as QuestData).offer_weight)
			if pick < acc:
				chosen = q
				break
		if chosen == null:
			return
		if Quests.offer(chosen.id):
			_toast_offer(chosen.title)

## A new-contract toast — but NEVER mid-match (don't distract the player). The contract is
## still offered + the board updates silently; the player sees the toast next time in the hub.
func _toast_offer(title: String) -> void:
	if GameState.phase == GameState.Phase.IN_MATCH:
		return
	Events.notify.emit(tr("New contract available: %s") % tr(title), 1)

# --- triggers ----------------------------------------------------------------
func _on_match_started() -> void:
	_rolled_this_raid = false

func _on_decision(_enemy_id: String) -> void:
	evaluate_offers()

func _on_loot(_payload: Array, _bonus: int) -> void:
	# A successful extraction = a "raid done" — condition pass + one weighted random offer.
	evaluate_offers()
	if not _rolled_this_raid:
		_rolled_this_raid = true
		roll_random_offer()

func _on_match_won() -> void:
	evaluate_offers()
	if not _rolled_this_raid:
		_rolled_this_raid = true
		roll_random_offer()

func _on_level_up(_new_level: int, _skill_points: int) -> void:
	evaluate_offers()

func _on_rep(_rep: int, _tier: int) -> void:
	evaluate_offers()
