extends Node
## Host/join + peer lifecycle + lobby "ready" handshake. Listen-server model:
## the host is peer id 1 AND a player. Spawning of entities happens in the world
## scene's MultiplayerSpawners (server-driven) — this autoload only manages the
## connection, peer registry, and the load->ready->start handshake.

var local_player_name: String = "Raider"
var is_offline: bool = false  # true when running single-player (no peer)


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	Events.entity_died.connect(_on_entity_died)
	# M6: world events are server-directed, so their Events fires never reached
	# co-op clients (no banner/beacon/marker on the join side). Mirror them.
	Events.world_event_started.connect(_relay_world_event_started)
	Events.world_event_ended.connect(_relay_world_event_ended)


# ----------------------------------------------------- world-event client sync
func _relay_world_event_started(kind: int, pos: Vector3, label: String) -> void:
	if GameState.is_local_authority_server() and not multiplayer.get_peers().is_empty():
		_rpc_world_event_started.rpc(kind, pos, label)


func _relay_world_event_ended(kind: int, success: bool) -> void:
	if GameState.is_local_authority_server() and not multiplayer.get_peers().is_empty():
		_rpc_world_event_ended.rpc(kind, success)


@rpc("authority", "call_remote", "reliable")
func _rpc_world_event_started(kind: int, pos: Vector3, label: String) -> void:
	Events.world_event_started.emit(kind, pos, label)


@rpc("authority", "call_remote", "reliable")
func _rpc_world_event_ended(kind: int, success: bool) -> void:
	Events.world_event_ended.emit(kind, success)


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
		print(
			"[net] roster synced on peer %d: %s" % [multiplayer.get_unique_id(), str(roster.keys())]
		)


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
	roll_raid_mutator()
	_loaded.clear()
	_begin_deploy.rpc()
	return true


## Host-driven RESTART / re-deploy of an ALREADY-formed squad (post-raid "Restart", or a
## re-deploy that shouldn't wait on the lobby ready toggles). Same synchronized path as
## request_start but WITHOUT the all-ready gate. Critically it clears `_loaded` and tells
## EVERY peer to reload its arena — a host-local load_arena() would respawn only the host
## and leave clients in their stale/empty arena (the grey-screen-on-restart bug).
func request_redeploy() -> bool:
	if not multiplayer.is_server():
		return false
	GameState.reset_match()
	roll_raid_mutator()
	_loaded.clear()
	_begin_deploy.rpc()
	return true


## Debug (AgentBridge `mutator` verb): when non-null, the next deploys use this exact
## mutator ("" = force none) instead of rolling — build-time mutators (double_loot /
## night_raid) can only be QA'd through a real deploy.
var forced_mutator: Variant = null


## SERVER: roll this match's raid mutator ONCE per deploy, BEFORE any peer loads its
## arena (double_loot is read at build time). 35% chance of exactly one mutator; the
## result is synced now AND re-synced in begin_match (covers a peer that was still
## connecting when the roll happened). Debug-forceable via set_raid_mutator. PUBLIC:
## the offline solo deploy/restart paths in main.gd roll through here too (they call
## GameState.reset_match() directly, never request_start/request_redeploy).
func roll_raid_mutator() -> void:
	if forced_mutator != null:
		set_raid_mutator(String(forced_mutator))
		return
	var mutator := ""
	if randf() < Settings.RAID_MUTATOR_CHANCE:
		mutator = Settings.RAID_MUTATORS[randi() % Settings.RAID_MUTATORS.size()]
	set_raid_mutator(mutator)


## SERVER: apply + broadcast a mutator (also the AgentBridge debug-force entry point).
func set_raid_mutator(mutator: String) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	GameState.raid_mutator = mutator
	Events.raid_mutator_changed.emit(mutator)
	if _is_remote_server():
		_rpc_mutator.rpc(mutator)


@rpc("authority", "call_remote", "reliable")
func _rpc_mutator(mutator: String) -> void:
	GameState.raid_mutator = mutator
	Events.raid_mutator_changed.emit(mutator)


## Runs on EVERY peer: kick off the local deploy (commit bring-list + load arena).
@rpc("authority", "call_local", "reliable")
func _begin_deploy() -> void:
	GameState.set_phase(GameState.Phase.LOADING)
	Events.begin_deploy.emit()


# --------------------------------------------------------- load gate -> start
var _loaded: Dictionary = {}  # peer_id -> true (reset each deploy in request_start)

