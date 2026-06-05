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
	# Replace the crude hand-placed cube "buildings" with procedural modular
	# structures BEFORE baking so the navmesh routes around the new geometry.
	_build_poi_structures()
	_enrich_ground()
	# Bake navmesh from the static geometry so enemy NavigationAgents have a path.
	_bake_navmesh.call_deferred()
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
	var asphalt := StandardMaterial3D.new()
	asphalt.albedo_color = Color(0.16, 0.165, 0.175)
	asphalt.roughness = 0.97
	asphalt.metallic = 0.0
	ground_mesh.set_surface_override_material(0, asphalt)
	# Subtle dirt-tint detail plane slightly above the ground (no collision), large
	# and faintly transparent so it reads as weathering variation, not a hard layer.
	var detail := MeshInstance3D.new()
	detail.name = "GroundDetail"
	var pm := PlaneMesh.new()
	pm.size = Vector2(160, 160)
	detail.mesh = pm
	var dm := StandardMaterial3D.new()
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.albedo_color = Color(0.22, 0.19, 0.15, 0.18)
	dm.roughness = 1.0
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
	# Spawn for anyone who joins after the match has already begun.
	if not Events.peer_registered.is_connected(_on_peer_registered):
		Events.peer_registered.connect(_on_peer_registered)

func _on_peer_registered(peer_id: int, _info: Dictionary) -> void:
	# A peer joining mid-match gets a player immediately; pre-match joins are handled
	# by the _on_match_started sweep above.
	if _match_running:
		_ensure_player_spawned(peer_id)

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
	players.add_child(p, true)
	if marker:
		p.global_transform = marker.global_transform
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

func _pick_marker(container: Node, index: int) -> Node3D:
	if container == null or container.get_child_count() == 0:
		return null
	var children := container.get_children()
	return children[index % children.size()] as Node3D
