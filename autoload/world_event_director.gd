extends Node
## WorldEventDirector — mid-raid dynamic event scheduler.
##
## Server-authoritative only (clients receive enemies/loot via MultiplayerSpawners
## and learn about events through the Events bus signals).
##
## DO NOT add class_name WorldEventDirector — the autoload name collides with a class_name
## and Godot will refuse to parse it. The lead registers this as autoload "WorldEventDirector".
##
## Four event kinds (mirror Events.gd comment):
##   0  supply_cache   — a guarded loot cache; players hold it to crack it open.
##   1  miniboss       — an Elite roamer; kill it for a currency reward.
##   2  contested_poi  — a POI goes hot with extra guards for CONTESTED_POI_DURATION s.
##   3  surge          — enemy-surge burst (extra spawns) for SURGE_DURATION s.
##
## "world_events" group convention (for Lane C — map / HUD):
##   All event markers AND SupplyCache instances are added to the group "world_events".
##   Every node in the group exposes:
##     get_meta("event_kind")  -> int   (0/1/2/3, matches the kind enum above)
##     get_meta("event_label") -> String
##     func event_ratio()      -> float (0..1 progress or countdown; meaning is kind-specific)
##   Optional:
##     get_meta("event_pos")   -> Vector3  (world position of the event)
##   For timed events (kind 2, 3) event_ratio() counts DOWN from 1→0 over the duration.
##   For supply cache (kind 0) event_ratio() counts UP from 0→1 as the hold fills.
##   For miniboss (kind 1) event_ratio() returns 0 (boss has no public fill progress).
##   The SupplyCache Area3D (kind 0) exposes the same interface + func event_label()->String.

# ─── internal state ──────────────────────────────────────────────────────────

var _active: bool = false            # true once match_started fires
var _active_kind: int = -1           # -1 = idle, 0-3 = busy
var _timer: float = 0.0              # counts up toward _next_fire
var _next_fire: float = 0.0          # seconds until next event attempt

# Lazy-cached scene references (re-located if freed).
var _wave_manager: Node = null
var _arena: Node = null

# Cached references set during an active event.
var _active_cache: Node = null       # kind 0: the SupplyCache Area3D
var _active_miniboss: Node = null    # kind 1: the tracked Elite node
var _active_marker: Node3D = null    # kind 2/3: the simple Node3D map marker
var _event_elapsed: float = 0.0     # time since current event started (for timeouts)

# Max lifetime for events that don't self-complete (keeps the scheduler unblocked).
const CACHE_MAX_LIFETIME: float = 120.0
const MINIBOSS_MAX_LIFETIME: float = 120.0
const CONTESTED_LIFETIME_PAD: float = 5.0   # extra slop over CONTESTED_POI_DURATION

# The SupplyCache scene path (written by THIS workstream).
const SUPPLY_CACHE_SCENE := "res://scenes/world/SupplyCache.tscn"

# ─── lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	Events.match_started.connect(_on_match_started)
	Events.entity_died.connect(_on_entity_died)
	if Events.has_signal("match_won"):
		Events.match_won.connect(_on_match_over)
	if Events.has_signal("match_lost"):
		Events.match_lost.connect(_on_match_over)
	# If the match is already running when this autoload finishes _ready (possible
	# when reloading mid-session), arm immediately.
	if GameState.phase == GameState.Phase.IN_MATCH:
		_on_match_started.call_deferred()

func _on_match_started() -> void:
	if not GameState.is_local_authority_server():
		return
	_active = true
	_active_kind = -1
	_timer = 0.0
	_next_fire = Settings.WORLD_EVENT_FIRST_DELAY
	_event_elapsed = 0.0
	_wave_manager = null
	_arena = null
	_active_cache = null
	_active_miniboss = null
	_active_marker = null

func _on_match_over() -> void:
	_active = false
	_active_kind = -1
	_clear_active_event_nodes()

func _clear_active_event_nodes() -> void:
	if is_instance_valid(_active_cache):
		_active_cache.queue_free()
	_active_cache = null
	if is_instance_valid(_active_marker):
		_active_marker.queue_free()
	_active_marker = null
	_active_miniboss = null

