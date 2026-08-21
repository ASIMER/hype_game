extends Node
## Hijack & Pilot (v0.5-B2) — the signature "steal a machine" mechanic. A SHOCK/EMP-stunned
## machine can be cracked (hold X in range) and PILOTED: the pilot's body rides hidden
## inside the hull, the machine's HP is the pilot's shield, fire = a hull slam, and leaving
## (or the timer running out) detonates the hull from inside.
##
## Server-authoritative (mirrors PowerCoreDirector): every rule runs on the host; the
## pilot's client sends ONLY thin inputs (move dir / attack / exit / damage-redirect).
## ZERO robot_enemy edits — the possession is fully EXTERNAL: while piloted the enemy's own
## _physics_process is switched OFF and this director moves the body directly (velocity +
## move_and_slide), so the position replicates to every peer through the existing enemy
## sync. Visuals (hidden pilot model + teal "hacked" ring) ride one FX rpc; a late joiner
## misses only the ring (accepted-lossy, the chemistry-flags precedent).

## peer_id -> {enemy, player, dir, until_ms, next_atk_ms} (server-only state).
var _pilots: Dictionary = {}


func _ready() -> void:
	Events.entity_died.connect(_on_entity_died)
	multiplayer.peer_disconnected.connect(_on_peer_left)


func _physics_process(delta: float) -> void:
	if not GameState.is_local_authority_server() or _pilots.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	for peer in _pilots.keys():
		var d: Dictionary = _pilots[peer]
		var e: Node = d.get("enemy")
		if GameState.phase != GameState.Phase.IN_MATCH or not _machine_alive(e):
			_end(int(peer), false)
			continue
		if now >= int(d["until_ms"]):
			_end(int(peer), true)
			continue
		_drive(e as CharacterBody3D, d["dir"] as Vector3, delta)


## Steer the stolen hull: pilot dir (world-space, flattened) at the machine's own speed,
## plus gravity. Facing mirrors robot_enemy._face_towards' yaw convention.
func _drive(e: CharacterBody3D, dir: Vector3, delta: float) -> void:
	var sp: float = 4.0
	var raw_sp: Variant = e.get("_stat_speed")
	if raw_sp != null and float(raw_sp) > 0.0:
		sp = float(raw_sp)
	sp *= Settings.HIJACK_SPEED_MULT
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() > 1.0:
		flat = flat.normalized()
	e.velocity.x = flat.x * sp
	e.velocity.z = flat.z * sp
	e.velocity.y = -0.5 if e.is_on_floor() else e.velocity.y - 20.0 * delta
	e.move_and_slide()
	if flat.length() > 0.05:
		var desired: float = atan2(flat.x, flat.z)
		e.rotation.y = lerp_angle(e.rotation.y, desired, clampf(delta * 8.0, 0.0, 1.0))


# ------------------------------------------------------------------ entry
## Pilot-side entry point: ask the server to crack `enemy_path`. Host applies directly.
func request_hijack(enemy_path: NodePath) -> void:
	if GameState.is_local_authority_server():
		_try_start(1, enemy_path)
	else:
		_request_rpc.rpc_id(1, enemy_path)


@rpc("any_peer", "call_remote", "reliable")
func _request_rpc(enemy_path: NodePath) -> void:
	if multiplayer.is_server():
		_try_start(multiplayer.get_remote_sender_id(), enemy_path)


## Server: validate the crack (stunned, hijackable, in range, pilot up) and start it.
func _try_start(peer: int, enemy_path: NodePath) -> void:
	if _pilots.has(peer):
		return
	var e := get_node_or_null(enemy_path)
	if e == null or not (e is CharacterBody3D) or not e.is_in_group(Groups.ENEMIES):
		return
	for d in _pilots.values():
		if (d as Dictionary).get("enemy") == e:
			return  # someone is already inside this hull
	if String(e.get("enemy_id")) in Settings.HIJACK_EXCLUDE:
		return
	if e.get("is_nemesis") == true:
		return  # the rival has hardened its firmware — never hackable
	if not _machine_alive(e):
		return
	var stunned_until: Variant = e.get("_stunned_until_ms")
	if stunned_until == null or Time.get_ticks_msec() >= int(stunned_until):
		return  # only a DISABLED machine can be cracked
	var p := _player_for_peer(peer)
	if p == null or not (p is Node3D):
		return
	if p.has_method("is_downed") and bool(p.call("is_downed")):
		return
	var dist: float = (p as Node3D).global_position.distance_to((e as Node3D).global_position)
	if dist > Settings.HIJACK_RANGE + 1.2:
		return
	_begin(peer, e, p)


func _begin(peer: int, e: Node, p: Node) -> void:
	# Fully external possession: freeze the machine's OWN brain; this director drives.
	e.set_physics_process(false)
	e.set("_stunned_until_ms", 0)
	_pilots[peer] = {
		"enemy": e,
		"player": p,
		"dir": Vector3.ZERO,
		"until_ms": Time.get_ticks_msec() + int(Settings.HIJACK_TIME * 1000.0),
		"next_atk_ms": 0,
	}
	_fx_rpc.rpc(p.get_path(), e.get_path(), true)
	if peer == 1:
		_grant_local(e)
	else:
		_granted_rpc.rpc_id(peer, e.get_path())