## Each peer calls this once its arena scene has finished loading. The match (and the
## player spawns) only begins once EVERY peer has loaded — so no peer's spawner is
## missing when players are created (the old grey-screen bug).
@rpc("any_peer", "call_local", "reliable")
func notify_loaded() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1  # the host's own call_local invocation has no remote sender
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
	# Re-sync the mutator at match start: a peer that joined mid-deploy missed the
	# roll-time broadcast; re-emitting locally also refreshes late HUD instances.
	if _is_remote_server():
		_rpc_mutator.rpc(GameState.raid_mutator)
	Events.raid_mutator_changed.emit(GameState.raid_mutator)
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


## Elemental-ammo chemistry (Phase 6): a landed elemental hit routes the ELEMENT KIND only —
## the SERVER derives every number from Settings.CHEM_AMMO_* (mirrors request_hit's shape,
## but with zero client-supplied magnitudes). Host applies directly; a client RPCs.
func request_chemistry(target_path: NodePath, kind: String) -> void:
	if GameState.is_local_authority_server():
		_do_chemistry(target_path, kind)
	else:
		_chemistry_rpc.rpc_id(1, target_path, kind)


@rpc("any_peer", "call_remote", "reliable")
func _chemistry_rpc(target_path: NodePath, kind: String) -> void:
	if not multiplayer.is_server():
		return
	_do_chemistry(target_path, kind)


func _do_chemistry(target_path: NodePath, kind: String) -> void:
	if kind not in ["shock", "burn", "slow"]:
		return
	var enemy := get_node_or_null(target_path)
	if enemy != null:
		MachineChemistry.apply_ammo(enemy, kind)


