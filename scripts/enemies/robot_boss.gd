extends RobotGunner
class_name RobotBoss
## Final-wave boss. Huge HP, mixed combat: it fires hitscan bursts at range
## (inherited from RobotGunner) but slams for heavy melee when the target gets
## close. Periodically it does a short "barrage" — a tighter burst — to keep the
## pressure spiking. Everything else (chase/separation/death/HP-bar/flash) is
## inherited.

const MELEE_RANGE: float = 4.0
const MELEE_MULT: float = 1.6          # melee slam hits harder than a shot
const BARRAGE_INTERVAL: float = 8.0
const BARRAGE_SHOTS: int = 6

var _barrage_t: float = BARRAGE_INTERVAL

# Procedural idle parts (visual only): the upper Torso tracks the player on Y; the
# chest core (via the base _pulse_part) AND the eyes pulse. Cached in _cache_proc_parts.
var _proc_torso: Node3D = null
var _proc_eyes: MeshInstance3D = null
var _proc_eyes_base_energy: float = 6.0

func _ready() -> void:
	super._ready()
	burst_count = 3
	burst_recovery = 1.6
	_shots_left_in_burst = burst_count

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not is_multiplayer_authority() or _dying or _health.is_dead:
		return
	# Periodic barrage: refill the burst with a bigger count and shorten recovery
	# for one cycle so the boss unloads. Only meaningful while it has a target.
	_barrage_t -= delta
	if _barrage_t <= 0.0 and _target != null:
		_barrage_t = BARRAGE_INTERVAL
		_shots_left_in_burst = BARRAGE_SHOTS

## OVERRIDE: cache the boss's Torso pivot + glowing chest core + eyes.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	var torso := asm.find_child("Torso", true, false)
	if torso is Node3D:
		_proc_torso = torso as Node3D
	var core := asm.find_child("ChestCore", true, false)
	if core is MeshInstance3D:
		_pulse_part = core as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(core as MeshInstance3D)
	var eyes := asm.find_child("Eyes", true, false)
	if eyes is MeshInstance3D:
		_proc_eyes = eyes as MeshInstance3D
		_proc_eyes_base_energy = _read_emission_energy(_proc_eyes)
	_has_proc_anim = _proc_torso != null or _pulse_part != null or _proc_eyes != null

## OVERRIDE: turn the upper torso to face the nearest player + pulse chest core and
## eyes (brighter/faster while attacking) so the boss looms and tracks you.
func _animate_visual(delta: float) -> void:
	_track_player_yaw(_proc_torso, delta, 2.0)
	var atk := current_state == State.ATTACK
	_pulse_emission(0.7, 1.5, 4.5 if atk else 2.0)
	# Eyes pulse on their own (the base _pulse_part owns the chest core).
	if _proc_eyes and is_instance_valid(_proc_eyes) and _flash_t <= 0.0:
		var mat := _proc_eyes.get_active_material(0)
		if mat is StandardMaterial3D:
			var k := 0.5 + 0.5 * sin(_anim_time * (5.0 if atk else 2.5) + 1.0)
			(mat as StandardMaterial3D).emission_energy_multiplier = _proc_eyes_base_energy * lerpf(0.6, 1.5, k)

## OVERRIDE: slam in melee range, otherwise fall back to the gunner hitscan burst.
func _strike(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	var dist := global_position.distance_to((target as Node3D).global_position)
	if dist <= MELEE_RANGE:
		_melee_slam(target)
	else:
		super._strike(target)

func _melee_slam(target: Node) -> void:
	var hb := target.get_node_or_null(Groups.NODE_HURTBOX)
	if hb and hb.has_method("apply_hit"):
		hb.apply_hit(_stat_damage * MELEE_MULT, self)
		return
	var hp := target.get_node_or_null(Groups.NODE_HEALTH)
	if hp and hp.has_method("take_damage"):
		hp.take_damage(_stat_damage * MELEE_MULT, self)

## OVERRIDE: bar sits well above the huge model.
func _health_bar_height() -> float:
	return 4.6

## OVERRIDE: boss death shakes the screen + makes bigger debris (via the base FX).
func _is_boss() -> bool:
	return true
