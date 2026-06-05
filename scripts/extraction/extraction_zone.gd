extends Area3D
class_name ExtractionZone
## Server-authoritative extraction point. While a player (group "players") stays
## inside the zone, a per-player timer fills toward Settings.EXTRACTION_TIME; on
## completion the peer is marked extracted and, once every peer is resolved
## (dead or extracted), the match is won. Leaving the zone cancels and resets that
## player's progress.
##
## Attach to the Arena's ExtractionZone Area3D (collision layer extraction=16,
## mask player=2). Only the local authority server advances timers; progress is
## broadcast over Events so the HUD can render it. Clients simply listen.

# player node -> elapsed seconds inside the zone
var _timers: Dictionary = {}
# players that have already finished extracting (avoid double-completion)
var _completed: Dictionary = {}
var _is_server: bool = false

func _ready() -> void:
	add_to_group("extraction")   # so the minimap/compass can mark zones
	_is_server = GameState.is_local_authority_server()
	if not _is_server:
		set_physics_process(false)
		return
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	# Pick up any players already overlapping when we attach.
	for body in get_overlapping_bodies():
		_on_body_entered(body)

func _on_body_entered(body: Node) -> void:
	if not _is_player(body):
		return
	if _completed.has(body):
		return
	if _timers.has(body):
		return
	_timers[body] = 0.0
	Events.extraction_started.emit(body, self)
	Events.extraction_progress.emit(body, 0.0)

func _on_body_exited(body: Node) -> void:
	if not _timers.has(body):
		return
	_timers.erase(body)
	# Don't fire a spurious cancel for a player who already finished.
	if not _completed.has(body):
		Events.extraction_cancelled.emit(body)

func _physics_process(delta: float) -> void:
	if _timers.is_empty():
		return
	# Iterate a copy so completion can erase from _timers mid-loop.
	for body in _timers.keys():
		if not is_instance_valid(body):
			_timers.erase(body)
			continue
		var elapsed: float = _timers[body] + delta
		var ratio: float = clampf(elapsed / maxf(Settings.EXTRACTION_TIME, 0.001), 0.0, 1.0)
		_timers[body] = elapsed
		Events.extraction_progress.emit(body, ratio)
		if ratio >= 1.0:
			_complete(body)

func _complete(body: Node) -> void:
	_timers.erase(body)
	_completed[body] = true
	Events.extraction_completed.emit(body)
	_mark_extracted(body)
	_grant_extraction(body)
	if GameState.all_players_resolved():
		NetworkManager.broadcast_match_won()

## Server-authoritative payout: the extracting player KEEPS its haul. We build the
## deposit from the found-loot Inventory (server-side authoritative) + the surviving
## brought consumables (replicated), then hand it to RaidManager, which deposits it into
## THAT peer's own stash (locally for the host, via RPC for a remote client) plus a
## wave-scaled survival-bonus currency. Death deposits nothing — gear is lost.
func _grant_extraction(body: Node) -> void:
	var peer_id := _peer_id_for(body)
	var stacks: Array = []
	var inv: Node = body.get_node_or_null("Inventory")
	if inv and "stacks" in inv:
		for s in inv.stacks:
			var it: ItemData = s.get("item", null)
			if it != null:
				stacks.append({ "id": it.id, "count": int(s.get("count", 0)) })
	if body.has_method("extracted_consumables"):
		stacks.append_array(body.extracted_consumables())
	var survival_bonus := 50 + GameState.current_wave * 25
	RaidManager.grant_extraction(peer_id, stacks, survival_bonus)

## Resolve the player node to a peer id and flag it extracted in GameState.
func _mark_extracted(body: Node) -> void:
	var peer_id := _peer_id_for(body)
	if peer_id != 0 and GameState.peers.has(peer_id):
		GameState.peers[peer_id]["extracted"] = true

func _peer_id_for(body: Node) -> int:
	# Player nodes are named after their peer id (see arena.gd _spawn_player).
	if body.name.is_valid_int():
		return body.name.to_int()
	if body.has_method("get_multiplayer_authority"):
		return body.get_multiplayer_authority()
	return 0

func _is_player(body: Node) -> bool:
	return body != null and body.is_in_group("players")
