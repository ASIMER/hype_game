extends RobotEnemy
class_name RobotGunner
## Ranged ground enemy (bastion / boss). Extends RobotEnemy but replaces the
## melee _strike with a hitscan shot at the target, optionally fired as a short
## burst. Everything else (chase/separation/death/HP-bar/flash) is inherited.
##
## Hitscan (not a physics projectile) keeps networking trivial — the authority
## resolves the hit and applies damage through the target's Hurtbox, exactly like
## the player's weapon. A visual tracer is drawn if res://scenes/fx/Tracer.tscn
## exists (guarded), so we don't hard-depend on fx-dev.

const TRACER_SCENE := "res://scenes/fx/Tracer.tscn"

# Burst flag/params come from Settings.ENEMY_STATS (burst=true on bastion). The
# cooldown in stats is the GAP BETWEEN SHOTS within a burst; we add a longer
# recovery between bursts so it's pressure, not a beam.
@export var burst_count: int = 1
@export var burst_recovery: float = 1.4

var _shots_left_in_burst: int = 0
var _burst_just_ended: bool = false

# Procedural idle parts (visual only): the bastion's turret head tracks the player
# on Y and its weak-point dome pulses. Cached in _cache_proc_parts (OVERRIDE).
var _proc_turret: Node3D = null


func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	if stats.get("burst", false):
		burst_count = max(burst_count, 3)
	_shots_left_in_burst = burst_count


## OVERRIDE: fire a hitscan shot instead of melee. Burst-aware: shots within a
## burst use the (short) stat cooldown; after the last shot we flag a longer
## recovery (applied by _next_cooldown) so bursts are spaced, not a beam.
func _strike(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	_fire_hitscan(target)
	_shots_left_in_burst -= 1
	_burst_just_ended = false
	if _shots_left_in_burst <= 0:
		_shots_left_in_burst = burst_count
		_burst_just_ended = true


## OVERRIDE: short gap between shots in a burst, longer recovery after the last.
## With burst_count == 1 there is no intra-burst gap, so every shot just uses the
## archetype's stat cooldown (the wasp case).
func _next_cooldown() -> float:
	if burst_count > 1 and _burst_just_ended:
		_burst_just_ended = false
		return burst_recovery
	return _stat_cooldown


## OVERRIDE: cache the bastion's TurretHead pivot + glowing weak-point dome.
func _cache_proc_parts() -> void:
	var asm := _proc_root()
	if asm == null:
		return
	var head := asm.find_child("TurretHead", true, false)
	if head is Node3D:
		_proc_turret = head as Node3D
	var dome := asm.find_child("WeakDome", true, false)
	if dome is MeshInstance3D:
		_pulse_part = dome as MeshInstance3D
		_pulse_base_energy = _read_emission_energy(dome as MeshInstance3D)
	_has_proc_anim = _proc_turret != null or _pulse_part != null


## OVERRIDE: slowly yaw the turret head to face the nearest player + pulse the weak
## point (brighter/faster while attacking) so the bastion reads as alive + aiming.
func _animate_visual(delta: float) -> void:
	_track_player_yaw(_proc_turret, delta, 2.5)
	var atk := current_state == State.ATTACK
	_pulse_emission(0.6, 1.4, 5.0 if atk else 2.5)


## Resolve a straight shot from our muzzle to the target centre. If the LOS ray
## is clear to the target we deal damage through its Hurtbox; otherwise the shot
## is blocked by geometry and misses (no damage).
func _fire_hitscan(target: Node3D) -> void:
	var muzzle := global_position + Vector3.UP * 1.3
	var aim := target.global_position + Vector3.UP * 1.0
	# Reuse the LOS check we already ran this frame conceptually; re-test to be safe.
	if not _check_line_of_sight(target):
		return
	var hb := target.get_node_or_null(Groups.NODE_HURTBOX)
	if hb and hb.has_method("apply_hit"):
		hb.apply_hit(_stat_damage, self)
	else:
		var hp := target.get_node_or_null(Groups.NODE_HEALTH)
		if hp and hp.has_method("take_damage"):
			hp.take_damage(_stat_damage, self)
	_spawn_tracer(muzzle, aim)


func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	if not ResourceLoader.exists(TRACER_SCENE):
		return
	var packed := load(TRACER_SCENE)
	if not (packed is PackedScene):
		return
	var tracer: Node = (packed as PackedScene).instantiate()
	_loot_container().add_child(tracer)
	# Best-effort: many tracer impls expose a setup(from,to) or from/to fields.
	if tracer.has_method("setup"):
		tracer.call("setup", from, to)
	elif tracer is Node3D:
		(tracer as Node3D).global_position = from
