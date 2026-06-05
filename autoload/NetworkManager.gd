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

# ---------------------------------------------------------------- host / join
func host_game(port: int = Settings.DEFAULT_PORT) -> Error:
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

func join_game(ip: String = Settings.DEFAULT_IP, port: int = Settings.DEFAULT_PORT) -> Error:
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

# --------------------------------------------------------- ready handshake
## Called by each client once the match scene has finished loading on its side.
@rpc("any_peer", "call_local", "reliable")
func notify_loaded() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if GameState.peers.has(sender):
		GameState.peers[sender]["ready"] = true
	if _everyone_ready():
		Events.all_players_ready.emit()
		begin_match.rpc()

func _everyone_ready() -> bool:
	if GameState.peers.is_empty():
		return false
	for id in GameState.peers:
		if not GameState.peers[id].get("ready", false):
			return false
	return true

@rpc("authority", "call_local", "reliable")
func begin_match() -> void:
	if Settings.NET_DEBUG:
		print("[net] begin_match on peer %d" % multiplayer.get_unique_id())
	GameState.set_phase(GameState.Phase.IN_MATCH)
	Events.match_started.emit()

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
