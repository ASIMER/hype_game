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
##
## AIDirector changes (Lane B):
##   • _spawn_enemy gains `as_hunter` param (default true — existing behaviour unchanged).
##   • spawn_reinforcements() — public API for AIDirector alarm/flank spawns.
##   • Camp-punish detection (clustered players → flank spawn).
##   • Between-wave patrols (_patrols array, separate from _alive_enemies).
##   • Boss-phase adds (spawn hunter adds when boss health < threshold).
##   • Registers/unregisters itself with AIDirector.

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

# Lane A archetype scenes (guarded with ResourceLoader.exists at spawn time).
const SCENE_CALLER := "res://scenes/enemies/RobotCaller.tscn"
const SCENE_ELITE := "res://scenes/enemies/RobotElite.tscn"

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

# --- Biome fauna scenes (v0.3) — guarded with ResourceLoader.exists at spawn time. ---
const SCENE_WORM := "res://scenes/enemies/RobotSandworm.tscn"
const SCENE_SCARAB := "res://scenes/enemies/RobotScarab.tscn"
const SCENE_DUSTDEVIL := "res://scenes/enemies/RobotDustdevil.tscn"
const SCENE_FROSTHOUND := "res://scenes/enemies/RobotFrosthound.tscn"
const SCENE_CRYOMORTAR := "res://scenes/enemies/RobotCryomortar.tscn"
const SCENE_AVALANCHE := "res://scenes/enemies/RobotAvalanche.tscn"
const SCENE_ONI := "res://scenes/enemies/RobotOni.tscn"
const SCENE_KAPPA := "res://scenes/enemies/RobotKappa.tscn"
const SCENE_RAIJU := "res://scenes/enemies/RobotRaiju.tscn"

# BIOME-EXCLUSIVE wave rosters: every spawn classifies its RESOLVED spawn point through
# WorldBounds.biome_at(x,z) and draws from THAT biome's per-wave pool — so a squad fighting
# in the desert gets worms/scarabs/dust-devils, the snow gets hounds/mortars/avalanches,
# the rain temple gets kappas/raijus/onis, and the original NW "urban" quadrant keeps the
# classic robot roster (WAVE_POOLS above). The wave-5 BOSS stays global (any biome).
const BIOME_WAVE_POOLS := {
	"desert":
	{
		1: [SCENE_SCARAB, SCENE_SCARAB, SCENE_DUSTDEVIL],
		2: [SCENE_SCARAB, SCENE_SCARAB, SCENE_DUSTDEVIL, SCENE_DUSTDEVIL],
		3: [SCENE_SCARAB, SCENE_DUSTDEVIL, SCENE_WORM],
		4: [SCENE_SCARAB, SCENE_DUSTDEVIL, SCENE_DUSTDEVIL, SCENE_WORM],
		5: [SCENE_SCARAB, SCENE_DUSTDEVIL, SCENE_WORM, SCENE_WORM],
	},
	"snow":
	{
		1: [SCENE_FROSTHOUND, SCENE_FROSTHOUND, SCENE_FROSTHOUND],
		2: [SCENE_FROSTHOUND, SCENE_FROSTHOUND, SCENE_CRYOMORTAR],
		3: [SCENE_FROSTHOUND, SCENE_CRYOMORTAR, SCENE_AVALANCHE],
		4: [SCENE_FROSTHOUND, SCENE_FROSTHOUND, SCENE_CRYOMORTAR, SCENE_AVALANCHE],
		5: [SCENE_FROSTHOUND, SCENE_CRYOMORTAR, SCENE_AVALANCHE, SCENE_AVALANCHE],
	},
	"rain":
	{
		1: [SCENE_KAPPA, SCENE_KAPPA, SCENE_RAIJU],
		2: [SCENE_KAPPA, SCENE_KAPPA, SCENE_RAIJU, SCENE_RAIJU],
		3: [SCENE_KAPPA, SCENE_RAIJU, SCENE_ONI],
		4: [SCENE_KAPPA, SCENE_KAPPA, SCENE_RAIJU, SCENE_ONI],
		5: [SCENE_KAPPA, SCENE_RAIJU, SCENE_ONI, SCENE_ONI],
	},
}

# Storm (final-wave flood) mixes per biome; urban keeps STORM_POOL.
const BIOME_STORM_POOLS := {
	"desert": [SCENE_WORM, SCENE_WORM, SCENE_DUSTDEVIL, SCENE_SCARAB, SCENE_SCARAB],
	"snow":
	[SCENE_AVALANCHE, SCENE_AVALANCHE, SCENE_CRYOMORTAR, SCENE_FROSTHOUND, SCENE_FROSTHOUND],
	"rain": [SCENE_ONI, SCENE_ONI, SCENE_RAIJU, SCENE_KAPPA, SCENE_KAPPA],
}

