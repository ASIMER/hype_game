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
	add_to_group(Groups.ARENA)
	# Loot replicates via a CUSTOM spawn_function so each pickup's id/count/pos travel as
	# spawn data — auto-spawn would re-instantiate LootPickup.tscn with its scene defaults
	# on clients (every pickup showed up as "loot_scrap"). Set on EVERY peer (host+client)
	# so both build the same pickup from the replicated data.
	var loot_spawner: MultiplayerSpawner = $Net/LootSpawner
	if loot_spawner != null:
		loot_spawner.spawn_function = Callable(LootPickup, "_spawn_loot")
	# Thrown grenades + placed gadgets replicate the same way (id/pos travel as spawn
	# data); NetThrowables dispatches grenade vs gadget. Set on EVERY peer.
	var gadget_spawner: MultiplayerSpawner = $Net/GadgetSpawner
	if gadget_spawner != null:
		gadget_spawner.spawn_function = Callable(NetThrowables, "spawn")
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
	# Localized climate zones (rain/snow/desert) at the 3 far-quadrant landmarks. Render-only,
	# per-peer cosmetic, headless-skipped inside. After fog zones so both share the build budget.
	Events.arena_build_progress.emit(0.88, "Climate")
	await get_tree().process_frame
	_build_climate_zones()
	# Building-detail kits (rooftop/street MultiMeshes + night lamps) and grime decals
	# (scorch/leak-streak/rain-puddle). Render-only, per-peer cosmetic, headless-skipped
	# inside; both live under the Arena ROOT (never NavigationRegion3D), so the golden
	# determinism snapshot is untouched.
	ProceduralBuildingDetail.build(self, _POI_DEFS, _extraction_zone_points())
	ProceduralGrimeDecals.build(self, _POI_DEFS, _scatter_spots)
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
	print(
		(
			"[net] player '%s' present under Net/Players (authority=%d) on peer %d"
			% [node.name, auth, multiplayer.get_unique_id()]
		)
	)


func _on_enemy_replicated(node: Node) -> void:
	if not Settings.NET_DEBUG:
		return
	print(
		(
			"[net] enemy '%s' present under Net/Enemies on peer %d"
			% [node.name, multiplayer.get_unique_id()]
		)
	)


# ------------------------------------------------- procedural terrain + flora hooks
## Direct class calls (every builder has a class_name) — the old guarded load-by-path
## indirection dated from the parallel-lane era and made a file move a SILENT no-op
## world (docs/AUDIT.md F6). CONTRACT:
##   ProceduralTerrain.build(parent, poi_defs, extraction_points) -> Node3D  (static;
##     adds itself under parent; ALL pads — POI footprints / extraction zones / spawn
##     cluster / plaza / scatter spots — blend to EXACTLY y=0 so markers, zones and
##     buildings keep their authored heights; deterministic from Settings.TERRAIN_SEED)
##   ProceduralTerrain.height_at(x, z) -> float           (static, pure)
##   ProceduralFlora.build(parent, poi_defs, extraction_points) -> Node3D  (static;
##     deterministic; reads height_at itself; collidable pieces on layer 1)
## Both receive the SAME _POI_DEFS + the ExtractionZone* positions read off THIS
## scene's nodes — Arena.tscn is the one source for zone coordinates (AUDIT F2).


## XZ centres of this arena's ExtractionZone* children, in scene order. `nw_only`
## filters to the original NW-quadrant zones — the only ones flora ever kept out of.
func _extraction_zone_points(nw_only: bool = false) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	for c in get_children():
		if c is Node3D and str(c.name).begins_with("ExtractionZone"):
			var p: Vector3 = (c as Node3D).position
			if nw_only and (p.x >= WorldBounds.CX or p.z >= WorldBounds.CZ):
				continue
			pts.append(Vector2(p.x, p.z))
	return pts


func _build_terrain() -> void:
	var terrain: Node3D = ProceduralTerrain.build(nav_region, _POI_DEFS, _extraction_zone_points())
	if terrain == null:
		return
	# The terrain REPLACES the flat Ground plane (render + collision). Remove the old
	# plane from the tree immediately so the deferred navmesh bake never parses it.
	var ground := nav_region.get_node_or_null("Ground")
	if ground:
		nav_region.remove_child(ground)
		ground.queue_free()


