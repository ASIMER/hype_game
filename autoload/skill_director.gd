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
## `dmg_power` folds in the caster's limb-passive damage × combo × evolution (the owner computes
## it — it knows its own passives). `big` = empowered (combo) OR evolved (max level) → +radius/FX.
func request_cast(
	skill_id: String,
	lvl: int,
	pos: Vector3,
	aim: Vector3,
	facing: Vector3,
	dmg_power: float = 1.0,
	big: bool = false
) -> void:
	var ability: String = String(Settings.skill_def(skill_id)["ability"])
	_apply_owner_effect(ability, lvl, pos, aim, facing, big)
	if GameState.is_local_authority_server():
		_server_cast(_local_peer(), skill_id, lvl, pos, aim, facing, dmg_power, big)
	else:
		_request_cast_rpc.rpc_id(1, skill_id, lvl, pos, aim, facing, dmg_power, big)


@rpc("any_peer", "call_remote", "reliable")
func _request_cast_rpc(
	skill_id: String,
	lvl: int,
	pos: Vector3,
	aim: Vector3,
	facing: Vector3,
	dmg_power: float,
	big: bool
) -> void:
	if not multiplayer.is_server():
		return
	var peer: int = multiplayer.get_remote_sender_id()
	_server_cast(peer, skill_id, lvl, pos, aim, facing, dmg_power, big)


func _server_cast(
	peer: int,
	skill_id: String,
	lvl: int,
	pos: Vector3,
	aim: Vector3,
	facing: Vector3,
	dmg_power: float,
	big: bool
) -> void:
	if not GameState.is_local_authority_server():
		return
	var ability: String = String(Settings.skill_def(skill_id)["ability"])
	_apply_server_effect(ability, lvl, _player_by_peer(peer), pos, aim, facing, dmg_power, big)
	_cast_vfx.rpc(skill_id, pos, aim, facing, big)


# ------------------------------------------------------------ owner-local effects (caster machine)
func _apply_owner_effect(
	ability: String, lvl: int, _pos: Vector3, aim: Vector3, facing: Vector3, big: bool = false
) -> void:
	var me: Node = _local_player()
	if not (me is CharacterBody3D):
		return
	var body := me as CharacterBody3D
	match ability:
		"dash":  # leap — reuse the dodge-roll dash (survives the move loop) + a jump arc
			if me.has_method("_begin_roll"):
				me.call("_begin_roll", facing)
				body.velocity.y = Settings.SKILL_DASH_IMPULSE * (0.75 if big else 0.5)
		"recon_dash":
			if me.has_method("_begin_roll"):
				me.call("_begin_roll", facing)
		"breach":
			if me.has_method("_begin_roll"):
				me.call("_begin_roll", facing)
		"leap_slam":
			# Ballistic leap TO the aim point (Malphite/Fist-of-Havoc): solve the launch
			# velocity that lands on `aim` after SKILL_LEAP_TIME under gravity 20.
			var t: float = Settings.SKILL_LEAP_TIME
			var dp: Vector3 = aim - body.global_position
			var v: Vector3 = dp / t
			v.y = dp.y / t + 0.5 * 20.0 * t
			body.velocity = v
		"blink":
			var rng: float = Settings.SKILL_BLINK_RANGE + float(lvl - 1) + (4.0 if big else 0.0)
			_blink(body, body.global_position + facing * rng)
		"shield":
			# VISIBLE energy dome: absorption via the existing _overshield pool — the
			# damage filter eats hits and emits shield_absorbed (frozen-bullet FX).
			var pool: float = Settings.SKILL_SHIELD_AMOUNT + 15.0 * float(lvl - 1)
			if big:
				pool *= 1.5
			body._overshield = maxf(float(body._overshield), pool)
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


# ------------------------------------------------------------ cloak (server truth)
# peer -> ms deadline while that player is CLOAKED (machines drop it as a target).
# Server-side only — the AI runs on the server, so no replication is needed; the
# body shimmer field is broadcast via the regular cast VFX.
var _cloak_until: Dictionary = {}


## Read by robot_enemy targeting: true while `player` is cloaked (server clock).
func is_player_cloaked(player: Node) -> bool:
	if player == null:
		return false
	var peer: int = str(player.name).to_int()
	return Time.get_ticks_msec() < int(_cloak_until.get(peer, 0))


func _server_set_cloak(peer: int, secs: float) -> void:
	_cloak_until[peer] = Time.get_ticks_msec() + int(secs * 1000.0)