# Between-wave patrol pools per biome. Urban is EMPTY = keep the legacy caller-first
# behaviour. Desert patrols include the WORM — a stealthable burrowed ambusher guarding
# the ruins is exactly the biome's flavour.
const BIOME_PATROL_POOLS := {
	"desert": [SCENE_WORM, SCENE_SCARAB, SCENE_DUSTDEVIL],
	"snow": [SCENE_FROSTHOUND, SCENE_CRYOMORTAR],
	"rain": [SCENE_KAPPA, SCENE_RAIJU],
}

var _arena: Node3D = null
var _enemies_container: Node = null
var _alive_enemies: Array[Node] = []
# Monotonic spawn counter (server-only — wave spawning is authority-gated, so this never
# needs to match across peers). Drives a golden-angle horizontal RING offset per spawn so
# consecutive enemies reusing the SAME marker don't land on the IDENTICAL snapped point and
# VERTICALLY STACK (CharacterBody collision shoves a pile straight up → enemies climbing to
# Y=100+/200+ at one X,Z — the "боты лезут в одну точку вверх" pile). See _jittered_spawn.
var _spawn_seq: int = 0
var _wave_active: bool = false
var _started: bool = false
var _wave_total: int = 0  # enemies to spawn this wave
var _wave_spawned: int = 0  # enemies spawned so far this wave
var _boss_spawned: bool = false  # boss-wave: ensures exactly one boss is spawned

# Wave watchdog: once the whole wave has spawned, if the alive count stops dropping
# for WATCHDOG_STALL seconds (a straggler jammed somewhere unreachable), relocate
# every alive enemy onto open navmesh near a player so the wave can always finish.
const WATCHDOG_STALL: float = 12.0
var _watchdog_time: float = 0.0

# --- Match timer + storm (final overwhelming wave) ---
# While the match is active the server ticks GameState.match_time_left down from
# match_duration. At FINAL_WAVE_WARN seconds we warn once; at 0 we flip into STORM
# mode: ignore MAX_WAVE, raise the alive-cap to FINAL_WAVE_CONCURRENT, spawn on
# FINAL_WAVE_SPAWN_INTERVAL from the toughest pool, and keep refilling an escalating
# stream so the player is physically pressured toward extraction.
var _timer_active: bool = false  # ticking the match clock
var _timer_emit_accum: float = 0.0  # throttle match_timer_changed to ~4x/sec
const TIMER_EMIT_INTERVAL: float = 0.25
var _warned: bool = false  # FINAL_WAVE_WARN notify fired once
var _storm: bool = false  # storm spawning engaged
var _storm_started: bool = false  # final_wave_started emitted once
# Storm pool: the heaviest archetypes, weighted toward the nastiest.
const STORM_POOL := [SCENE_HEAVY, SCENE_BASTION, SCENE_BASTION, SCENE_WASP, SCENE_HEAVY, SCENE_TICK]

# ---------------------------------------------------------------------------
# AIDirector integration — patrols, camp detection, boss-phase adds
# ---------------------------------------------------------------------------

## Between-wave patrol enemies. NOT tracked in _alive_enemies so they never block
## wave-clear accounting. Freed when the next wave starts.
var _patrols: Array[Node] = []

## Camp-punish state. Reset whenever players disperse below the radius threshold.
var _camp_timer: float = 0.0
var _camp_cooldown: float = 0.0  # counts DOWN; 0 = ready to punish again

## Boss-phase adds: spawned once when the boss HP drops below DIRECTOR_BOSS_ADD_HP.
var _boss_adds_spawned: bool = false

## Throttle the boss-HP check so we don't scan every frame.
var _boss_check_accum: float = 0.0
const BOSS_CHECK_INTERVAL: float = 0.5


func _ready() -> void:
	# Discoverable by systems that request reinforcements (recon drone, siege event)
	# without copy-pasting a director-resolution helper.
	add_to_group(Groups.WAVE_MANAGER)
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

	# Register with AIDirector so it can call spawn_reinforcements.
	# Resolved lazily via get_node_or_null so a missing autoload (not yet registered
	# by the lead) is a no-op at runtime rather than a parse-time hard reference error.
	var director: Node = get_node_or_null("/root/AIDirector")
	if director != null:
		director.call("set_wave_manager", self)


func _exit_tree() -> void:
	var director: Node = get_node_or_null("/root/AIDirector")
	if director != null:
		director.call("set_wave_manager", null)


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
	_boss_adds_spawned = false
	# Arm the match clock. reset_match() set match_duration; default it if still 0.
	if GameState.match_duration <= 0.0:
		GameState.match_duration = Settings.MATCH_DURATION
		GameState.match_time_left = Settings.MATCH_DURATION
	_timer_active = true
	_timer_emit_accum = 0.0
	_warned = false
	_storm = false
	_storm_started = false
	Events.match_timer_changed.emit(GameState.match_time_left, GameState.match_duration)
	# Surface the active difficulty so the player can SEE the selected level took effect.
	Events.notify.emit(tr("Difficulty: %s") % tr(_difficulty_name()), 2)
	# Spawn pre-first-wave patrols so the map feels alive from second one.
	_spawn_patrols()
	_start_next_wave()


