extends RobotEnemy
class_name RobotSlammer
## SNOW AVALANCHE — a tank brute whose attack is a TELEGRAPHED ground slam: it plants
## itself, winds up for `slam_windup` seconds (its core strobes hard — the replicated
## ATTACK state drives the same telegraph on clients), then slams: AoE damage to every
## player within `slam_radius` at the moment of IMPACT. The windup is the counterplay —
## walk out of the circle. Once winding it is COMMITTED (backpedalling doesn't cancel).

var _slam_radius: float = 3.6
var _slam_windup: float = 0.9
var _slam_damage: float = 20.0

var _winding: bool = false
var _windup_t: float = 0.0

# Visual: the two fists + the chest core.
var _fists: Array[Node3D] = []
var _fist_rest: Array[Vector3] = []

func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	_slam_radius = float(stats.get("slam_radius", _slam_radius))
	_slam_windup = float(stats.get("slam_windup", _slam_windup))
	_slam_damage = float(stats.get("slam_damage", _slam_damage))

## OVERRIDE: in range = begin the windup; the slam lands when the timer expires.
func _do_attack(delta: float) -> void:
	_apply_movement(Vector3.ZERO, delta)
	if _target and is_instance_valid(_target):
		_face_towards(_target.global_position, delta)
	if not _winding and _attack_cooldown <= 0.0:
		_winding = true
		_windup_t = _slam_windup
	_tick_windup(delta)

## OVERRIDE: a started windup keeps ticking even if the FSM flips back to CHASE
## (the player stepping out of range IS the dodge — the slam still lands on the spot).
func _do_chase(delta: float) -> void:
	if _winding:
		# Committed: hold ground and finish the slam.
		_apply_movement(Vector3.ZERO, delta)
		if _target and is_instance_valid(_target):
			_face_towards(_target.global_position, delta)
		_tick_windup(delta)
		return
	super._do_chase(delta)

func _tick_windup(delta: float) -> void:
	if not _winding:
		return
	# Replicated telegraph: clients strobe the core off ATTACK.
	current_state = State.ATTACK
	_windup_t -= delta
	if _windup_t <= 0.0:
		_winding = false
		_slam()
		_attack_cooldown = _next_cooldown()

## IMPACT: AoE damage (linear falloff) + a burst + a shake for anyone close.
func _slam() -> void:
	var hit_close := false
	for p in get_tree().get_nodes_in_group("players"):
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		var pn := p as Node3D
		if pn.has_method("is_downed") and pn.is_downed():
			continue
		var d := global_position.distance_to(pn.global_position)
		if d > _slam_radius:
			continue
		hit_close = true
		var dmg := _slam_damage * clampf(1.0 - 0.5 * d / _slam_radius, 0.4, 1.0)
		var hb := pn.get_node_or_null("Hurtbox")
		if hb and hb.has_method("apply_hit"):
			hb.apply_hit(dmg, self)
	_spawn_death_burst()   # ground-impact flash/sparks at the body
	if hit_close:
		Events.screen_shake.emit(0.35)

## OVERRIDE: cache the fists + chest core.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	for i in 2:
		var fist := asm.find_child("Fist%d" % i, true, false)
		if fist is Node3D:
			_fists.append(fist as Node3D)
			_fist_rest.append((fist as Node3D).position)
	var core := asm.find_child("Core", true, false)
	if core is MeshInstance3D:
		_pulse_part = core as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(core as MeshInstance3D)
	_has_proc_anim = not _fists.is_empty() or _pulse_part != null

## OVERRIDE: fists RAISE during the windup (the visible tell) and the core strobes;
## idle = a slow heavy sway.
func _animate_visual(_delta: float) -> void:
	var atk := current_state == State.ATTACK
	for i in _fists.size():
		var fist := _fists[i]
		if fist == null or not is_instance_valid(fist):
			continue
		var lift := 0.55 if atk else 0.05 * sin(_anim_time * 1.6 + float(i) * PI)
		fist.position = _fist_rest[i] + Vector3(0.0, lift, 0.0)
	_pulse_emission(0.4 if atk else 0.7, 2.0 if atk else 1.3, 14.0 if atk else 2.0)
