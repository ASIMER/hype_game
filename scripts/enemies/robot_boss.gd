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
	var hb := target.get_node_or_null("Hurtbox")
	if hb and hb.has_method("apply_hit"):
		hb.apply_hit(_stat_damage * MELEE_MULT, self)
		return
	var hp := target.get_node_or_null("Health")
	if hp and hp.has_method("take_damage"):
		hp.take_damage(_stat_damage * MELEE_MULT, self)

## OVERRIDE: bar sits well above the huge model.
func _health_bar_height() -> float:
	return 4.6
