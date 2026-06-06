extends Node
## Progression tracker autoload (registered as "Progression" by the lead in project.godot).
## Listens to Events bus signals and routes them into MetaProgression. Purely LOCAL —
## no networking, no RPC. Each peer runs its own copy against its own MetaProgression.
##
## DO NOT add class_name here — the autoload name "Progression" is the identifier.
##
## Lead: register this file as autoload "Progression" in project.godot:
##   Progression="*res://autoload/progression.gd"

# Per-run accumulator: tracks whether any RARE+ item was in the haul this extraction
# so we only grant REP_PER_HIGH_TIER_HAUL once per extraction event.
var _rare_haul_rep_granted: bool = false


func _ready() -> void:
	# Reset per-run state on each new match.
	Events.match_started.connect(_on_match_started)

	# Kill XP + weapon mastery.
	Events.entity_died.connect(_on_entity_died)

	# Extraction loot XP + rep.
	Events.raid_loot_granted.connect(_on_raid_loot_granted)

	# World event XP.
	Events.world_event_ended.connect(_on_world_event_ended)

	# Quest completion rep.
	Events.quest_completed.connect(_on_quest_completed)


# ── Per-run reset ─────────────────────────────────────────────────────────────

func _on_match_started() -> void:
	_rare_haul_rep_granted = false


# ── Kill XP + weapon mastery ──────────────────────────────────────────────────

func _on_entity_died(entity: Node, killer: Node) -> void:
	# Only award XP/mastery when the LOCAL player is the killer.
	# entity_died fires on all peers; the killer==local check scopes it correctly.
	if entity == null or killer == null:
		return
	# The killed entity must NOT be in the "players" group (i.e. it must be an enemy).
	if entity.is_in_group("players"):
		return
	# Killer must be the local authority player.
	if not killer.is_in_group("players"):
		return
	if not killer.is_multiplayer_authority():
		return

	# Award account XP for the kill.
	MetaProgression.add_xp(Settings.XP_PER_KILL, "kill")

	# Award weapon mastery for the active weapon.
	# Path: the killer (CharacterBody3D) → CameraPivot/SpringArm3D/Camera3D/WeaponController
	# Guard every step — never crash if the tree differs.
	var wc: WeaponController = _find_weapon_controller(killer)
	if wc != null:
		var wid: String = wc.current_weapon_id()
		if wid != "":
			MetaProgression.add_weapon_mastery(wid, Settings.WEAPON_MASTERY_XP_PER_KILL)


## Walks the killer's subtree to locate its WeaponController child (deep under
## CameraPivot/SpringArm3D/Camera3D). Returns null if not found.
func _find_weapon_controller(player: Node) -> WeaponController:
	# Try the documented path first (fast, zero allocation).
	var direct: Node = player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D/WeaponController")
	if direct is WeaponController:
		return direct as WeaponController
	# Fallback: breadth-first search for any WeaponController descendant.
	var queue: Array[Node] = []
	queue.append(player)
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is WeaponController:
			return n as WeaponController
		for child in n.get_children():
			queue.append(child)
	return null


# ── Extraction loot XP + rep ──────────────────────────────────────────────────

func _on_raid_loot_granted(payload: Array, _bonus: int) -> void:
	# Base extract XP + rep — always on extraction.
	MetaProgression.add_xp(Settings.XP_PER_EXTRACT, "extract")
	MetaProgression.grant_rep(Settings.REP_PER_EXTRACT)

	# Rare+ haul bonus: +XP per rare item (×count, capped at 10 per item to avoid abuse)
	# and a one-shot rep bonus if ANY rare+ item is present.
	var has_rare: bool = false
	for entry in payload:
		var id: String = String(entry.get("id", ""))
		var cnt: int = mini(int(entry.get("count", 1)), 10)
		if id == "":
			continue
		var item_data: ItemData = ItemCatalog.get_item(id)
		if item_data == null:
			continue
		if item_data.rarity >= 2:   # ItemData.Rarity.RARE = 2
			MetaProgression.add_xp(Settings.XP_PER_RARE_LOOT * cnt, "loot")
			has_rare = true

	if has_rare and not _rare_haul_rep_granted:
		_rare_haul_rep_granted = true
		MetaProgression.grant_rep(Settings.REP_PER_HIGH_TIER_HAUL)


# ── World event XP ────────────────────────────────────────────────────────────

func _on_world_event_ended(_kind: int, success: bool) -> void:
	if success:
		MetaProgression.add_xp(Settings.XP_PER_EVENT, "event")


# ── Quest completion rep ──────────────────────────────────────────────────────

func _on_quest_completed(_quest_id: String) -> void:
	MetaProgression.grant_rep(Settings.REP_PER_CONTRACT)
