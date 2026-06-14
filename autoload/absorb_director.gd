extends Node
## Absorption director (autoload name: AbsorbDirector) — the signature "consume a part" loop.
##
## On a kill, the KILLER absorbs the dead enemy's signature part: a homing streak flies from the
## corpse onto a growing trophy CLUSTER on the killer's back (each enemy archetype → a different
## part, capped per type). Parts also fill a CHARGE meter → a burst AoE shockwave.
##
## Server-authoritative ROUTING (mirrors NetworkManager.grant_nemesis_bounty + the grenade
## request): the accumulation runs on the KILLER's own machine (the owner mutates its replicated
## `absorbed` dict, which fans out to every peer that rebuilds the identical cluster — the
## cosmetics precedent), the homing FX is broadcast to all peers, and the burst AoE applies
## server-side (the grenade pattern). No class_name (autoload singleton). PARSE TRAP: locals typed.

const _STREAK := preload("res://scripts/fx/absorb_streak.gd")


# ------------------------------------------------------------ kill → absorb (server entry)
## Called SERVER-ONLY from NetworkManager._on_entity_died for an attributed enemy kill.
func grant_absorb(peer: int, enemy_id: String, corpse_pos: Vector3) -> void:
	if not GameState.is_local_authority_server() or peer <= 0 or enemy_id == "":
		return
	# Homing part FX that everyone sees (call_local → the host plays it too).
	_absorb_fx.rpc(enemy_id, corpse_pos, peer)
	# Accumulate on the KILLER's own machine so the owner mutates its own replicated dict
	# (a server-side mutation would be overwritten by the owner's next sync — keys/flares lesson).
	if peer == _local_peer():
		_do_absorb(enemy_id)
	else:
		_grant_absorb_rpc.rpc_id(peer, enemy_id)


@rpc("authority", "call_remote", "reliable")
func _grant_absorb_rpc(enemy_id: String) -> void:
	_do_absorb(enemy_id)


## Runs on the killer's machine: hand the part to its local player's Absorb component.
func _do_absorb(enemy_id: String) -> void:
	var pl: Node = _local_player()
	if pl == null:
		return
	var ab: Node = pl.get_node_or_null("Absorb")
	if ab != null and ab.has_method("gain"):
		ab.gain(enemy_id)


# ------------------------------------------------------------ homing FX (every peer)
@rpc("authority", "call_local", "unreliable")
func _absorb_fx(enemy_id: String, corpse_pos: Vector3, target_peer: int) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var target: Node3D = _player_by_peer(target_peer)
	if target == null or not _fx_near(corpse_pos):
		return
	var arena: Node = get_tree().get_first_node_in_group(Groups.ARENA)
	if arena == null:
		return
	var def: Dictionary = Settings.ABSORB_PARTS.get(enemy_id, Settings.ABSORB_FALLBACK)
	var streak: Node3D = _STREAK.new()
	arena.add_child(streak)
	streak.setup(corpse_pos, target, def["color"], String(def["part"]))


# ------------------------------------------------------------ burst ability
## Called by the OWNER (PlayerAbsorb) when it fires the burst — it has already gated on a full
## charge and reset its own meter locally (trusted like the grenade/consumable economy).
func request_burst(pos: Vector3) -> void:
	if GameState.is_local_authority_server():
		_do_burst(_local_peer(), pos)
	else:
		_request_burst_rpc.rpc_id(1, pos)


@rpc("any_peer", "call_remote", "reliable")
func _request_burst_rpc(pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_do_burst(multiplayer.get_remote_sender_id(), pos)


func _do_burst(peer: int, pos: Vector3) -> void:
	if not GameState.is_local_authority_server():
		return
	_apply_burst(pos, _player_by_peer(peer))
	_burst_vfx.rpc(pos)


## Server-side radial damage + stagger on enemies (mirrors Grenade._apply_radial_damage).
func _apply_burst(center: Vector3, caster: Node) -> void:
	var tree := get_tree()
	if tree == null:
		return
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if e == null or not (e is Node3D):
			continue
		var dist: float = (e as Node3D).global_position.distance_to(center)
		if dist > Settings.ABSORB_ULT_RADIUS:
			continue
		var health: Node = e.get_node_or_null(Groups.NODE_HEALTH)
		if health == null or not health.has_method("take_damage"):
			continue
		var falloff: float = lerpf(1.0, 0.4, clampf(dist / Settings.ABSORB_ULT_RADIUS, 0.0, 1.0))
		var dmg: float = Settings.ABSORB_ULT_DAMAGE * falloff
		if e.has_method("filter_blast"):  # nemesis blast resist (duck-typed)
			dmg = e.filter_blast(dmg)
		health.take_damage(dmg, caster)
		if e.has_method("apply_stun"):
			e.apply_stun(Settings.ABSORB_ULT_STAGGER)
	NetworkManager.report_noise(center, Settings.ABSORB_ULT_RADIUS, 2)


@rpc("authority", "call_local", "unreliable")
func _burst_vfx(pos: Vector3) -> void:
	Events.absorb_burst_cast.emit(pos)
	if DisplayServer.get_name() == "headless":
		return
	Events.screen_shake.emit(0.4)
	var arena: Node = get_tree().get_first_node_in_group(Groups.ARENA)
	if arena != null:
		_spawn_burst_ring(arena, pos)


func _spawn_burst_ring(arena: Node, pos: Vector3) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.5
	tm.outer_radius = 0.66
	ring.mesh = tm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.95, 1.0, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(0.45, 0.95, 1.0)
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	arena.add_child(ring)
	ring.global_position = pos + Vector3(0.0, 0.25, 0.0)
	ring.rotation_degrees = Vector3(90.0, 0.0, 0.0)  # lay the ring flat on the ground
	ring.scale = Vector3.ONE * 0.2
	var light := OmniLight3D.new()
	light.light_color = Color(0.5, 0.95, 1.0)
	light.light_energy = 8.0
	light.omni_range = Settings.ABSORB_ULT_RADIUS
	ring.add_child(light)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * Settings.ABSORB_ULT_RADIUS * 1.4, 0.35)
	tw.tween_property(mat, "albedo_color", Color(0.45, 0.95, 1.0, 0.0), 0.35)
	tw.tween_property(light, "light_energy", 0.0, 0.3)
	tw.set_parallel(false)
	tw.tween_callback(ring.queue_free)


# ------------------------------------------------------------ helpers
func _local_peer() -> int:
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return 1


func _local_player() -> Node:
	for pl in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if pl.has_method("is_multiplayer_authority") and pl.is_multiplayer_authority():
			return pl
	return null


func _player_by_peer(peer: int) -> Node3D:
	for pl in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if pl is Node3D and str(pl.name).to_int() == peer:
			return pl as Node3D
	return null


## True if the homing FX is worth spawning on THIS machine (local player within FX range).
func _fx_near(pos: Vector3) -> bool:
	var me: Node = _local_player()
	if not (me is Node3D):
		return true
	return (me as Node3D).global_position.distance_to(pos) <= Settings.ABSORB_FX_DIST


# ------------------------------------------------------------ QA
func debug_state() -> Dictionary:
	var pl: Node = _local_player()
	var ab: Node = pl.get_node_or_null("Absorb") if pl != null else null
	return {
		"absorbed": pl.get("absorbed") if pl != null and "absorbed" in pl else {},
		"charge": ab.charge() if ab != null and ab.has_method("charge") else 0.0,
	}
