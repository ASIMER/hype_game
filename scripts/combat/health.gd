extends Node
class_name Health
## Reusable health component. Attach as a child Node named "Health" to any entity
## (player, enemy). Authority model: in multiplayer, only the node's authority
## mutates health and then replicates `current` via a MultiplayerSynchronizer on
## the parent. Single-player: everything is authority, so it just works.
##
## CONTRACT (depended on by combat, enemy, player, loot/death workstreams):
##   func take_damage(amount: float, source: Node = null) -> void
##   func heal(amount: float) -> void
##   var current: float ; var max_health: float ; var is_dead: bool
##   signal died(killer) ; signal health_changed(current, max_health)

signal health_changed(current: float, max_health: float)
signal died(killer: Node)

@export var max_health: float = 100.0
@export var invulnerable: bool = false

var current: float
var is_dead: bool = false
var _last_attacker: Node = null
## Optional owner-set hook to transform incoming damage BEFORE it hits HP: (amount, source)->amount.
## The player sets this for armor / overshield buffs; enemies leave it unset (no-op).
var damage_filter: Callable = Callable()

func _ready() -> void:
	current = max_health

## Only call on the authority of the owning entity. Returns nothing; listen to
## signals or Events.damage_dealt / Events.entity_died for reactions.
func take_damage(amount: float, source: Node = null) -> void:
	if is_dead or invulnerable or amount <= 0.0:
		return
	if damage_filter.is_valid():
		amount = float(damage_filter.call(amount, source))
		if amount <= 0.0:
			return
	_last_attacker = source
	current = maxf(0.0, current - amount)
	health_changed.emit(current, max_health)
	Events.damage_dealt.emit(get_parent(), amount, source)
	if current <= 0.0:
		_die(source)

func heal(amount: float) -> void:
	if is_dead or amount <= 0.0:
		return
	current = minf(max_health, current + amount)
	health_changed.emit(current, max_health)

func set_max_health(value: float, refill: bool = true) -> void:
	max_health = value
	if refill:
		current = value
	health_changed.emit(current, max_health)

func _die(killer: Node) -> void:
	is_dead = true
	current = 0.0
	died.emit(killer)
	Events.entity_died.emit(get_parent(), killer)
