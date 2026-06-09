extends Node3D
## The match world. Owns the navigation bake and entity containers. Spawning of
## players/enemies/loot is server-driven through the MultiplayerSpawner children
## under Net/. Works offline (no peer => is_server() true) and networked.
##
## Other workstreams plug in here:
##   WS-G  fills in multi-peer player spawning (currently spawns local peer only)
##   WS-F  drives enemy waves via the EnemySpawner + spawn markers
##   WS-B/A provide Player.tscn / RobotEnemy.tscn (loaded if present, else skipped)

const PLAYER_SCENE := "res://scenes/player/Player.tscn"

@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var players: Node3D = $Net/Players
@onready var enemies: Node3D = $Net/Enemies
@onready var loot: Node3D = $Net/Loot
@onready var player_spawn_markers: Node3D = $PlayerSpawnMarkers
@onready var enemy_spawn_markers: Node3D = $EnemySpawnMarkers
@onready var poi_markers: Node3D = $POIMarkers
@onready var loot_cache_markers: Node3D = $LootCacheMarkers

func _ready() -> void:
	# Discoverable by the map UI (which is nested elsewhere and can't reach us via
	# current_scene) for POI/zone-of-interest labels.
	add_to_group("arena")
	# Loot replicates via a CUSTOM spawn_function so each pickup's id/count/pos travel as
	# spawn data — auto-spawn would re-instantiate LootPickup.tscn with its scene defaults
	# on clients (every pickup showed up as "loot_scrap"). Set on EVERY peer (host+client)
	# so both build the same pickup from the replicated data.
	var loot_spawner: MultiplayerSpawner = $Net/LootSpawner
	if loot_spawner != null:
		loot_spawner.spawn_function = Callable(LootPickup, "_spawn_loot")
	# The build below is synchronous + heavy (it used to freeze the window). We now
	# PHASE it: each step emits arena_build_progress (the LoadingScreen advances its bar)
	# and yields a frame so the bar actually repaints between phases. Making _ready a
	# coroutine via these awaits is safe — the node is never freed mid-build, and the
	# deferred navmesh-bake / match-start calls below still run in their original order
	# AFTER the build completes.
	# Procedural TERRAIN first (hills/river/perimeter cliffs replace the flat Ground
	# plane) so buildings sit on its flat y=0 pads and the navmesh bakes the relief.
	Events.arena_build_progress.emit(0.05, "Terrain")
	await get_tree().process_frame
	_build_terrain()
	# Replace the crude hand-placed cube "buildings" with procedural modular
	# structures BEFORE baking so the navmesh routes around the new geometry.
	Events.arena_build_progress.emit(0.30, "Structures")
	await get_tree().process_frame
	_build_poi_structures()
	Events.arena_build_progress.emit(0.55, "Ground detail")
	await get_tree().process_frame
	_enrich_ground()
	# Flora (trees/grass/boulders) after structures; collidable pieces join the bake.
	Events.arena_build_progress.emit(0.75, "Flora")
	await get_tree().process_frame
	_build_flora()
	# Reflection probes (Ultra+RT tier only) — render-only, per-peer cosmetic; placed at
	# the POIs AFTER structures exist. Headless/dedicated skips them inside the builder.
	Events.arena_build_progress.emit(0.82, "Reflections")
	await get_tree().process_frame
	_build_reflection_probes()
	# Localized FogVolume mist pools (render-only, per-peer cosmetic; appear when global
	# volumetric fog is on). Placed at the POIs after structures exist; headless skips inside.
	Events.arena_build_progress.emit(0.86, "Fog zones")
	await get_tree().process_frame
	_build_fog_zones()
	Events.arena_build_progress.emit(0.90, "Navmesh")
	await get_tree().process_frame
	# Bake navmesh from the static geometry so enemy NavigationAgents have a path.
	_bake_navmesh.call_deferred()
	# World loot: scatter tier-appropriate pickups at the pre-placed LootCacheMarkers.
	# Runs AFTER the deferred navmesh bake so ground geometry is final; server-only.
	# NOTE: the ACTUAL spawn is deferred to _on_match_started (see below) — exactly like
	# players. Populating here (during the build) drops loot into Net/Loot BEFORE remote
	# peers' MultiplayerSpawners exist, so it never replicates → clients saw an empty map.
	Events.arena_build_progress.emit(0.96, "World loot")
	await get_tree().process_frame
	Events.arena_build_progress.emit(1.0, "Ready")
	# Wave director (server-only logic guarded inside the script). Child of Arena
	# so its parent-walk finds get_enemy_spawn_point().
	var wm: Node = (load("res://scripts/waves/wave_manager.gd") as Script).new()
	wm.name = "WaveManager"
	add_child(wm)
	if multiplayer.has_multiplayer_peer():
		Events.match_started.connect(_on_match_started)
		# Diagnostic: log replicated entities as they arrive on THIS peer (server or
		# client) so two-process tests can confirm spawners replicate correctly.
		players.child_entered_tree.connect(_on_player_replicated)
		enemies.child_entered_tree.connect(_on_enemy_replicated)
	else:
		# Offline: start right away.
		_on_match_started.call_deferred()