func _build_flora() -> void:
	# Flora keep-outs cover ALL 12 extraction zones (the old NW-only asymmetry —
	# docs/AUDIT.md F2 — was deliberately closed by the vegetation overhaul: at 4×
	# tree density, trees planting on the 9 new-biome zone pads became a real bug).
	ProceduralFlora.build(nav_region, _POI_DEFS, _extraction_zone_points())


## Ultra+RT tier: spawn baked ReflectionProbes at the POIs for off-screen reflections.
## The builder early-returns on headless and when Settings.reflection_probes_enabled is
## off. Render-only + deterministic (placement derives from POI markers), so it never
## touches the navmesh/collision/netcode.
func _build_reflection_probes() -> void:
	ProceduralReflectionProbes.build(self, poi_markers)
	# Experimental VoxelGI (off by default; gated inside on Settings.voxelgi_enabled).
	ProceduralReflectionProbes.build_voxelgi(self, Vector3(80.0, 24.0, 80.0))


## Localized FogVolume mist pools at a few POIs + river-valley spots. The builder
## early-returns on headless and when Settings.local_fog_enabled is off. Render-only +
## deterministic (placement from POI markers + fixed river points), so it never touches
## the navmesh/collision/netcode. The zones only render when the active Environment's
## volumetric fog is on (driven by the quality setting).
func _build_fog_zones() -> void:
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
	ProceduralFogZones.build(self, poi_markers, spawn_center)


## Localized climate zones (rain over the Temple, snow over the Lodge, sand-haze over
## the Ruins) at the 3 far-quadrant landmarks. The builder early-returns on headless and
## when Settings.climate_zones_enabled is off. Render-only + deterministic (placement
## from the POI markers), so it never touches the navmesh/collision/netcode.
func _build_climate_zones() -> void:
	ProceduralClimateZones.build(self, poi_markers)


## POI center (world x,z), theme, and footprint (X×Z meters). Tower/warehouse/house/
## yard are placed at each POI; the three POIs that host an extraction zone use a
## courtyard (open center) so the zone stays reachable, roofless and walkable.
## NOTE: the POIMarkers children in Arena.tscn MUST be in the SAME ORDER as these keys —
## get_poi_tier(idx) indexes _POI_DEFS.keys() by the POIMarker index, and power/loot caches
## map by POIMarker order. The first 6 are the ORIGINAL NW-quadrant POIs (unchanged); the next
## 6 are the new POIs across the +X/+Z quadrants (paired with the Phase-3 climate zones):
## NE→snow (lodge+depot), SW→desert (ruins×2), SE→rain (temple+shrine house).
const _POI_DEFS := {
	"POI_NorthTower":
	{"theme": "tower", "x": -40.0, "z": -45.0, "w": 17.0, "d": 15.0, "court": false},
	"POI_EastWarehouse":
	{"theme": "warehouse", "x": 45.0, "z": -28.0, "w": 22.0, "d": 18.0, "court": true},
	"POI_Plaza": {"theme": "plaza", "x": 0.0, "z": 0.0, "w": 0.0, "d": 0.0, "court": false},
	"POI_SWHouse": {"theme": "house", "x": -52.0, "z": 30.0, "w": 15.0, "d": 15.0, "court": true},
	"POI_SouthYard": {"theme": "yard", "x": -30.0, "z": 50.0, "w": 18.0, "d": 16.0, "court": true},
	"POI_EastYard": {"theme": "yard", "x": 50.0, "z": 42.0, "w": 18.0, "d": 16.0, "court": false},
	# --- NE quadrant: SNOW (alpine) ---
	"POI_SnowLodge":
	{"theme": "snow_lodge", "x": 160.0, "z": -10.0, "w": 22.0, "d": 18.0, "court": false},
	"POI_SnowDepot":
	{"theme": "warehouse", "x": 205.0, "z": 40.0, "w": 20.0, "d": 16.0, "court": false},
	# --- SW quadrant: DESERT (ruins) ---
	"POI_DesertRuins":
	{"theme": "desert_ruins", "x": 0.0, "z": 158.0, "w": 24.0, "d": 22.0, "court": false},
	"POI_RuinColumns":
	{"theme": "desert_ruins", "x": 45.0, "z": 205.0, "w": 16.0, "d": 14.0, "court": false},
	# --- SE quadrant: RAIN (Japanese temple) ---
	"POI_Temple": {"theme": "temple", "x": 160.0, "z": 158.0, "w": 22.0, "d": 22.0, "court": false},
	"POI_ShrineHouse":
	{"theme": "house", "x": 205.0, "z": 205.0, "w": 14.0, "d": 14.0, "court": false},
}