## Human-readable name of the active difficulty (English source string = CSV key).
func _difficulty_name() -> String:
	match GameState.difficulty:
		GameState.Difficulty.EASY:
			return "EASY"
		GameState.Difficulty.HARD:
			return "HARD"
		_:
			return "NORMAL"


func _start_next_wave() -> void:
	# NOTE: between-wave patrols PERSIST across wave starts (they live in _patrols, which is
	# separate from _alive_enemies, so they never affect _finish_wave's wave-clear accounting).
	# They used to be freed here every wave — which made them spawn, then vanish seconds later,
	# then respawn elsewhere ("the bots disappear and re-spawn"). Now they stay in the world
	# until the player kills them; _spawn_patrols() just tops the population back up.

	# During the storm the gradual 1-5 progression is over: keep the same "wave"
	# spinning and just refill from the storm stream instead of ending the match.
	if _storm:
		_begin_storm_wave()
		return
	var next := GameState.current_wave + 1
	if next > MAX_WAVE:
		_on_all_waves_survived()
		return
	GameState.current_wave = next
	_wave_total = _enemy_count_for_wave(next)
	_wave_spawned = 0
	_boss_spawned = false
	_boss_adds_spawned = false
	_wave_active = true
	_alive_enemies.clear()
	_watchdog_time = 0.0
	# Reset camp timers at wave start so leftover pressure doesn't carry over.
	_camp_timer = 0.0
	Events.wave_started.emit(next, _wave_total)
	NetworkManager.sync_wave(next, _wave_total)  # mirror to co-op clients' HUD
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
	var cap: int = Settings.FINAL_WAVE_CONCURRENT if _storm else Settings.WAVE_MAX_CONCURRENT
	var interval: float = (
		Settings.FINAL_WAVE_SPAWN_INTERVAL if _storm else Settings.WAVE_SPAWN_INTERVAL
	)
	if _wave_spawned < _wave_total and _alive_enemies.size() < cap:
		# Empty scene path → _spawn_enemy resolves the spawn point first and draws the
		# enemy from THAT point's biome pool (biome-exclusive rosters).
		_spawn_enemy(_wave_spawned)
		_wave_spawned += 1
	if _wave_spawned < _wave_total:
		get_tree().create_timer(interval).timeout.connect(_spawn_loop)


## Belt-and-suspenders so a wave can never deadlock on an unreachable straggler.
## Only meaningful once the wave is fully spawned; if the alive count holds steady
## for WATCHDOG_STALL seconds, un-stick every survivor (relocate near a player).
func _process(delta: float) -> void:
	if not GameState.is_local_authority_server():
		return
	_tick_match_timer(delta)
	if not _wave_active:
		return
	# NOTE: do NOT gate on "fully spawned" — stuck enemies fill the concurrency cap
	# (WAVE_MAX_CONCURRENT), which stalls spawning, so the wave would never report
	# fully-spawned and the watchdog would never run. The 12 s timer below is the grace
	# window; legit enemies have closed within 55 m by then.
	_watchdog_time += delta
	if _watchdog_time >= WATCHDOG_STALL:
		_watchdog_time = 0.0
		# Relocate any straggler still far from EVERY player. This late in a fully-spawned
		# wave a real chaser would have closed in, so a >55 m enemy is marooned (covers
		# stuck ranged archetypes that the per-enemy melee stuck-check intentionally skips).
		# Legit ranged enemies sit at their 15–22 m stand-off, well inside 55 m — untouched.
		var players := get_tree().get_nodes_in_group(Groups.PLAYERS)
		if not players.is_empty():
			for e in _alive_enemies:
				if not is_instance_valid(e) or not (e is Node3D):
					continue
				var nd: float = INF
				for pl in players:
					if pl is Node3D:
						nd = minf(
							nd,
							(e as Node3D).global_position.distance_to(
								(pl as Node3D).global_position
							)
						)
				if nd > 55.0 and e.has_method("force_unstuck"):
					e.force_unstuck()

	# --- Camp-punish ---
	_tick_camp_detection(delta)

	# --- Boss-phase adds ---
	_tick_boss_adds(delta)