func _on_player_replicated(node: Node) -> void:
	if not Settings.NET_DEBUG:
		return
	# Authority is derived from the node name on every peer (see player.gd).
	var auth := str(node.name).to_int()
	print("[net] player '%s' present under Net/Players (authority=%d) on peer %d" % [
		node.name, auth, multiplayer.get_unique_id()])

func _on_enemy_replicated(node: Node) -> void:
	if not Settings.NET_DEBUG:
		return
	print("[net] enemy '%s' present under Net/Enemies on peer %d" % [
		node.name, multiplayer.get_unique_id()])

# ------------------------------------------------- procedural terrain + flora hooks
## Both builders are GUARDED (load-by-path, no class_name reference) so the arena
## runs before/without those workstreams landing. CONTRACT with the lanes:
##   ProceduralTerrain.build(parent, poi_defs) -> Node3D  (static; adds itself under
##     parent; ALL pads — POI footprints / extraction zones / spawn cluster / plaza /
##     scatter spots — blend to EXACTLY y=0 so markers, zones and buildings keep their
##     authored heights; deterministic from Settings.TERRAIN_SEED only)
##   ProceduralTerrain.height_at(x, z) -> float           (static, pure)
##   ProceduralFlora.build(parent) -> Node3D               (static; deterministic;
##     reads height_at itself; collidable pieces on layer 1 so the bake parses them)
func _build_terrain() -> void:
	var path := "res://scripts/visual/procedural_terrain.gd"
	if not ResourceLoader.exists(path):
		return
	var script: GDScript = load(path)
	if script == null:
		return
	var terrain: Node3D = script.build(nav_region, _POI_DEFS)
	if terrain == null:
		return
	# The terrain REPLACES the flat Ground plane (render + collision). Remove the old
	# plane from the tree immediately so the deferred navmesh bake never parses it.
	var ground := nav_region.get_node_or_null("Ground")
	if ground:
		nav_region.remove_child(ground)
		ground.queue_free()

func _build_flora() -> void:
	var path := "res://scripts/visual/procedural_flora.gd"
	if not ResourceLoader.exists(path):
		return
	var script: GDScript = load(path)
	if script == null:
		return
	script.build(nav_region)

## Ultra+RT tier: spawn baked ReflectionProbes at the POIs for off-screen reflections.
## GUARDED (load-by-path) so the arena runs even without the file; the builder itself
## early-returns on headless and when Settings.reflection_probes_enabled is off. Render-
## only + deterministic (placement derives from POI markers), so it never touches the
## navmesh/collision/netcode.
func _build_reflection_probes() -> void:
	var path := "res://scripts/visual/procedural_reflection_probes.gd"
	if not ResourceLoader.exists(path):
		return
	var script: GDScript = load(path)
	if script == null:
		return
	script.build(self, poi_markers)
	# Experimental VoxelGI (off by default; gated inside on Settings.voxelgi_enabled).
	if script.has_method("build_voxelgi"):
		script.build_voxelgi(self, Vector3(80.0, 24.0, 80.0))

