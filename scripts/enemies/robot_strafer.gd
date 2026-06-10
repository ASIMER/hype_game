extends RobotGunner
class_name RobotStrafer
## GROUNDED orbit-strafing gunner (the desert dust-devil). The same ring-holding +
## tangential-strafe steering as the flying wasp (robot_flyer.gd), but on FOOT: it
## inherits the base grounded _apply_movement (gravity, separation, navmesh-free local
## steering) and RobotGunner's hitscan/burst attack. Reads as a skirmisher that circles
## you at mid range instead of standing in the open trading shots.

const ORBIT_BAND: float = 2.5
const STRAFE_SPEED_SCALE: float = 0.85

var _orbit_distance: float = 9.0
var _strafe_dir: float = 1.0
var _strafe_flip_t: float = 0.0

# Visual parts: the sand-skirt cone spins, the eye pulses.
var _skirt: Node3D = null


func _ready() -> void:
	super._ready()
	# Hold the ring just inside the firing range so shots stay in range while circling.
	_orbit_distance = maxf(6.0, _stat_attack_range * 0.55)


## OVERRIDE: chase = steer onto the orbit ring (not into melee).
func _do_chase(delta: float) -> void:
	_fsm.clear_patrol_target()
	if _target == null:
		_apply_movement(Vector3.ZERO, delta)
		return
	_apply_movement(_orbit_dir(delta), delta)
	_face_towards(_target.global_position, delta)


## OVERRIDE: keep strafing WHILE firing — a circling gunner is the whole identity.
func _do_attack(delta: float) -> void:
	_apply_movement(_orbit_dir(delta), delta)
	if _target and is_instance_valid(_target):
		_face_towards(_target.global_position, delta)
	if _attack_cooldown <= 0.0:
		_strike(_target)
		_attack_cooldown = _next_cooldown()


## Horizontal steering toward the orbit ring + a tangential strafe (flips every few s)
## (shared Steering.orbit_dir — it reads/writes our _strafe_dir/_strafe_flip_t).
func _orbit_dir(delta: float) -> Vector3:
	return Steering.orbit_dir(self, _target, delta, _orbit_distance, ORBIT_BAND, STRAFE_SPEED_SCALE)


## OVERRIDE: cache the spinning skirt + the amber eye.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	var skirt := asm.find_child("Skirt", true, false)
	if skirt is Node3D:
		_skirt = skirt as Node3D
	var eye := asm.find_child("Eye", true, false)
	if eye is MeshInstance3D:
		_pulse_part = eye as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(eye as MeshInstance3D)
	_has_proc_anim = _skirt != null or _pulse_part != null


## OVERRIDE: spin the sand skirt (faster in a firefight) + pulse the eye.
func _animate_visual(delta: float) -> void:
	var atk := current_state == State.ATTACK
	if _skirt and is_instance_valid(_skirt):
		_skirt.rotation.y += delta * (13.0 if atk else 8.0)
	_pulse_emission(0.6, 1.4, 6.0 if atk else 2.5)