## Server-auth match clock. Counts match_time_left down, throttle-emits
## match_timer_changed (~4x/sec), warns once at FINAL_WAVE_WARN, and triggers the
## storm at 0. Stops ticking once the match is resolved.
func _tick_match_timer(delta: float) -> void:
	if not _timer_active:
		return
	if GameState.all_players_resolved():
		_timer_active = false
		return
	GameState.match_time_left = maxf(GameState.match_time_left - delta, 0.0)

	# Throttled HUD update.
	_timer_emit_accum += delta
	if _timer_emit_accum >= TIMER_EMIT_INTERVAL or GameState.match_time_left <= 0.0:
		_timer_emit_accum = 0.0
		Events.match_timer_changed.emit(GameState.match_time_left, GameState.match_duration)
		NetworkManager.sync_match_timer(
			GameState.match_time_left, GameState.match_duration, GameState.final_wave
		)

	# One-shot "storm incoming" warning.
	if not _warned and GameState.match_time_left <= Settings.FINAL_WAVE_WARN:
		_warned = true
		Events.notify.emit(tr("Storm incoming — extract!"), 2)

	# Clock expired -> engage the storm (once).
	if GameState.match_time_left <= 0.0 and not _storm_started:
		_trigger_storm()


## Flip the match into STORM mode: ignore MAX_WAVE, raise the alive-cap, spawn faster
## from the toughest pool, and keep refilling an escalating stream until everyone is
## resolved (extract = win, wipe = loss via the existing paths).
func _trigger_storm() -> void:
	_storm = true
	_storm_started = true
	GameState.final_wave = true
	Events.final_wave_started.emit()
	Events.notify.emit(tr("THE STORM HAS ARRIVED"), 2)
	# Flood IMMEDIATELY, even mid-wave — the storm interrupts whatever is happening so
	# pressure spikes the instant the clock runs out. Any already-alive enemies are
	# kept (see _begin_storm_wave) and the cap fills around them.
	_begin_storm_wave()


## Start (or re-arm) one storm "wave". The storm runs as a chain of large refilling
## batches so the alive-cap stays saturated; each batch ends -> the next begins, so
## the match never wins-by-survival while the storm runs.
func _begin_storm_wave() -> void:
	_wave_total = _storm_batch_size()
	_wave_spawned = 0
	_boss_spawned = true  # no scripted boss in the storm batches
	_wave_active = true
	# Keep any already-alive enemies tracked (the storm may interrupt a live wave) so
	# the concurrency cap fills around them rather than double-counting.
	_watchdog_time = 0.0
	# Keep the wave number monotonically climbing so HUDs read an escalating storm.
	GameState.current_wave += 1
	Events.wave_started.emit(GameState.current_wave, _wave_total)
	NetworkManager.sync_wave(GameState.current_wave, _wave_total)
	if not ResourceLoader.exists(ENEMY_SCENE) or _enemies_container == null:
		# Can't spawn — don't busy-loop; just stop the storm spinning.
		_wave_active = false
		return
	_spawn_loop()


## Storm batch size: a late-wave count scaled by FINAL_WAVE_COUNT_MULT.
func _storm_batch_size() -> int:
	var late := _enemy_count_for_wave(MAX_WAVE)
	return maxi(Settings.FINAL_WAVE_CONCURRENT, int(round(late * Settings.FINAL_WAVE_COUNT_MULT)))


func _enemy_count_for_wave(wave: int) -> int:
	var base := Settings.WAVE_BASE_ENEMIES + (wave - 1) * Settings.WAVE_ENEMY_GROWTH
	# Difficulty scales the wave size (Easy thins it, Hard swells it). Always >= 1.
	var count_mult: float = float(Settings.difficulty_mods().get("enemy_count", 1.0))
	return maxi(1, int(round(base * count_mult)))


## Choose which enemy scene to spawn next based on the current wave's pool for the
## given BIOME (of the already-resolved spawn point — see _spawn_enemy). On the final
## wave the boss is force-spawned first (once, any biome); the rest draw from the
## biome's support pool. Missing scenes fall back to the grunt so a wave never deadlocks.
func _scene_for_spawn(biome: String = "urban") -> String:
	var wave: int = GameState.current_wave
	# Storm draws from the biome's heaviest pool — no boss, just an overwhelming stream.
	if _storm:
		var spool: Array = BIOME_STORM_POOLS.get(biome, STORM_POOL)
		var sp: String = spool[randi() % spool.size()]
		return sp if ResourceLoader.exists(sp) else SCENE_GRUNT
	if wave >= MAX_WAVE and not _boss_spawned:
		_boss_spawned = true
		if ResourceLoader.exists(SCENE_BOSS):
			return SCENE_BOSS
		# No boss art — fall through to a heavy so the final wave still bites.
		return SCENE_BASTION if ResourceLoader.exists(SCENE_BASTION) else SCENE_GRUNT
	var pools: Dictionary = BIOME_WAVE_POOLS.get(biome, WAVE_POOLS)
	var pool: Array = pools.get(clampi(wave, 1, MAX_WAVE), [SCENE_GRUNT])
	if pool.is_empty():
		return SCENE_GRUNT
	var pick: String = pool[randi() % pool.size()]
	return pick if ResourceLoader.exists(pick) else SCENE_GRUNT