## Localized FogVolume mist pools at a few POIs + river-valley spots. GUARDED (load-by-path)
## so the arena runs even without the file; the builder early-returns on headless and when
## Settings.local_fog_enabled is off. Render-only + deterministic (placement from POI markers
## + fixed river points), so it never touches the navmesh/collision/netcode. The zones only
## render when the active Environment's volumetric fog is on (driven by the quality setting).
func _build_fog_zones() -> void:
	var path := "res://scripts/visual/procedural_fog_zones.gd"
	if not ResourceLoader.exists(path):
		return
	var script: GDScript = load(path)
	if script == null:
		return
	# Pass the player-spawn centroid so the fog zones keep the start corner clear.
	var spawn_center := Vector3(58.0, 0.0, 62.0)
	if player_spawn_markers != null and player_spawn_markers.get_child_count() > 0:
		var acc := Vector3.ZERO
		var n := 0
		for m in player_spawn_markers.get_children():
			if m is Node3D:
				acc += (m as Node3D).global_position
				n += 1
		if n > 0:
			spawn_center = acc / float(n)
	script.build(self, poi_markers, spawn_center)

## POI center (world x,z), theme, and footprint (X×Z meters). Tower/warehouse/house/
## yard are placed at each POI; the three POIs that host an extraction zone use a
## courtyard (open center) so the zone stays reachable, roofless and walkable.
const _POI_DEFS := {
	"POI_NorthTower":    {"theme": "tower",     "x": -40.0, "z": -45.0, "w": 17.0, "d": 15.0, "court": false},
	"POI_EastWarehouse": {"theme": "warehouse", "x":  45.0, "z": -28.0, "w": 22.0, "d": 18.0, "court": true},
	"POI_Plaza":         {"theme": "plaza",     "x":   0.0, "z":   0.0, "w":  0.0, "d":  0.0, "court": false},
	"POI_SWHouse":       {"theme": "house",     "x": -52.0, "z":  30.0, "w": 15.0, "d": 15.0, "court": true},
	"POI_SouthYard":     {"theme": "yard",      "x": -30.0, "z":  50.0, "w": 18.0, "d": 16.0, "court": true},
	"POI_EastYard":      {"theme": "yard",      "x":  50.0, "z":  42.0, "w": 18.0, "d": 16.0, "court": false},
}

## Tears down the old crude POI cubes and instances a themed ProceduralBuildings
## structure at each POI center under NavigationRegion3D/Geometry (so it's parsed by
## the bake). Also rebuilds the Scatter as procedural rubble piles on open ground.
func _build_poi_structures() -> void:
	var geometry := nav_region.get_node_or_null("Geometry") as Node3D
	if geometry == null:
		return
	for poi_name in _POI_DEFS.keys():
		var def: Dictionary = _POI_DEFS[poi_name]
		var old := geometry.get_node_or_null(poi_name)
		if old:
			old.free()
		var theme: String = def["theme"]
		var fp := Vector2(def["w"], def["d"])
		var court: bool = def["court"]
		var building: Node3D = null
		match theme:
			"tower":     building = ProceduralBuildings.build_tower(fp)
			"warehouse": building = ProceduralBuildings.build_warehouse(fp, court)
			"house":     building = ProceduralBuildings.build_house(fp, court)
			"yard":      building = ProceduralBuildings.build_container_yard(fp, court)
			"plaza":     building = ProceduralBuildings.build_plaza_cover()
		if building == null:
			continue
		building.name = poi_name
		building.position = Vector3(def["x"], 0.0, def["z"])
		geometry.add_child(building)
	_rebuild_scatter(geometry)

