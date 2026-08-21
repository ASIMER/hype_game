## M5.4 RUNTIME micro-vignettes — 4-7 tiny "someone was here" scenes scattered across the
## 320×320 rect each raid (a wrecked convoy, a roadside shrine, a downed drone, a warning
## totem, a cracked stash, an abandoned evac point, a machine salvage line, a last-stand
## firing line, a dead comms mast, a spent drop pod), so wandering between the authored POIs
## keeps paying off. Every scene is a SILENT diorama: it has to read from 10-15 m with no
## text at all, so each one is built around ONE silhouette (a shape you can name from a
## distance) plus ONE accent (a light, a smoke column, a painted ground mark).
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

## APPEND-ONLY: templates are picked by INDEX, so a new scene goes on the END of this enum
## (an insert would silently re-map every existing case).
enum Template { CONVOY, SHRINE, DRONE, TOTEM, STASH, EVAC, HARVEST, BARRICADE, MAST, POD }

const ROOT_NAME: String = "MicroVignettes"
const DEBUG_ROOT_NAME: String = "MicroVignettesDebug"  # QA-forced scenes (see spawn_debug)
const COUNT_MIN: int = 4
const COUNT_MAX: int = 7
const TEMPLATE_COUNT: int = 10

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
const LOOT_AMMO: String = "loot_ammo"
const LOOT_DATA_CHIP: String = "loot_data_chip"

# Shared material cache — 7 vignettes must not allocate 40 near-identical materials.
static var _mat_cache: Dictionary = {}
# Ground-paint ring, generated once per session (see _ring_texture).
static var _ring_tex: ImageTexture = null


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
	for i in points.size():
		var holder := Node3D.new()
		root.add_child(holder)
		holder.global_position = points[i]
		holder.rotation.y = rng.randf_range(-PI, PI)
		# Named AFTER the build (the roll happens inside) so QA can find a specific scene in
		# the tree — "Arena/MicroVignettes/Vignette_3_MAST" — instead of "@Node3D@412". The
		# index leads so two rolls of the same template can't collide into a "@2" suffix.
		holder.name = "Vignette_%d_%s" % [i, Template.keys()[_build_one(holder, loot_root, rng)]]
	return points.size()