## World positions of the players enemies will actually chase — alive and NOT downed
## (matching robot_enemy._find_nearest_player, which ignores downed players). Falls back to
## ALL players if everyone is downed, so spawn-side selection still has something to work with.
func _player_positions() -> Array[Vector3]:
	var up: Array[Vector3] = []
	var all: Array[Vector3] = []
	for pl in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if not (pl is Node3D) or not is_instance_valid(pl):
			continue
		var pos: Vector3 = (pl as Node3D).global_position
		all.append(pos)
		var downed: bool = pl.has_method("is_downed") and pl.is_downed()
		var dead: bool = false
		var h: Node = pl.get_node_or_null(Groups.NODE_HEALTH)
		if h != null and "is_dead" in h:
			dead = bool(h.is_dead)
		if not downed and not dead:
			up.append(pos)
	if not up.is_empty():
		return up
	if not all.is_empty():
		return all
	# No player nodes yet (the very first spawns of a match fire before players register in the
	# "players" group). Use the player SPAWN markers as the side-of-river reference so early
	# enemies still spawn on the bank the players will appear on, not stranded across the river.
	if _arena != null and _arena.has_method("get_player_spawn_points"):
		var pts: Array[Vector3] = _arena.get_player_spawn_points()
		return pts
	return all


## True when `pos` is on the SAME side of the river as at least one player (the straight line
## to that player doesn't cross the deep channel). The river splits the map into two banks
## joined only by a narrow bridge/ford; an enemy spawned on the WRONG bank can't path to the
## player and just jitters in place ("боты не идут"). Spawning same-side means a direct walk-in,
## no fragile river crossing. Returns true if it can't be evaluated (no players).
func _spawn_ok_for_players(pos: Vector3, players: Array[Vector3]) -> bool:
	for p in players:
		if not _crosses_river(pos, p):
			return true
	return false


## Sample the straight XZ segment a→b; true if any sample lies over the deep river channel.
func _crosses_river(a: Vector3, b: Vector3) -> bool:
	const SAMPLES: int = 16
	for i in range(SAMPLES + 1):
		var t: float = float(i) / float(SAMPLES)
		var x: float = lerpf(a.x, b.x, t)
		var z: float = lerpf(a.z, b.z, t)
		if ProceduralTerrain._river_dist(x, z) < ProceduralTerrain.RIVER_CHANNEL_HALF:
			return true
	return false


## Pick a spawn transform on the player's side of the river so the enemy can actually walk in.
## Collect EVERY same-side marker, PREFER the ones NEAR a player (the 320×320 map has markers
## in every quadrant — without the proximity filter a wave fans out across the whole world and
## treks in from other biomes, diluting the biome-exclusive roster), then spread enemies evenly
## across the surviving markers (index % count — the de-stack fix). Falls back gracefully:
## near-markers → any same-side marker → the raw index marker.
const NEAR_SPAWN_RADIUS: float = 70.0  # markers within this of a player are "local"


func _spawn_xform(index: int) -> Transform3D:
	if _arena == null:
		return Transform3D.IDENTITY
	var players := _player_positions()
	var n: int = _arena.enemy_marker_count() if _arena.has_method("enemy_marker_count") else 0
	if players.is_empty() or n <= 0:
		return _jittered_spawn(_arena.get_enemy_spawn_point(index))
	var ok: Array[int] = []
	var near: Array[int] = []
	for i in n:
		var origin: Vector3 = _arena.get_enemy_spawn_point(i).origin
		if not _spawn_ok_for_players(origin, players):
			continue
		ok.append(i)
		for p in players:
			if origin.distance_to(p) <= NEAR_SPAWN_RADIUS:
				near.append(i)
				break
	var pick_from: Array[int] = near if not near.is_empty() else ok
	if pick_from.is_empty():
		return _jittered_spawn(_arena.get_enemy_spawn_point(index))
	return _jittered_spawn(_arena.get_enemy_spawn_point(pick_from[index % pick_from.size()]))


## Spread each spawn around its marker on a small golden-angle DISC so a burst of enemies that
## share one marker forms a flat ring (collision resolves them HORIZONTALLY) instead of a
## vertical pile that climbs the Y axis. The offset point is re-snapped to the navmesh so it
## stays walkable; if the snap can't run (map not synced) the small offset is harmless. Uses
## the monotonic `_spawn_seq` so even callers that reuse `index` (reinforcements/flanks) get
## distinct points.
func _jittered_spawn(xform: Transform3D) -> Transform3D:
	var k: int = _spawn_seq
	_spawn_seq += 1
	var ang: float = float(k) * 2.39996323  # golden angle (rad) — even angular spread
	var rad: float = 1.5 + float(k % 5) * 0.7  # 1.5 .. 4.3 m rings, cycling
	var p: Vector3 = xform.origin + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	if _arena != null and _arena.has_method("snap_to_navmesh"):
		p = _arena.snap_to_navmesh(p)
	xform.origin = p
	return xform