## Replaces the old Scatter cubes with deterministic procedural rubble piles spread
## across open ground (kept away from POI centers, spawns and extraction zones).
func _rebuild_scatter(geometry: Node3D) -> void:
	var old_scatter := geometry.get_node_or_null("Scatter")
	if old_scatter:
		old_scatter.free()
	var scatter := Node3D.new()
	scatter.name = "Scatter"
	geometry.add_child(scatter)
	# Hand-picked open-ground spots (avoid POIs at ~±40/±50, spawns at +60, zones).
	var spots: Array[Vector3] = [
		Vector3(-15, 0, -20), Vector3(20, 0, 8), Vector3(-25, 0, 5),
		Vector3(30, 0, -55), Vector3(-60, 0, -20), Vector3(60, 0, -5),
		Vector3(15, 0, 55), Vector3(-10, 0, 35), Vector3(5, 0, -35),
		Vector3(-66, 0, -60), Vector3(66, 0, 60), Vector3(-70, 0, 12),
		# Extra debris across open ground for landscape interest (still clear of
		# POIs/spawns/zones — small piles between the existing crossroads).
		Vector3(38, 0, 22), Vector3(-40, 0, -8), Vector3(8, 0, 20),
		Vector3(-18, 0, 58), Vector3(48, 0, 10), Vector3(-48, 0, 56),
		Vector3(22, 0, -10), Vector3(-8, 0, -58),
	]
	for i in range(spots.size()):
		var pile := ProceduralBuildings.rubble_pile(i * 137 + 11)
		pile.position = spots[i]
		scatter.add_child(pile)

## Gives the ground a richer weathered material + a faint large-scale tint plane for
## depth. Collision stays the flat box at y=0 (untouched) so the navmesh is unchanged.
func _enrich_ground() -> void:
	var ground_mesh := nav_region.get_node_or_null("Ground/Mesh") as MeshInstance3D
	if ground_mesh == null:
		return
	# Triplanar noise-detailed asphalt: broad cracks/patches via the shared toolkit
	# (low scale = large-scale features) so the ground reads as worn paving, not flat.
	var asphalt: StandardMaterial3D = ProcMaterials.weathered(
		Color(0.16, 0.165, 0.175), 0.0, 0.95, 0.5, 7,
		Vector3(0.05, 0.05, 0.05), true)
	ground_mesh.set_surface_override_material(0, asphalt)
	# Second, very-low-frequency stain layer (no collision): a large faintly-transparent
	# plane carrying its own coarse grime noise for big tonal patches of dirt/oil.
	var detail := MeshInstance3D.new()
	detail.name = "GroundDetail"
	var pm := PlaneMesh.new()
	pm.size = Vector2(160, 160)
	detail.mesh = pm
	var dm: StandardMaterial3D = ProcMaterials.weathered(
		Color(0.22, 0.19, 0.15), 0.0, 1.0, 0.35, 13,
		Vector3(0.02, 0.02, 0.02), true)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.albedo_color = Color(0.22, 0.19, 0.15, 0.22)
	detail.material_override = dm
	detail.position = Vector3(0, 0.02, 0)
	var ground_body := nav_region.get_node_or_null("Ground")
	if ground_body:
		ground_body.add_child(detail)

func _bake_navmesh() -> void:
	if nav_region and nav_region.navigation_mesh:
		# Align the runtime navigation map's cell height with our NavigationMesh
		# (0.2). The project default map uses 0.25, which otherwise logs a
		# rasterization-mismatch warning and can misplace navmesh edges on the
		# larger ruins map.
		var map := nav_region.get_navigation_map()
		if map.is_valid():
			NavigationServer3D.map_set_cell_height(map, nav_region.navigation_mesh.cell_height)
			NavigationServer3D.map_set_cell_size(map, nav_region.navigation_mesh.cell_size)
		nav_region.bake_navigation_mesh()

# Stable spawn index per peer so each player keeps the same marker, and a guard so
# a peer is never spawned twice (match_started can fire and peers can join while the
# match is already running — both routes funnel through _ensure_player_spawned).
var _spawn_index: Dictionary = {}   # peer_id -> int
var _match_running: bool = false