# ------------------------------------------------------------------ pilot inputs
## Pilot-side: world-space move direction (y ignored), throttled by the component.
func send_move(dir: Vector3) -> void:
	if GameState.is_local_authority_server():
		_apply_move(1, dir)
	else:
		_move_rpc.rpc_id(1, dir)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _move_rpc(dir: Vector3) -> void:
	if multiplayer.is_server():
		_apply_move(multiplayer.get_remote_sender_id(), dir)


func _apply_move(peer: int, dir: Vector3) -> void:
	if _pilots.has(peer):
		(_pilots[peer] as Dictionary)["dir"] = dir


## Pilot-side: the fire button while piloting = a hull SLAM ahead of the machine.
func send_attack() -> void:
	if GameState.is_local_authority_server():
		_apply_attack(1)
	else:
		_attack_rpc.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _attack_rpc() -> void:
	if multiplayer.is_server():
		_apply_attack(multiplayer.get_remote_sender_id())


func _apply_attack(peer: int) -> void:
	if not _pilots.has(peer):
		return
	var d: Dictionary = _pilots[peer]
	var now: int = Time.get_ticks_msec()
	if now < int(d["next_atk_ms"]):
		return
	d["next_atk_ms"] = now + int(Settings.HIJACK_ATTACK_CD * 1000.0)
	var e := d.get("enemy") as CharacterBody3D
	if not _machine_alive(e):
		return
	var fwd := Vector3(sin(e.rotation.y), 0.0, cos(e.rotation.y))
	var origin: Vector3 = e.global_position + fwd * 1.8
	var dmg: float = 12.0
	var raw_dmg: Variant = e.get("_stat_damage")
	if raw_dmg != null and float(raw_dmg) > 0.0:
		dmg = float(raw_dmg)
	dmg *= Settings.HIJACK_ATTACK_DMG_MULT
	_damage_machines_near(origin, Settings.HIJACK_ATTACK_RANGE, dmg, e, d.get("player"))
	_slam_fx_rpc.rpc(origin)


## Pilot-side exit request (X while piloting) — leaving detonates the hull.
func send_exit() -> void:
	if GameState.is_local_authority_server():
		_end(1, true)
	else:
		_exit_rpc.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _exit_rpc() -> void:
	if multiplayer.is_server():
		_end(multiplayer.get_remote_sender_id(), true)


## Pilot-side: a hit that landed on the pilot flows into the hull instead (the machine IS
## the pilot's armor). Kind-only trust shape: the server clamps the amount.
func redirect_damage(amount: float) -> void:
	if GameState.is_local_authority_server():
		_apply_redirect(1, amount)
	else:
		_redirect_rpc.rpc_id(1, amount)


@rpc("any_peer", "call_remote", "reliable")
func _redirect_rpc(amount: float) -> void:
	if multiplayer.is_server():
		_apply_redirect(multiplayer.get_remote_sender_id(), amount)


func _apply_redirect(peer: int, amount: float) -> void:
	if not _pilots.has(peer):
		return
	var e: Node = (_pilots[peer] as Dictionary).get("enemy")
	if not _machine_alive(e):
		return
	var hp: Node = e.get_node_or_null(Groups.NODE_HEALTH)
	if hp != null:
		hp.call("take_damage", clampf(amount, 0.0, 500.0), null)


# ------------------------------------------------------------------ end / cleanup
func _end(peer: int, explode: bool) -> void:
	if not _pilots.has(peer):
		return
	var d: Dictionary = _pilots[peer]
	_pilots.erase(peer)
	var e: Node = d.get("enemy")
	var p: Node = d.get("player")
	if _machine_alive(e):
		e.set_physics_process(true)
		if explode:
			_detonate(e, p)
	if e != null and is_instance_valid(e) and p != null and is_instance_valid(p):
		_fx_rpc.rpc(p.get_path(), e.get_path(), false)
	if peer == 1:
		_release_local()
	elif peer in multiplayer.get_peers():
		_ended_rpc.rpc_id(peer)


## Leaving the hull blows it from inside: machines near it take the blast (credited to the
## pilot), then the hull itself dies through the normal death path (loot / kill credit).
func _detonate(e: Node, pilot: Node) -> void:
	var pos: Vector3 = (e as Node3D).global_position
	_damage_machines_near(
		pos, Settings.HIJACK_EXIT_BLAST_RADIUS, Settings.HIJACK_EXIT_BLAST_DMG, e, pilot
	)
	var own_hp: Node = e.get_node_or_null(Groups.NODE_HEALTH)
	if own_hp != null:
		own_hp.call("take_damage", 999999.0, pilot)
	_slam_fx_rpc.rpc(pos)


## Radial ENEMY-only damage helper (players are never hit — PvE-friendly theft).
func _damage_machines_near(
	pos: Vector3, radius: float, dmg: float, exclude: Node, src: Node
) -> void:
	for t in get_tree().get_nodes_in_group(Groups.ENEMIES):
		if t == exclude or not (t is Node3D) or not _machine_alive(t):
			continue
		if (t as Node3D).global_position.distance_to(pos) > radius:
			continue
		var hp: Node = t.get_node_or_null(Groups.NODE_HEALTH)
		if hp != null:
			hp.call("take_damage", dmg, src)