## Firing BREAKS the cloak. Host shots arrive via Events.weapon_fired locally; a
## CLIENT tells the server through the break rpc (wired in _ready).
func _on_weapon_fired(shooter: Node, _wid: String) -> void:
	if shooter == null or not shooter.is_in_group(Groups.PLAYERS):
		return
	if not shooter.has_method("is_multiplayer_authority") or not shooter.is_multiplayer_authority():
		return
	if GameState.is_local_authority_server():
		_cloak_until.erase(_local_peer())
	else:
		_break_cloak_rpc.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _break_cloak_rpc() -> void:
	if multiplayer.is_server():
		_cloak_until.erase(multiplayer.get_remote_sender_id())


func _ready() -> void:
	Events.weapon_fired.connect(_on_weapon_fired)
	Events.match_started.connect(func() -> void: _cloak_until.clear())


# ------------------------------------------------------------ server effects (enemies)
func _apply_server_effect(
	ability: String,
	lvl: int,
	caster: Node,
	_pos: Vector3,
	aim: Vector3,
	_facing: Vector3,
	dmg_power: float = 1.0,
	big: bool = false
) -> void:
	var me: Node3D = caster as Node3D
	if me == null:
		return
	var center: Vector3 = me.global_position
	var rmul: float = 1.25 if big else 1.0  # evolved/combo casts hit a wider area
	match ability:
		"leap_slam":
			# The AoE lands WITH the caster at the aim point (airtime-delayed).
			var rad: float = (Settings.SKILL_SLAM_RADIUS + 0.4 * float(lvl - 1)) * rmul
			var dmg: float = (Settings.SKILL_SLAM_DAMAGE + 12.0 * float(lvl - 1)) * dmg_power
			var stun: float = Settings.SKILL_SLAM_STAGGER + 0.15 * float(lvl - 1)
			var t := get_tree().create_timer(Settings.SKILL_LEAP_TIME)
			t.timeout.connect(_radial.bind(aim, rad, dmg, stun, caster))
		"meteor":
			# Telegraph → impact after SKILL_METEOR_DELAY: radial damage + BURN + the
			# walls in the blast CRUMBLE (BreakableChunk) — the destruction IS the show.
			var mr: float = (Settings.SKILL_METEOR_RADIUS + 0.3 * float(lvl - 1)) * rmul
			var md: float = (Settings.SKILL_METEOR_DAMAGE + 15.0 * float(lvl - 1)) * dmg_power
			var mt := get_tree().create_timer(Settings.SKILL_METEOR_DELAY)
			mt.timeout.connect(_meteor_impact.bind(aim, mr, md, caster))
		"storm":
			_storm(center, lvl, dmg_power, rmul, caster)
		"breach":
			# The charge SMASHES THROUGH breakable walls along its path (The Finals
			# charge-n-slam) + damages machines in the lane.
			var rr: float = Settings.SKILL_RAM_RANGE
			var rd: float = (Settings.SKILL_RAM_DAMAGE + 12.0 * float(lvl - 1)) * dmg_power
			var dir: Vector3 = (aim - center).normalized()
			var steps: int = int(rr / 1.2) + 1
			for i in steps:
				BreakableChunk.break_in_radius(
					center + dir * (1.2 * float(i)) + Vector3.UP * 1.2,
					Settings.SKILL_BREACH_BREAK_R
				)
			var rc: Vector3 = center + dir * (rr * 0.5)
			_radial(rc, rr * 0.5 * rmul, rd, 1.0, caster)
		"bite_cone":
			_cone(me, lvl, caster, dmg_power, rmul)
		"chain":
			_chain(center, lvl, big)
		"cloak":
			var secs: float = Settings.SKILL_CLOAK_TIME + 0.5 * float(lvl - 1)
			_server_set_cloak(str(me.name).to_int(), secs * 1.4 if big else secs)
		_:
			pass


## METEOR impact (server, delayed): radial damage + stagger, BURN chemistry on the
## victims, and the walls inside the demolition radius crumble.
func _meteor_impact(aim: Vector3, radius: float, damage: float, caster: Node) -> void:
	_radial(aim, radius, damage, 1.0, caster, "burn", Settings.SKILL_METEOR_BURN)
	BreakableChunk.break_in_radius(aim + Vector3.UP * 1.0, Settings.SKILL_METEOR_BREAK_R)
	BreakableChunk.break_in_radius(aim + Vector3.UP * 2.4, Settings.SKILL_METEOR_BREAK_R * 0.8)


