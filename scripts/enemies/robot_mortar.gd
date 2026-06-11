extends RobotGunner
class_name RobotMortar
## SNOW CRYO-MORTAR — slow long-range frost artillery. Inherits RobotGunner's burst
## hitscan (burst=true in stats → 3-shot volleys with a recovery), and every shot that
## actually CONNECTS chills the player: a brief movement SLOW routed to the owning
## peer via player.server_apply_slow (movement is client-authoritative, so the server
## rpc_id's the debuff — same trust pattern as begin_power_open).

var _slow_mult: float = 0.6
var _slow_dur: float = 1.6

# Visual: the mortar tube tracks the player's yaw; the frost core pulses.
var _tube: Node3D = null


func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	_slow_mult = float(stats.get("slow_mult", _slow_mult))
	_slow_dur = float(stats.get("slow_dur", _slow_dur))


## OVERRIDE: fire the inherited hitscan, then chill the target if the shot had a
## clear line (mirrors _fire_hitscan's own LOS gate — a wall blocks the chill too).
func _strike(target: Node) -> void:
	super._strike(target)
	if target == null or not is_instance_valid(target) or not (target is Node3D):
		return
	if not _check_line_of_sight(target as Node3D):
		return
	if target.has_method("server_apply_slow"):
		target.server_apply_slow.rpc_id(target.get_multiplayer_authority(), _slow_mult, _slow_dur)


## OVERRIDE: cache the tracking Tube pivot + the frost Core.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	var tube := asm.find_child("Tube", true, false)
	if tube is Node3D:
		_tube = tube as Node3D
	var core := asm.find_child("Core", true, false)
	if core is MeshInstance3D:
		_pulse_part = core as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(core as MeshInstance3D)
	_has_proc_anim = _tube != null or _pulse_part != null


## OVERRIDE: the tube slowly tracks the player; the frost core pulses harder mid-volley.
func _animate_visual(delta: float) -> void:
	_track_player_yaw(_tube, delta, 2.0)
	var atk := current_state == State.ATTACK
	_pulse_emission(0.6, 1.4, 6.0 if atk else 2.0)
