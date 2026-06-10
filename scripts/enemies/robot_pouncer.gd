extends RobotEnemy
class_name RobotPouncer
## LEAPING melee chaser — serves TWO archetypes via stats:
##   robot_frosthound (snow): LOW fast lunge-dash (pounce_up ~5, fwd ~9) — a wolf-bot
##   that closes the last metres in a flat dash and bites on landing.
##   robot_kappa (rain): HIGH pounce arc (pounce_up ~8, fwd ~7) — it leaps ONTO you.
## Between pounces it chases/fights like a normal melee enemy. The leap itself is a
## velocity burst finished by gravity (same arc mechanics as the sand-worm's emerge);
## landing deals an AoE swipe so a dodged pounce still threatens the spot you held.
##
## All params from Settings.ENEMY_STATS[enemy_id]: pounce_range / pounce_up /
## pounce_fwd / pounce_cooldown / pounce_damage / pounce_radius.

var _pounce_range: float = 7.0
var _pounce_up: float = 5.0
var _pounce_fwd: float = 9.0
var _pounce_cooldown: float = 4.0
var _pounce_damage: float = 12.0
var _pounce_radius: float = 1.8

var _pounce_cd: float = 0.0
var _pouncing: bool = false
var _pounce_air_t: float = 0.0

# Visual parts: 4 leg pivots gait-sway; the Core pulses.
var _p_legs: Array[Node3D] = []
var _p_leg_rest: Array[Vector3] = []

func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	_pounce_range = float(stats.get("pounce_range", _pounce_range))
	_pounce_up = float(stats.get("pounce_up", _pounce_up))
	_pounce_fwd = float(stats.get("pounce_fwd", _pounce_fwd))
	_pounce_cooldown = float(stats.get("pounce_cooldown", _pounce_cooldown))
	_pounce_damage = float(stats.get("pounce_damage", _pounce_damage))
	_pounce_radius = float(stats.get("pounce_radius", _pounce_radius))
	# First pounce comes quickly so the archetype reads immediately.
	_pounce_cd = _pounce_cooldown * 0.4

## OVERRIDE: while AIRBORNE the leap owns the body (gravity arc + landing swipe);
## otherwise the base AI runs normally with the pounce cooldown ticking down.
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if _dying or _health.is_dead:
		return
	if _pouncing:
		_pounce_air_t += delta
		velocity.y -= _gravity * delta
		move_and_slide()
		if _pounce_air_t >= 0.2 and (is_on_floor() or _pounce_air_t > 2.5):
			_pouncing = false
			velocity = Vector3.ZERO
			_swipe_area()
		return
	if _pounce_cd > 0.0:
		_pounce_cd -= delta
	super._physics_process(delta)

## OVERRIDE: chase normally, but LAUNCH when the pounce is ready and the prey is in
## the pounce window (not point-blank — a leap from 1 m looks silly).
func _do_chase(delta: float) -> void:
	if _target != null and is_instance_valid(_target) and _pounce_cd <= 0.0 and is_on_floor():
		var d := global_position.distance_to(_target.global_position)
		# Min distance is barely above melee so a circling fight still re-pounces.
		if d <= _pounce_range and d >= _stat_attack_range * 1.1:
			_launch_pounce()
			return
	super._do_chase(delta)

func _launch_pounce() -> void:
	var to := _target.global_position - global_position
	to.y = 0.0
	if to.length() < 0.01:
		return
	var fwd := to.normalized()
	rotation.y = atan2(fwd.x, fwd.z)
	velocity = fwd * _pounce_fwd + Vector3.UP * _pounce_up
	_pouncing = true
	_pounce_air_t = 0.0
	_pounce_cd = _pounce_cooldown
	current_state = State.CHASE

## Landing swipe: AoE damage around the impact point.
func _swipe_area() -> void:
	for p in get_tree().get_nodes_in_group("players"):
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		var pn := p as Node3D
		if pn.has_method("is_downed") and pn.is_downed():
			continue
		if global_position.distance_to(pn.global_position) > _pounce_radius:
			continue
		var hb := pn.get_node_or_null("Hurtbox")
		if hb and hb.has_method("apply_hit"):
			hb.apply_hit(_pounce_damage, self)

## OVERRIDE: cache the quadruped's 4 leg pivots + the glowing Core.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	for i in 4:
		var leg := asm.find_child("Leg%d" % i, true, false)
		if leg is Node3D:
			_p_legs.append(leg as Node3D)
			_p_leg_rest.append((leg as Node3D).rotation)
	var core := asm.find_child("Core", true, false)
	if core is MeshInstance3D:
		_pulse_part = core as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(core as MeshInstance3D)
	_has_proc_anim = not _p_legs.is_empty() or _pulse_part != null

## OVERRIDE: trot gait (diagonal leg pairs out of phase) + core pulse.
func _animate_visual(_delta: float) -> void:
	var moving := current_state == State.CHASE or current_state == State.INVESTIGATE
	var rate := 9.0 if moving else 2.5
	for i in _p_legs.size():
		var leg := _p_legs[i]
		if leg == null or not is_instance_valid(leg):
			continue
		# Diagonal pairs (0,3) and (1,2) swing together like a trot.
		var phase := 0.0 if (i == 0 or i == 3) else PI
		var sway := sin(_anim_time * rate + phase) * (0.35 if moving else 0.06)
		leg.rotation = _p_leg_rest[i] + Vector3(sway, 0.0, 0.0)
	var atk := current_state == State.ATTACK
	_pulse_emission(0.6, 1.5, 7.0 if atk else 3.0)