## Spawn one enemy. `as_hunter` defaults true (existing wave/storm behaviour).
## Patrols call with `as_hunter = false`; alarms/flanks call with `as_hunter = true`.
## With an EMPTY `scene_path` the spawn point is resolved FIRST and the scene comes
## from that point's BIOME pool — the heart of biome-exclusive rosters.
func _spawn_enemy(index: int, scene_path: String = "", as_hunter: bool = true) -> void:
	if _enemies_container == null:
		push_warning("WaveManager: Net/Enemies container not found — cannot spawn")
		return
	# WHERE first, so the WHAT can be biome-exclusive (xform → biome → pool).
	var xform: Transform3D = _spawn_xform(index)
	if scene_path.is_empty():
		scene_path = _scene_for_spawn(WorldBounds.biome_at(xform.origin.x, xform.origin.z))
	if not ResourceLoader.exists(scene_path):
		push_warning("WaveManager: %s not present — skipping enemy spawn" % scene_path)
		return
	var enemy: Node = (load(scene_path) as PackedScene).instantiate()
	# Ensure it's discoverable as an enemy even if the scene forgot the group.
	if not enemy.is_in_group(Groups.ENEMIES):
		enemy.add_to_group(Groups.ENEMIES)
	# Apply hunter flag only when the property exists (guard against scene variants
	# that may not have it — prevents "Invalid set index" at runtime).
	if "hunter" in enemy:
		enemy.hunter = as_hunter
	_enemies_container.add_child(enemy, true)
	# Position at the pre-resolved marker (reachable side of the river + de-stack jitter).
	if enemy is Node3D and _arena:
		(enemy as Node3D).global_transform = xform
	_alive_enemies.append(enemy)
	Events.enemy_spawned.emit(enemy)


func _on_entity_died(entity: Node, _killer: Node) -> void:
	# Patrol cleanup runs BEFORE the wave-active gate so patrols that die during the
	# intermission (or pre-first-wave window) are properly removed.
	if entity != null and _patrols.has(entity):
		_patrols.erase(entity)

	if not _wave_active:
		return
	if entity == null or not entity.is_in_group(Groups.ENEMIES):
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
	NetworkManager.sync_wave_cleared(cleared)
	# Storm: the team somehow cleared a batch — immediately refill another, no win,
	# no intermission. The storm only ends when everyone is resolved (extract/wipe).
	if _storm:
		_begin_storm_wave.call_deferred()
		return
	if cleared >= MAX_WAVE:
		_on_all_waves_survived()
		return
	# Intermission: spawn patrols then start the next wave after the break.
	_spawn_patrols()
	get_tree().create_timer(Settings.WAVE_INTERMISSION).timeout.connect(_start_next_wave)


func _on_all_waves_survived() -> void:
	# All scripted waves cleared. Survival itself counts as a win condition; the
	# extraction zone may have already won earlier. Emit once.
	if GameState.all_players_resolved():
		return
	NetworkManager.broadcast_match_won()


# ---------------------------------------------------------------------------
# Public API for AIDirector
# ---------------------------------------------------------------------------


## How many more enemies can be spawned before hitting the hard alive ceiling. The
## WorldEventDirector reads this to avoid firing a guard-needing event (cache/contested/
## mini-boss) that would spawn ZERO guards (an undefended event reads as broken).
func reinforcement_capacity() -> int:
	return maxi(0, Settings.FINAL_WAVE_CONCURRENT - (_alive_enemies.size() + _patrols.size()))


