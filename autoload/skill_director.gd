extends Node
## Skill director (autoload name: SkillDirector) — the Mutant-Harvest skill backend.
##
## Server-authoritative ROUTING (mirrors the old AbsorbDirector + the grenade request):
##  • grant_skill(peer, skill_id): a body-part pickup grants the skill on the KILLER/PICKER's own
##    machine (host-direct vs rpc_id) so the owner mutates its OWN replicated `skills` dict.
##  • request_cast(...): the owner applies its own movement/buff immediately, then routes the
##    enemy-side effect (damage/status) to the server; the server broadcasts the VFX (call_local).
##
## Owner effects (dash/blink/shield/ram-lunge) run on the caster; server effects (radial damage,
## cone, chain) on the server (enemies are server-auth). Cooldowns are authority-local in
## PlayerSkills. No class_name (autoload singleton). PARSE TRAP: type every local.


# ------------------------------------------------------------ pickup → skill (server entry)
## Called SERVER-ONLY when a player picks up a body-part. Routes the grant to that peer's machine.
func grant_skill(peer: int, skill_id: String) -> void:
	if not GameState.is_local_authority_server() or peer <= 0 or skill_id == "":
		return
	if peer == _local_peer():
		_do_grant(skill_id)
	else:
		_grant_skill_rpc.rpc_id(peer, skill_id)


@rpc("authority", "call_remote", "reliable")
func _grant_skill_rpc(skill_id: String) -> void:
	_do_grant(skill_id)


func _do_grant(skill_id: String) -> void:
	var pl: Node = _local_player()
	if pl == null:
		return
	var sk: Node = pl.get_node_or_null("Skills")
	if sk != null and sk.has_method("acquire"):
		sk.acquire(skill_id)


# ------------------------------------------------------------ cast (owner → server)
## Called by the OWNER (PlayerSkills.cast). Owner movement/buff applies immediately; the enemy
## effect routes to the server; the VFX is broadcast by the server.
func request_cast(skill_id: String, lvl: int, pos: Vector3, aim: Vector3, facing: Vector3) -> void:
	var ability: String = String(Settings.skill_def(skill_id)["ability"])
	_apply_owner_effect(ability, lvl, pos, aim, facing)
	if GameState.is_local_authority_server():
		_server_cast(_local_peer(), skill_id, lvl, pos, aim, facing)
	else:
		_request_cast_rpc.rpc_id(1, skill_id, lvl, pos, aim, facing)


@rpc("any_peer", "call_remote", "reliable")
func _request_cast_rpc(
	skill_id: String, lvl: int, pos: Vector3, aim: Vector3, facing: Vector3
) -> void:
	if not multiplayer.is_server():
		return
	_server_cast(multiplayer.get_remote_sender_id(), skill_id, lvl, pos, aim, facing)


func _server_cast(
	peer: int, skill_id: String, lvl: int, pos: Vector3, aim: Vector3, facing: Vector3
) -> void:
	if not GameState.is_local_authority_server():
		return
	var ability: String = String(Settings.skill_def(skill_id)["ability"])
	_apply_server_effect(ability, lvl, _player_by_peer(peer), pos, aim, facing)
	_cast_vfx.rpc(skill_id, pos, aim)


# ------------------------------------------------------------ owner-local effects (caster machine)
func _apply_owner_effect(
	ability: String, lvl: int, _pos: Vector3, aim: Vector3, facing: Vector3
) -> void:
	var me: Node = _local_player()
	if not (me is CharacterBody3D):
		return
	var body := me as CharacterBody3D
	match ability:
		"dash":  # leap — reuse the dodge-roll dash (survives the move loop) + a jump arc
			if me.has_method("_begin_roll"):
				me.call("_begin_roll", facing)
				body.velocity.y = Settings.SKILL_DASH_IMPULSE * 0.5
		"recon_dash":
			if me.has_method("_begin_roll"):
				me.call("_begin_roll", facing)
		"ram_charge":
			if me.has_method("_begin_roll"):
				me.call("_begin_roll", facing)
		"blink":
			var rng: float = Settings.SKILL_BLINK_RANGE + float(lvl - 1)
			_blink(body, body.global_position + facing * rng)
		"shield":
			_grant_shield(body, Settings.SKILL_SHIELD_TIME + 0.5 * float(lvl - 1))
		_:
			pass
	# Mortar/bite/whirlwind/slam/chain have no owner-local effect (server-only); aim used there.
	if aim == Vector3.INF:
		pass


