extends Node
## Match-level state shared across systems. Server is the source of truth in
## multiplayer; clients read mirrored values. Kept deliberately small.

enum Phase { MENU, LOBBY, LOADING, IN_MATCH, RESULTS }
enum Difficulty { EASY, NORMAL, HARD }

var phase: int = Phase.MENU
var current_wave: int = 0
var map_scene: String = "res://scenes/world/Arena.tscn"
## Selected difficulty (persisted via MetaProgression). Scales enemy stats + counts
## (see Settings.difficulty_mods). Set from the Workshop before deploying.
var difficulty: int = Difficulty.NORMAL
## Loot value extracted this run (summed at extraction; used for the rewards screen).
var last_run_reward: int = 0

## Match countdown (server-authoritative; WaveManager ticks it, clients mirror via
## Events.match_timer_changed). `match_time_left` counts down from `match_duration`.
## When it hits 0 the final overwhelming wave begins (`final_wave` = true).
var match_duration: float = 0.0
var match_time_left: float = 0.0
var final_wave: bool = false

## This match's raid mutator ("" = none) — rolled by the server in _begin_deploy
## BEFORE load_arena (double_loot is read at build time) and synced to clients via
## NetworkManager.sync_mutator. Read-only everywhere else.
var raid_mutator: String = ""

## Machine Nemesis codex mirror (Phase 4) — the HOST owns nemesis.cfg, so it pushes the
## active rival + retired history here via NetworkManager.sync_nemesis_codex so the co-op
## CLIENT's Hub "Rivals" tab can display them. `nemesis_active` = a profile dict or {}.
var nemesis_active: Dictionary = {}
var nemesis_history: Array = []


func match_timer_ratio() -> float:
	if match_duration <= 0.0:
		return 0.0
	return clampf(match_time_left / match_duration, 0.0, 1.0)


func difficulty_name() -> String:
	match difficulty:
		Difficulty.EASY:
			return "EASY"
		Difficulty.HARD:
			return "HARD"
		_:
			return "NORMAL"


# peer_id -> { name: String, ready: bool, alive: bool, extracted: bool }
var peers: Dictionary = {}

## Per-player mob kills (peer_id -> int) and the team total. Server-authoritative,
## broadcast to every client so the TAB leaderboard is identical for all. Keys are
## ints (peer ids); deaths tracked separately for the "deaths" column.
var kills: Dictionary = {}
var deaths: Dictionary = {}
var mobs_killed: int = 0
## Co-op downed/revive (server-authoritative). `downed[pid]=true` while a peer is bleeding
## out (not yet truly dead). `revives[pid]` = how many teammates THIS peer has picked up
## (the cohesion/reputation stat shown on the scoreboard).
var downed: Dictionary = {}
var revives: Dictionary = {}


## Record one mob kill by `peer_id` (server-side). Returns nothing; caller broadcasts.
func record_kill(peer_id: int) -> void:
	kills[peer_id] = int(kills.get(peer_id, 0)) + 1
	mobs_killed += 1


func record_death(peer_id: int) -> void:
	deaths[peer_id] = int(deaths.get(peer_id, 0)) + 1


## Mark/clear a peer's DOWNED (bleedout) state — server-authoritative.
func set_downed(peer_id: int, value: bool) -> void:
	downed[peer_id] = value


func is_downed(peer_id: int) -> bool:
	return bool(downed.get(peer_id, false))


## Credit `peer_id` with a successful teammate revive (the reputation stat).
func record_revive(peer_id: int) -> void:
	revives[peer_id] = int(revives.get(peer_id, 0)) + 1


## True if at least one peer is still UP (alive, not downed, not extracted) — i.e. the squad
## can still revive/fight. The match is lost only when NO ONE is up and no one extracted.
func any_player_up() -> bool:
	for id in peers:
		var p: Dictionary = peers[id]
		if p["alive"] and not p["extracted"] and not is_downed(id):
			return true
	return false


func reset_match() -> void:
	current_wave = 0
	match_time_left = match_duration
	final_wave = false
	raid_mutator = ""
	kills.clear()
	deaths.clear()
	mobs_killed = 0
	downed.clear()
	revives.clear()
	for id in peers:
		peers[id]["alive"] = true
		peers[id]["extracted"] = false
		peers[id]["ready"] = false


func register_peer(peer_id: int, pname: String) -> void:
	peers[peer_id] = {"name": pname, "ready": false, "alive": true, "extracted": false}
	Events.peer_registered.emit(peer_id, peers[peer_id])


func unregister_peer(peer_id: int) -> void:
	if peers.has(peer_id):
		peers.erase(peer_id)
		Events.peer_unregistered.emit(peer_id)


func set_phase(p: int) -> void:
	phase = p


func is_local_authority_server() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


## This peer's id (1 when offline / host).
func local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 1
	return multiplayer.get_unique_id()


## The squad leader is always the host (peer 1). This peer leads if it's the host.
func is_leader() -> bool:
	return is_local_authority_server()


## True when every NON-leader squad member is marked ready (the host/leader is
## implicitly ready). Used to gate START RAID. Host-alone → true.
func squad_all_ready() -> bool:
	for id in peers:
		if int(id) == 1:
			continue
		if not peers[id].get("ready", false):
			return false
	return true


## Mark a peer ready/unready in the roster (server-side).
func set_peer_ready(peer_id: int, ready: bool) -> void:
	if peers.has(peer_id):
		peers[peer_id]["ready"] = ready


## True when every registered peer is marked alive==false or extracted (match over).
func all_players_resolved() -> bool:
	if peers.is_empty():
		return false
	for id in peers:
		var p: Dictionary = peers[id]
		if p["alive"] and not p["extracted"]:
			return false
	return true


## Flag a peer as dead (called on the server when its player's Health hits 0).
func mark_dead(peer_id: int) -> void:
	if peers.has(peer_id):
		peers[peer_id]["alive"] = false


## True when every registered peer is dead and none extracted — a total wipe (loss).
## (If anyone extracted, that's a win path handled by all_players_resolved + match_won.)
func all_players_dead() -> bool:
	if peers.is_empty():
		return false
	for id in peers:
		var p: Dictionary = peers[id]
		if p["alive"] or p["extracted"]:
			return false
	return true