# ─── main scheduler tick ─────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _active or not GameState.is_local_authority_server():
		return
	# Suspend scheduling during the final storm wave.
	if GameState.final_wave:
		return

	if _active_kind >= 0:
		# An event is running — tick its lifetime and check for timeout fallbacks.
		_event_elapsed += delta
		_tick_active_event(delta)
		return

	# Idle: count down to next event.
	_timer += delta
	if _timer >= _next_fire:
		_timer = 0.0
		_fire_random_event()
		_arm_next(_rearm_interval())

func _rearm_interval() -> float:
	var jitter: float = randf_range(-Settings.WORLD_EVENT_JITTER, Settings.WORLD_EVENT_JITTER)
	return Settings.WORLD_EVENT_INTERVAL + jitter

func _arm_next(delay: float) -> void:
	_next_fire = maxf(delay, 15.0)   # never less than 15 s between events

func _fire_random_event() -> void:
	# Weighted pick (supply_cache and miniboss more interesting than surge).
	var kind: int = randi() % 4
	# Guard-needing events (cache/mini-boss/contested) must have spawn capacity, else they'd
	# appear UNDEFENDED (spawn_reinforcements would silently no-op at the alive-cap). If there's
	# no room, fall back to the surge (it needs no guards) so an event still fires.
	if kind != 3 and _guards_capacity() <= 0:
		kind = 3
	match kind:
		0: _start_supply_cache()
		1: _start_miniboss()
		2: _start_contested_poi()
		3: _start_surge()

## Remaining enemy-spawn headroom (via the WaveManager); 99 if the manager isn't found yet.
func _guards_capacity() -> int:
	var wm: Node = _get_wave_manager()
	if wm != null and wm.has_method("reinforcement_capacity"):
		return int(wm.call("reinforcement_capacity"))
	return 99

# ─── event lifetime tick (timeout fallbacks) ─────────────────────────────────

func _tick_active_event(delta: float) -> void:
	match _active_kind:
		0:  # supply cache — the cache itself drives completion; guard max lifetime.
			if _event_elapsed >= CACHE_MAX_LIFETIME:
				_end_supply_cache_timeout()
		1:  # miniboss — watch entity_died; guard max lifetime.
			if _event_elapsed >= MINIBOSS_MAX_LIFETIME:
				_end_miniboss(false)
		2:  # contested POI — timed duration.
			if _event_elapsed >= Settings.CONTESTED_POI_DURATION + CONTESTED_LIFETIME_PAD:
				_end_contested_poi(true)
		3:  # surge — timed duration.
			if _event_elapsed >= Settings.SURGE_DURATION + 1.0:
				_end_surge(true)

# ─── helpers: scene tree lookups ────────────────────────────────────────────

func _get_wave_manager() -> Node:
	if is_instance_valid(_wave_manager):
		return _wave_manager
	# Search the whole scene for the WaveManager (child of Arena).
	if get_tree() == null:
		return null
	for node in get_tree().get_nodes_in_group("arena"):
		if is_instance_valid(node) and node.has_method("get_poi_points"):
			# Found the arena; look for the WaveManager child.
			var wm: Node = node.get_node_or_null("WaveManager")
			if wm == null:
				# Fallback: scan all children.
				for child in node.get_children():
					if child.has_method("spawn_reinforcements"):
						wm = child
						break
			if wm != null and wm.has_method("spawn_reinforcements"):
				_wave_manager = wm
				return _wave_manager
	# Broader tree scan in case WaveManager lives elsewhere.
	_wave_manager = _find_by_method(get_tree().root, "spawn_reinforcements")
	return _wave_manager

func _get_arena() -> Node:
	if is_instance_valid(_arena):
		return _arena
	if get_tree() == null:
		return null
	for node in get_tree().get_nodes_in_group("arena"):
		if is_instance_valid(node) and node.has_method("get_poi_points"):
			_arena = node
			return _arena
	return null

func _find_by_method(from: Node, method: String) -> Node:
	if from.has_method(method):
		return from
	for child in from.get_children():
		var found: Node = _find_by_method(child, method)
		if found != null:
			return found
	return null