## Teleport `body` to a navmesh-snapped point (forward blink), with the iteration-id guard.
func _blink(body: CharacterBody3D, target: Vector3) -> void:
	var dest: Vector3 = target
	var map: RID = body.get_world_3d().get_navigation_map()
	if NavigationServer3D.map_get_iteration_id(map) != 0:
		dest = NavigationServer3D.map_get_closest_point(map, target)
	body.global_position = dest
	body.velocity = Vector3.ZERO


## Brief protection (Phase-1 placeholder via Health.invulnerable; Phase 5 → overshield).
func _grant_shield(body: Node, secs: float) -> void:
	var hp: Node = body.get_node_or_null(Groups.NODE_HEALTH)
	if hp == null or not ("invulnerable" in hp):
		return
	hp.invulnerable = true
	get_tree().create_timer(secs).timeout.connect(
		func() -> void:
			if is_instance_valid(hp):
				hp.invulnerable = false
	)


# ------------------------------------------------------------ server effects (enemies)
func _apply_server_effect(
	ability: String, lvl: int, caster: Node, _pos: Vector3, aim: Vector3, _facing: Vector3
) -> void:
	var me: Node3D = caster as Node3D
	if me == null:
		return
	var center: Vector3 = me.global_position
	match ability:
		"aoe_stagger":
			var rad: float = Settings.SKILL_SLAM_RADIUS + 0.4 * float(lvl - 1)
			var dmg: float = Settings.SKILL_SLAM_DAMAGE + 12.0 * float(lvl - 1)
			var stun: float = Settings.SKILL_SLAM_STAGGER + 0.15 * float(lvl - 1)
			_radial(center, rad, dmg, stun, caster)
		"mortar":
			var mr: float = Settings.SKILL_MORTAR_RADIUS + 0.3 * float(lvl - 1)
			var md: float = Settings.SKILL_MORTAR_DAMAGE + 15.0 * float(lvl - 1)
			_radial(aim, mr, md, 0.8, caster)
		"whirlwind":
			var wr: float = Settings.SKILL_WHIRL_RADIUS + 0.3 * float(lvl - 1)
			var wd: float = Settings.SKILL_WHIRL_DAMAGE + 8.0 * float(lvl - 1)
			_radial(center, wr, wd, 0.6, caster)
		"ram_charge":
			var rr: float = Settings.SKILL_RAM_RANGE
			var rd: float = Settings.SKILL_RAM_DAMAGE + 12.0 * float(lvl - 1)
			_radial(center + (aim - center).normalized() * (rr * 0.5), rr * 0.5, rd, 1.0, caster)
		"bite_cone":
			_cone(me, lvl, caster)
		"chain":
			_chain(center, lvl)
		_:
			pass


## Radial damage + stagger to enemies (the grenade/old-burst pattern).
func _radial(center: Vector3, radius: float, damage: float, stagger: float, caster: Node) -> void:
	var tree := get_tree()
	if tree == null:
		return
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if e == null or not (e is Node3D):
			continue
		var dist: float = (e as Node3D).global_position.distance_to(center)
		if dist > radius:
			continue
		var health: Node = e.get_node_or_null(Groups.NODE_HEALTH)
		if health == null or not health.has_method("take_damage"):
			continue
		var falloff: float = lerpf(1.0, 0.4, clampf(dist / radius, 0.0, 1.0))
		var dmg: float = damage * falloff
		if e.has_method("filter_blast"):
			dmg = e.filter_blast(dmg)
		health.take_damage(dmg, caster)
		if stagger > 0.0 and e.has_method("apply_stun"):
			e.apply_stun(stagger)
	NetworkManager.report_noise(center, radius, 2)