## Tears down the old crude POI cubes and instances a themed ProceduralBuildings
## structure at each POI center under NavigationRegion3D/Geometry (so it's parsed by
## the bake). Also rebuilds the Scatter as procedural rubble piles on open ground.
func _build_poi_structures() -> void:
	var geometry := nav_region.get_node_or_null("Geometry") as Node3D
	if geometry == null:
		return
	_annexes.clear()
	ProceduralBuildings._glass_seq = 0  # per-build window-pick determinism (co-op parity)
	ProceduralBuildings._chunk_seq = 0  # per-build BreakableChunk id determinism (co-op parity)
	ChunkMeshMerger.reset()  # merged chunk-render batches rebuild per arena
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
			"tower":
				building = ProceduralBuildings.build_tower(fp)
			"warehouse":
				building = ProceduralBuildings.build_warehouse(fp, court)
			"house":
				building = ProceduralBuildings.build_house(fp, court)
			"yard":
				building = ProceduralBuildings.build_container_yard(fp, court)
			"plaza":
				building = ProceduralBuildings.build_plaza_cover()
			"temple":
				building = ProceduralBuildings.build_temple(fp)
			"snow_lodge":
				building = ProceduralBuildings.build_snow_lodge(fp)
			"desert_ruins":
				building = ProceduralBuildings.build_desert_ruins(fp)
		if building == null:
			continue
		building.name = poi_name
		building.position = Vector3(def["x"], 0.0, def["z"])
		geometry.add_child(building)
		# Batch C: the 3 landmark POIs get a key-locked loot annex bolted on just
		# outside their footprint (door facing away from the landmark).
		if Settings.LOCKED_ROOM_POIS.has(poi_name):
			_build_locked_annex(geometry, poi_name, def)
	_rebuild_scatter(geometry)
	# Batch all breakable cells queued by the builders above into per-(parent, material)
	# MultiMeshes — the draw-call fix that makes the fine 0.8 m destruction grid affordable.
	ChunkMeshMerger.flush()


# Locked-annex roots built this arena (batch C) — read by _populate_locked_loot.
var _annexes: Array[Node3D] = []
# Rubble-pile world positions from the last _rebuild_scatter — fed to ProceduralGrimeDecals.
var _scatter_spots: Array[Vector3] = []
var _locked_loot_done: bool = false  # idempotence: begin_match can re-fire


## Build + place the key-locked annex for landmark `poi_name`: just outside the
## footprint on a ProcHash-picked cardinal side, door (+Z) facing OUTWARD from the
## landmark, floor seated on the real terrain (the annex sits off the flattened y=0
## pad). Under the navmesh Geometry node so the bake routes around its walls (and the
## closed door seals the interior out of the navmesh entirely).
func _build_locked_annex(geometry: Node3D, poi_name: String, def: Dictionary) -> void:
	var cfg: Dictionary = Settings.LOCKED_ROOM_POIS[poi_name]
	var idx: int = _POI_DEFS.keys().find(poi_name)
	var seed_val: int = 7100 + idx * 131
	const ANNEX_W := 5.0
	const ANNEX_D := 4.2
	const ANNEX_H := 3.0
	var stale := geometry.get_node_or_null("%s_Annex" % poi_name)
	if stale:
		stale.free()
	var annex := ProceduralBuildings.locked_annex(
		ANNEX_W, ANNEX_D, ANNEX_H, String(cfg["theme"]), String(cfg["key"]), seed_val
	)
	annex.name = "%s_Annex" % poi_name
	var sides: Array[Vector3] = [
		Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)
	]
	var dir: Vector3 = sides[int(ProcHash.hf(seed_val + 9) * 4.0) % 4]
	var clearance: float = maxf(float(def["w"]), float(def["d"])) * 0.5 + ANNEX_D * 0.5 + 0.8
	var pos := Vector3(def["x"], 0.0, def["z"]) + dir * clearance
	pos.y = ProceduralTerrain.height_at(pos.x, pos.z)
	annex.position = pos
	# Door wall is the annex's local +Z — face it outward (away from the landmark).
	annex.rotation.y = atan2(dir.x, dir.z)
	geometry.add_child(annex)
	_annexes.append(annex)


