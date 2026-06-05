extends Node
class_name WaveManager
## Server-authoritative wave director. Spawns escalating waves of RobotEnemy into
## the Arena's Net/Enemies container at the EnemySpawnMarkers, then advances to the
## next wave once every spawned enemy is dead. After MAX_WAVE is survived the match
## is considered won by survival (extraction may also win earlier).
##
## Attach at runtime under the Arena (anywhere; it resolves the Arena via owner /
## tree). Drives spawning through Arena.get_enemy_spawn_point(index) and adds
## children directly to Net/Enemies. Guarded so only the local authority server runs
## the simulation — clients receive enemies through the MultiplayerSpawner.

const ENEMY_SCENE := "res://scenes/enemies/RobotEnemy.tscn"
const MAX_WAVE: int = 5

# Per-archetype scenes. Guarded at spawn time so a missing file falls back to the
# grunt rather than deadlocking the wave.
const SCENE_GRUNT := "res://scenes/enemies/RobotEnemy.tscn"
const SCENE_TICK := "res://scenes/enemies/RobotTick.tscn"
const SCENE_HEAVY := "res://scenes/enemies/RobotHeavy.tscn"
const SCENE_WASP := "res://scenes/enemies/RobotWasp.tscn"
const SCENE_BASTION := "res://scenes/enemies/RobotBastion.tscn"
const SCENE_BOSS := "res://scenes/enemies/RobotBoss.tscn"

# Escalating type mix per wave. Each entry is a weighted pool the trickle spawner
# samples for every non-boss enemy. Wave 5 is the boss wave (handled specially:
# one boss is force-spawned first, then this support pool fills the rest).
#   w1: grunts only            w2: + ticks
#   w3: + wasp + heavy         w4: + bastion (heavier mix)
const WAVE_POOLS := {
	1: [SCENE_GRUNT, SCENE_GRUNT, SCENE_GRUNT],
	2: [SCENE_GRUNT, SCENE_GRUNT, SCENE_TICK, SCENE_TICK],
	3: [SCENE_GRUNT, SCENE_TICK, SCENE_WASP, SCENE_HEAVY],
	4: [SCENE_GRUNT, SCENE_TICK, SCENE_WASP, SCENE_HEAVY, SCENE_BASTION],
	5: [SCENE_GRUNT, SCENE_TICK, SCENE_WASP, SCENE_HEAVY, SCENE_BASTION],
}

var _arena: Node3D = null
var _enemies_container: Node = null
var _alive_enemies: Array[Node] = []
var _wave_active: bool = false
var _started: bool = false
var _wave_total: int = 0      # enemies to spawn this wave
var _wave_spawned: int = 0    # enemies spawned so far this wave
var _boss_spawned: bool = false   # boss-wave: ensures exactly one boss is spawned

# Wave watchdog: once the whole wave has spawned, if the alive count stops dropping
# for WATCHDOG_STALL seconds (a straggler jammed somewhere unreachable), relocate
# every alive enemy onto open navmesh near a player so the wave can always finish.
const WATCHDOG_STALL: float = 12.0
var _watchdog_time: float = 0.0

func _ready() -> void:
	# Resolve the Arena root and the enemy container. The Arena exposes
	# get_enemy_spawn_point(index); enemies live under Net/Enemies.
	_arena = _resolve_arena()
	if _arena:
		_enemies_container = _arena.get_node_or_null("Net/Enemies")

	# Only the server (or offline host) drives waves. Clients just watch.
	if not GameState.is_local_authority_server():
		return

	# entity_died lets us decrement reliably even if an enemy frees out of band.
	if not Events.entity_died.is_connected(_on_entity_died):
		Events.entity_died.connect(_on_entity_died)

	# Begin when the match starts. Offline arena emits match_started immediately on
	# load, which may have already fired before we attached, so guard with a check.
	if not Events.match_started.is_connected(_on_match_started):
		Events.match_started.connect(_on_match_started)
	if GameState.phase == GameState.Phase.IN_MATCH:
		_on_match_started.call_deferred()

func _resolve_arena() -> Node3D:
	# Prefer the scene owner (we're attached under the Arena), else walk up.
	if owner is Node3D and owner.has_method("get_enemy_spawn_point"):
		return owner as Node3D
	var n: Node = get_parent()
	while n != null:
		if n is Node3D and n.has_method("get_enemy_spawn_point"):
			return n as Node3D
		n = n.get_parent()
	return null

func _on_match_started() -> void:
	if _started:
		return
	if not GameState.is_local_authority_server():
		return
	_started = true
	GameState.current_wave = 0
	_start_next_wave()

func _start_next_wave() -> void:
	var next := GameState.current_wave + 1
	if next > MAX_WAVE:
		_on_all_waves_survived()
		return
	GameState.current_wave = next
	_wave_total = _enemy_count_for_wave(next)
	_wave_spawned = 0
	_boss_spawned = false
	_wave_active = true
	_alive_enemies.clear()
	_watchdog_time = 0.0
	Events.wave_started.emit(next, _wave_total)
	# Can't spawn (scene missing / no container)? Don't deadlock the match.
	if not ResourceLoader.exists(ENEMY_SCENE) or _enemies_container == null:
		_finish_wave()
		return
	_spawn_loop()

