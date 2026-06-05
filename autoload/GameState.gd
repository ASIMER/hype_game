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

func match_timer_ratio() -> float:
	if match_duration <= 0.0:
		return 0.0
	return clampf(match_time_left / match_duration, 0.0, 1.0)

func difficulty_name() -> String:
	match difficulty:
		Difficulty.EASY: return "EASY"
		Difficulty.HARD: return "HARD"
		_: return "NORMAL"

# peer_id -> { name: String, ready: bool, alive: bool, extracted: bool }
var peers: Dictionary = {}

func reset_match() -> void:
	current_wave = 0
	match_time_left = match_duration
	final_wave = false
	for id in peers:
		peers[id]["alive"] = true
		peers[id]["extracted"] = false
		peers[id]["ready"] = false

func register_peer(peer_id: int, pname: String) -> void:
	peers[peer_id] = { "name": pname, "ready": false, "alive": true, "extracted": false }
	Events.peer_registered.emit(peer_id, peers[peer_id])

func unregister_peer(peer_id: int) -> void:
	if peers.has(peer_id):
		peers.erase(peer_id)
		Events.peer_unregistered.emit(peer_id)

func set_phase(p: int) -> void:
	phase = p

func is_local_authority_server() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()

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