## QA ONLY: force ONE named template onto a known point (no keep-outs, no rejection
## sampling, no authority gate) and return its holder. Lives under a SEPARATE root so it
## never trips spawn_all's idempotency guard, and so `restart` clears it with the arena.
## `template` is a Template enum index; `pos.y` is ignored — the point is seated on the
## terrain exactly like the real placer does it. Call it repeatedly, each call adds a holder.
##
## Resolves the arena + Net/Loot itself (Groups.ARENA, the NemesisDirector._loot_container
## convention) so a debug verb is a two-liner. Returns null if there is no arena yet.
static func spawn_debug(tree: SceneTree, template: int, pos: Vector3, rng_seed: int = 1) -> Node3D:
	if tree == null:
		return null
	var arena: Node = tree.get_first_node_in_group(Groups.ARENA)
	if arena == null or not is_instance_valid(arena):
		return null
	var loot_root: Node = arena.get_node_or_null("Net/Loot")
	var root: Node3D = arena.get_node_or_null(NodePath(DEBUG_ROOT_NAME)) as Node3D
	if root == null:
		root = Node3D.new()
		root.name = DEBUG_ROOT_NAME
		arena.add_child(root)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var holder := Node3D.new()
	root.add_child(holder)
	holder.global_position = Vector3(pos.x, ProceduralTerrain.height_at(pos.x, pos.z), pos.z)
	var idx: int = clampi(template, 0, TEMPLATE_COUNT - 1)
	_dispatch(holder, loot_root, rng, idx)
	holder.name = "Dbg_%d_%s" % [root.get_child_count() - 1, Template.keys()[idx]]
	return holder


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
## Rolls a template and builds it. Returns the chosen Template index so the caller can name
## the holder after it (the roll must stay the caller's ONLY rng draw here — de-inlining it
## would shift every downstream random value for a given seed).
static func _build_one(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> int:
	var idx: int = rng.randi_range(0, TEMPLATE_COUNT - 1)
	_dispatch(holder, loot_root, rng, idx)
	return idx


static func _dispatch(
	holder: Node3D, loot_root: Node, rng: RandomNumberGenerator, idx: int
) -> void:
	match idx:
		Template.CONVOY:
			_build_convoy(holder, loot_root, rng)
		Template.SHRINE:
			_build_shrine(holder, loot_root, rng)
		Template.DRONE:
			_build_drone(holder, loot_root, rng)
		Template.TOTEM:
			_build_totem(holder, rng)
		Template.EVAC:
			_build_evac(holder, loot_root, rng)
		Template.HARVEST:
			_build_harvest(holder, loot_root, rng)
		Template.BARRICADE:
			_build_barricade(holder, loot_root, rng)
		Template.MAST:
			_build_mast(holder, loot_root, rng)
		Template.POD:
			_build_pod(holder, loot_root, rng)
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


## ABANDONED EVAC POINT — a painted landing circle, a queue of dropped duffels that never
## got loaded, a toppled crowd barrier, and one flare still burning itself out. The dropship
## came, it filled up, and it left. Read at range: the ground ring + the smoke column.
static func _build_evac(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	# The circle is a DECAL, not a disc mesh: the placer tolerates 1.6 m of drop across the
	# footprint and a flat mesh at the holder's single Y would clip into or float over it.
	_decal(holder, true, 11.0, Color(0.86, 0.78, 0.42), 0.45)
	var canvas: StandardMaterial3D = _mat(Color(0.26, 0.25, 0.19), 0.95, 0.0)
	var strap: StandardMaterial3D = _mat(Color(0.14, 0.13, 0.11), 0.95, 0.0)
	# A queue of duffels along one edge — a LINE of bags reads as "people stood here" in a
	# way a scatter never does, so the row is deliberate and only the jitter is random.
	for i in range(6):
		var bx: float = -2.6 + float(i) * 1.05 + rng.randf_range(-0.16, 0.16)
		var bz: float = 3.3 + rng.randf_range(-0.5, 0.5)
		var bag: MeshInstance3D = _box(
			holder, Vector3(0.78, 0.42, 0.46), Vector3(bx, 0.21, bz), canvas
		)
		bag.rotation = Vector3(0.0, rng.randf_range(-0.6, 0.6), rng.randf_range(-0.1, 0.1))
		var band: MeshInstance3D = _box(
			holder, Vector3(0.80, 0.07, 0.12), Vector3(bx, 0.30, bz), strap
		)
		band.rotation.y = bag.rotation.y
		# The queue runs ~3.3 m out — past the flatness probe, so re-seat each bag.
		_settle(bag, holder)
		_settle(band, holder)
	# Two crowd barriers knocked flat in the rush for the ramp.
	var rail: StandardMaterial3D = _mat(Color(0.55, 0.42, 0.12), 0.7, 0.4)
	for i in range(2):
		var rx: float = -1.4 + float(i) * 2.9
		var bar: MeshInstance3D = _box(
			holder, Vector3(2.3, 0.09, 0.16), Vector3(rx, 0.06, 1.5 + float(i) * 0.4), rail
		)
		var byaw: float = rng.randf_range(-0.5, 0.5)
		bar.rotation = Vector3(0.0, byaw, 0.0)
		var leg: MeshInstance3D = _box(
			holder, Vector3(0.12, 0.09, 0.62), bar.position + Vector3(0.0, 0.02, 0.0), rail
		)
		leg.rotation.y = byaw
	# The flare: the accent that finds the scene from 15 m out.
	var flare_pos := Vector3(rng.randf_range(-1.0, 1.0), 0.14, rng.randf_range(-1.6, -0.6))
	_cyl(holder, 0.06, 0.28, flare_pos, strap)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.34, 0.18)
	glow.light_energy = 1.9
	glow.omni_range = 6.5
	holder.add_child(glow)
	glow.position = flare_pos + Vector3(0.0, 0.25, 0.0)
	_blink(glow)
	_smoke(holder, flare_pos + Vector3(0.0, 0.3, 0.0), Color(0.72, 0.36, 0.24, 0.34), 14)
	_drop(loot_root, holder, Vector3(-3.7, 0.4, 3.1), LOOT_MEDKIT, 1)
	_drop(loot_root, holder, Vector3(3.5, 0.4, 2.6), LOOT_PLASTIC, 2)


## SALVAGE LINE — machines taken apart on purpose: torsos laid out in a row on a tarp, limbs
## sorted into piles by type, one hull still hanging from a field gantry. Not a battlefield —
## a WORKSHOP. Somebody was farming the things that hunt you, and then stopped.
static func _build_harvest(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	var tarp: StandardMaterial3D = _mat(Color(0.15, 0.19, 0.15), 0.98, 0.0)
	var hull: StandardMaterial3D = _mat(Color(0.19, 0.20, 0.22), 0.7, 0.6)
	var limb: StandardMaterial3D = _mat(Color(0.15, 0.16, 0.17), 0.8, 0.5)
	var frame: StandardMaterial3D = _mat(Color(0.33, 0.30, 0.26), 0.9, 0.2)
	_box(holder, Vector3(4.4, 0.05, 3.0), Vector3(0.0, 0.03, 0.0), tarp)
	# Three torsos in a ROW on the tarp — the order is the whole story.
	for i in range(3):
		var tz: float = -1.0 + float(i) * 1.0
		var torso: MeshInstance3D = _box(
			holder, Vector3(1.05, 0.5, 0.62), Vector3(-0.9, 0.3, tz), hull
		)
		torso.rotation.y = rng.randf_range(-0.09, 0.09)
		torso.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_box(holder, Vector3(0.3, 0.16, 0.3), Vector3(-0.42, 0.36, tz), limb)
	# Two SORTED piles: rods in one, plates in the other. Sorting is what reads as deliberate.
	for i in range(5):
		var rod: MeshInstance3D = _cyl(
			holder,
			0.09,
			0.95,
			Vector3(1.05 + rng.randf_range(-0.12, 0.12), 0.1 + float(i) * 0.16, -0.9),
			limb
		)
		rod.rotation = Vector3(0.0, 0.0, PI * 0.5 + rng.randf_range(-0.12, 0.12))
	for i in range(4):
		var plate: MeshInstance3D = _box(
			holder, Vector3(0.62, 0.06, 0.46), Vector3(1.15, 0.06 + float(i) * 0.08, 0.9), hull
		)
		plate.rotation.y = rng.randf_range(-0.3, 0.3)
	# The gantry: two posts + a beam, one hull still slung under it. The vertical read.
	_cyl(holder, 0.09, 2.6, Vector3(-2.3, 1.3, -1.5), frame)
	_cyl(holder, 0.09, 2.6, Vector3(-2.3, 1.3, 1.5), frame)
	var beam: MeshInstance3D = _box(
		holder, Vector3(0.16, 0.16, 3.3), Vector3(-2.3, 2.65, 0.0), frame
	)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_cyl(holder, 0.03, 0.95, Vector3(-2.3, 2.1, 0.35), limb)
	var slung: MeshInstance3D = _box(
		holder, Vector3(0.9, 0.85, 0.6), Vector3(-2.3, 1.2, 0.35), hull
	)
	slung.rotation = Vector3(0.0, rng.randf_range(-0.4, 0.4), rng.randf_range(-0.2, 0.2))
	slung.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_drop(loot_root, holder, Vector3(2.6, 0.4, 0.2), LOOT_SCRAP, 3)
	_drop(loot_root, holder, Vector3(2.4, 0.4, -1.5), LOOT_CIRCUIT, 1)


## FIRING LINE — a crate barricade dug in facing ONE way, brass all over the ground behind
## it, a deployable knocked on its side, and the machine that got within five metres anyway.
## The direction everything faces is the story: they knew what was coming and from where.
static func _build_barricade(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	var sack: StandardMaterial3D = _mat(Color(0.31, 0.29, 0.22), 0.98, 0.0)
	var steel: StandardMaterial3D = _mat(Color(0.17, 0.18, 0.19), 0.65, 0.65)
	var brass: StandardMaterial3D = _mat(Color(0.62, 0.48, 0.16), 0.35, 0.9)
	# A shallow arc, every block square to the arc — a wall, not a heap.
	for i in range(6):
		var a: float = -0.75 + float(i) * 0.30
		var p := Vector3(sin(a) * 3.4, 0.0, -cos(a) * 3.4)
		var blk: MeshInstance3D = _box(
			holder,
			Vector3(1.0, 0.55, 0.55),
			p + Vector3(0.0, 0.28 + (0.5 if i == 2 or i == 3 else 0.0), 0.0),
			sack
		)
		blk.rotation.y = -a
		blk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		# The arc sits 3.4 m out; settle each block on its own ground so the wall follows
		# the slope instead of half-burying one end.
		_settle(blk, holder)
		if i == 2 or i == 3:
			# The centre is stacked two high — the spot they expected to be hit hardest.
			# Same xz as `blk`, so the same correction keeps the stack glued together.
			var under: MeshInstance3D = _box(
				holder, Vector3(1.0, 0.55, 0.55), p + Vector3(0.0, 0.28, 0.0), sack
			)
			under.rotation.y = -a
			_settle(under, holder)
	# Spent brass behind the line — the volume of fire, told in litter.
	for i in range(12):
		var ba: float = rng.randf_range(-PI, PI)
		var br: float = rng.randf_range(0.4, 2.4)
		var case_mi: MeshInstance3D = _cyl(
			holder, 0.028, 0.09, Vector3(sin(ba) * br, 0.045, cos(ba) * br * 0.6 + 0.6), brass
		)
		case_mi.rotation = Vector3(PI * 0.5, ba, 0.0)
	# The deployable that ran dry, tipped over on its side.
	var pod: MeshInstance3D = _box(holder, Vector3(0.8, 0.9, 0.8), Vector3(1.6, 0.42, 1.3), steel)
	pod.rotation = Vector3(0.0, rng.randf_range(-0.6, 0.6), 1.45)
	var mast_stub: MeshInstance3D = _cyl(holder, 0.05, 1.1, Vector3(1.6, 0.9, 1.3), steel)
	mast_stub.rotation.z = 1.45
	# And the one that still got through, stopped just past the crates.
	var wreck: MeshInstance3D = _box(
		holder, Vector3(1.3, 0.95, 1.6), Vector3(rng.randf_range(-1.2, 1.2), 0.45, -5.6), steel
	)
	wreck.rotation = Vector3(rng.randf_range(0.3, 0.6), rng.randf_range(-0.8, 0.8), 0.25)
	wreck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var arm: MeshInstance3D = _cyl(holder, 0.14, 1.2, Vector3(1.5, 0.12, -5.0), steel)
	arm.rotation = Vector3(0.0, rng.randf_range(-1.0, 1.0), PI * 0.5)
	# 5-6 m out — the furthest ground contact in the whole set, so it gets its own seat.
	_settle(wreck, holder)
	_settle(arm, holder)
	_settle(pod, holder)
	_settle(mast_stub, holder)
	_sparks(holder, Vector3(0.0, 0.7, -5.4))
	_drop(loot_root, holder, Vector3(-0.6, 0.4, 1.9), LOOT_AMMO, 2)
	if rng.randf() < 0.6:
		_drop(loot_root, holder, Vector3(1.1, 0.4, 2.3), LOOT_SCRAP, 2)


## DEAD REPEATER — a lattice mast guyed down in the dirt, a dish still aimed at a sky nobody
## answered from, and a battery bank blinking on its last cell. Whoever raised this was
## calling for a long time. The tallest silhouette in the set: visible well past 15 m.
static func _build_mast(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	var steel: StandardMaterial3D = _mat(Color(0.36, 0.35, 0.33), 0.7, 0.55)
	var dark: StandardMaterial3D = _mat(Color(0.13, 0.14, 0.15), 0.8, 0.4)
	var top: float = 5.2
	var tilt: float = rng.randf_range(0.05, 0.12)
	var lean := Vector3(sin(tilt) * top, cos(tilt) * top, 0.0)
	# Three legs + rungs: a LATTICE, so the mast reads as structure and not as a pole.
	var legs: Array[Vector3] = [
		Vector3(0.30, 0.0, 0.0), Vector3(-0.15, 0.0, 0.26), Vector3(-0.15, 0.0, -0.26)
	]
	for l in legs:
		_strut(holder, l, l + lean, 0.055, steel)
	for i in range(6):
		var t: float = 0.12 + float(i) * 0.16
		for j in range(3):
			_strut(holder, legs[j] + lean * t, legs[(j + 1) % 3] + lean * (t + 0.08), 0.028, steel)
	# The dish, still pointed somewhere specific.
	var dish: MeshInstance3D = _cyl(holder, 0.85, 0.1, lean + Vector3(0.0, -0.5, 0.0), steel)
	dish.rotation = Vector3(1.25, rng.randf_range(-PI, PI), 0.0)
	dish.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Guy-wires to three stakes — the thing that makes it read as RAISED, not dropped.
	for i in range(3):
		var ga: float = float(i) * TAU / 3.0 + 0.4
		var ax: float = sin(ga) * 3.6
		var az: float = cos(ga) * 3.6
		# The stake's ground is resolved FIRST (not settled afterwards) so the wire ENDS on
		# it — a settled stake under an un-settled wire is exactly the "floating rope" bug.
		var anchor := Vector3(ax, _ground_delta(holder, ax, az), az)
		_strut(holder, lean * 0.82, anchor + Vector3(0.0, 0.15, 0.0), 0.022, dark)
		_box(holder, Vector3(0.16, 0.34, 0.16), anchor + Vector3(0.0, 0.14, 0.0), dark)
	# Battery bank at the foot, one cell still alive.
	var bank: MeshInstance3D = _box(holder, Vector3(1.2, 0.55, 0.7), Vector3(1.5, 0.28, 1.0), dark)
	bank.rotation.y = rng.randf_range(-0.5, 0.5)
	_box(holder, Vector3(1.24, 0.1, 0.16), Vector3(1.5, 0.6, 1.0), steel)
	var lamp := OmniLight3D.new()
	lamp.light_color = Color(0.30, 1.0, 0.55)
	lamp.light_energy = 1.4
	lamp.omni_range = 5.5
	holder.add_child(lamp)
	lamp.position = Vector3(1.5, 0.72, 1.0)
	_blink(lamp)
	var spool: MeshInstance3D = _cyl(holder, 0.55, 0.22, Vector3(-1.7, 0.11, 1.4), dark)
	spool.rotation = Vector3(rng.randf_range(-0.1, 0.1), 0.0, rng.randf_range(-0.1, 0.1))
	_drop(loot_root, holder, Vector3(2.6, 0.4, 1.4), LOOT_CELL, 1)
	_drop(loot_root, holder, Vector3(-2.4, 0.4, 2.0), LOOT_DATA_CHIP, 1)


## SPENT DROP POD — a scorched capsule half-buried at the end of its own skid, hatch blown
## clean off, chute crumpled downwind, debris thrown in a fan. Somebody ARRIVED here. The
## pod is a one-way vehicle, so there is no story where they left the way they came.
static func _build_pod(holder: Node3D, loot_root: Node, rng: RandomNumberGenerator) -> void:
	_decal(holder, false, 9.0, Color(0.08, 0.07, 0.07), 0.6)
	var burnt: StandardMaterial3D = _mat(Color(0.11, 0.11, 0.12), 0.8, 0.5)
	var hot: StandardMaterial3D = _mat(Color(0.20, 0.21, 0.23), 0.55, 0.75)
	var chute: StandardMaterial3D = _mat(Color(0.52, 0.51, 0.46), 0.98, 0.0)
	var yaw: float = rng.randf_range(-0.5, 0.5)
	# The capsule, nose down and buried to the shoulder at the end of its furrow.
	var caps: MeshInstance3D = _cyl(holder, 1.0, 2.5, Vector3(0.0, 0.62, 0.0), burnt)
	caps.rotation = Vector3(rng.randf_range(0.95, 1.25), yaw, 0.0)
	caps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# The nose cone sheared off on impact and came to rest on its side beside the hull.
	var nose: MeshInstance3D = _taper(holder, 0.95, 0.22, 1.2, Vector3(1.9, 0.36, 1.5), burnt)
	nose.rotation = Vector3(1.4, yaw, 0.22)
	# The skid it dug coming in: ridges of thrown dirt trailing back along the entry line,
	# drifting sideways with the hull's yaw so the whole scene points ONE way.
	for i in range(5):
		var t: float = float(i) * 0.9
		var ridge: MeshInstance3D = _box(
			holder,
			Vector3(1.9 - float(i) * 0.2, 0.16, 0.5),
			Vector3(sin(yaw) * t * 0.4, 0.07, -1.4 - t * 0.9),
			burnt
		)
		ridge.rotation.y = yaw + rng.randf_range(-0.15, 0.15)
		_settle(ridge, holder)  # the furrow runs 5 m back, past the flatness probe
	# Hatch blown off and lying face-up a few metres out — the "it OPENED" beat.
	var hatch: MeshInstance3D = _cyl(holder, 0.95, 0.12, Vector3(3.0, 0.07, 1.1), hot)
	hatch.rotation = Vector3(rng.randf_range(-0.25, 0.25), 0.0, rng.randf_range(-0.3, 0.3))
	_settle(hatch, holder)
	# Crumpled canopy downwind — pale cloth is the one bright shape in the scene.
	for i in range(3):
		var ca: float = rng.randf_range(-PI, PI)
		var cloth: MeshInstance3D = _box(
			holder,
			Vector3(2.1 - float(i) * 0.3, 0.05, 1.6),
			Vector3(-3.4 + float(i) * 0.5, 0.04 + float(i) * 0.05, 2.6 + float(i) * 0.4),
			chute
		)
		cloth.rotation = Vector3(rng.randf_range(-0.12, 0.12), ca, rng.randf_range(-0.12, 0.12))
		_settle(cloth, holder)
	for i in range(7):
		var da: float = rng.randf_range(-PI, PI)
		var dr: float = rng.randf_range(2.0, 4.4)
		var frag: MeshInstance3D = _box(
			holder,
			Vector3(rng.randf_range(0.15, 0.4), 0.1, rng.randf_range(0.15, 0.35)),
			Vector3(sin(da) * dr, 0.05, cos(da) * dr),
			hot
		)
		frag.rotation = Vector3(rng.randf_range(-0.3, 0.3), da, rng.randf_range(-0.3, 0.3))
		_settle(frag, holder)  # the fan throws out to 4.4 m
	_smoke(holder, Vector3(0.3, 0.9, 0.2), Color(0.26, 0.26, 0.28, 0.30), 10)
	_drop(loot_root, holder, Vector3(2.2, 0.5, 2.3), LOOT_CELL, 1)
	if rng.randf() < 0.55:
		_drop(loot_root, holder, Vector3(-2.0, 0.5, 1.4), LOOT_MEDKIT, 1)


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


## Re-seat ONE already-positioned prop on the terrain under its OWN xz.
##
## WHY: the holder is placed at a SINGLE `ProceduralTerrain.height_at`, and every prop hangs
## off that one Y. `_is_flat` only probes ±2.5 m and tolerates MAX_SLOPE_DROP (1.6 m), so a
## piece sitting 4-6 m out — the barricade's stopped wreck, the pod's debris fan, the mast's
## guy stakes — can legally end up ~1 m above or below the actual ground. Anything that must
## TOUCH the ground at range gets this; centre pieces and anything structurally tied to
## another prop (gantry beam, stacked crates at the same xz) deliberately do NOT.
##
## Uses height_at, NOT a raycast: it must agree with the placer, and it has to work at
## match-start before the props/physics around it are settled.
static func _settle(prop: Node3D, holder: Node3D) -> void:
	if prop == null or holder == null or not holder.is_inside_tree():
		return
	var g: Vector3 = holder.to_global(Vector3(prop.position.x, 0.0, prop.position.z))
	prop.position.y += ProceduralTerrain.height_at(g.x, g.z) - holder.global_position.y


## Local-space Y correction for a holder-local xz — the value `_settle` applies, for callers
## that need it BEFORE building (a guy-wire has to end exactly on its settled stake).
static func _ground_delta(holder: Node3D, local_x: float, local_z: float) -> float:
	if not holder.is_inside_tree():
		return 0.0
	var g: Vector3 = holder.to_global(Vector3(local_x, 0.0, local_z))
	return ProceduralTerrain.height_at(g.x, g.z) - holder.global_position.y


## Truncated cone (CylinderMesh with unequal radii) — the one shape `_cyl` can't make.
static func _taper(
	parent: Node3D, bottom: float, top: float, height: float, pos: Vector3, mat: Material
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = 10
	mesh.rings = 1
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.position = pos
	return mi


## A cylinder spanning two holder-LOCAL points (mast legs, rungs, guy-wires). CylinderMesh is
## Y-axis, so the basis is rebuilt with Y along the span — `position` survives the assignment
## because basis and origin are independent halves of the transform.
static func _strut(
	parent: Node3D, from: Vector3, to: Vector3, radius: float, mat: Material
) -> void:
	var delta: Vector3 = to - from
	var span: float = delta.length()
	if span < 0.02:
		return
	var mi: MeshInstance3D = _cyl(parent, radius, span, (from + to) * 0.5, mat)
	var up: Vector3 = delta / span
	# Any reference axis that isn't parallel to the span works — pick the safer of two.
	# (Explicitly typed: an inferred ternary parses as Variant under warnings-as-errors.)
	var ref: Vector3 = Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var xax: Vector3 = ref.cross(up).normalized()
	mi.basis = Basis(xax, up, xax.cross(up))


## Ground paint (`ring` = a painted landing circle, else a filled scorch). A `Decal` PROJECTS
## straight down onto whatever is under it, so it survives the ±MAX_SLOPE_DROP the placer
## tolerates — a flat disc mesh sat at the holder's single Y would clip into the rise on one
## side and float on the other. SKIPPED on a dedicated headless server, and the texture is
## resolved only AFTER that check so the server never runs the image bake at all (the same
## discipline extraction_zone/ProceduralClimateZones use around _radial_texture).
static func _decal(parent: Node3D, ring: bool, size: float, tint: Color, mix: float) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var tex: Texture2D = _ring_texture() if ring else ProceduralClimateZones._radial_texture()
	if tex == null:
		return
	var dec := Decal.new()
	dec.texture_albedo = tex
	dec.size = Vector3(size, 2.6, size)
	dec.modulate = tint
	dec.albedo_mix = mix
	dec.upper_fade = 0.4
	dec.lower_fade = 0.4
	parent.add_child(dec)
	dec.position = Vector3(0.0, 1.0, 0.0)


## Slow drifting smoke (a burning flare, a cooling hull). Deliberately thin and short-ranged:
## this is a scene accent that finds the eye, not weather.
static func _smoke(parent: Node3D, pos: Vector3, tint: Color, amount: int) -> void:
	var p := GPUParticles3D.new()
	p.amount = maxi(1, amount)
	p.lifetime = 3.4
	p.randomness = 0.6
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 14.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.1
	pm.gravity = Vector3(0.35, 0.25, 0.0)
	pm.scale_min = 0.7
	pm.scale_max = 1.9
	pm.color = tint
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 0.9)
	quad.material = _soft_mat(tint)
	p.draw_pass_1 = quad
	parent.add_child(p)
	p.position = pos
	p.emitting = true


## Unshaded, alpha-blended, particle-billboarded material for smoke quads. Shares the
## `_mat` cache under its own key prefix so the two never collide.
static func _soft_mat(col: Color) -> StandardMaterial3D:
	var key: String = "soft|%s" % col
	var cached: StandardMaterial3D = _mat_cache.get(key, null)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[key] = mat
	return mat


## Cached RING texture for the evac landing circle (the radial one in ProceduralClimateZones
## is a filled disc). Built once for the whole session — 96² is plenty at decal scale.
static func _ring_texture() -> ImageTexture:
	if _ring_tex != null:
		return _ring_tex
	var n: int = 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var dx: float = (float(x) / float(n - 1) - 0.5) * 2.0
			var dy: float = (float(y) / float(n - 1) - 0.5) * 2.0
			var d: float = sqrt(dx * dx + dy * dy)
			# A painted band at 0.78 R, plus a faint wash inside it so the circle reads FILLED.
			var band: float = clampf(1.0 - absf(d - 0.78) / 0.15, 0.0, 1.0)
			var wash: float = clampf(1.0 - d / 0.64, 0.0, 1.0) * 0.20
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(band + wash, 0.0, 1.0)))
	_ring_tex = ImageTexture.create_from_image(img)
	return _ring_tex
