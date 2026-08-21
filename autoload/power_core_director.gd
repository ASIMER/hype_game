extends Node
## Power-Core Beacon director (autoload name: PowerCoreDirector) — Phase 4 synergy layer.
##
## A boss/miniboss death drops a glowing CORE the squad must physically CARRY to extract for
## a big reward — but carrying PINGS every machine to the carrier's position (a growing
## beacon) and occupies the hands (no ADS, slower; firing still allowed). Power = exposure.
##
## Server-authoritative (mirrors AIDirector/NemesisDirector). It owns the state (active /
## world position / carrier peer) and SYNCS it on change via an RPC; every peer builds ONE
## local PowerCore visual and the director positions it each frame (on the ground, or above
## the carrier). Pickup is a server-side distance check (no networked Area3D). No new RPC
## plumbing in player.gd — player._carrying_core() just reads is_carried_by().
##
## Registered in project.godot as "PowerCoreDirector". (No class_name — singleton collision.)
## PARSE TRAP: never `var x := <Variant>`; locals explicitly typed.

var _active: bool = false
var _pos: Vector3 = Vector3.ZERO
var _carrier_peer: int = 0  # 0 = on the ground
var _age: float = 0.0  # seconds since pickup (ramps the beacon)
var _noise_cd: float = 0.0
var _node: PowerCore = null  # the local visual (per peer)


func _ready() -> void:
	Events.match_started.connect(_on_match_started)
	Events.entity_died.connect(_on_entity_died)
	Events.player_downed.connect(_on_carrier_lost.unbind(1))
	Events.player_bleedout.connect(_on_carrier_lost)
	Events.extraction_completed.connect(_on_extraction_completed)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _process(delta: float) -> void:
	_update_visual()
	if not GameState.is_local_authority_server() or not _active:
		return
	if _carrier_peer == 0:
		_check_pickup()
	else:
		var carrier: Node3D = _player_by_peer(_carrier_peer)
		if carrier == null:
			return
		_pos = carrier.global_position  # so a drop lands where the carrier is
		_age += delta
		_noise_cd -= delta
		if _noise_cd <= 0.0:
			_noise_cd = Settings.POWER_CORE_NOISE_CD
			var t: float = clampf(_age / Settings.POWER_CORE_RAMP, 0.0, 1.0)
			var radius: float = lerpf(
				Settings.POWER_CORE_NOISE_MIN, Settings.POWER_CORE_NOISE_MAX, t
			)
			NetworkManager.report_noise(_pos, radius, 2)  # kind 2 = grenade-loud → AIDirector reacts


# ----------------------------------------------------------------- visual (all peers)
func _update_visual() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not _active:
		if _node != null and is_instance_valid(_node):
			_node.queue_free()
		_node = null
		return
	if _node == null or not is_instance_valid(_node):
		var arena: Node = get_tree().get_first_node_in_group(Groups.ARENA)
		if arena == null:
			return
		_node = PowerCore.make()
		arena.add_child(_node)
	if _carrier_peer != 0:
		var carrier: Node3D = _player_by_peer(_carrier_peer)
		if carrier != null:
			_node.global_position = carrier.global_position + Vector3(0.0, 1.4, 0.0)
			return
	_node.global_position = _pos


# ----------------------------------------------------------------- server logic
func _check_pickup() -> void:
	for pl in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if not (pl is Node3D) or bool(pl.get("downed")):
			continue
		if (pl as Node3D).global_position.distance_to(_pos) <= Settings.POWER_CORE_PICKUP_RADIUS:
			_carrier_peer = str(pl.name).to_int()
			_age = 0.0
			_noise_cd = 0.0
			_sync()
			Events.power_core_picked.emit(_carrier_peer)
			return


func _on_entity_died(entity: Node, _killer: Node) -> void:
	if not GameState.is_local_authority_server() or _active or entity == null:
		return
	if not _is_boss_class(entity):
		return
	_active = true
	_carrier_peer = 0
	_age = 0.0
	_pos = (entity as Node3D).global_position if entity is Node3D else Vector3.ZERO
	_sync()
	Events.power_core_spawned.emit(null)


func _on_carrier_lost(player: Node) -> void:
	if not GameState.is_local_authority_server() or not _active or player == null:
		return
	if str(player.name).to_int() == _carrier_peer:
		_carrier_peer = 0  # dropped at the body (the carrier's last synced _pos)
		_sync()


func _on_peer_disconnected(peer: int) -> void:
	if GameState.is_local_authority_server() and _active and peer == _carrier_peer:
		_carrier_peer = 0
		_sync()


func _on_extraction_completed(player: Node) -> void:
	if not GameState.is_local_authority_server() or not _active or player == null:
		return
	if str(player.name).to_int() != _carrier_peer:
		return
	NetworkManager.grant_power_core(_carrier_peer)
	Events.power_core_extracted.emit(_carrier_peer)
	_active = false
	_carrier_peer = 0
	_sync()


func _on_match_started() -> void:
	_active = false
	_carrier_peer = 0
	_age = 0.0
	if _node != null and is_instance_valid(_node):
		_node.queue_free()
	_node = null


# ----------------------------------------------------------------- helpers / sync
## Is this dead enemy a boss-class drop source? The wave-5 boss or a biome miniboss.
func _is_boss_class(entity: Node) -> bool:
	var eid: String = String(entity.get("enemy_id")) if "enemy_id" in entity else ""
	if eid == "robot_boss":
		return true
	var sp: String = entity.scene_file_path
	return sp != "" and sp in Settings.MINIBOSS_BY_BIOME.values()


func _player_by_peer(peer: int) -> Node3D:
	for pl in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if pl is Node3D and str(pl.name).to_int() == peer:
			return pl as Node3D
	return null


## True on ANY peer if `peer` currently carries the core (player.gd reads this for ADS/speed).
func is_carried_by(peer: int) -> bool:
	return _active and _carrier_peer == peer and peer != 0


func _sync() -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rpc_core_state.rpc(_active, _pos, _carrier_peer)


@rpc("authority", "call_remote", "reliable")
func _rpc_core_state(active: bool, pos: Vector3, carrier: int) -> void:
	var was_picked: bool = _carrier_peer == 0 and carrier != 0
	var was_spawned: bool = not _active and active
	_active = active
	_pos = pos
	_carrier_peer = carrier
	if was_spawned:
		Events.power_core_spawned.emit(null)
	if was_picked:
		Events.power_core_picked.emit(carrier)


# ----------------------------------------------------------------- QA
func debug_state() -> Dictionary:
	return {
		"active": _active,
		"carrier": _carrier_peer,
		"pos": [_pos.x, _pos.y, _pos.z],
		"age": _age,
	}


## QA: drop a core at a world position (or near the local player) without a boss kill.
func debug_spawn(pos: Vector3) -> Dictionary:
	if GameState.is_local_authority_server():
		_active = true
		_carrier_peer = 0
		_age = 0.0
		_pos = pos
		_sync()
		Events.power_core_spawned.emit(null)
	return debug_state()
