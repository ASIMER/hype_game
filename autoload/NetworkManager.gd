extends Node
## Host/join + peer lifecycle + lobby "ready" handshake. Listen-server model:
## the host is peer id 1 AND a player. Spawning of entities happens in the world
## scene's MultiplayerSpawners (server-driven) — this autoload only manages the
## connection, peer registry, and the load->ready->start handshake.

var local_player_name: String = "Raider"
var is_offline: bool = false   # true when running single-player (no peer)

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	Events.entity_died.connect(_on_entity_died)

# ---------------------------------------------------------------- host / join
func host_game(port: int = Settings.net_port) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, Settings.MAX_PLAYERS)
	if err != OK:
		push_error("Failed to create server: %s" % err)
		return err
	multiplayer.multiplayer_peer = peer
	is_offline = false
	GameState.set_phase(GameState.Phase.LOBBY)
	GameState.register_peer(1, local_player_name)
	return OK

func join_game(ip: String = Settings.DEFAULT_IP, port: int = Settings.net_port) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		push_error("Failed to create client: %s" % err)
		return err
	multiplayer.multiplayer_peer = peer
	is_offline = false
	GameState.set_phase(GameState.Phase.LOBBY)
	return OK

func start_offline() -> void:
	# Single-player: use an OfflineMultiplayerPeer (NOT null). With a null peer,
	# multiplayer.get_unique_id() errors and is_multiplayer_authority() returns
	# false on every entity — freezing the player camera/input and enemy AI. The
	# offline peer makes get_unique_id()==1 and is_server()==true with no actual
	# networking, so all authority checks pass locally.
	is_offline = true
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	GameState.set_phase(GameState.Phase.IN_MATCH)
	GameState.register_peer(1, local_player_name)

func disconnect_game() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	GameState.peers.clear()
	GameState.set_phase(GameState.Phase.MENU)