## Replaces the old Scatter cubes with deterministic procedural rubble piles spread
## across open ground (kept away from POI centers, spawns and extraction zones).
func _rebuild_scatter(geometry: Node3D) -> void:
	var old_scatter := geometry.get_node_or_null("Scatter")
	if old_scatter:
		old_scatter.free()
	var scatter := Node3D.new()
	scatter.name = "Scatter"
	geometry.add_child(scatter)
	_scatter_spots.clear()
	# Hand-picked open-ground spots (avoid POIs at ~±40/±50, spawns at +60, zones).
	var spots: Array[Vector3] = [
		Vector3(-15, 0, -20),
		Vector3(20, 0, 8),
		Vector3(-25, 0, 5),
		Vector3(30, 0, -55),
		Vector3(-60, 0, -20),
		Vector3(60, 0, -5),
		Vector3(15, 0, 55),
		Vector3(-10, 0, 35),
		Vector3(5, 0, -35),
		Vector3(-66, 0, -60),
		Vector3(66, 0, 60),
		Vector3(-70, 0, 12),
		# Extra debris across open ground for landscape interest (still clear of
		# POIs/spawns/zones — small piles between the existing crossroads).
		Vector3(38, 0, 22),
		Vector3(-40, 0, -8),
		Vector3(8, 0, 20),
		Vector3(-18, 0, 58),
		Vector3(48, 0, 10),
		Vector3(-48, 0, 56),
		Vector3(22, 0, -10),
		Vector3(-8, 0, -58),
	]
	var pile_positions: Array[Vector3] = []
	for i in range(spots.size()):
		pile_positions.append(spots[i])
		_scatter_spots.append(spots[i])
	# NEW quadrants (NE/SW/SE): rubble across the open areas for cover + landscape interest, so
	# the new biomes don't read as empty. These have no flat pad, so they sit on the rolling
	# terrain via height_at (rocks following the hills look natural). Clear of POIs/evac zones.
	var new_spots: Array[Vector2] = [
		Vector2(110, -45),
		Vector2(185, 5),
		Vector2(130, 60),
		Vector2(215, 10),  # NE snow
		Vector2(-55, 100),
		Vector2(30, 165),
		Vector2(-60, 195),
		Vector2(10, 210),  # SW desert
		Vector2(110, 180),
		Vector2(180, 105),
		Vector2(210, 160),
		Vector2(150, 210),  # SE rain
	]
	for j in range(new_spots.size()):
		var s2: Vector2 = new_spots[j]
		var p2 := Vector3(s2.x, ProceduralTerrain.height_at(s2.x, s2.y), s2.y)
		pile_positions.append(p2)
		_scatter_spots.append(p2)
	# BATCHED rubble: same per-pile chunk math/seeds (cover geometry identical), but
	# ~150 per-chunk draws collapse into 3 map-wide MultiMeshes; collision stays one
	# StaticBody3D per pile so the navmesh input is unchanged.
	ProceduralBuildingDetail.rubble_field(scatter, pile_positions)


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
		if not nav_region.bake_finished.is_connected(_verify_navmesh_commit):
			nav_region.bake_finished.connect(_verify_navmesh_commit)
		nav_region.bake_navigation_mesh()


## The threaded bake sometimes finishes WITHOUT its result ever syncing into the
## runtime navigation map (a per-boot race on the 320x320 mesh): the NavigationMesh
## resource holds all polygons, yet map queries answer "empty" — closest_point
## returns the origin and every agent path comes back unreachable, so ground
## enemies freeze at spawn. Verify the map actually answers after the bake and
## heal it by forcing a map sync / re-registering the region.
func _verify_navmesh_commit() -> void:
	if nav_region == null or nav_region.navigation_mesh == null:
		return
	var map := nav_region.get_navigation_map()
	if not map.is_valid():
		return
	# Probe with a vertex of the baked mesh itself (region is at the world origin,
	# so mesh-local == global). Any vertex must be on the map; prefer one away from
	# the origin so an "empty map returns ZERO" reply can never false-pass.
	var verts: PackedVector3Array = nav_region.navigation_mesh.get_vertices()
	if verts.is_empty():
		push_warning("[arena] navmesh bake produced NO vertices — enemy pathing dead")
		return
	var probe: Vector3 = verts[0]
	for v in verts:
		if v.length_squared() > 16.0:
			probe = v
			break
	var tree := get_tree()
	var waited := 0.0
	var toggles := 0
	while waited < 20.0:
		NavigationServer3D.map_force_update(map)
		var got: Vector3 = NavigationServer3D.map_get_closest_point(map, probe)
		if got.distance_to(probe) <= 2.0:
			# Up to ~1s with no re-registration is the NORMAL post-bake sync latency
			# (bake_finished fires before the map's next sync) — only warn beyond it.
			if toggles > 0 or waited > 1.0:
				push_warning(
					(
						(
							"[arena] navmesh map was empty after bake — healed in %.1fs "
							+ "(%d re-registrations, map iteration %d)"
						)
						% [waited, toggles, NavigationServer3D.map_get_iteration_id(map)]
					)
				)
			return
		# Give the engine's own post-bake sync one ~1s grace window first; after
		# that, re-register the region so the next sync re-ingests the baked mesh
		# (the lost-update race leaves the map empty forever otherwise).
		if waited >= 1.0:
			nav_region.enabled = false
			nav_region.enabled = true
			toggles += 1
		for i in range(30):
			await tree.physics_frame
		# The arena can be torn down mid-verify (restart / match end) — resuming a
		# coroutine on a freed node would error-spam every awaited frame.
		if not is_instance_valid(self) or not is_inside_tree() or nav_region == null:
			return
		waited += 0.5
	push_warning("[arena] navmesh map STILL empty after heal retries — enemy pathing degraded")