## Spawn `count` hunter (or non-hunter) enemies at markers nearest `near_pos`.
## Called by AIDirector for alarm reinforcements and camp-punish flanks.
## Respects FINAL_WAVE_CONCURRENT as a hard alive-count ceiling so it can't
## avalanche. Reinforcements during an active wave count in _alive_enemies;
## patrols (spawned with as_hunter=false via _spawn_patrols) do NOT (they go
## into _patrols instead).
func spawn_reinforcements(
	count: int, near_pos: Vector3, as_hunter: bool = true, scene_path: String = ""
) -> void:
	if not GameState.is_local_authority_server():
		return
	if _enemies_container == null or _arena == null:
		return

	# Resolve scene: caller may override; an EMPTY path stays empty here so the
	# per-spawn helper below can resolve it from each spawn POINT's biome pool.
	var resolved_path: String = scene_path
	if not resolved_path.is_empty() and not ResourceLoader.exists(resolved_path):
		resolved_path = SCENE_GRUNT

	# Hard cap: never let alive count exceed FINAL_WAVE_CONCURRENT.
	var current_alive: int = _alive_enemies.size() + _patrols.size()
	var can_spawn: int = maxi(0, Settings.FINAL_WAVE_CONCURRENT - current_alive)
	var actual: int = mini(count, can_spawn)
	if actual <= 0:
		return

	# Find best spawn markers — pick markers by proximity to near_pos.
	# We cycle through a range of marker indices and pick the closest ones.
	# Arena.get_enemy_spawn_point(index) returns a Transform3D.
	const CANDIDATE_COUNT: int = 16  # how many markers to sample
	var chosen_indices: Array[int] = []
	var best_pairs: Array = []  # Array of [dist, index]

	for i in CANDIDATE_COUNT:
		if not _arena.has_method("get_enemy_spawn_point"):
			break
		var xform: Transform3D = _arena.get_enemy_spawn_point(i)
		var dist: float = xform.origin.distance_to(near_pos)
		best_pairs.append([dist, i])

	# Sort ascending by distance so we pick the closest markers first.
	best_pairs.sort_custom(func(a, b): return a[0] < b[0])

	for j in actual:
		var idx: int = 0
		if j < best_pairs.size():
			idx = int(best_pairs[j][1])
		else:
			idx = j  # fallback: sequential index
		# Spawn the enemy; for reinforcements (as_hunter=true) track in _alive_enemies
		# (handled inside _spawn_enemy_reinforcement below).
		_spawn_enemy_reinforcement(idx, resolved_path, as_hunter)


## Internal helper: like _spawn_enemy but does NOT push to _alive_enemies when
## used for wave-independent patrol spawns (caller handles tracking in _patrols).
## All reinforcement spawns go into _alive_enemies normally.
func _spawn_enemy_reinforcement(index: int, scene_path: String, as_hunter: bool) -> void:
	if _enemies_container == null:
		return
	# WHERE first; an empty path then draws from the spawn point's biome pool.
	var xform: Transform3D = _spawn_xform(index)
	if scene_path.is_empty():
		scene_path = _scene_for_spawn(WorldBounds.biome_at(xform.origin.x, xform.origin.z))
	if not ResourceLoader.exists(scene_path):
		push_warning("WaveManager: reinforcement scene %s missing — skipping" % scene_path)
		return
	var enemy: Node = (load(scene_path) as PackedScene).instantiate()
	if not enemy.is_in_group(Groups.ENEMIES):
		enemy.add_to_group(Groups.ENEMIES)
	if "hunter" in enemy:
		enemy.hunter = as_hunter
	_enemies_container.add_child(enemy, true)
	if enemy is Node3D and _arena:
		(enemy as Node3D).global_transform = xform
	# Reinforcements count toward alive enemies (wave-clear accounting).
	_alive_enemies.append(enemy)
	Events.enemy_spawned.emit(enemy)


# ---------------------------------------------------------------------------
# Camp-punish detection
# ---------------------------------------------------------------------------


func _tick_camp_detection(delta: float) -> void:
	# Only active during a wave (not storm — storm is already overwhelming).
	if not _wave_active or _storm:
		_camp_timer = 0.0
		return

	# Tick the camp cooldown.
	if _camp_cooldown > 0.0:
		_camp_cooldown = maxf(_camp_cooldown - delta, 0.0)

	var players := get_tree().get_nodes_in_group(Groups.PLAYERS)
	if players.is_empty():
		_camp_timer = 0.0
		return

	# Compute centroid of all living (Node3D) players.
	var centroid := Vector3.ZERO
	var count: int = 0
	for pl in players:
		if pl is Node3D and is_instance_valid(pl):
			centroid += (pl as Node3D).global_position
			count += 1
	if count == 0:
		_camp_timer = 0.0
		return
	centroid /= float(count)

	# Check whether ALL players are within the camp radius of the centroid.
	var all_clustered: bool = true
	for pl in players:
		if not (pl is Node3D) or not is_instance_valid(pl):
			continue
		if (pl as Node3D).global_position.distance_to(centroid) > Settings.DIRECTOR_CAMP_RADIUS:
			all_clustered = false
			break

	if all_clustered:
		_camp_timer += delta
		if _camp_timer >= Settings.DIRECTOR_CAMP_TIME and _camp_cooldown <= 0.0:
			# Trigger flank: spawn hunters around/behind the centroid.
			_camp_timer = 0.0
			_camp_cooldown = Settings.DIRECTOR_CAMP_COOLDOWN
			spawn_reinforcements(Settings.DIRECTOR_FLANK_COUNT, centroid, true)
			Events.notify.emit(tr("Flanked!"), 2)
	else:
		# Players dispersed — reset the timer.
		_camp_timer = 0.0


# ---------------------------------------------------------------------------
# Between-wave patrols
# ---------------------------------------------------------------------------


