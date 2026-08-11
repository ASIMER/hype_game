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

	# Kill XP + weapon mastery are NOT driven off Events.entity_died here: that signal
	# fires SERVER-ONLY (enemies are server-authoritative), so a co-op client would never
	# see its own kills. Instead NetworkManager._on_entity_died (the server-auth scoreboard
	# attribution) routes the credit to the KILLER's machine, which calls credit_kill() below.

	# Extraction loot XP + rep.
	Events.raid_loot_granted.connect(_on_raid_loot_granted)

	# World event XP.
	Events.world_event_ended.connect(_on_world_event_ended)

	# Quest completion rep.
	Events.quest_completed.connect(_on_quest_completed)

	# M7.8 usage telemetry: personal extracts + deaths (local player only).
	Events.extraction_completed.connect(_count_extract)
	Events.player_bleedout.connect(_count_death)


func _count_extract(player: Node) -> void:
	if player != null and player.has_method("is_multiplayer_authority"):
		if player.is_multiplayer_authority():
			MetaProgression.count_usage("extracts")


func _count_death(player: Node) -> void:
	if player != null and player.has_method("is_multiplayer_authority"):
		if player.is_multiplayer_authority():
			MetaProgression.count_usage("deaths")


# ── Per-run reset ─────────────────────────────────────────────────────────────


func _on_match_started() -> void:
	_rare_haul_rep_granted = false
	MetaProgression.count_usage("raids")


# ── Kill XP + weapon mastery ──────────────────────────────────────────────────


## Called on the KILLER's own machine by NetworkManager (server-auth attribution → the
## killer peer). Awards account XP for the kill + mastery to THIS machine's active weapon
## (read locally so it's correct per-peer). Works identically in single-player + co-op.
func credit_kill(enemy_id: String = "") -> void:
	MetaProgression.add_xp(Settings.XP_PER_KILL, "kill")
	# Decision-tracking: record this PERSONAL kill by archetype (drives kill quests + the
	# QuestDirector's condition-based offering) and broadcast it on the LOCAL bus. add_xp
	# already saved the profile, so the kill_by_type bump rides the next save.
	if enemy_id != "":
		MetaProgression.record_kill_type(enemy_id)
		MetaProgression.save_profile()
		Events.player_kill.emit(enemy_id)
	# Weapon mastery for the local player's active weapon.
	var local_player: Node = _local_player()
	if local_player == null:
		return
	var wc: WeaponController = _find_weapon_controller(local_player)
	if wc != null:
		var wid: String = wc.current_weapon_id()
		if wid != "":
			MetaProgression.add_weapon_mastery(wid, Settings.WEAPON_MASTERY_XP_PER_KILL)


## The local-authority player node (this peer's own player), or null if not spawned yet.
func _local_player() -> Node:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p != null and is_instance_valid(p) and (p as Node).is_multiplayer_authority():
			return p
	return null


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
		if item_data.rarity >= 2:  # ItemData.Rarity.RARE = 2
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