func _on_match_started() -> void:
	if not GameState.is_local_authority_server():
		return
	_match_running = true
	# Spawn a player for every registered peer. Offline/host => peer 1 included.
	var ids := GameState.peers.keys()
	if ids.is_empty():
		ids = [1]
	if Settings.NET_DEBUG:
		print("[arena] match started — ensuring %d player(s) for peers %s" % [ids.size(), str(ids)])
	for peer_id in ids:
		_ensure_player_spawned(peer_id)
	# World loot is scattered HERE for the same reason players are: only now (after the
	# synchronized deploy) does every peer have its Net/Loot MultiplayerSpawner, so the
	# pickups actually replicate to clients. Guarded internally + idempotent.
	_populate_world_loot()
	# NOTE: players are spawned ONLY here, after the synchronized deploy guarantees
	# EVERY peer has loaded its arena (and thus its MultiplayerSpawner). We deliberately
	# do NOT spawn on peer-register/connect anymore: doing so created a peer's player on
	# the server before that peer's own arena existed, so it never replicated back to
	# them → no camera → grey screen. A peer that connects mid-raid waits in the hub
	# lobby and deploys with the squad next round.

## Idempotent: spawns the Player for `peer_id` exactly once. Safe to call from the
## match-start sweep and from the peer-joined hook.
func _ensure_player_spawned(peer_id: int) -> void:
	if not GameState.is_local_authority_server():
		return
	var node_name := str(peer_id)
	if players.has_node(node_name):
		return
	if not ResourceLoader.exists(PLAYER_SCENE):
		push_warning("Player.tscn not present yet — skipping spawn (peer %d)" % peer_id)
		return
	if not _spawn_index.has(peer_id):
		_spawn_index[peer_id] = _spawn_index.size()
	var index: int = _spawn_index[peer_id]
	var p: Node = (load(PLAYER_SCENE) as PackedScene).instantiate()
	p.name = node_name
	# set_multiplayer_authority BEFORE add_child so the spawn replication carries the
	# right owner; player.gd also re-derives it from the name on every peer.
	if p.has_method("set_multiplayer_authority"):
		p.set_multiplayer_authority(peer_id)
	var marker := _pick_marker(player_spawn_markers, index)
	var mx := marker.global_transform if marker else global_transform
	# With more players than markers (5-8), _pick_marker wraps modulo → players would
	# stack. Offset extras around their marker on a golden-angle ring so they spread.
	var marker_count: int = player_spawn_markers.get_child_count() if player_spawn_markers else 0
	if marker_count > 0 and index >= marker_count:
		var ring: int = index / marker_count
		var ang: float = float(index) * 2.39996323   # golden angle, even spread
		var rad: float = 1.9 * float(ring)
		mx.origin += Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	# Set on the server copy (also the host's own player, which the host owns).
	p.global_transform = mx
	players.add_child(p, true)
	# A CLIENT owns its own transform and ignores the server's spawn position (it would
	# start at world origin), so explicitly tell the owning client where to spawn.
	if peer_id != 1 and multiplayer.has_multiplayer_peer() and not NetworkManager.is_offline:
		p._net_place.rpc_id(peer_id, mx.origin)
	if Settings.NET_DEBUG:
		print("[arena] spawned player '%s' (authority=%d, marker=%d)" % [node_name, peer_id, index])

func get_enemy_spawn_point(index: int) -> Transform3D:
	var m := _pick_marker(enemy_spawn_markers, index)
	var xform: Transform3D = m.global_transform if m else global_transform
	# Markers sit at POI centres which can be INSIDE building geometry; snap the
	# spawn to the nearest walkable navmesh point so enemies never spawn trapped in
	# a wall (off-navmesh → NavigationAgent yields no path → enemy freezes).
	xform.origin = snap_to_navmesh(xform.origin)
	return xform

## Number of enemy spawn markers available. Lets the wave manager rescan EVERY
## marker (not just index % n) when picking a spawn far from the players.
func enemy_marker_count() -> int:
	if enemy_spawn_markers == null:
		return 0
	return enemy_spawn_markers.get_child_count()