# Stable spawn index per peer so each player keeps the same marker, and a guard so
# a peer is never spawned twice (match_started can fire and peers can join while the
# match is already running — both routes funnel through _ensure_player_spawned).
var _spawn_index: Dictionary = {}  # peer_id -> int
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
	_populate_locked_loot()
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
		var ang: float = float(index) * 2.39996323  # golden angle, even spread
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


## Number of enemy spawn markers. Lets the wave manager round-robin over all markers
## (not just index % n) when it needs to pick a spawn the player can actually reach.
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


## World positions of the player spawn markers. The wave manager uses these as the side-of-river
## reference for the FIRST spawns of a match, before any player node has registered in the
## "players" group, so early enemies still spawn on the bank the players will appear on.
func get_player_spawn_points() -> Array[Vector3]:
	return _marker_positions(player_spawn_markers)


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
	# Batch C "double_loot" mutator: every world-loot count is doubled (rolled on the
	# server BEFORE the arena built, so it's already synced by the time we populate).
	var loot_mult: int = 2 if GameState.raid_mutator == "double_loot" else 1
	for cache_pos in cache_points:
		var best_idx: int = _nearest_poi_index(cache_pos, poi_points)
		var tier: int = get_poi_tier(best_idx)
		var count_to_spawn: int = int(Settings.RISK_TIER_CACHE_COUNT.get(tier, 2)) * loot_mult
		for _i in range(count_to_spawn):
			var id: String = LootTables.roll_by_tier(tier)
			if id == "":
				continue
			var jitter := Vector3(randf_range(-1.2, 1.2), 0.0, randf_range(-1.2, 1.2))
			LootPickup.spawn_at(loot, cache_pos + jitter, id, 1)
	# GENEROUS: scatter findable loot across the OPEN areas of the new quadrants too (not just
	# at the POI caches), so the new biomes have things to find between landmarks.
	_scatter_field_loot(poi_points)
	_populate_power_caches()


## Index of the nearest POI centre to `pos` (−1 if there are no POIs). Shared by the cache
## loop + the field-loot scatter so both derive the loot tier the same way.
func _nearest_poi_index(pos: Vector3, poi_points: Array[Vector3]) -> int:
	var best_idx: int = -1
	var best_dist: float = INF
	for i in range(poi_points.size()):
		var d: float = poi_points[i].distance_to(pos)
		if d < best_dist:
			best_dist = d
			best_idx = i
	return best_idx


