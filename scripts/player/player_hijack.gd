class_name PlayerHijack
extends Node
## Hijack & Pilot (v0.5-B2) — the player-side component (the "Hijack" child, code-built
## like PlayerGear so player.gd stays under the file ceiling). Owns: the stunned-machine
## prompt scan, the hold-X crack timer, the pilot loop (body snapped to the hull + thin
## move/attack/exit inputs to HijackDirector), and the eject i-frames.
## player.gd touches exactly two points: PlayerHijack.attach(self) + the _fire_current gate.

var _p: CharacterBody3D = null
var _piloting: Node = null
var _until_ms: int = 0
var _hold: float = 0.0
var _scan_timer: float = 0.0
var _candidate: Node = null
var _candidate_stunned: bool = false
var _stun_seen_ms: int = 0  # sticky window — the client's shock FLAG is only 0.5s visible
var _move_accum: float = 0.0


## One-line wiring for player.gd: build + name + parent the component.
static func attach(player: CharacterBody3D) -> void:
	var hj := PlayerHijack.new()
	hj.name = Groups.NODE_HIJACK
	hj._p = player
	player.add_child(hj)


func _physics_process(delta: float) -> void:
	if _p == null or not _p.is_multiplayer_authority():
		return
	if _piloting != null:
		_pilot_tick(delta)
		return
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.25
		_refresh_candidate()
	if _candidate == null or not Input.is_action_pressed("hijack"):
		_hold = 0.0
		return
	# No stun gate HERE: a client can't see a plain EMP stun at all (and the shock flag
	# is only a 0.5s visual) — the hold always accrues and the SERVER judges the truth.
	_hold += delta
	if _hold >= Settings.HIJACK_HOLD_TIME:
		_hold = 0.0
		HijackDirector.request_hijack(_candidate.get_path())


## While piloting: ride the hull (the player's client-authoritative transform replicates
## the seat to every peer), stream the move dir, and watch for the exit press.
func _pilot_tick(delta: float) -> void:
	if not is_instance_valid(_piloting):
		end_pilot()
		return
	_p.global_position = (_piloting as Node3D).global_position
	_p.velocity = Vector3.ZERO
	if Input.is_action_just_pressed("hijack"):
		HijackDirector.send_exit()
		return
	_move_accum -= delta
	if _move_accum <= 0.0:
		_move_accum = 0.05
		HijackDirector.send_move(_move_dir())


## Camera-relative WASD → world-space drive dir. Mirrors player.gd's move handling,
## including the AgentBridge override so the self-play harness can drive a stolen hull.
func _move_dir() -> Vector3:
	var strafe: float
	var fwd_amt: float
	if AgentBridge.active:
		strafe = AgentBridge.move.x
		fwd_amt = AgentBridge.move.y
	else:
		strafe = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		fwd_amt = (
			Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
		)
	var pivot := _p.get("camera_pivot") as Node3D
	if pivot == null:
		return Vector3.ZERO
	var basis := pivot.global_transform.basis
	var forward := -basis.z
	var right := basis.x
	forward.y = 0.0
	right.y = 0.0
	var dir := right.normalized() * strafe + forward.normalized() * fwd_amt
	return dir.normalized() if dir.length_squared() > 0.01 else Vector3.ZERO


# ------------------------------------------------------------------ director callbacks
func begin_pilot(enemy: Node) -> void:
	_piloting = enemy
	_until_ms = Time.get_ticks_msec() + int(Settings.HIJACK_TIME * 1000.0)


func end_pilot() -> void:
	if _piloting == null:
		return
	_piloting = null
	# Enemy-source i-frames + a small hop so the eject reads (and can't be an instant kill).
	var safe_ms: int = Time.get_ticks_msec() + int(Settings.HIJACK_EJECT_IFRAMES * 1000.0)
	_p.set("_iframes_until_ms", safe_ms)
	_p.velocity = Vector3(0.0, 4.5, 0.0)


func is_piloting() -> bool:
	return _piloting != null and is_instance_valid(_piloting)


## Fire while piloting = the hull slam (routed from player._fire_current).
func pilot_fire() -> void:
	HijackDirector.send_attack()


func time_left() -> float:
	return maxf(0.0, float(_until_ms - Time.get_ticks_msec()) / 1000.0)


func pilot_label() -> String:
	if not is_piloting():
		return ""
	var eid := String(_piloting.get("enemy_id"))
	return eid.trim_prefix("robot_").to_upper() if eid != "" else str(_piloting.name)


# ------------------------------------------------------------------ prompt scan
func _refresh_candidate() -> void:
	_candidate = null
	_candidate_stunned = false
	var best: float = Settings.HIJACK_RANGE
	for e in _p.get_tree().get_nodes_in_group(Groups.ENEMIES):
		if not (e is Node3D):
			continue
		if String(e.get("enemy_id")) in Settings.HIJACK_EXCLUDE:
			continue
		if e.get("is_nemesis") == true:
			continue
		var dd: float = _p.global_position.distance_to((e as Node3D).global_position)
		if dd <= best:
			best = dd
			_candidate = e
	if _candidate != null:
		# Sticky: the shock FLAG flashes for only 0.5s on clients — remember a recent
		# sighting so the prompt (and the player's read) survives the whole stun.
		if _looks_stunned(_candidate):
			_stun_seen_ms = Time.get_ticks_msec()
		_candidate_stunned = Time.get_ticks_msec() - _stun_seen_ms < 2500


## Host reads the true stun clock; a client falls back to the synced chemistry SHOCK flag
## (a plain EMP stun isn't replicated — the server re-validates the request anyway).
func _looks_stunned(e: Node) -> bool:
	if GameState.is_local_authority_server():
		var su: Variant = e.get("_stunned_until_ms")
		return su != null and Time.get_ticks_msec() < int(su)
	if e.has_method("chemistry_status"):
		return (e.call("chemistry_status") as Dictionary).has("shock")
	return false


## HUD chip text (hud polls this): the hack prompt near a candidate, "" otherwise.
func prompt_text() -> String:
	if _piloting != null or _candidate == null:
		return ""
	if _candidate_stunned:
		return tr("HOLD [X] — HACK THE MACHINE")
	return tr("Machine in reach — stun it (shock/EMP) to hack [X]")