## Returns a random squad-member position for near-squad spawning, or (0,5,0) fallback.
func _squad_pos() -> Vector3:
	if get_tree() == null:
		return Vector3(0.0, 5.0, 0.0)
	var players: Array = get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return Vector3(0.0, 5.0, 0.0)
	var p: Node = players[randi() % players.size()]
	if p is Node3D:
		return (p as Node3D).global_position
	return Vector3(0.0, 5.0, 0.0)

## Returns a list of (index, tier) pairs sorted descending by tier.
func _poi_by_tier(arena: Node) -> Array:
	var result: Array = []
	if not arena.has_method("get_poi_points"):
		return result
	var points: Array[Vector3] = arena.get_poi_points()
	for i in range(points.size()):
		var tier: int = arena.get_poi_tier(i)
		result.append([i, tier, points[i]])
	result.sort_custom(func(a, b): return a[1] > b[1])
	return result

## Returns world position of the highest-tier POI (or squad pos if no arena).
func _high_tier_poi_pos(arena: Node) -> Vector3:
	var by_tier: Array = _poi_by_tier(arena)
	if by_tier.is_empty():
		return _squad_pos()
	return by_tier[0][2] as Vector3

func _net_loot_container(arena: Node) -> Node:
	if arena == null:
		return null
	return arena.get_node_or_null("Net/Loot")

## Creates a plain Node3D map marker in the "world_events" group at `world_pos`.
func _make_marker(world_pos: Vector3, kind: int, label: String, until_elapsed: float) -> Node3D:
	var marker := Node3D.new()
	marker.global_position = world_pos
	marker.set_meta("event_kind", kind)
	marker.set_meta("event_label", label)
	marker.set_meta("event_pos", world_pos)
	marker.set_meta("_until_elapsed", until_elapsed)
	marker.add_to_group("world_events")
	# Attach a script-method so Lane C can call event_ratio() without a cast.
	# We store the director ref so the method can compute from _event_elapsed.
	marker.set_meta("_director_ref", self)
	marker.set_meta("_duration", until_elapsed)
	# GDScript doesn't support anonymous lambdas assigned to method overrides, so
	# Lane C should call: marker.get_meta("_director_ref").marker_event_ratio(marker)
	# OR use the helper below via marker.get_meta("event_kind") + event_ratio().
	return marker

## Lane C helper: returns the countdown ratio (1→0) for a marker node. Call as:
##   director.marker_event_ratio(marker_node)  where director = get_meta("_director_ref")
func marker_event_ratio(marker: Node) -> float:
	if marker == null or not is_instance_valid(marker):
		return 0.0
	var duration: float = float(marker.get_meta("_duration", 1.0))
	if duration <= 0.0:
		return 0.0
	return clampf(1.0 - (_event_elapsed / duration), 0.0, 1.0)

# ─── EVENT 0: Supply Cache ────────────────────────────────────────────────────