## Server-only: scatter "field loot" across the OPEN areas of the 3 NEW quadrants (the L-shaped
## region where x>82 OR z>82 — the original NW quadrant keeps its current density). Walks a grid,
## jitters each point, skips anything inside a POI footprint (the POI caches already cover those),
## derives the tier from the nearest POI, snaps to the navmesh (ground), and spawns 1-2 items.
## Host-authoritative + replicated via the Net/Loot spawner exactly like the cache loot.
func _scatter_field_loot(poi_points: Array[Vector3]) -> void:
	var step: float = 28.0
	var lo: float = -60.0
	var hi: float = 212.0  # inset from the new walls (240/−80) so loot stays off the berm
	var x: float = lo
	while x <= hi:
		var z: float = lo
		while z <= hi:
			# NEW region only (NE/SW/SE) — skip the original NW quadrant (x≤82 AND z≤82).
			if x <= 82.0 and z <= 82.0:
				z += step
				continue
			var px: float = x + randf_range(-step * 0.4, step * 0.4)
			var pz: float = z + randf_range(-step * 0.4, step * 0.4)
			var flat := Vector3(px, 0.0, pz)
			var pidx: int = _nearest_poi_index(flat, poi_points)
			# Keep loot in the OPEN — skip points sitting on a POI building footprint.
			if pidx >= 0 and poi_points[pidx].distance_to(flat) < 16.0:
				z += step
				continue
			var tier: int = get_poi_tier(pidx) if pidx >= 0 else 1
			var pos: Vector3 = snap_to_navmesh(Vector3(px, 0.6, pz))
			var count: int = 2 if tier >= 3 else 1  # richer biomes drop a bit more
			if GameState.raid_mutator == "double_loot":
				count *= 2
			for _i in range(count):
				var id: String = LootTables.roll_by_tier(tier)
				if id == "":
					continue
				var j := Vector3(randf_range(-0.8, 0.8), 0.0, randf_range(-0.8, 0.8))
				LootPickup.spawn_at(loot, pos + j, id, 1)
			z += step
		x += step


## Server-only: high-tier loot INSIDE each locked annex, at the builder-tagged local
## `loot_points`. Deliberately NOT snapped to the navmesh — the sealed interior is
## navmesh-dark (the closed door blocked the bake), which also means enemies never
## path inside; the room is a safe payoff once the key is spent. Replicates via the
## Net/Loot spawner like all world loot.
func _populate_locked_loot() -> void:
	if not GameState.is_local_authority_server():
		return
	# Idempotent: begin_match can re-fire for a later joiner — never double-fill.
	if _locked_loot_done:
		return
	_locked_loot_done = true
	for annex in _annexes:
		if not is_instance_valid(annex):
			continue
		var pts: Array = annex.get_meta("loot_points", [])
		var spawned: int = 0
		for p in pts:
			if spawned >= Settings.LOCKED_LOOT_ROLLS:
				break
			var id: String = LootTables.roll_by_tier(3)
			if id == "":
				continue
			var world_p: Vector3 = annex.to_global(Vector3(p)) + Vector3.UP * 0.45
			LootPickup.spawn_at(loot, world_p, id, 1)
			spawned += 1


## Scatter a few Power Caches (Vampire-Survivors-style buff chests) at POI centres, snapped to
## the navmesh so they sit on walkable ground. Server-only; replicated via the Net/Loot spawner
## like world loot. Opening one (interact) plays the non-blocking reveal then grants a timed buff.
func _populate_power_caches() -> void:
	if not GameState.is_local_authority_server():
		return
	var poi_points: Array[Vector3] = get_poi_points()
	if poi_points.is_empty():
		return
	# Original NW POIs: ~half get a cache (i%2). EVERY new-quadrant POI (index ≥ 6) gets one so
	# the new biomes all have a booster (was only the even ones → SnowLodge/DesertRuins/Temple).
	for i in range(poi_points.size()):
		var is_new_poi: bool = i >= 6
		if i % 2 != 0 and not is_new_poi:
			continue
		var pos: Vector3 = (
			poi_points[i] + Vector3(randf_range(-2.5, 2.5), 0.0, randf_range(-2.5, 2.5))
		)
		pos = snap_to_navmesh(pos)
		LootPickup.spawn_at(loot, pos, "power_cache", 1)
	# Plus a couple of scattered boosters in the OPEN areas of each new biome (between POIs).
	var extra_caches: Array[Vector3] = [
		Vector3(130.0, 0.6, 12.0),
		Vector3(195.0, 0.6, 15.0),  # NE snow
		Vector3(-30.0, 0.6, 185.0),
		Vector3(60.0, 0.6, 175.0),  # SW desert
		Vector3(135.0, 0.6, 135.0),
		Vector3(195.0, 0.6, 185.0),  # SE rain
	]
	for c in extra_caches:
		LootPickup.spawn_at(loot, snap_to_navmesh(c), "power_cache", 1)


func _pick_marker(container: Node, index: int) -> Node3D:
	if container == null or container.get_child_count() == 0:
		return null
	var children := container.get_children()
	return children[index % children.size()] as Node3D
