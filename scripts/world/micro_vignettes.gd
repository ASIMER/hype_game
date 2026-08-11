## M5.4 RUNTIME micro-vignettes — 4-7 tiny "someone was here" scenes scattered across the
## 320×320 rect each raid (a wrecked convoy, a roadside shrine, a downed drone, a warning
## totem, a cracked stash), so wandering between the authored POIs keeps paying off.
##
## GOLDEN-SNAPSHOT CONTRACT: nothing in here may run at arena BUILD time. This is a RUNTIME
## server-side spawn (exactly like wave enemies and the field loot) invoked from the
## match-start hook, so the procedural world pipeline — and therefore
## tools/lint/golden_world.json — stays byte-identical. ALL randomness comes from a LOCAL
## RandomNumberGenerator seeded by the caller; never Time-based entropy.
##
## CO-OP (v1 scope): the PROPS are built server-side only and are NOT replicated, so a
## joined client sees the loot but not the wreck around it. Accepted for v1 — the payoff
## (loot) travels through the normal Net/Loot MultiplayerSpawner. See docs/WIRING_M54.md.
##
## Everything is render-only: MeshInstance3D / OmniLight3D / GPUParticles3D, no collision,
## no physics, no navmesh contribution (the bake already ran, and it parses colliders only).
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>` — every local is typed.
class_name MicroVignettes

enum Template { CONVOY, SHRINE, DRONE, TOTEM, STASH }

const ROOT_NAME: String = "MicroVignettes"
const COUNT_MIN: int = 4
const COUNT_MAX: int = 7
const TEMPLATE_COUNT: int = 5

# Placement rules (all metres, flat XZ distances).
const EDGE_INSET: float = 16.0  # keep off the perimeter berm/walls
const KEEPOUT_SPAWN: float = 25.0  # never in the squad's deploy pocket
const KEEPOUT_EXTRACT: float = 12.0  # never inside an evac courtyard
const KEEPOUT_POI: float = 20.0  # never on a POI building footprint
const MIN_SEPARATION: float = 34.0  # vignettes must feel like separate finds
const TRIES_PER_POINT: int = 60
const MAX_SLOPE_DROP: float = 1.6  # reject cliff edges — props must sit ON the ground
const SLOPE_PROBES: Array[Vector2] = [
	Vector2(2.5, 0.0), Vector2(-2.5, 0.0), Vector2(0.0, 2.5), Vector2(0.0, -2.5)
]

# Verified item ids (the `id` field inside resources/items/*.tres — NOT the filename).
const LOOT_SCRAP: String = "loot_scrap"
const LOOT_PLASTIC: String = "loot_plastic"
const LOOT_CIRCUIT: String = "loot_circuit"
const LOOT_CELL: String = "loot_cell"
const LOOT_CHEMICALS: String = "loot_chemicals"
const LOOT_MEDKIT: String = "loot_medkit"
const LOOT_ARTIFACT: String = "loot_artifact"

# Shared material cache — 7 vignettes must not allocate 40 near-identical materials.
static var _mat_cache: Dictionary = {}


## Server-only entry point: place the raid's micro-vignettes and return how many landed.
## `arena` is the Arena node (the props are parented under a single "MicroVignettes" child),
## `loot_root` is Net/Loot (LootPickup.spawn_at routes through its sibling spawner so the
## drops replicate), `rng_seed` seeds the LOCAL rng — pass a per-raid value.
## Idempotent: a second call while the root still exists is a no-op (begin_match can
## re-fire for a late joiner).
static func spawn_all(arena: Node, loot_root: Node, rng_seed: int) -> int:
	if arena == null or not is_instance_valid(arena):
		return 0
	if not GameState.is_local_authority_server():
		return 0
	if arena.get_node_or_null(NodePath(ROOT_NAME)) != null:
		return 0
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var points: Array[Vector3] = _pick_points(arena, rng)
	if points.is_empty():
		return 0
	var root := Node3D.new()
	root.name = ROOT_NAME
	arena.add_child(root)
	for p in points:
		var holder := Node3D.new()
		root.add_child(holder)
		holder.global_position = p
		holder.rotation.y = rng.randf_range(-PI, PI)
		_build_one(holder, loot_root, rng)
	return points.size()


# ------------------------------------------------------------------- placement
## Rejection-sample open ground: inside the inset rect, clear of the deploy pocket / evac
## zones / POI footprints / the river channel / each other, and flat enough to sit on.
static func _pick_points(arena: Node, rng: RandomNumberGenerator) -> Array[Vector3]:
	var keepouts: Array[Vector4] = _keepouts(arena)
	var want: int = rng.randi_range(COUNT_MIN, COUNT_MAX)
	var lo_x: float = WorldBounds.X_MIN + EDGE_INSET
	var hi_x: float = WorldBounds.X_MAX - EDGE_INSET
	var lo_z: float = WorldBounds.Z_MIN + EDGE_INSET
	var hi_z: float = WorldBounds.Z_MAX - EDGE_INSET
	var out: Array[Vector3] = []
	var tries: int = 0
	var budget: int = TRIES_PER_POINT * want
	while out.size() < want and tries < budget:
		tries += 1
		var x: float = rng.randf_range(lo_x, hi_x)
		var z: float = rng.randf_range(lo_z, hi_z)
		if not _is_open(x, z, keepouts, out):
			continue
		out.append(Vector3(x, ProceduralTerrain.height_at(x, z), z))
	return out


static func _is_open(x: float, z: float, keepouts: Array[Vector4], placed: Array[Vector3]) -> bool:
	var flat := Vector2(x, z)
	for k in keepouts:
		if flat.distance_to(Vector2(k.x, k.z)) < k.w:
			return false
	for p in placed:
		if flat.distance_to(Vector2(p.x, p.z)) < MIN_SEPARATION:
			return false
	# water_surface_at returns NaN off-river — a non-NaN means we're over the channel.
	if not is_nan(ProceduralTerrain.water_surface_at(x, z)):
		return false
	return _is_flat(x, z)


## Reject slopes/cliff lips: props are placed on one Y, so a steep spot leaves them floating.
static func _is_flat(x: float, z: float) -> bool:
	var h: float = ProceduralTerrain.height_at(x, z)
	var lo: float = h
	var hi: float = h
	for o in SLOPE_PROBES:
		var s: float = ProceduralTerrain.height_at(x + o.x, z + o.y)
		lo = minf(lo, s)
		hi = maxf(hi, s)
	return hi - lo <= MAX_SLOPE_DROP


## Circular no-place zones packed as Vector4 (x/z = ground-plane centre, w = radius; y
## unused): the deploy pocket, every player spawn marker, every POI, every evac zone.
## Arena accessors are duck-typed so this file never hard-depends on arena.gd's shape.
static func _keepouts(arena: Node) -> Array[Vector4]:
	var out: Array[Vector4] = [Vector4(0.0, 0.0, 0.0, KEEPOUT_SPAWN)]
	if arena.has_method("get_player_spawn_points"):
		var spawns: Array = arena.get_player_spawn_points()
		for s in spawns:
			var sp: Vector3 = s
			out.append(Vector4(sp.x, 0.0, sp.z, KEEPOUT_SPAWN))
	if arena.has_method("get_poi_points"):
		var pois: Array = arena.get_poi_points()
		for p in pois:
			var pp: Vector3 = p
			out.append(Vector4(pp.x, 0.0, pp.z, KEEPOUT_POI))
	var tree: SceneTree = arena.get_tree()
	if tree == null:
		return out
	for n in tree.get_nodes_in_group(Groups.EXTRACTION):
		var zone := n as Node3D
		if zone == null or not zone.is_inside_tree():
			continue
		var zp: Vector3 = zone.global_position
		out.append(Vector4(zp.x, 0.0, zp.z, KEEPOUT_EXTRACT))
	return out


# ------------------------------------------------------------------- templates
static func _build_one(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	match rng.randi_range(0, TEMPLATE_COUNT - 1):
		Template.CONVOY:
			_build_convoy(holder, loot_root, rng)
		Template.SHRINE:
			_build_shrine(holder, loot_root, rng)
		Template.DRONE:
			_build_drone(holder, loot_root, rng)
		Template.TOTEM:
			_build_totem(holder, rng)
		_:
			_build_stash(holder, loot_root, rng)


## BROKEN CONVOY — 2-3 burnt-out box-frame hulks nose-to-tail with scattered wheels, and
## the salvage the last crew never came back for lying between them.
static func _build_convoy(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	var hull: StandardMaterial3D = _mat(Color(0.13, 0.13, 0.14), 0.85, 0.55)
	var rubber: StandardMaterial3D = _mat(Color(0.07, 0.07, 0.08), 0.95, 0.0)
	var wrecks: int = rng.randi_range(2, 3)
	for i in range(wrecks):
		var z: float = -4.6 + float(i) * 5.4 + rng.randf_range(-0.6, 0.6)
		var lean: float = rng.randf_range(-0.22, 0.22)
		var yaw: float = rng.randf_range(-0.5, 0.5)
		var body: MeshInstance3D = _box(holder, Vector3(2.4, 1.5, 5.0), Vector3(0.0, 0.75, z), hull)
		body.rotation = Vector3(0.0, yaw, lean)
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var cab: MeshInstance3D = _box(
			holder, Vector3(2.2, 1.1, 1.6), Vector3(0.0, 1.75, z - 1.5), hull
		)
		cab.rotation = Vector3(0.0, yaw, lean)
		# One wheel knocked clean off, lying flat in the dirt beside the hulk (a CylinderMesh
		# is already Y-axis, so flat is the UNROTATED pose — only a settle tilt is added).
		var side: float = 1.9 if rng.randf() < 0.5 else -1.9
		var wheel: MeshInstance3D = _cyl(
			holder, 0.55, 0.34, Vector3(side, 0.17, z + rng.randf_range(-1.4, 1.4)), rubber
		)
		wheel.rotation = Vector3(rng.randf_range(-0.22, 0.22), 0.0, rng.randf_range(-0.22, 0.22))
	# Loot sits BESIDE the hulks, never under one: LootPickup.spawn_at snaps down onto the
	# terrain (layer 1) and these props are render-only, so a drop inside the 2.4 m-wide
	# hull footprint (|x| < 1.2, wheels out to 2.45) would end up buried inside the mesh.
	_drop(loot_root, holder, Vector3(3.1, 0.4, 0.4), LOOT_SCRAP, 2)
	_drop(loot_root, holder, Vector3(-3.0, 0.4, -2.6), LOOT_PLASTIC, 1)


## FIELD SHRINE — a stacked stone cairn with a candle still burning on top. Someone made it
## this far, and someone came back to mark it.
static func _build_shrine(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	var stone: StandardMaterial3D = _mat(Color(0.42, 0.40, 0.37), 0.95, 0.0)
	var y: float = 0.0
	var w: float = 1.15
	for i in range(4):
		var h: float = 0.34 - float(i) * 0.05
		var slab: MeshInstance3D = _box(
			holder, Vector3(w, h, w), Vector3(0.0, y + h * 0.5, 0.0), stone
		)
		slab.rotation.y = rng.randf_range(-0.35, 0.35)
		y += h
		w *= 0.76
	var wax: StandardMaterial3D = _mat(Color(0.86, 0.80, 0.62), 0.7, 0.0)
	_cyl(holder, 0.07, 0.22, Vector3(0.0, y + 0.11, 0.0), wax)
	var flame := OmniLight3D.new()
	flame.light_color = Color(1.0, 0.72, 0.36)
	flame.light_energy = 0.8
	flame.omni_range = 5.0
	holder.add_child(flame)
	flame.position = Vector3(0.0, y + 0.3, 0.0)
	_drop(loot_root, holder, Vector3(0.0, 0.3, 1.0), LOOT_ARTIFACT, 1)


## CRASHED DRONE — a machine that lost, half-buried at the end of its own furrow, still
## spitting sparks. The one vignette that reads as recent.
static func _build_drone(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	var shell: StandardMaterial3D = _mat(Color(0.20, 0.21, 0.23), 0.6, 0.7)
	var plate: StandardMaterial3D = _mat(Color(0.16, 0.17, 0.18), 0.75, 0.5)
	var fuselage: MeshInstance3D = _cyl(holder, 0.62, 2.6, Vector3(0.0, 0.34, 0.0), shell)
	fuselage.rotation = Vector3(rng.randf_range(0.5, 0.85), rng.randf_range(-0.4, 0.4), 0.35)
	fuselage.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var wing: MeshInstance3D = _box(holder, Vector3(2.7, 0.1, 0.85), Vector3(1.1, 0.16, 0.7), plate)
	wing.rotation = Vector3(0.15, rng.randf_range(-0.6, 0.6), -0.28)
	_box(holder, Vector3(0.9, 0.08, 0.6), Vector3(-1.3, 0.1, -0.9), plate)
	_sparks(holder, Vector3(0.0, 0.75, -0.5))
	_drop(loot_root, holder, Vector3(0.9, 0.4, -0.7), LOOT_CIRCUIT, 1)
	if rng.randf() < 0.6:
		_drop(loot_root, holder, Vector3(-0.8, 0.4, 0.9), LOOT_CELL, 1)


## WARNING TOTEM — a pole, a machine head on a spike, a red light that will not stop
## blinking. Pure mood: no loot, only the message that something here kills robots.
static func _build_totem(holder: Node3D, rng: RandomNumberGenerator) -> void:
	var wood: StandardMaterial3D = _mat(Color(0.24, 0.19, 0.14), 0.95, 0.0)
	var dark: StandardMaterial3D = _mat(Color(0.10, 0.10, 0.11), 0.55, 0.75)
	var pole: MeshInstance3D = _cyl(holder, 0.11, 3.0, Vector3(0.0, 1.5, 0.0), wood)
	pole.rotation = Vector3(rng.randf_range(-0.06, 0.06), 0.0, rng.randf_range(-0.06, 0.06))
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var head := MeshInstance3D.new()
	var skull := SphereMesh.new()
	skull.radius = 0.34
	skull.height = 0.68
	skull.radial_segments = 12
	skull.rings = 6
	head.mesh = skull
	head.material_override = dark
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(head)
	head.position = Vector3(0.0, 3.05, 0.0)
	head.rotation.y = rng.randf_range(-PI, PI)
	# Rubble ring at the base — the pole reads as planted, not dropped.
	var grit: StandardMaterial3D = _mat(Color(0.28, 0.27, 0.25), 0.95, 0.0)
	for i in range(4):
		var a: float = rng.randf_range(-PI, PI)
		var r: float = rng.randf_range(0.5, 1.1)
		var chunk: MeshInstance3D = _box(
			holder, Vector3(0.3, 0.18, 0.28), Vector3(cos(a) * r, 0.09, sin(a) * r), grit
		)
		chunk.rotation.y = a
	var beacon := OmniLight3D.new()
	beacon.light_color = Color(1.0, 0.16, 0.12)
	beacon.light_energy = 2.2
	beacon.omni_range = 7.0
	holder.add_child(beacon)
	beacon.position = Vector3(0.0, 3.4, 0.0)
	_blink(beacon)


## CACHE STASH — a crate someone cracked open and abandoned mid-haul, lid hanging back.
static func _build_stash(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	var crate: StandardMaterial3D = _mat(Color(0.30, 0.26, 0.17), 0.9, 0.1)
	var trim: StandardMaterial3D = _mat(Color(0.17, 0.17, 0.18), 0.7, 0.6)
	var box: MeshInstance3D = _box(holder, Vector3(1.5, 0.9, 1.1), Vector3(0.0, 0.45, 0.0), crate)
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var lid: MeshInstance3D = _box(holder, Vector3(1.5, 0.1, 1.1), Vector3(0.0, 1.28, -0.62), crate)
	lid.rotation.x = rng.randf_range(-1.25, -0.85)
	_box(holder, Vector3(1.56, 0.12, 0.14), Vector3(0.0, 0.45, 0.56), trim)
	# Spilled out the open FRONT (z > the crate's 0.55 half-depth), not left in the tray:
	# spawn_at snaps down to the terrain and the crate is render-only, so a drop over the
	# footprint would sink through it and read as loot buried inside a solid box.
	_drop(loot_root, holder, Vector3(0.34, 0.5, 1.05), LOOT_MEDKIT, 1)
	var second: String = LOOT_CELL if rng.randf() < 0.5 else LOOT_CHEMICALS
	_drop(loot_root, holder, Vector3(-0.38, 0.5, 1.25), second, 1)


# --------------------------------------------------------------- build helpers
## Render-only box. Shadows OFF by default (these are small props scattered map-wide);
## callers flip `cast_shadow` back on for the few silhouettes that need grounding.
static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.position = pos
	return mi


static func _cyl(
	parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	mesh.rings = 1
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.position = pos
	return mi


## A few short-lived amber sparks off a broken machine. Headless-safe (the dummy renderer
## accepts particle nodes); no collision, no subemitters.
static func _sparks(parent: Node3D, pos: Vector3) -> void:
	var p := GPUParticles3D.new()
	p.amount = 10
	p.lifetime = 0.9
	p.randomness = 0.7
	p.explosiveness = 0.4
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 38.0
	pm.initial_velocity_min = 0.8
	pm.initial_velocity_max = 2.4
	pm.gravity = Vector3(0.0, -4.5, 0.0)
	pm.scale_min = 0.3
	pm.scale_max = 0.8
	pm.color = Color(1.0, 0.72, 0.25)
	p.process_material = pm
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.05, 0.05, 0.05)
	mesh.material = _mat(Color(1.0, 0.72, 0.25), 1.0, 0.0, 3.0)
	p.draw_pass_1 = mesh
	parent.add_child(p)
	p.position = pos
	p.emitting = true


## Loop a light between hot and near-dead. Requires the light to already be in the tree
## (create_tween() is a Node call) — every caller adds it first.
static func _blink(light: OmniLight3D) -> void:
	if not light.is_inside_tree():
		return
	var full: float = light.light_energy
	var tw: Tween = light.create_tween()
	tw.set_loops()
	tw.tween_property(light, "light_energy", full * 0.08, 0.5)
	tw.tween_property(light, "light_energy", full, 0.5)


## Drop one replicated pickup at a holder-LOCAL offset. spawn_at snaps to the surface
## below server-side, so a slightly-high offset never leaves loot floating.
static func _drop(
	loot_root: Node, holder: Node3D, local: Vector3, id: String, count: int = 1
) -> void:
	if loot_root == null or not is_instance_valid(loot_root):
		return
	if not holder.is_inside_tree():
		return
	LootPickup.spawn_at(loot_root, holder.to_global(local), id, count)


## Cached StandardMaterial3D. `emit > 0` also flips the material unshaded so sparks and
## signal bits read at distance instead of dissolving into the cold grade.
static func _mat(col: Color, rough: float, metal: float, emit: float = 0.0) -> StandardMaterial3D:
	var key: String = "%s|%.2f|%.2f|%.2f" % [col, rough, metal, emit]
	var cached: StandardMaterial3D = _mat_cache.get(key, null)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = rough
	mat.metallic = metal
	if emit > 0.0:
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = emit
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_cache[key] = mat
	return mat
