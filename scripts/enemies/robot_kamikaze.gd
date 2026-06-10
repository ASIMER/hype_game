extends RobotEnemy
class_name RobotKamikaze
## DESERT SCARAB — a fast skittering suicide beetle. It rushes the player; once inside
## attack range it ARMS (its red core blinks hard — the player gets `fuse` seconds of
## telegraph), keeps pressing in, then SELF-DESTRUCTS: an AoE blast with linear damage
## falloff, killing itself through the normal death path (debris/burst/loot included).
## Once armed it is COMMITTED — backpedalling out of range doesn't disarm it.
##
## All gameplay is authority-side; clients read the replicated `current_state` (ATTACK
## == armed) to drive the frantic core blink, so the telegraph is visible in co-op.

var _armed: bool = false
var _fuse_t: float = 0.0
var _fuse: float = 0.8
var _blast_radius: float = 3.4
var _blast_damage: float = 24.0

# Cached visual parts (Leg pivots skitter, the Core blinks).
var _kami_legs: Array[Node3D] = []
var _kami_leg_rest: Array[Vector3] = []

func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	_fuse = float(stats.get("fuse", _fuse))
	_blast_radius = float(stats.get("blast_radius", _blast_radius))
	_blast_damage = float(stats.get("blast_damage", _blast_damage))

## OVERRIDE: in range = arm + hold the pressure (keep nudging toward the target while
## the fuse burns — a stationary bomb is trivial to walk away from).
func _do_attack(delta: float) -> void:
	if not _armed:
		_armed = true
		_fuse_t = _fuse
	if _target and is_instance_valid(_target):
		var to := _target.global_position - global_position
		to.y = 0.0
		_apply_movement(to.normalized() * 0.6 if to.length() > 0.3 else Vector3.ZERO, delta)
		_face_towards(_target.global_position, delta)
	else:
		_apply_movement(Vector3.ZERO, delta)
	_tick_fuse(delta)

## OVERRIDE: an armed scarab stays armed even if the FSM flips back to CHASE.
func _do_chase(delta: float) -> void:
	super._do_chase(delta)
	_tick_fuse(delta)

func _tick_fuse(delta: float) -> void:
	if not _armed:
		return
	# Keep clients' blink running: ATTACK is the replicated "armed" hint.
	current_state = State.ATTACK
	_fuse_t -= delta
	if _fuse_t <= 0.0:
		_detonate()

## The boom: AoE damage with linear falloff to every player in the blast, then die
## through Health so the standard death FX/loot/wave accounting all fire.
func _detonate() -> void:
	if _dying or (_health != null and _health.is_dead):
		return
	# Full linear falloff (floor 0.25); the blast hits DOWNED players too.
	CombatAoe.damage_players(global_position, _blast_radius, _blast_damage, self,
		1.0, 0.25, true)
	_health.take_damage(1.0e6, self)

## OVERRIDE: cache the 4 skitter-leg pivots + the red arming Core.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	for i in 4:
		var leg := asm.find_child("Leg%d" % i, true, false)
		if leg is Node3D:
			_kami_legs.append(leg as Node3D)
			_kami_leg_rest.append((leg as Node3D).rotation)
	var core := asm.find_child("Core", true, false)
	if core is MeshInstance3D:
		_pulse_part = core as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(core as MeshInstance3D)
	_has_proc_anim = not _kami_legs.is_empty() or _pulse_part != null

## OVERRIDE: frantic leg skitter + the core blink — slow idle pulse normally, a hard
## fast strobe while ARMED (current_state == ATTACK replicates to clients).
func _animate_visual(_delta: float) -> void:
	for i in _kami_legs.size():
		var leg := _kami_legs[i]
		if leg == null or not is_instance_valid(leg):
			continue
		var sway := sin(_anim_time * 9.0 + float(i) * 1.4) * 0.16
		leg.rotation = _kami_leg_rest[i] + Vector3(sway * 0.4, 0.0, sway)
	var armed := current_state == State.ATTACK
	_pulse_emission(0.3 if armed else 0.7, 2.2 if armed else 1.3, 16.0 if armed else 3.0)