## Forward cone (bite): enemies within range AND the half-angle of the caster's facing.
func _cone(me: Node3D, lvl: int, caster: Node) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var rng: float = Settings.SKILL_BITE_RANGE + 0.3 * float(lvl - 1)
	var dmg: float = Settings.SKILL_BITE_DAMAGE + 14.0 * float(lvl - 1)
	var half: float = deg_to_rad(Settings.SKILL_BITE_ANGLE + 5.0 * float(lvl - 1))
	var fwd: Vector3 = -me.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if e == null or not (e is Node3D):
			continue
		var to: Vector3 = (e as Node3D).global_position - me.global_position
		to.y = 0.0
		if to.length() > rng or to.length() < 0.01:
			continue
		if fwd.angle_to(to.normalized()) > half:
			continue
		var health: Node = e.get_node_or_null(Groups.NODE_HEALTH)
		if health != null and health.has_method("take_damage"):
			health.take_damage(dmg, caster)
			if e.has_method("apply_stun"):
				e.apply_stun(1.0)
	NetworkManager.report_noise(me.global_position, rng, 2)


## Chain shock: shock the nearest enemy + arc to nearby ones (reuse MachineChemistry).
func _chain(center: Vector3, lvl: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var jumps: int = Settings.SKILL_CHAIN_JUMPS + (lvl - 1)
	var nearest: Node = null
	var best: float = 12.0
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if e == null or not (e is Node3D):
			continue
		var d: float = (e as Node3D).global_position.distance_to(center)
		if d < best:
			best = d
			nearest = e
	if nearest == null:
		return
	if nearest.has_method("apply_chemistry"):
		nearest.apply_chemistry("shock", 1.0 + 0.3 * float(lvl - 1), 1.0)
	MachineChemistry.discharge(nearest, jumps, [nearest], 1.0)


# ------------------------------------------------------------ VFX (every peer)
@rpc("authority", "call_local", "unreliable")
func _cast_vfx(skill_id: String, pos: Vector3, aim: Vector3) -> void:
	Events.skill_cast.emit(skill_id, 0)
	if DisplayServer.get_name() == "headless":
		return
	if not _fx_near(pos):
		return
	var arena: Node = get_tree().get_first_node_in_group(Groups.ARENA)
	if arena == null:
		return
	var def: Dictionary = Settings.skill_def(skill_id)
	var color: Color = def["color"]
	var ability: String = String(def["ability"])
	# Ground-targeted abilities ring at the aim point; the rest at the caster.
	var at: Vector3 = aim if ability == "mortar" else pos
	_spawn_ring(arena, at, color)
	Events.screen_shake.emit(0.25)


func _spawn_ring(arena: Node, pos: Vector3, color: Color) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.5
	tm.outer_radius = 0.66
	ring.mesh = tm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.85)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	arena.add_child(ring)
	ring.global_position = pos + Vector3(0.0, 0.25, 0.0)
	ring.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	ring.scale = Vector3.ONE * 0.2
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 6.0
	light.omni_range = 6.0
	ring.add_child(light)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * 6.0, 0.35)
	tw.tween_property(mat, "albedo_color", Color(color.r, color.g, color.b, 0.0), 0.35)
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


## True if a cast VFX is worth spawning on THIS machine (local player within FX range).
func _fx_near(pos: Vector3) -> bool:
	var me: Node = _local_player()
	if not (me is Node3D):
		return true
	return (me as Node3D).global_position.distance_to(pos) <= Settings.SKILL_FX_DIST


# ------------------------------------------------------------ QA
func debug_state() -> Dictionary:
	var pl: Node = _local_player()
	var sk: Node = pl.get_node_or_null("Skills") if pl != null else null
	return {
		"skills": pl.get("skills") if pl != null and "skills" in pl else {},
		"slots": sk.slot_order() if sk != null and sk.has_method("slot_order") else [],
	}