## Returns the nearest point on the baked navigation map to `pos`, or `pos`
## unchanged if the map isn't ready / the closest point is implausibly far (a sign
## the map hasn't synced yet). Also used by enemy stuck-recovery.
func snap_to_navmesh(pos: Vector3) -> Vector3:
	if nav_region == null:
		return pos
	var map := nav_region.get_navigation_map()
	if not map.is_valid():
		return pos
	# The map's first synchronization completes a frame or two after baking; querying
	# before that errors. Until it's ready, return pos unchanged (caller keeps the raw
	# marker; the enemy's own stuck-recovery snaps it once the map has synced).
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return pos
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(map, pos)
	# Map not yet synced can return the origin; reject that and absurdly far snaps.
	if snapped == Vector3.ZERO and pos.length() > 1.0:
		return pos
	if snapped.distance_to(pos) > 14.0:
		return pos
	return snapped

## True when a walkable navmesh path exists from `from` to `to` (the path actually
## arrives within `tol` of `to`). Used by the wave spawner so it never drops an enemy
## on a navmesh patch it can't path off (e.g. the wrong side of the river). Returns
## true when the map isn't ready yet (don't block spawns) — the enemy's stuck-recovery
## handles the rare not-yet-synced case.
func navmesh_reachable(from: Vector3, to: Vector3, tol: float = 4.0) -> bool:
	if nav_region == null:
		return true
	var map := nav_region.get_navigation_map()
	if not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) == 0:
		return true
	var path: PackedVector3Array = NavigationServer3D.map_get_path(map, from, to, true)
	if path.size() < 2:
		return false
	# The path is clamped to the navmesh; if its final point lands near `to`, the two
	# points are on the same connected region (reachable).
	return path[path.size() - 1].distance_to(to) <= tol

## Returns the risk tier (1 low … 3 high) for a POI identified either by its
## integer index into the _POI_DEFS insertion order, or by its String name.
## Falls back to tier 1 for unknown indices/names.
func get_poi_tier(which) -> int:
	var name_str: String = ""
	if which is int:
		var keys: Array = _POI_DEFS.keys()
		if which >= 0 and which < keys.size():
			name_str = keys[which]
	elif which is String:
		name_str = which
	return int(Settings.POI_RISK_TIERS.get(name_str, 1))


## World positions of each POI center (north tower, warehouse, plaza, etc.).
## Used by minimap / loot placement. Order matches the POIMarkers children.
func get_poi_points() -> Array[Vector3]:
	return _marker_positions(poi_markers)

## World positions of loot-cache spots seeded across the POIs (roofs, floors,
## container tops, plaza). Used by loot spawning.
func get_loot_cache_points() -> Array[Vector3]:
	return _marker_positions(loot_cache_markers)

func _marker_positions(container: Node) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if container == null:
		return out
	for child in container.get_children():
		if child is Node3D:
			out.append((child as Node3D).global_position)
	return out

## Server-only: scatter world-loot pickups into Net/Loot after the navmesh bake.
## For each loot-cache marker find the nearest POI, look up its risk tier, then
## scatter RISK_TIER_CACHE_COUNT[tier] pickups via LootPickup.spawn_at so they
## replicate to clients through the Net/Loot MultiplayerSpawner.
func _populate_world_loot() -> void:
	if not GameState.is_local_authority_server():
		return
	var cache_points: Array[Vector3] = get_loot_cache_points()
	if cache_points.is_empty():
		return
	var poi_points: Array[Vector3] = get_poi_points()
	if poi_points.is_empty():
		return
	for cache_pos in cache_points:
		# Find the nearest POI centre.
		var best_idx: int = 0
		var best_dist: float = INF
		for i in range(poi_points.size()):
			var d: float = poi_points[i].distance_to(cache_pos)
			if d < best_dist:
				best_dist = d
				best_idx = i
		var tier: int = get_poi_tier(best_idx)
		var count_to_spawn: int = int(Settings.RISK_TIER_CACHE_COUNT.get(tier, 2))
		for _i in range(count_to_spawn):
			var id: String = LootTables.roll_by_tier(tier)
			if id == "":
				continue
			var jitter := Vector3(randf_range(-1.2, 1.2), 0.0, randf_range(-1.2, 1.2))
			LootPickup.spawn_at(loot, cache_pos + jitter, id, 1)


func _pick_marker(container: Node, index: int) -> Node3D:
	if container == null or container.get_child_count() == 0:
		return null
	var children := container.get_children()
	return children[index % children.size()] as Node3D