## STORM (Crystal-Maiden field): SKILL_STORM_PULSES explosions rain in a ring around
## the CAST POINT over SKILL_STORM_TIME — each pulse damages + SLOWS machines near it.
func _storm(center: Vector3, lvl: int, dmg_power: float, rmul: float, caster: Node) -> void:
	var pulses: int = Settings.SKILL_STORM_PULSES + (lvl - 1)
	var gap: float = Settings.SKILL_STORM_TIME / float(maxi(1, pulses))
	for i in pulses:
		var t := get_tree().create_timer(gap * float(i) + 0.25)
		t.timeout.connect(_storm_pulse.bind(center, lvl, dmg_power, rmul, caster))


func _storm_pulse(center: Vector3, lvl: int, dmg_power: float, rmul: float, caster: Node) -> void:
	var ang: float = randf() * TAU
	var r: float = randf_range(Settings.SKILL_STORM_RING_MIN, Settings.SKILL_STORM_RING_MAX)
	var at: Vector3 = center + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	var dmg: float = (Settings.SKILL_STORM_PULSE_DMG + 5.0 * float(lvl - 1)) * dmg_power
	_radial(
		at,
		Settings.SKILL_STORM_PULSE_RADIUS * rmul,
		dmg,
		0.4,
		caster,
		"slow",
		Settings.SKILL_STORM_SLOW
	)


## Radial damage + stagger to enemies (the grenade/old-burst pattern). Optional
## `chem` applies a machine-chemistry status to every victim (meteor→burn,
## storm→slow) so the MOBA casts feed the status/reaction system.
func _radial(
	center: Vector3,
	radius: float,
	damage: float,
	stagger: float,
	caster: Node,
	chem: String = "",
	chem_dur: float = 0.0
) -> void:
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
		if chem != "" and e.has_method("apply_chemistry"):
			e.apply_chemistry(chem, chem_dur, 0.5 if chem == "slow" else 1.0)
	NetworkManager.report_noise(center, radius, 2)


## Forward cone (bite): enemies within range AND the half-angle of the caster's facing.
func _cone(me: Node3D, lvl: int, caster: Node, dmg_power: float = 1.0, rmul: float = 1.0) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var rng: float = (Settings.SKILL_BITE_RANGE + 0.3 * float(lvl - 1)) * rmul
	var dmg: float = (Settings.SKILL_BITE_DAMAGE + 14.0 * float(lvl - 1)) * dmg_power
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
func _chain(center: Vector3, lvl: int, big: bool = false) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var jumps: int = Settings.SKILL_CHAIN_JUMPS + (lvl - 1) + (2 if big else 0)
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
## Distinct per-ability cast effect (built by SkillVFX), broadcast to every peer (call_local).
## Render-only — headless-skipped + FX-distance-gated, so it never touches gameplay/golden.
@rpc("authority", "call_local", "unreliable")
func _cast_vfx(skill_id: String, pos: Vector3, aim: Vector3, facing: Vector3, big: bool) -> void:
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
	SkillVFX.play(ability, color, pos, aim, facing, arena)
	_play_cast_audio(ability)
	if big:
		# Evolved / combo-empowered cast — a bright shock-ring emphasis + a stronger shake.
		var at: Vector3 = aim if ability == "mortar" else pos
		SkillVFX.emphasis(at, arena)
		Events.screen_shake.emit(SkillVFX.shake_for(ability) * 1.5)
	else:
		Events.screen_shake.emit(SkillVFX.shake_for(ability))


## Per-ability cast audio, with the payoff layer scheduled where the impact is
## delayed (meteor boom at touchdown, slam thud at landing). Runs on every peer
## already inside the _fx_near distance gate.
func _play_cast_audio(ability: String) -> void:
	match ability:
		"meteor":
			AudioManager.play_skill("skill_meteor")
			get_tree().create_timer(Settings.SKILL_METEOR_DELAY).timeout.connect(
				func() -> void: AudioManager.play_skill("explosion")
			)
		"leap_slam":
			AudioManager.play_skill("skill_leap")
			get_tree().create_timer(Settings.SKILL_LEAP_TIME).timeout.connect(
				func() -> void: AudioManager.play_skill("skill_slam")
			)
		"storm":
			AudioManager.play_skill("skill_storm")
		"breach":
			AudioManager.play_skill("skill_breach")
		"chain":
			AudioManager.play_skill("skill_zap")
		_:
			AudioManager.play_skill("skill_cast")


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