func _player_for_peer(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if str(p.name).to_int() == peer_id:
			return p
	return null


## Broadcast a fired shot to OTHER peers so teammates see the tracer/muzzle/impact
## (the shooter already spawned its own FX locally). Unreliable — purely cosmetic.
func broadcast_shot(
	muzzle: Vector3, hit_point: Vector3, arc: PackedVector3Array, enemy_hit: bool, normal: Vector3
) -> void:
	if multiplayer.has_multiplayer_peer() and not is_offline:
		_shot_rpc.rpc(muzzle, hit_point, arc, enemy_hit, normal)


@rpc("any_peer", "call_remote", "unreliable")
func _shot_rpc(
	muzzle: Vector3, hit_point: Vector3, arc: PackedVector3Array, enemy_hit: bool, normal: Vector3
) -> void:
	Events.remote_shot.emit(muzzle, hit_point, arc, enemy_hit, normal)


# =========================================================== noise -> server AI
## A loud event (gunfire / grenade) was made — route it to the SERVER so the
## server-authoritative enemy AI can HEAR it. The host emits Events.noise_emitted
## directly; a client RPCs the server (its own enemy copies don't run AI, so a local
## emit would be heard by nobody). Footsteps are NOT reported through here — the server
## derives footstep loudness from each player's synced velocity+stance every frame.
func report_noise(world_pos: Vector3, loudness: float, kind: int) -> void:
	if GameState.is_local_authority_server():
		Events.noise_emitted.emit(world_pos, loudness, kind)
	else:
		_noise_rpc.rpc_id(1, world_pos, loudness, kind)


@rpc("any_peer", "call_remote", "reliable")
func _noise_rpc(world_pos: Vector3, loudness: float, kind: int) -> void:
	if not multiplayer.is_server():
		return
	Events.noise_emitted.emit(world_pos, loudness, kind)


# =========================================================== breakable window glass
## A pane was hit — route the break to the SERVER (authoritative), which validates and
## broadcasts so every peer shatters the SAME pane. Panes are addressed by their
## deterministic build index (wall roots are anonymous → node-path RPCs can't target
## them; the index registry lives in BreakableGlass). The break is also a small noise
## the server AI investigates.
func request_break_glass(index: int) -> void:
	if GameState.is_local_authority_server():
		_server_break_glass(index)
	else:
		_break_glass_request_rpc.rpc_id(1, index)


@rpc("any_peer", "call_remote", "reliable")
func _break_glass_request_rpc(index: int) -> void:
	if not multiplayer.is_server():
		return
	_server_break_glass(index)


func _server_break_glass(index: int) -> void:
	var pane: BreakableGlass = BreakableGlass.by_index(index)
	if pane == null or pane.broken:
		return
	report_noise(pane.global_position, BreakableGlass.NOISE_LOUDNESS, 1)
	_glass_broken_rpc.rpc(index)


@rpc("authority", "call_local", "reliable")
func _glass_broken_rpc(index: int) -> void:
	var pane: BreakableGlass = BreakableGlass.by_index(index)
	if pane != null:
		pane.shatter()


## Building wall-segment damage (BreakableChunk, index-keyed like glass). HP is server-only:
## the host applies directly; a client routes the shot's damage via rpc_id(1). When a hit
## depletes the segment, the server broadcasts the crumble to every peer. `normal` is the shot's
## surface normal (points toward the shooter) so the falling debris sprays the right way; it rides
## through to crumble() — Vector3.ZERO for a grenade (radial burst).
func request_damage_chunk(index: int, dmg: float, normal: Vector3 = Vector3.ZERO) -> void:
	if GameState.is_local_authority_server():
		_server_damage_chunk(index, dmg, normal)
	else:
		_damage_chunk_request_rpc.rpc_id(1, index, dmg, normal)


@rpc("any_peer", "call_remote", "reliable")
func _damage_chunk_request_rpc(index: int, dmg: float, normal: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_server_damage_chunk(index, dmg, normal)


func _server_damage_chunk(index: int, dmg: float, normal: Vector3) -> void:
	var chunk: BreakableChunk = BreakableChunk.by_index(index)
	if chunk == null or chunk.broken:
		return
	if chunk.server_take_damage(dmg):
		report_noise(chunk.global_position, BreakableChunk.NOISE_LOUDNESS, 1)
		_chunk_broken_rpc.rpc(index, normal)


@rpc("authority", "call_local", "reliable")
func _chunk_broken_rpc(index: int, normal: Vector3) -> void:
	var chunk: BreakableChunk = BreakableChunk.by_index(index)
	if chunk != null:
		chunk.crumble(normal)


# ================================================== destructible trees (by index)
## Shot damage to a tree trunk (index = TreeTrunks child order, deterministic on
## every peer — the glass/chunk discipline). Server owns HP; the fell broadcasts.
func request_fell_tree(index: int, dmg: float, normal: Vector3 = Vector3.ZERO) -> void:
	if GameState.is_local_authority_server():
		_server_fell_tree(index, dmg, normal)
	else:
		_fell_tree_request_rpc.rpc_id(1, index, dmg, normal)


@rpc("any_peer", "call_remote", "reliable")
func _fell_tree_request_rpc(index: int, dmg: float, normal: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_server_fell_tree(index, dmg, normal)


func _server_fell_tree(index: int, dmg: float, normal: Vector3) -> void:
	if not FellableTree.server_take_damage(index, dmg):
		return
	report_noise(FellableTree.position_of(index), FellableTree.NOISE_LOUDNESS, 1)
	_tree_felled_rpc.rpc(index, normal)


@rpc("authority", "call_local", "reliable")
func _tree_felled_rpc(index: int, normal: Vector3) -> void:
	var host: Node = get_tree().current_scene
	if host != null:
		FellableTree.do_fell(host, index, normal)


# ============================================== server-spawned throwables / gadgets
## ALL grenade throws + gadget placements spawn on the SERVER under Arena/Net/Gadgets
## (a MultiplayerSpawner with NetThrowables.spawn as its custom spawn_function), so
## server-side effects (EMP stun, decoy noise, smoke AI, turret damage) exist exactly
## once and every peer builds the same node from the replicated spawn data. The host
## spawns directly; a client RPCs the server. Counts were already decremented on the
## OWNING peer (replicated player properties — trusted like the rest of the
## consumable economy).
func request_throw_grenade(type: String, from: Vector3, dir: Vector3) -> void:
	if GameState.is_local_authority_server():
		_spawn_throwable(
			{
				"kind": "grenade",
				"type": type,
				"from": from,
				"dir": dir,
				"force": Settings.GRENADE_THROW_FORCE,
			}
		)
	else:
		_throw_grenade_rpc.rpc_id(1, type, from, dir)


@rpc("any_peer", "call_remote", "reliable")
func _throw_grenade_rpc(type: String, from: Vector3, dir: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_spawn_throwable(
		{
			"kind": "grenade",
			"type": type,
			"from": from,
			"dir": dir,
			"force": Settings.GRENADE_THROW_FORCE,
		}
	)


func request_place_gadget(type: String, world_pos: Vector3, yaw: float) -> void:
	if GameState.is_local_authority_server():
		_spawn_throwable(
			{
				"kind": "gadget",
				"type": type,
				"pos": world_pos,
				"yaw": yaw,
				"owner_peer": GameState.local_peer_id(),
			}
		)
	else:
		_place_gadget_rpc.rpc_id(1, type, world_pos, yaw)


@rpc("any_peer", "call_remote", "reliable")
func _place_gadget_rpc(type: String, world_pos: Vector3, yaw: float) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	_spawn_throwable(
		{"kind": "gadget", "type": type, "pos": world_pos, "yaw": yaw, "owner_peer": sender}
	)


## Server-side: route the spawn through the arena's GadgetSpawner (replicates to all).
func _spawn_throwable(data: Dictionary) -> void:
	var arena: Node = get_tree().get_first_node_in_group(Groups.ARENA)
	if arena == null:
		return
	var spawner: MultiplayerSpawner = arena.get_node_or_null("Net/GadgetSpawner")
	if spawner == null or not spawner.spawn_function.is_valid():
		return
	spawner.spawn(data)


# =========================================================== kill leaderboard sync
## On the server, attribute each mob kill to the killer's peer and broadcast the
## full table so every client's TAB leaderboard is identical.
func _on_entity_died(entity: Node, killer: Node) -> void:
	if not GameState.is_local_authority_server():
		return
	if entity == null:
		return
	if entity.is_in_group(Groups.PLAYERS):
		GameState.record_death(_peer_of(entity))
		_sync_scores.rpc(
			GameState.kills, GameState.deaths, GameState.mobs_killed, GameState.revives
		)
		Events.scoreboard_changed.emit()
		return
	if not entity.is_in_group(Groups.ENEMIES):
		return
	var peer := _peer_of(killer)
	# Enemy archetype (robot_grunt/heavy/elite/…) — threaded to the killer so its PERSONAL
	# kills_by_type + kill quests advance on the right machine (the co-op kill-tracking fix).
	var eid := String(entity.get("enemy_id")) if "enemy_id" in entity else ""
	if peer > 0:
		GameState.record_kill(peer)
		# Credit PROGRESSION (XP + weapon mastery + kill-by-type) on the KILLER's own machine.
		# entity_died fires server-only (enemies are server-auth), so a client never sees its
		# own kill — we route the credit to the killer peer here (the same server-auth
		# attribution the scoreboard uses). Host kill → local; client kill → rpc to that peer
		# only. This is why a client earned no kill-XP before. Exactly one path fires.
		if is_offline or peer == multiplayer.get_unique_id():
			Progression.credit_kill(eid)
		else:
			_credit_kill_rpc.rpc_id(peer, eid)
	else:
		GameState.mobs_killed += 1  # unattributed (environment/explosion) still counts to the team
	_sync_scores.rpc(GameState.kills, GameState.deaths, GameState.mobs_killed, GameState.revives)
	Events.scoreboard_changed.emit()


## Server → the killer peer: credit your own kill locally (XP + this machine's active
## weapon's mastery). Runs on the killer's machine so it reads that peer's own profile + gun.
@rpc("authority", "call_remote", "reliable")
func _credit_kill_rpc(enemy_id: String = "") -> void:
	Progression.credit_kill(enemy_id)


# ===================================================== Machine Nemesis (Phase 3)
## Server-side: grant the Machine Nemesis defeat BOUNTY to `peer` (currency + vendor rep +
## XP). Routed like the kill credit — the host grants itself directly, a remote killer gets
## it on ITS OWN machine via rpc_id so its profile/HUD update correctly.
func grant_nemesis_bounty(peer: int) -> void:
	if not GameState.is_local_authority_server() or peer <= 0:
		return
	if peer == _peer_of_local():
		_award_nemesis_bounty()
	else:
		_grant_nemesis_bounty_rpc.rpc_id(peer)


@rpc("authority", "call_remote", "reliable")
func _grant_nemesis_bounty_rpc() -> void:
	_award_nemesis_bounty()


func _award_nemesis_bounty() -> void:
	MetaProgression.earn(Settings.NEMESIS_BOUNTY_CURRENCY)
	MetaProgression.grant_rep(Settings.NEMESIS_BOUNTY_REP)
	MetaProgression.add_xp(Settings.NEMESIS_BOUNTY_XP, "nemesis_kill")


## A peer whose player just truly DIED reports its at-risk (committed) gear ids to the HOST
## so the NemesisDirector can have the surviving rival "wear" + drop it on defeat ("reclaim
## your armor"). The host applies directly; a client routes to the host via rpc_id(1).
func report_nemesis_loss(ids: Array) -> void:
	if ids.is_empty():
		return
	if GameState.is_local_authority_server():
		_record_nemesis_loss(ids)
	else:
		_report_loss_rpc.rpc_id(1, ids)


@rpc("any_peer", "call_remote", "reliable")
func _report_loss_rpc(ids: Array) -> void:
	if GameState.is_local_authority_server():
		_record_nemesis_loss(ids)


func _record_nemesis_loss(ids: Array) -> void:
	var dir: Node = get_node_or_null("/root/NemesisDirector")
	if dir != null:
		dir.call("record_lost_gear", ids)


# ===================================================== Phase 4 synergy layers
## Server-side: reward the carrier `peer` who EXTRACTED with the Power-Core (currency + rep +
## the core item in their stash). Routed to that peer's own machine like the kill credit.
func grant_power_core(peer: int) -> void:
	if not GameState.is_local_authority_server() or peer <= 0:
		return
	if peer == _peer_of_local():
		_award_power_core()
	else:
		_grant_power_core_rpc.rpc_id(peer)


@rpc("authority", "call_remote", "reliable")
func _grant_power_core_rpc() -> void:
	_award_power_core()


func _award_power_core() -> void:
	MetaProgression.earn(Settings.POWER_CORE_BOUNTY)
	MetaProgression.grant_rep(Settings.POWER_CORE_REP)
	Stash.add("loot_power_core", 1)


## Host → clients: push the Machine Nemesis codex (active rival + retired history) so a co-op
## client's Hub "Rivals" tab can display it (the host owns nemesis.cfg). Called by the
## NemesisDirector on birth/level/defeat + match start (catch-up for late joiners).
func sync_nemesis_codex(active: Dictionary, history: Array) -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rpc_nemesis_codex.rpc(active, history)


@rpc("authority", "call_remote", "reliable")
func _rpc_nemesis_codex(active: Dictionary, history: Array) -> void:
	GameState.nemesis_active = active
	GameState.nemesis_history = history
	Events.nemesis_codex_synced.emit()


## Walk up from a node (hurtbox/weapon/player) to the owning player and return its
## peer id (the player node is named str(peer_id)). 0 = no player owner.
func _peer_of(node: Node) -> int:
	var n := node
	while n != null:
		if n.is_in_group(Groups.PLAYERS):
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
	# Validate the reviver server-side (defense in depth — the client only sends this when
	# prompted, but never trust it): the reviver must exist, be UP (not downed), and be
	# within interaction range of the downed target. Blocks a downed-squad loop-revive +
	# out-of-range revives.
	var reviver := _player_for_peer(reviver_peer)
	if reviver == null or reviver_peer == target_peer or GameState.is_downed(reviver_peer):
		return
	if (
		(reviver as Node3D).global_position.distance_to((target as Node3D).global_position)
		> Settings.INTERACT_RANGE * 1.5
	):
		return
	target.server_revive(reviver)  # player clears downed + heals (synced)
	if reviver_peer > 0 and reviver_peer != target_peer:
		GameState.record_revive(reviver_peer)
		_sync_scores.rpc(
			GameState.kills, GameState.deaths, GameState.mobs_killed, GameState.revives
		)
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
		return  # only split your OWN inventory
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
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
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
		_relax_peer_timeout(id)
		if Settings.NET_DEBUG:
			print("[net] peer %d connected to server" % id)
		_broadcast_roster.rpc_id(id, _serialize_roster())


func _on_peer_disconnected(id: int) -> void:
	GameState.unregister_peer(id)
	# Server: despawn the disconnected player's body so it doesn't linger frozen in the
	# arena (freeing it on the authority replicates the removal to the other clients).
	if multiplayer.is_server():
		for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
			if str(p.name).to_int() == id:
				p.queue_free()
		# A disconnect could have been the last unresolved player — re-check win/lose.
		if GameState.all_players_dead():
			broadcast_match_lost()
		elif GameState.all_players_resolved():
			broadcast_match_won()


func _on_connected_to_server() -> void:
	_relax_peer_timeout(1)
	_register_self.rpc_id(1, local_player_name)


## Widen the ENet inactivity window for one link (both ends call this on connect).
## The arena build stalls the main thread for seconds at a time (5k+ breakable chunks,
## merged-mesh bakes, navmesh) — at ENet's ~5–30s defaults the OTHER side times the
## frozen peer out mid-load, the server begins the match without it, and the dropped
## client zombies in an empty world. 20s min / 90s max survives the heaviest load.
func _relax_peer_timeout(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var link: ENetPacketPeer = enet.get_peer(peer_id)
	if link != null:
		link.set_timeout(64, 20000, 90000)


func _on_connection_failed() -> void:
	push_warning("Connection failed")
	multiplayer.multiplayer_peer = null
	GameState.set_phase(GameState.Phase.MENU)


func _on_server_disconnected() -> void:
	push_warning("Server disconnected")
	multiplayer.multiplayer_peer = null
	GameState.peers.clear()
	GameState.set_phase(GameState.Phase.MENU)