## Spawn non-hunter patrols so the map feels active during intermission.
## Uses the Caller scene (Lane A) when available, falls back to the grunt.
func _spawn_patrols() -> void:
	if not GameState.is_local_authority_server():
		return
	if _enemies_container == null or _arena == null:
		return

	# Patrols PERSIST now, so only TOP UP to a steady target population (PATROL_COUNT live
	# patrols) — replacing ones the player killed — instead of adding a fresh batch each
	# intermission (which would accumulate). Also respect the global alive ceiling.
	# (The patrol SCENE is resolved per spawn point: biome pools, urban = caller/grunt.)
	var need: int = maxi(0, Settings.PATROL_COUNT - _patrols.size())
	var current_alive: int = _alive_enemies.size() + _patrols.size()
	var can_spawn: int = maxi(0, Settings.FINAL_WAVE_CONCURRENT - current_alive)
	var count: int = mini(need, can_spawn)

	for i in count:
		_spawn_patrol_enemy(i)


func _spawn_patrol_enemy(index: int) -> void:
	if _enemies_container == null:
		return
	# WHERE first: spread away from the wave markers, then pick the patrol scene from
	# the spawn point's BIOME pool. New biomes patrol their own fauna (the desert even
	# fields burrowed ambush-WORMS); urban keeps the stealthable Caller/Snitch.
	var marker_offset: int = 8 + index
	var xform: Transform3D = _spawn_xform(marker_offset)
	var biome: String = WorldBounds.biome_at(xform.origin.x, xform.origin.z)
	var scene_path: String
	var pool: Array = BIOME_PATROL_POOLS.get(biome, [])
	if pool.is_empty():
		scene_path = SCENE_CALLER if ResourceLoader.exists(SCENE_CALLER) else SCENE_GRUNT
	else:
		scene_path = pool[randi() % pool.size()]
		if not ResourceLoader.exists(scene_path):
			scene_path = SCENE_GRUNT
	if not ResourceLoader.exists(scene_path):
		return
	var enemy: Node = (load(scene_path) as PackedScene).instantiate()
	if not enemy.is_in_group(Groups.ENEMIES):
		enemy.add_to_group(Groups.ENEMIES)
	# Patrols are NOT hunters — they roam/sense normally so the player can avoid them.
	if "hunter" in enemy:
		enemy.hunter = false
	_enemies_container.add_child(enemy, true)
	if enemy is Node3D and _arena:
		(enemy as Node3D).global_transform = xform
	# Track in _patrols, NOT _alive_enemies.
	_patrols.append(enemy)
	Events.enemy_spawned.emit(enemy)


## Free all surviving patrol enemies. Called at wave start so they never interfere
## with _finish_wave's wave-clear accounting.
func _clear_patrols() -> void:
	for p in _patrols:
		if is_instance_valid(p):
			p.queue_free()
	_patrols.clear()


# ---------------------------------------------------------------------------
# Boss-phase adds
# ---------------------------------------------------------------------------


func _tick_boss_adds(delta: float) -> void:
	if _boss_adds_spawned or not _wave_active:
		return
	# Only check on the final scripted wave (wave 5 = boss wave).
	if GameState.current_wave < MAX_WAVE:
		return
	# Throttle the scan.
	_boss_check_accum += delta
	if _boss_check_accum < BOSS_CHECK_INTERVAL:
		return
	_boss_check_accum = 0.0

	# Find the boss among alive enemies by enemy_id.
	var boss: Node = null
	for e in _alive_enemies:
		if not is_instance_valid(e):
			continue
		# Check enemy_id property (the enemy's archetype string).
		if e.get("enemy_id") == "robot_boss":
			boss = e
			break

	if boss == null:
		return

	# Read Health node (standard pattern: boss has a child named Health with current/max).
	var health_node: Node = boss.get_node_or_null(Groups.NODE_HEALTH)
	if health_node == null:
		return
	var hp_current: float = float(health_node.get("current") if "current" in health_node else 0.0)
	var hp_max: float = float(health_node.get("max_health") if "max_health" in health_node else 1.0)
	if hp_max <= 0.0:
		return

	if hp_current / hp_max <= Settings.DIRECTOR_BOSS_ADD_HP:
		_boss_adds_spawned = true
		# Spawn elite adds near the boss; fall back to heavy if elite not available.
		var add_scene: String = SCENE_ELITE if ResourceLoader.exists(SCENE_ELITE) else SCENE_HEAVY
		if not ResourceLoader.exists(add_scene):
			add_scene = SCENE_GRUNT
		var boss_pos: Vector3 = (boss as Node3D).global_position if boss is Node3D else Vector3.ZERO
		spawn_reinforcements(Settings.DIRECTOR_BOSS_ADD_COUNT, boss_pos, true, add_scene)
		Events.notify.emit(tr("Boss called for backup!"), 2)
