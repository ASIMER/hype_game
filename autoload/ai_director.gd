extends Node
## Reactive AI Director (autoload name: AIDirector).
##
## Server-authoritative — every spawn/logic gate checks
## GameState.is_local_authority_server(). Clients receive enemies through the
## existing Net/Enemies MultiplayerSpawner automatically.
##
## Responsibilities:
##   • Alarm reinforcements — when Events.enemy_alerted fires (e.g. from a
##     RobotCaller / Snitch), summon ALARM_REINFORCE_COUNT hunters toward the
##     alert position (on a per-alarm cooldown so it can't avalanche).
##   • Noise-triggered alarms — very loud events (grenade, kind==2) on
##     Events.noise_emitted may also trigger the alarm path (same cooldown).
##
## The WaveManager registers itself on _ready and clears on _exit_tree so this
## director always holds a valid (or null-checked) reference.
##
## Registered in project.godot by the LEAD as autoload "AIDirector" pointing at
## res://autoload/ai_director.gd.
## (No class_name — the autoload singleton name "AIDirector" would collide with it.)

## Reference set by WaveManager._ready() / cleared on _exit_tree().
var _wave_mgr = null  # typed as Variant — WaveManager is not an autoload we import

## Alarm cooldown: counts DOWN in _process; 0 means "ready to fire again".
var _alarm_cooldown: float = 0.0

## Separate cooldown for noise-triggered alarms so grenade spam can't stack
## with Snitch alarms. Shares the same Settings constant for simplicity.
var _noise_alarm_cooldown: float = 0.0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


func _ready() -> void:
	if not Events.enemy_alerted.is_connected(_on_enemy_alerted):
		Events.enemy_alerted.connect(_on_enemy_alerted)
	if not Events.noise_emitted.is_connected(_on_noise_emitted):
		Events.noise_emitted.connect(_on_noise_emitted)
	# Reset director state whenever a new match begins.
	if not Events.match_started.is_connected(_on_match_started):
		Events.match_started.connect(_on_match_started)


func _process(delta: float) -> void:
	if not GameState.is_local_authority_server():
		return
	# Tick cooldowns toward zero.
	if _alarm_cooldown > 0.0:
		_alarm_cooldown = maxf(_alarm_cooldown - delta, 0.0)
	if _noise_alarm_cooldown > 0.0:
		_noise_alarm_cooldown = maxf(_noise_alarm_cooldown - delta, 0.0)


# ---------------------------------------------------------------------------
# Public API (called by WaveManager)
# ---------------------------------------------------------------------------


## Called by WaveManager._ready() on the server; cleared on _exit_tree().
func set_wave_manager(wm) -> void:
	_wave_mgr = wm


# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------


func _on_match_started() -> void:
	_alarm_cooldown = 0.0
	_noise_alarm_cooldown = 0.0


## A Snitch / caller / alarm signal fired at `world_pos`.
## `level` scales the response — currently 1.0 = standard reinforcement.
func _on_enemy_alerted(world_pos: Vector3, level: float) -> void:
	if not GameState.is_local_authority_server():
		return
	if _alarm_cooldown > 0.0:
		return
	if not is_instance_valid(_wave_mgr):
		return
	# Fire reinforcements toward the alert position.
	var count: int = maxi(1, int(round(float(Settings.ALARM_REINFORCE_COUNT) * level)))
	_wave_mgr.spawn_reinforcements(count, world_pos, true)
	Events.notify.emit(tr("Reinforcements inbound!"), 2)
	_alarm_cooldown = Settings.ALARM_COOLDOWN


## Loud events (grenade) can also trigger the alarm path.
## Gunfire (kind==1) is deliberately NOT forwarded — too spammy.
func _on_noise_emitted(world_pos: Vector3, loudness: float, kind: int) -> void:
	if not GameState.is_local_authority_server():
		return
	# Only grenades (kind==2) trigger director-level reinforcements.
	if kind != 2:
		return
	# Must be loud enough to count as an alarm-level event.
	if loudness < Settings.ALARM_GRENADE_MIN_LOUDNESS:
		return
	if _noise_alarm_cooldown > 0.0:
		return
	if not is_instance_valid(_wave_mgr):
		return
	_wave_mgr.spawn_reinforcements(Settings.ALARM_REINFORCE_COUNT, world_pos, true)
	Events.notify.emit(tr("Reinforcements inbound!"), 2)
	_noise_alarm_cooldown = Settings.ALARM_COOLDOWN