# ------------------------------------------------------- peer registry (RPCs)
## Client tells the server its info; server records and broadcasts the full roster.
@rpc("any_peer", "call_remote", "reliable")
func _register_self(pname: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	GameState.register_peer(sender, pname)
	_broadcast_roster.rpc(_serialize_roster())

@rpc("authority", "call_remote", "reliable")
func _broadcast_roster(roster: Dictionary) -> void:
	GameState.peers = roster
	for id in roster:
		Events.peer_registered.emit(id, roster[id])
	if Settings.NET_DEBUG:
		print("[net] roster synced on peer %d: %s" % [multiplayer.get_unique_id(), str(roster.keys())])

func _serialize_roster() -> Dictionary:
	return GameState.peers.duplicate(true)

# --------------------------------------------------------- squad ready-up
## A client toggles its lobby ready state; the server records it and re-broadcasts
## the roster so every lobby UI updates. (The host/leader is implicitly ready.)
@rpc("any_peer", "call_local", "reliable")
func set_ready(ready: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	GameState.set_peer_ready(sender, ready)
	_broadcast_roster.rpc(_serialize_roster())
	Events.squad_changed.emit()

## LEADER (host) presses START RAID. Server-only: gate on LOBBY + all members ready,
## then reset the match and tell EVERY peer to deploy on the same tick.
func request_start() -> bool:
	if not multiplayer.is_server():
		return false
	if not GameState.squad_all_ready():
		return false
	GameState.reset_match()
	_loaded.clear()
	_begin_deploy.rpc()
	return true

## Runs on EVERY peer: kick off the local deploy (commit bring-list + load arena).
@rpc("authority", "call_local", "reliable")
func _begin_deploy() -> void:
	GameState.set_phase(GameState.Phase.LOADING)
	Events.begin_deploy.emit()

# --------------------------------------------------------- load gate -> start
var _loaded: Dictionary = {}   # peer_id -> true (reset each deploy in request_start)

## Each peer calls this once its arena scene has finished loading. The match (and the
## player spawns) only begins once EVERY peer has loaded — so no peer's spawner is
## missing when players are created (the old grey-screen bug).
@rpc("any_peer", "call_local", "reliable")
func notify_loaded() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1   # the host's own call_local invocation has no remote sender
	_loaded[sender] = true
	if _all_loaded():
		# Don't clear _loaded here — keeping peers marked lets a LATER joiner's load
		# re-fire begin_match so the (idempotent) match-start sweep spawns them, after
		# their own arena exists. _loaded is reset at the next synchronized deploy
		# (request_start). begin_match/_ensure_player_spawned are both idempotent.
		Events.all_players_ready.emit()
		begin_match.rpc()

func _all_loaded() -> bool:
	if GameState.peers.is_empty():
		return false
	for id in GameState.peers:
		if not _loaded.has(id):
			return false
	return true

@rpc("authority", "call_local", "reliable")
func begin_match() -> void:
	if Settings.NET_DEBUG:
		print("[net] begin_match on peer %d" % multiplayer.get_unique_id())
	GameState.set_phase(GameState.Phase.IN_MATCH)
	Events.match_started.emit()

# -------------------------------------------------- gameplay state sync (HUD parity)
## The wave system + match timer run server-only, so clients' HUDs would show stale
## "PREPARING"/wrong timer. The server mirrors that state to clients here. No-ops in
## single-player / on a client.
func _is_remote_server() -> bool:
	return multiplayer.has_multiplayer_peer() and not is_offline and multiplayer.is_server()

func sync_wave(wave: int, count: int) -> void:
	if _is_remote_server():
		_rpc_wave.rpc(wave, count)

func sync_wave_cleared(wave: int) -> void:
	if _is_remote_server():
		_rpc_wave_cleared.rpc(wave)

func sync_match_timer(left: float, total: float, final_wave: bool) -> void:
	if _is_remote_server():
		_rpc_match_timer.rpc(left, total, final_wave)

@rpc("authority", "call_remote", "reliable")
func _rpc_wave(wave: int, count: int) -> void:
	GameState.current_wave = wave
	Events.wave_started.emit(wave, count)

@rpc("authority", "call_remote", "reliable")
func _rpc_wave_cleared(wave: int) -> void:
	Events.wave_cleared.emit(wave)

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_match_timer(left: float, total: float, final_wave: bool) -> void:
	GameState.match_time_left = left
	GameState.match_duration = total
	if final_wave and not GameState.final_wave:
		Events.final_wave_started.emit()
	GameState.final_wave = final_wave
	Events.match_timer_changed.emit(left, total)

# ----------------------------------------------------- match-end broadcast
## Server calls these to end the match on EVERY peer. Offline (incl. the offline
## peer) emits locally. Keeps win/loss consistent across co-op; single-player just
## emits. Each handler also flips GameState to RESULTS so restart input is accepted.
func broadcast_match_won() -> void:
	if multiplayer.has_multiplayer_peer() and not is_offline:
		_rpc_match_won.rpc()
	else:
		_rpc_match_won()

func broadcast_match_lost() -> void:
	if multiplayer.has_multiplayer_peer() and not is_offline:
		_rpc_match_lost.rpc()
	else:
		_rpc_match_lost()

@rpc("authority", "call_local", "reliable")
func _rpc_match_won() -> void:
	# Idempotent: ignore if the match already ended (e.g. survival + extraction
	# resolving in the same tick, or a late match_lost after a win).
	if GameState.phase == GameState.Phase.RESULTS:
		return
	GameState.set_phase(GameState.Phase.RESULTS)
	Events.match_won.emit()

@rpc("authority", "call_local", "reliable")
func _rpc_match_lost() -> void:
	if GameState.phase == GameState.Phase.RESULTS:
		return
	GameState.set_phase(GameState.Phase.RESULTS)
	Events.match_lost.emit()

# ============================================================ co-op combat sync
# A CLIENT's weapon resolves the hit locally but must NOT apply damage to its own
# copy of the enemy (the server owns the enemy). It routes the hit here; the server
# applies it authoritatively so the enemy actually takes damage / dies for everyone.

## Called by weapon.gd on a CLIENT after it resolves a hurtbox hit. The host applies
## directly (it IS the server); a client RPCs the server.
func request_hit(target_path: NodePath, amount: float, attacker_peer: int) -> void:
	if GameState.is_local_authority_server():
		_do_hit(target_path, amount, attacker_peer)
	else:
		_hit_rpc.rpc_id(1, target_path, amount, attacker_peer)

@rpc("any_peer", "call_remote", "reliable")
func _hit_rpc(target_path: NodePath, amount: float, attacker_peer: int) -> void:
	if not multiplayer.is_server():
		return
	_do_hit(target_path, amount, attacker_peer)

func _do_hit(target_path: NodePath, amount: float, attacker_peer: int) -> void:
	var hb := get_node_or_null(target_path)
	if hb != null and hb.has_method("apply_hit"):
		hb.apply_hit(amount, _player_for_peer(attacker_peer))

func _player_for_peer(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if str(p.name).to_int() == peer_id:
			return p
	return null

## Broadcast a fired shot to OTHER peers so teammates see the tracer/muzzle/impact
## (the shooter already spawned its own FX locally). Unreliable — purely cosmetic.
func broadcast_shot(muzzle: Vector3, hit_point: Vector3, arc: PackedVector3Array, enemy_hit: bool, normal: Vector3) -> void:
	if multiplayer.has_multiplayer_peer() and not is_offline:
		_shot_rpc.rpc(muzzle, hit_point, arc, enemy_hit, normal)

@rpc("any_peer", "call_remote", "unreliable")
func _shot_rpc(muzzle: Vector3, hit_point: Vector3, arc: PackedVector3Array, enemy_hit: bool, normal: Vector3) -> void:
	Events.remote_shot.emit(muzzle, hit_point, arc, enemy_hit, normal)

# =========================================================== kill leaderboard sync
## On the server, attribute each mob kill to the killer's peer and broadcast the
## full table so every client's TAB leaderboard is identical.
func _on_entity_died(entity: Node, killer: Node) -> void:
	if not GameState.is_local_authority_server():
		return
	if entity == null:
		return
	if entity.is_in_group("players"):
		GameState.record_death(_peer_of(entity))
		_sync_scores.rpc(GameState.kills, GameState.deaths, GameState.mobs_killed, GameState.revives)
		Events.scoreboard_changed.emit()
		return
	if not entity.is_in_group("enemies"):
		return
	var peer := _peer_of(killer)
	if peer > 0:
		GameState.record_kill(peer)
	else:
		GameState.mobs_killed += 1   # unattributed (environment/explosion) still counts to the team
	_sync_scores.rpc(GameState.kills, GameState.deaths, GameState.mobs_killed, GameState.revives)
	Events.scoreboard_changed.emit()

## Walk up from a node (hurtbox/weapon/player) to the owning player and return its
## peer id (the player node is named str(peer_id)). 0 = no player owner.
func _peer_of(node: Node) -> int:
	var n := node
	while n != null:
		if n.is_in_group("players"):
			var pid := str(n.name).to_int()
			return pid if pid > 0 else 1
		n = n.get_parent()
	return 0

@rpc("authority", "call_remote", "reliable")
func _sync_scores(k: Dictionary, d: Dictionary, total: int, r: Dictionary = {}) -> void:
	GameState.kills = k
	GameState.deaths = d
	GameState.mobs_killed = total
	GameState.revives = r
	Events.scoreboard_changed.emit()

# =========================================================== co-op revive / downed / ping
## A CLIENT (or host) asks the server to revive a downed teammate. Server validates the
## reviver is up + near + the target is actually downed, then heals the target to a fraction
## and credits the reviver (reputation). Authority-only mutation; mirrors request_hit.
func request_revive(target_peer: int) -> void:
	if GameState.is_local_authority_server():
		_do_revive(target_peer, _peer_of_local())
	else:
		_revive_rpc.rpc_id(1, target_peer, multiplayer.get_unique_id())

@rpc("any_peer", "call_remote", "reliable")
func _revive_rpc(target_peer: int, reviver_peer: int) -> void:
	if not multiplayer.is_server():
		return
	_do_revive(target_peer, reviver_peer)

func _do_revive(target_peer: int, reviver_peer: int) -> void:
	if not GameState.is_downed(target_peer):
		return
	var target := _player_for_peer(target_peer)
	if target == null or not target.has_method("server_revive"):
		return
	target.server_revive(_player_for_peer(reviver_peer))   # player clears downed + heals (synced)
	if reviver_peer > 0 and reviver_peer != target_peer:
		GameState.record_revive(reviver_peer)
		_sync_scores.rpc(GameState.kills, GameState.deaths, GameState.mobs_killed, GameState.revives)
		Events.scoreboard_changed.emit()

## Server broadcasts a peer's DOWNED state to everyone (drives the loss check + HUD + AI).
func broadcast_downed(pid: int, value: bool) -> void:
	if GameState.is_local_authority_server():
		GameState.set_downed(pid, value)
		if multiplayer.has_multiplayer_peer() and not is_offline:
			_downed_rpc.rpc(pid, value)

@rpc("authority", "call_remote", "reliable")
func _downed_rpc(pid: int, value: bool) -> void:
	GameState.set_downed(pid, value)

## Any peer places a ping → server relays to all (incl. sender via call_local) so the whole
## squad sees the world marker + HUD arrow. Cosmetic/comms; cheap + reliable.
func broadcast_ping(kind: int, world_pos: Vector3, target_path: NodePath) -> void:
	var me := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	if not multiplayer.has_multiplayer_peer() or is_offline:
		Events.ping_placed.emit(me, kind, world_pos, target_path)
		return
	_ping_rpc.rpc(me, kind, world_pos, target_path)

@rpc("any_peer", "call_local", "reliable")
func _ping_rpc(peer_id: int, kind: int, world_pos: Vector3, target_path: NodePath) -> void:
	Events.ping_placed.emit(peer_id, kind, world_pos, target_path)

## The local player's peer id (1 for host/offline).
func _peer_of_local() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1

# ============================================================ item transfer (give/trade)
## Server-authoritative atomic move of `count` of `item_id` from one player's
## inventory to another's. Validates the source has it and the target has room;
## partial moves are allowed (moves as much as fits). Returns the amount moved.
## Drives both inventories' owner-mirror so both clients see the result.
func transfer_item(from_peer: int, to_peer: int, item_id: String, count: int) -> int:
	if not GameState.is_local_authority_server():
		# Clients ask the server to perform the transfer.
		_transfer_rpc.rpc_id(1, from_peer, to_peer, item_id, count)
		return 0
	var src := _inventory_for_peer(from_peer)
	var dst := _inventory_for_peer(to_peer)
	if src == null or dst == null or count <= 0:
		return 0
	var item: ItemData = ItemCatalog.get_item(item_id)
	if item == null:
		return 0
	# How much can actually move = min(have, room).
	var have := 0
	for s in src.stacks:
		if (s["item"] as ItemData).id == item_id:
			have += int(s["count"])
	if have <= 0:
		return 0
	var want: int = mini(count, have)
	# Take, then add; refund whatever didn't fit in the destination.
	var taken: int = src.remove_item(item_id, want)
	var leftover: int = dst.add_item(item, taken)
	if leftover > 0:
		src.add_item(item, leftover)
	var moved: int = taken - leftover
	if moved > 0:
		Events.item_received.emit(from_peer, item_id, moved)
		_notify_received.rpc_id(to_peer, from_peer, item_id, moved)
	return moved

@rpc("any_peer", "call_remote", "reliable")
func _transfer_rpc(from_peer: int, to_peer: int, item_id: String, count: int) -> void:
	if not multiplayer.is_server():
		return
	# Only allow a peer to give away ITS OWN items (from_peer must be the sender).
	var sender := multiplayer.get_remote_sender_id()
	if sender != from_peer:
		return
	transfer_item(from_peer, to_peer, item_id, count)

@rpc("authority", "call_remote", "reliable")
func _notify_received(from_peer: int, item_id: String, count: int) -> void:
	Events.item_received.emit(from_peer, item_id, count)

## Server-authoritative stack split. A client asks the server to split `amount` off
## its own stack of `item_id` into a new stack; the owner-mirror then reflects it.
func request_split(peer_id: int, item_id: String, amount: int) -> void:
	if not GameState.is_local_authority_server():
		_split_rpc.rpc_id(1, peer_id, item_id, amount)
		return
	var inv := _inventory_for_peer(peer_id)
	if inv != null and inv.has_method("split_stack"):
		inv.split_stack(item_id, amount)

@rpc("any_peer", "call_remote", "reliable")
func _split_rpc(peer_id: int, item_id: String, amount: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != peer_id:
		return   # only split your OWN inventory
	request_split(peer_id, item_id, amount)

## Nearest OTHER player's peer id to the given peer (by world distance). 0 if alone.
## Used by GIVE + TRADE proximity. Works locally on any peer (positions are synced).
func nearest_teammate(peer_id: int) -> int:
	var me: Node = _player_for_peer(peer_id)
	if me == null or not (me is Node3D):
		return 0
	var my_pos: Vector3 = (me as Node3D).global_position
	var best := 0
	var best_d := INF
	for p in get_tree().get_nodes_in_group("players"):
		var pid := str(p.name).to_int()
		if pid == peer_id or not (p is Node3D):
			continue
		var d: float = my_pos.distance_to((p as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = pid
	return best

## Resolve a peer's Inventory node (child of its player). Server-side only.
func _inventory_for_peer(peer_id: int) -> Node:
	var p := _player_for_peer(peer_id)
	if p == null:
		return null
	return p.get_node_or_null("Inventory")

# ------------------------------------------------------------- net callbacks
func _on_peer_connected(id: int) -> void:
	# Server: a new client joined the ENet session. Roster is filled once the
	# client calls _register_self. WS-G wires entity spawning off match_started.
	if multiplayer.is_server():
		if Settings.NET_DEBUG:
			print("[net] peer %d connected to server" % id)
		_broadcast_roster.rpc_id(id, _serialize_roster())

func _on_peer_disconnected(id: int) -> void:
	GameState.unregister_peer(id)
	# Server: despawn the disconnected player's body so it doesn't linger frozen in the
	# arena (freeing it on the authority replicates the removal to the other clients).
	if multiplayer.is_server():
		for p in get_tree().get_nodes_in_group("players"):
			if str(p.name).to_int() == id:
				p.queue_free()
		# A disconnect could have been the last unresolved player — re-check win/lose.
		if GameState.all_players_dead():
			broadcast_match_lost()
		elif GameState.all_players_resolved():
			broadcast_match_won()

func _on_connected_to_server() -> void:
	_register_self.rpc_id(1, local_player_name)

func _on_connection_failed() -> void:
	push_warning("Connection failed")
	multiplayer.multiplayer_peer = null
	GameState.set_phase(GameState.Phase.MENU)

func _on_server_disconnected() -> void:
	push_warning("Server disconnected")
	multiplayer.multiplayer_peer = null
	GameState.peers.clear()
	GameState.set_phase(GameState.Phase.MENU)