func _start_supply_cache() -> void:
	var arena: Node = _get_arena()
	var wm: Node = _get_wave_manager()

	# Pick the highest-tier POI for maximum drama.
	var cache_pos: Vector3 = Vector3(0.0, 0.5, 0.0)
	var tier: int = 2
	if arena != null:
		var by_tier: Array = _poi_by_tier(arena)
		if not by_tier.is_empty():
			var chosen: Array = by_tier[0]
			tier = chosen[1]
			cache_pos = (chosen[2] as Vector3) + Vector3(randf_range(-3.0, 3.0), 0.5, randf_range(-3.0, 3.0))

	# Instance the cache scene.
	var cache_scene: Resource = load(SUPPLY_CACHE_SCENE)
	if cache_scene == null:
		push_warning("WorldEventDirector: SupplyCache.tscn not found at " + SUPPLY_CACHE_SCENE)
		return

	var cache: Node = cache_scene.instantiate()
	if cache == null:
		push_warning("WorldEventDirector: failed to instantiate SupplyCache")
		return

	# Set tier before adding to tree so _ready can read it.
	if "tier" in cache:
		cache.tier = tier

	# Parent under the arena root (or scene root as fallback) so it's in the world.
	var parent: Node = arena if arena != null else get_tree().current_scene
	parent.add_child(cache)
	if cache is Node3D:
		(cache as Node3D).global_position = cache_pos

	# Connect completion signal so the director clears active when the cache cracks.
	if cache.has_signal("cache_cracked"):
		cache.cache_cracked.connect(_on_cache_cracked)
	# Connect loot container reference so the cache can spawn pickups.
	var net_loot: Node = _net_loot_container(arena)
	if cache.has_method("set_loot_parent") and net_loot != null:
		cache.set_loot_parent(net_loot)

	_active_cache = cache
	_active_kind = 0
	_event_elapsed = 0.0

	# Spawn guards near the cache.
	if wm != null:
		wm.spawn_reinforcements(Settings.SUPPLY_CACHE_GUARDS, cache_pos, true)

	Events.world_event_started.emit(0, cache_pos, "Supply Cache")
	Events.notify.emit("Supply cache detected — hold to crack it open", 1)

func _on_cache_cracked() -> void:
	# Called back from the SupplyCache on successful crack.
	_active_kind = -1
	_active_cache = null
	# world_event_ended(0, true) is emitted by the cache itself.

func _end_supply_cache_timeout() -> void:
	if is_instance_valid(_active_cache):
		_active_cache.queue_free()
	_active_cache = null
	Events.world_event_ended.emit(0, false)
	Events.notify.emit("Supply cache lost", 2)
	_active_kind = -1

# ─── EVENT 1: Mini-boss ───────────────────────────────────────────────────────

func _start_miniboss() -> void:
	var wm: Node = _get_wave_manager()
	if wm == null:
		return

	var spawn_pos: Vector3 = _squad_pos()

	# Spawn one RobotElite as the roaming mini-boss.
	wm.spawn_reinforcements(1, spawn_pos, true, "res://scenes/enemies/RobotElite.tscn")

	# Find the freshly-spawned Elite: scan Net/Enemies for the newest RobotElite.
	_active_miniboss = null
	var arena: Node = _get_arena()
	if arena != null:
		var enemies_node: Node = arena.get_node_or_null("Net/Enemies")
		if enemies_node != null:
			# The just-spawned node is typically the last child added.
			var children: Array = enemies_node.get_children()
			for i in range(children.size() - 1, -1, -1):
				var c: Node = children[i]
				if is_instance_valid(c) and "RobotElite" in c.get_class() or _is_elite_node(c):
					_active_miniboss = c
					break
			# Fallback: pick the newest child (it was just added).
			if _active_miniboss == null and not children.is_empty():
				_active_miniboss = children[children.size() - 1]

	# Create a map marker so Lane C can show a skull icon.
	_active_marker = _make_marker(spawn_pos, 1, "Mini-boss", float(MINIBOSS_MAX_LIFETIME))
	# Attach to scene root so it persists even if arena is null.
	var marker_parent: Node = arena if arena != null else get_tree().current_scene
	if marker_parent != null:
		marker_parent.add_child(_active_marker)

	_active_kind = 1
	_event_elapsed = 0.0

	Events.world_event_started.emit(1, spawn_pos, "Mini-boss")
	Events.notify.emit("Hostile Elite detected — eliminate the target", 2)

func _is_elite_node(node: Node) -> bool:
	# Check the scene file path as a reliable identifier.
	var sc: String = node.get_scene_file_path() if node.has_method("get_scene_file_path") else ""
	return sc.contains("RobotElite")

func _on_entity_died(entity: Node, _killer: Node) -> void:
	if not GameState.is_local_authority_server():
		return
	if _active_kind != 1:
		return
	if entity != _active_miniboss:
		return
	_end_miniboss(true)