func _on_entity_died(entity: Node, _killer: Node) -> void:
	if not GameState.is_local_authority_server():
		return
	for peer in _pilots.keys():
		if (_pilots[peer] as Dictionary).get("enemy") == entity:
			_end(int(peer), false)
			return


func _on_peer_left(peer: int) -> void:
	if GameState.is_local_authority_server() and _pilots.has(peer):
		_end(peer, true)


# ------------------------------------------------------------------ per-peer FX / grants
@rpc("authority", "call_remote", "reliable")
func _granted_rpc(enemy_path: NodePath) -> void:
	_grant_local(get_node_or_null(enemy_path))


func _grant_local(e: Node) -> void:
	var hj := _own_hijack()
	if hj != null and e != null:
		hj.call("begin_pilot", e)


@rpc("authority", "call_remote", "reliable")
func _ended_rpc() -> void:
	_release_local()


func _release_local() -> void:
	var hj := _own_hijack()
	if hj != null:
		hj.call("end_pilot")


## Every peer: park the pilot's collider, hide/show the body, toggle the hull ring.
@rpc("authority", "call_local", "reliable")
func _fx_rpc(player_path: NodePath, enemy_path: NodePath, on: bool) -> void:
	var p := get_node_or_null(player_path)
	var e := get_node_or_null(enemy_path)
	var peer: int = str(p.name).to_int() if p != null else 0
	if on:
		Events.hijack_started.emit(peer, _label_of(e))
	else:
		Events.hijack_ended.emit(peer)
	# The pilot's collider must be OFF on every peer while riding: two CharacterBody3D
	# overlapping at the hull point makes the physics solver depenetrate them violently
	# (the pair rockets skyward). Runs BEFORE the headless gate — the server needs it most.
	if p is CollisionObject3D:
		var body := p as CollisionObject3D
		if on:
			p.set_meta("hj_layer", body.collision_layer)
			p.set_meta("hj_mask", body.collision_mask)
			body.collision_layer = 0
			body.collision_mask = 0
		else:
			body.collision_layer = int(p.get_meta("hj_layer", body.collision_layer))
			body.collision_mask = int(p.get_meta("hj_mask", body.collision_mask))
	if DisplayServer.get_name() == "headless":
		return
	if p != null:
		var mr := p.get_node_or_null(Groups.NODE_MODEL_ROOT)
		if mr is Node3D:
			if on:
				(mr as Node3D).visible = false
			elif p.is_multiplayer_authority() and p.has_method("_apply_view_visibility"):
				p.call("_apply_view_visibility")  # owner: respect first-person hiding
			else:
				(mr as Node3D).visible = true
	if e != null and is_instance_valid(e):
		_set_ring(e, on)


func _set_ring(e: Node, on: bool) -> void:
	var old := e.get_node_or_null("HijackRing")
	if not on:
		if old != null:
			old.queue_free()
		return
	if old != null:
		return
	var ring := MeshInstance3D.new()
	ring.name = "HijackRing"
	var tor := TorusMesh.new()
	tor.inner_radius = 0.9
	tor.outer_radius = 1.05
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(0.2, 0.95, 0.85, 0.85)
	tor.material = mat
	ring.mesh = tor
	ring.position = Vector3(0.0, 0.25, 0.0)
	var light := OmniLight3D.new()
	light.light_color = Color(0.2, 0.95, 0.85)
	light.light_energy = 1.6
	light.omni_range = 5.0
	ring.add_child(light)
	e.add_child(ring)


## Quick expanding shock-ring at a slam/detonation point (render-only, every peer).
@rpc("authority", "call_local", "unreliable")
func _slam_fx_rpc(pos: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.8
	tor.outer_radius = 1.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(0.3, 0.95, 0.85, 0.8)
	tor.material = mat
	ring.mesh = tor
	scene.add_child(ring)
	ring.global_position = pos + Vector3.UP * 0.4
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(3.2, 1.0, 3.2), 0.35)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.35)
	tw.chain().tween_callback(ring.queue_free)


# ------------------------------------------------------------------ helpers
func _own_hijack() -> Node:
	var p := _player_for_peer(multiplayer.get_unique_id())
	return p.get_node_or_null(Groups.NODE_HIJACK) if p != null else null


func _player_for_peer(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if str(p.name).to_int() == peer_id:
			return p
	return null


func _machine_alive(e: Node) -> bool:
	if e == null or not is_instance_valid(e):
		return false
	if "_dying" in e and bool(e.get("_dying")):
		return false
	var hp: Node = e.get_node_or_null(Groups.NODE_HEALTH)
	return hp == null or not bool(hp.get("is_dead"))


func _label_of(e: Node) -> String:
	if e == null:
		return "?"
	var eid := String(e.get("enemy_id"))
	if eid != "":
		return eid.trim_prefix("robot_").to_upper()
	return str(e.name)