## Trickle spawner: keeps at most WAVE_MAX_CONCURRENT enemies alive, adding one
## every WAVE_SPAWN_INTERVAL until the whole wave has been spawned. Re-arms itself
## (a freed slot from a kill is filled on the next tick) until _wave_spawned hits
## _wave_total; the wave then clears once the last enemy dies (_on_entity_died).
func _spawn_loop() -> void:
	if not _wave_active:
		return
	if _wave_spawned < _wave_total and _alive_enemies.size() < Settings.WAVE_MAX_CONCURRENT:
		_spawn_enemy(_wave_spawned, _scene_for_spawn())
		_wave_spawned += 1
	if _wave_spawned < _wave_total:
		get_tree().create_timer(Settings.WAVE_SPAWN_INTERVAL).timeout.connect(_spawn_loop)

## Belt-and-suspenders so a wave can never deadlock on an unreachable straggler.
## Only meaningful once the wave is fully spawned; if the alive count holds steady
## for WATCHDOG_STALL seconds, un-stick every survivor (relocate near a player).
func _process(delta: float) -> void:
	if not _wave_active or not GameState.is_local_authority_server():
		return
	# NOTE: do NOT gate on "fully spawned" — stuck enemies fill the concurrency cap
	# (WAVE_MAX_CONCURRENT), which stalls spawning, so the wave would never report
	# fully-spawned and the watchdog would never run. The 12 s timer below is the grace
	# window; legit enemies have closed within 55 m by then.
	_watchdog_time += delta
	if _watchdog_time < WATCHDOG_STALL:
		return
	_watchdog_time = 0.0
	# Relocate any straggler still far from EVERY player. This late in a fully-spawned
	# wave a real chaser would have closed in, so a >55 m enemy is marooned (covers
	# stuck ranged archetypes that the per-enemy melee stuck-check intentionally skips).
	# Legit ranged enemies sit at their 15–22 m stand-off, well inside 55 m — untouched.
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return
	for e in _alive_enemies:
		if not is_instance_valid(e) or not (e is Node3D):
			continue
		var nd := INF
		for pl in players:
			if pl is Node3D:
				nd = minf(nd, (e as Node3D).global_position.distance_to((pl as Node3D).global_position))
		if nd > 55.0 and e.has_method("force_unstuck"):
			e.force_unstuck()

func _enemy_count_for_wave(wave: int) -> int:
	var base := Settings.WAVE_BASE_ENEMIES + (wave - 1) * Settings.WAVE_ENEMY_GROWTH
	# Difficulty scales the wave size (Easy thins it, Hard swells it). Always >= 1.
	var count_mult: float = float(Settings.difficulty_mods().get("enemy_count", 1.0))
	return maxi(1, int(round(base * count_mult)))

## Choose which enemy scene to spawn next based on the current wave's pool. On the
## final wave the boss is force-spawned first (once); the rest draw from the
## support pool. Missing scenes fall back to the grunt so a wave never deadlocks.
func _scene_for_spawn() -> String:
	var wave: int = GameState.current_wave
	if wave >= MAX_WAVE and not _boss_spawned:
		_boss_spawned = true
		if ResourceLoader.exists(SCENE_BOSS):
			return SCENE_BOSS
		# No boss art — fall through to a heavy so the final wave still bites.
		return SCENE_BASTION if ResourceLoader.exists(SCENE_BASTION) else SCENE_GRUNT
	var pool: Array = WAVE_POOLS.get(wave, [SCENE_GRUNT])
	if pool.is_empty():
		return SCENE_GRUNT
	var pick: String = pool[randi() % pool.size()]
	return pick if ResourceLoader.exists(pick) else SCENE_GRUNT

func _spawn_enemy(index: int, scene_path: String = ENEMY_SCENE) -> void:
	if not ResourceLoader.exists(scene_path):
		push_warning("WaveManager: %s not present — skipping enemy spawn" % scene_path)
		return
	if _enemies_container == null:
		push_warning("WaveManager: Net/Enemies container not found — cannot spawn")
		return
	var enemy: Node = (load(scene_path) as PackedScene).instantiate()
	# Ensure it's discoverable as an enemy even if the scene forgot the group.
	if not enemy.is_in_group("enemies"):
		enemy.add_to_group("enemies")
	# Wave enemies actively hunt the player so survival waves stay aggressive on the
	# big map (they path in from their nest instead of idling).
	if "hunter" in enemy:
		enemy.hunter = true
	_enemies_container.add_child(enemy, true)
	# Position at a spawn marker after entering the tree (global_transform needs it).
	if enemy is Node3D and _arena:
		(enemy as Node3D).global_transform = _arena.get_enemy_spawn_point(index)
	_alive_enemies.append(enemy)
	Events.enemy_spawned.emit(enemy)

func _on_entity_died(entity: Node, _killer: Node) -> void:
	if not _wave_active:
		return
	if entity == null or not entity.is_in_group("enemies"):
		return
	_alive_enemies.erase(entity)
	# Cleared only once the whole wave has spawned AND every enemy is dead.
	if _wave_spawned >= _wave_total and _alive_enemies.is_empty():
		_finish_wave()

func _finish_wave() -> void:
	if not _wave_active:
		return
	_wave_active = false
	var cleared := GameState.current_wave
	Events.wave_cleared.emit(cleared)
	if cleared >= MAX_WAVE:
		_on_all_waves_survived()
		return
	# Intermission, then the next wave.
	get_tree().create_timer(Settings.WAVE_INTERMISSION).timeout.connect(_start_next_wave)

func _on_all_waves_survived() -> void:
	# All scripted waves cleared. Survival itself counts as a win condition; the
	# extraction zone may have already won earlier. Emit once.
	if GameState.all_players_resolved():
		return
	NetworkManager.broadcast_match_won()