func _end_miniboss(success: bool) -> void:
	if success:
		# MVP: credit host's profile. Co-op caveat: full per-peer reward needs RPC
		# (each peer calls MetaProgression.earn on its own machine). The host always
		# gets the reward; a client's reward would require NetworkManager involvement
		# (beyond this workstream's scope — wire via a dedicated RPC or Events in a
		# future co-op pass).
		MetaProgression.earn(Settings.MINIBOSS_REWARD_CURRENCY)
		Events.world_event_ended.emit(1, true)
		Events.notify.emit("Mini-boss eliminated! +" + str(Settings.MINIBOSS_REWARD_CURRENCY) + " credits", 1)
	else:
		Events.world_event_ended.emit(1, false)
		Events.notify.emit("Hostile Elite escaped", 2)

	if is_instance_valid(_active_marker):
		_active_marker.queue_free()
	_active_marker = null
	_active_miniboss = null
	_active_kind = -1

# ─── EVENT 2: Contested POI ───────────────────────────────────────────────────

func _start_contested_poi() -> void:
	var arena: Node = _get_arena()
	var wm: Node = _get_wave_manager()

	var poi_pos: Vector3 = _squad_pos()
	var poi_label: String = "Unknown"

	if arena != null:
		var by_tier: Array = _poi_by_tier(arena)
		if not by_tier.is_empty():
			# Pick a random POI from the top half by tier.
			var top_count: int = maxi(1, by_tier.size() / 2)
			var pick_idx: int = randi() % top_count
			var chosen: Array = by_tier[pick_idx]
			poi_pos = chosen[2] as Vector3
			# Derive a short label from the POI index.
			if arena.has_method("get_poi_points"):
				poi_label = _poi_label_for_index(int(chosen[0]))

	var event_label: String = "Contested: " + poi_label

	# Create a map marker for the duration.
	_active_marker = _make_marker(poi_pos, 2, event_label, Settings.CONTESTED_POI_DURATION)
	var marker_parent: Node = arena if arena != null else get_tree().current_scene
	if marker_parent != null:
		marker_parent.add_child(_active_marker)

	_active_kind = 2
	_event_elapsed = 0.0

	if wm != null:
		wm.spawn_reinforcements(Settings.CONTESTED_POI_GUARDS, poi_pos, true)

	Events.world_event_started.emit(2, poi_pos, event_label)
	Events.notify.emit("Hot zone — " + poi_label + " is contested!", 3)

func _poi_label_for_index(idx: int) -> String:
	var labels: Array[String] = ["North Tower", "East Warehouse", "Plaza", "SW House", "South Yard", "East Yard"]
	if idx >= 0 and idx < labels.size():
		return labels[idx]
	return "POI"

func _end_contested_poi(success: bool) -> void:
	if is_instance_valid(_active_marker):
		_active_marker.queue_free()
	_active_marker = null
	Events.world_event_ended.emit(2, success)
	Events.notify.emit("Hot zone cleared", 1)
	_active_kind = -1

# ─── EVENT 3: Surge ──────────────────────────────────────────────────────────

func _start_surge() -> void:
	var wm: Node = _get_wave_manager()
	var squad_pos: Vector3 = _squad_pos()

	# Surge kind 0 = enemy-surge (more spawns).
	var surge_count: int = 4 + randi() % 4   # 4–7 extra enemies

	if wm != null:
		wm.spawn_reinforcements(surge_count, squad_pos, true)

	# Create a marker so the map can show the surge zone.
	var arena: Node = _get_arena()
	_active_marker = _make_marker(squad_pos, 3, "Surge", Settings.SURGE_DURATION)
	var marker_parent: Node = arena if arena != null else get_tree().current_scene
	if marker_parent != null:
		marker_parent.add_child(_active_marker)

	_active_kind = 3
	_event_elapsed = 0.0

	Events.environmental_surge_changed.emit(true, 0)
	Events.world_event_started.emit(3, squad_pos, "Surge")
	Events.notify.emit("Enemy surge incoming!", 2)

func _end_surge(success: bool) -> void:
	Events.environmental_surge_changed.emit(false, 0)
	Events.world_event_ended.emit(3, success)
	Events.notify.emit("Surge subsiding", 0)
	if is_instance_valid(_active_marker):
		_active_marker.queue_free()
	_active_marker = null
	_active_kind = -1
