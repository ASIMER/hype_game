extends RefCounted
class_name ProceduralFlora
## Procedural VEGETATION + ROCKS across the 320×320 map: trees in FOREST/CLEARING
## clusters (FloraField density field — groves, treelines, ecotone edges, authored
## corridors), edge-hugging bushes, a dense two-LOD grass MultiMesh with meadow/
## canopy modulation, ground clutter (FloraClutter: ferns/flowers/mushrooms/pebbles)
## and a handful of BIG collidable boulders used as cover.
##
## EVERYTHING is DETERMINISTIC — co-op peers each build the arena locally, so the
## geometry MUST be identical on every machine. All placement and per-instance
## variation derives ONLY from `Settings.TERRAIN_SEED` + the shared ProcHash.h/hf/hrange
## arithmetic hash (scripts/core/proc_hash.gd). NO randf/randi/Time.
##
## Ground height comes from ProceduralTerrain.height_at(x,z) (direct class call).
## Inside the river `height_at` is NEGATIVE — we skip planting where height < -0.05.
##
## Collision model (so the runtime navmesh routes around cover):
##   - tree TRUNKS: StaticBody3D + CylinderShape3D (layer 1, mask 0); canopies render-only.
##   - BOULDERS: StaticBody3D + SphereShape3D (layer 1, mask 0) — gameplay cover.
##   - bushes / grass / small stones: render-only (no collision).
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; every Dictionary.get
## and ternary local below is explicitly typed.

# Seed hashing: ProcHash.h/hf/hrange (scripts/core/proc_hash.gd) — ONE copy shared
# with terrain/buildings so every procedural system stays determinism-synchronized.

# ---------------------------------------------------------------- world rectangle
# World bounds: WorldBounds.* (scripts/core/world_bounds.gd) is the ONE source. ALL
# scatter spans the full rectangle (NOT the old origin-centred ±70), and uses EVEN
# per-cell acceptance — never a fill-from-a-corner cap — so the new +X/+Z quadrants
# are populated, not barren.


# ---------------------------------------------------------------- terrain hook
static func _ground_y(x: float, z: float) -> float:
	return ProceduralTerrain.height_at(x, z)


# ---------------------------------------------------------------- keep-out tests
# Built in build() from the SAME arena._POI_DEFS the structures use (no hand-copied
# rect list to drift) + the extraction points arena passes. Rects = POI footprint
# half-extents + an 8 m margin; the plaza (w=0) becomes a r=14 circle; extraction
# keep-outs are r=11; the player-spawn cluster circle is flora tuning, kept local.
const _POI_MARGIN: float = 8.0
const _PLAZA_KEEPOUT_R: float = 14.0
const _EXTRACT_KEEPOUT_R: float = 11.0
const _SPAWN_CIRCLE: Array = [59.0, 60.0, 17.0]
static var _poi_rects: Array = []  # [cx, cz, half-w+margin, half-d+margin]
static var _circles: Array = []  # [cx, cz, radius]


## Derive the keep-outs from the POI defs + extraction points (called by build()).
static func _collect_keepouts(poi_defs: Dictionary, extraction_points: Array[Vector2]) -> void:
	_poi_rects = []
	_circles = [_SPAWN_CIRCLE]
	for k in poi_defs.keys():
		var d: Dictionary = poi_defs[k]
		var px: float = float(d.get("x", 0.0))
		var pz: float = float(d.get("z", 0.0))
		var w: float = float(d.get("w", 0.0))
		var dd: float = float(d.get("d", 0.0))
		if w <= 0.1 and dd <= 0.1:
			_circles.append([px, pz, _PLAZA_KEEPOUT_R])
		else:
			_poi_rects.append([px, pz, w * 0.5 + _POI_MARGIN, dd * 0.5 + _POI_MARGIN])
	for zc in extraction_points:
		_circles.append([zc.x, zc.y, _EXTRACT_KEEPOUT_R])


## PUBLIC keep-out test for the flora family (FloraClutter scatters with the same
## rules) — true when (x,z) is inside any structure/zone/spawn keep-out or off-field.
static func blocked_at(x: float, z: float) -> bool:
	return _blocked(x, z)


## True when (x,z) is inside any structure/zone/spawn keep-out OR off the playable
## field. `allow_berm` lets boulders sit a little closer to the perimeter wall (inset 5 vs 8).
static func _blocked(x: float, z: float, allow_berm: bool = false) -> bool:
	var inset: float = 5.0 if allow_berm else 8.0
	if (
		x < WorldBounds.X_MIN + inset
		or x > WorldBounds.X_MAX - inset
		or z < WorldBounds.Z_MIN + inset
		or z > WorldBounds.Z_MAX - inset
	):
		return true
	for r in _circles:
		var dx: float = x - float(r[0])
		var dz: float = z - float(r[1])
		var rad: float = float(r[2])
		if dx * dx + dz * dz < rad * rad:
			return true
	for b in _poi_rects:
		if absf(x - float(b[0])) < float(b[2]) and absf(z - float(b[1])) < float(b[3]):
			return true
	return false


# ================================================================ entry point
## Construct all flora, add a single root under `parent`, and return it. `poi_defs` is
## arena._POI_DEFS (the ONE POI source); `extraction_points` are the zone XZ centres
## arena passes — since the vegetation overhaul this is ALL 12 zones (the old 3-NW-only
## asymmetry was a deliberate deferral, docs/AUDIT.md F2, closed when 4× tree density
## made trees-on-pads a real bug).
static func build(
	parent: Node3D, poi_defs: Dictionary = {}, extraction_points: Array[Vector2] = []
) -> Node3D:
	_collect_keepouts(poi_defs, extraction_points)

	var root := Node3D.new()
	root.name = "Flora"
	parent.add_child(root)

	var seed: int = Settings.TERRAIN_SEED

	_build_trees(root, seed)
	_build_bushes(root, seed)
	_build_grass(root, seed)
	FloraClutter.build(root, seed, poi_defs)
	_build_boulders(root, seed)
	return root


# ---------------------------------------------------------------- glTF model tables
## Quaternius CC0 MegaKit models (assets/models/flora/). Mesh loading + MultiMesh
## emission live in FloraMeshLib (shared with FloraClutter). `base_scale` normalises
## raw model height (~7-19 m) to the ~5-8 m world look; `trunk_r` = collision radius.
const _TREE_DEFS: Dictionary = {
	# id: [base_scale, trunk_radius]
	"CommonTree_1": [0.95, 0.42],
	"CommonTree_2": [0.95, 0.42],
	"CommonTree_3": [0.95, 0.42],
	"CommonTree_4": [0.95, 0.42],
	"CommonTree_5": [0.95, 0.42],
	"Pine_1": [0.95, 0.40],
	"Pine_2": [0.85, 0.40],
	"Pine_3": [0.85, 0.40],
	"Pine_4": [0.75, 0.42],
	"DeadTree_1": [0.60, 0.40],
	"DeadTree_2": [0.62, 0.40],
	"DeadTree_3": [0.45, 0.40],
	"TwistedTree_1": [0.42, 0.55],
	"TwistedTree_2": [0.40, 0.55],
	"TwistedTree_3": [0.45, 0.55],
}
## Per-biome model mixes (weights sum to 100): urban parkland, snow conifers,
## desert deadwood, lush rain broadleaf. Picked by hash per accepted site.
const _TREE_MIX: Dictionary = {
	"urban":
	[
		["CommonTree_1", 18],
		["CommonTree_2", 14],
		["CommonTree_3", 18],
		["CommonTree_5", 10],
		["Pine_1", 10],
		["Pine_2", 8],
		["DeadTree_2", 8],
		["TwistedTree_1", 8],
		["TwistedTree_2", 6],
	],
	"snow":
	[
		["Pine_1", 22],
		["Pine_2", 20],
		["Pine_3", 18],
		["Pine_4", 14],
		["DeadTree_1", 10],
		["DeadTree_2", 8],
		["CommonTree_3", 8],
	],
	"desert":
	[
		["DeadTree_1", 30],
		["DeadTree_2", 25],
		["DeadTree_3", 20],
		["TwistedTree_1", 15],
		["TwistedTree_2", 10],
	],
	"rain":
	[
		["CommonTree_4", 18],
		["CommonTree_2", 16],
		["CommonTree_5", 16],
		["TwistedTree_1", 12],
		["TwistedTree_2", 12],
		["TwistedTree_3", 10],
		["Pine_3", 8],
		["CommonTree_1", 8],
	],
}
const _ROCK_MODELS: Array = [
	# [id, base_scale]
	["Rock_Medium_1", 1.0],
	["Rock_Medium_2", 1.0],
	["Rock_Medium_3", 1.0],
]
const _BUSH_MODELS: Array = [
	# Raw bushes are ~1.6 m tall; 0.6 base keeps them as low ground shrubs, not domes.
	["Bush_Common", 0.6],
	["Bush_Common_Flowers", 0.6],
]
# Rain-quadrant bushes mix in Plant_1 as broadleaf undergrowth.
const _BUSH_MODELS_RAIN: Array = [
	["Bush_Common", 0.6],
	["Bush_Common_Flowers", 0.6],
	["Plant_1", 0.9],
]


## Flora layers cull beyond this (× draw_distance_scale): a tree is pixels at 120 m.
static func _flora_vis_end() -> float:
	return 120.0 * clampf(Settings.draw_distance_scale, 0.5, 2.0)


# ================================================================ TREES (Quaternius glTF)
## FOREST/CLEARING scatter: a fine 4 m jittered grid whose per-cell acceptance is
## FloraField.forest_w × 0.45 — groves cluster where the field is high, clearings stay
## open, the 0.45 cap keeps even grove cores walkable (navmesh corridors guaranteed by
## the field's authored lanes). Model per site = the biome's weighted mix. Collision:
## ONE shared "TreeTrunks" StaticBody3D holding a CylinderShape3D per tree (same navmesh
## input as per-tree bodies at half the node count).
static func _build_trees(root: Node3D, seed: int) -> int:
	var trees := Node3D.new()
	trees.name = "Trees"
	root.add_child(trees)
	var trunks := StaticBody3D.new()
	trunks.name = "TreeTrunks"
	trunks.collision_layer = 1
	trunks.collision_mask = 0
	trees.add_child(trunks)

	# Destructible-tree registry: fresh per arena build (restart restores all trees).
	FellableTree.reset()
	# Per-model-id transform buckets (only ids actually used get an MMI) + the
	# parallel tree-index buckets (aligned 1:1) for FellableTree instance binding.
	var buckets: Dictionary = {}
	var uid_buckets: Dictionary = {}

	var placed: int = 0
	var step: float = 4.0
	var nx: int = int((WorldBounds.X_MAX - WorldBounds.X_MIN) / step)
	var nz: int = int((WorldBounds.Z_MAX - WorldBounds.Z_MIN) / step)
	for gx in range(nx):
		for gz in range(nz):
			var cell: int = ProcHash.h(seed * 911 + gx * 257 + gz * 31 + 7)
			var px: float = (
				WorldBounds.X_MIN + (float(gx) + 0.5) * step + ProcHash.hrange(cell + 1, -1.4, 1.4)
			)
			var pz: float = (
				WorldBounds.Z_MIN + (float(gz) + 0.5) * step + ProcHash.hrange(cell + 2, -1.4, 1.4)
			)
			# Cluster acceptance: the forest field IS the density (cap 0.45 ⇒ walkable groves).
			var accept_p: float = FloraField.forest_w(px, pz) * 0.45
			if ProcHash.hf(cell + 9) >= accept_p:
				continue
			if _blocked(px, pz):
				continue
			var gy: float = _ground_y(px, pz)
			if gy < -0.05:  # not in the river
				continue
			_place_tree(trunks, buckets, uid_buckets, cell, px, gy, pz)
			placed += 1

	# Emit TILED MultiMeshes per model id (sorted for deterministic node order) — 64 m
	# tiles so distant groves genuinely cull from the camera AND the shadow splits.
	# The out_map binds each tree's MMI set + instance slot into FellableTree so a
	# felled tree's standing visual can be zero-scaled on every peer.
	var ids: Array = buckets.keys()
	ids.sort()
	for id in ids:
		var fmap: Array = []
		FloraMeshLib.emit_model_mm_tiled(
			trees,
			"Tree_%s" % String(id),
			FloraMeshLib.model_meshes(String(id)),
			buckets[id],
			64.0,
			_flora_vis_end(),
			fmap
		)
		var uids: Array = uid_buckets.get(id, [])
		for k in uids.size():
			if k < fmap.size() and fmap[k] is Dictionary:
				FellableTree.bind_instances(
					int(uids[k]),
					(fmap[k] as Dictionary)["mmis"],
					int((fmap[k] as Dictionary)["idx"])
				)
	if Settings.NET_DEBUG:
		print("[flora] trees placed=%d (target %d)" % [placed, Settings.FLORA_TREES])
	return placed


## Weighted biome-mix pick: roll in [0,100) walks the cumulative weight table.
static func _pick_tree_id(biome: String, roll: int) -> String:
	var mix: Array = _TREE_MIX.get(biome, _TREE_MIX["urban"])
	var acc: int = 0
	for e in mix:
		acc += int(e[1])
		if roll < acc:
			return String(e[0])
	return String(mix[0][0])


## Pick the biome-mix model, append a yaw+scale-jittered Transform3D to its bucket, and
## add a trunk CylinderShape3D to the SHARED TreeTrunks body (layer 1, navmesh input).
## Registers the tree as FELLABLE (index = the shape's TreeTrunks child order —
## deterministic across peers, the glass/chunk discipline).
static func _place_tree(
	trunks: StaticBody3D,
	buckets: Dictionary,
	uid_buckets: Dictionary,
	hseed: int,
	x: float,
	y: float,
	z: float
) -> void:
	var id: String = _pick_tree_id(WorldBounds.biome_at(x, z), ProcHash.h(hseed + 5) % 100)
	var def: Array = _TREE_DEFS[id]
	var base_scale: float = float(def[0])
	var trunk_r: float = float(def[1])
	var yaw: float = ProcHash.hrange(hseed + 11, 0.0, TAU)
	# Wider per-instance scale variation so groves don't read as clone stamps.
	var sc: float = base_scale * ProcHash.hrange(hseed + 13, 0.75, 1.25)
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3(sc, sc, sc))
	var xform := Transform3D(basis, Vector3(x, y, z))
	if not buckets.has(id):
		buckets[id] = [] as Array[Transform3D]
		uid_buckets[id] = []
	(buckets[id] as Array[Transform3D]).append(xform)

	var col := CollisionShape3D.new()
	var cs := CylinderShape3D.new()
	cs.radius = maxf(trunk_r * sc, 0.25)
	# A tall trunk cylinder so players/AI can't clip past it; height scaled with the model.
	cs.height = 6.0 * sc
	col.shape = cs
	col.position = Vector3(x, y + cs.height * 0.5, z)
	trunks.add_child(col)
	var tree_idx: int = col.get_index()
	FellableTree.register(tree_idx, col, id, xform)
	(uid_buckets[id] as Array).append(tree_idx)


# ================================================================ BUSHES (Quaternius glTF)
## Render-only shrubs hugging the FOREST EDGES (the ecotone): acceptance = a small open-
## field base + a strong FloraField.edge_w term, scaled per biome (lush rain, sparse
## snow/desert). Rain mixes Plant_1 in as broadleaf undergrowth. One MultiMesh per model.
static func _build_bushes(root: Node3D, seed: int) -> int:
	var bushes := Node3D.new()
	bushes.name = "Bushes"
	root.add_child(bushes)

	# Buckets per model id across BOTH mix tables.
	var buckets: Dictionary = {}

	var placed: int = 0
	var step: float = 4.5
	var nx: int = int((WorldBounds.X_MAX - WorldBounds.X_MIN) / step)
	var nz: int = int((WorldBounds.Z_MAX - WorldBounds.Z_MIN) / step)
	for gx in range(nx):
		for gz in range(nz):
			var cell: int = ProcHash.h(seed * 1303 + gx * 193 + gz * 47 + 17)
			var px: float = (
				WorldBounds.X_MIN + (float(gx) + 0.5) * step + ProcHash.hrange(cell + 1, -2.0, 2.0)
			)
			var pz: float = (
				WorldBounds.Z_MIN + (float(gz) + 0.5) * step + ProcHash.hrange(cell + 2, -2.0, 2.0)
			)
			var biome: String = WorldBounds.biome_at(px, pz)
			var bf: float = 1.0
			if biome == "snow":
				bf = 0.6
			elif biome == "desert":
				bf = 0.25
			elif biome == "rain":
				bf = 1.3
			var accept_p: float = (0.10 + 0.40 * FloraField.edge_w(px, pz)) * bf
			if ProcHash.hf(cell + 9) >= accept_p:
				continue
			if _blocked(px, pz):
				continue
			var gy: float = _ground_y(px, pz)
			if gy < -0.05:
				continue
			var models: Array = _BUSH_MODELS_RAIN if biome == "rain" else _BUSH_MODELS
			var mi: int = ProcHash.h(cell + 51) % models.size()
			var id: String = String(models[mi][0])
			var bscale: float = float(models[mi][1])
			var yaw: float = ProcHash.hrange(cell + 3, 0.0, TAU)
			# Bushes are small/low — keep them under 1× so they don't tower.
			var sc: float = bscale * ProcHash.hrange(cell + 4, 0.55, 0.95)
			var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3(sc, sc, sc))
			if not buckets.has(id):
				buckets[id] = [] as Array[Transform3D]
			(buckets[id] as Array[Transform3D]).append(Transform3D(basis, Vector3(px, gy, pz)))
			placed += 1

	var ids: Array = buckets.keys()
	ids.sort()
	for id in ids:
		FloraMeshLib.emit_model_mm_tiled(
			bushes,
			"Bush_%s" % String(id),
			FloraMeshLib.model_meshes(String(id)),
			buckets[id],
			64.0,
			_flora_vis_end()
		)
	if Settings.NET_DEBUG:
		print("[flora] bushes placed=%d (target %d)" % [placed, Settings.FLORA_BUSHES])
	return placed


# ================================================================ GRASS (dense, LOD + spatial tiling)
## TWO LOD layers (NEAR ~11k fine clumped tufts within GRASS_VIS_RANGE, FAR ~2k larger
## tufts to GRASS_FAR_RANGE) sharing ONE fine-blade ArrayMesh + ONE ShaderMaterial
## (shaders/grass.gdshader: tip-weighted wind sway, root→tip colour gradient, per-tuft
## hash tint).
##
## PERF / CULLING — WHY TILES: `visibility_range_end` keys off the MultiMeshInstance3D
## node's WHOLE-AABB distance to the camera. A single map-wide MultiMesh has an AABB that
## spans the entire ~140×140 m field, so the camera is ALWAYS inside it → distance≈0 → it
## NEVER culls and all 14k blades draw every frame (42 fps). FIX: partition the field into
## GRID_M-metre tiles; each tile is its OWN MMI holding only the instances inside it, so its
## AABB is ~tile-sized and tiles beyond GRASS_VIS_RANGE genuinely cull. Empty tiles emit no
## node. Both NEAR and FAR are tiled the same way. This restores ≥200 fps with grass on-screen.
##
## render_mode cull_back halves the fragment/overdraw cost vs cull_disabled (the blades are
## viewed from many angles and the density hides the missing back-faces). NO vertex / per-
## instance colors (colour lives in the shader; the MultiMesh vertex-color albedo path is
## silently lossy in Godot 4.6 here). Density uses a clumped jittered grid; keep-out / river
## instances aren't emitted. Fully deterministic (_h/_hf).
const GRASS_TILE_M: float = 16.0  # spatial-tile edge (m) for the MultiMesh-LOD cull fix
# DENSITY model (4× map): grass is PER-CELL-PROBABILITY-driven, not a global instance cap.
# Vegetation-overhaul v2: mean ≈386 tufts per 16 m tile (the FAIRNESS/perf invariant —
# identical on every preset; per-frame cost is bounded by the visible tile bubble, not the
# map size). Density up (0.5→0.72) with the clump floor LOWERED back (0.85→0.50) so natural
# bald patches return — organic rhythm instead of a uniform lawn — plus a coarse 18 m
# patchiness octave, tall meadows at forest edges and thinning under grove canopies.
const NEAR_GRASS_DENSITY: float = 0.72  # base near-layer per-cell acceptance at q=1
const NEAR_GRASS_GRID: float = 0.7  # near-layer nominal blade spacing (m)
const GRASS_CLUMP_FLOOR: float = 0.50  # min per-clump emission weight (organic gaps)
const GRASS_CLUMP_RANGE: float = 1.05  # added on top of the floor => 0.50x .. 1.55x
const GRASS_PATCH_M: float = 18.0  # coarse second patchiness octave (×0.8..1.2)
const GRASS_MEADOW_BOOST: float = 0.4  # density boost at forest edges (× edge_w)
const GRASS_MEADOW_HEIGHT: float = 0.35  # tuft height boost at forest edges (× edge_w)
const GRASS_CANOPY_THIN: float = 0.25  # density cut inside grove cores


static func _build_grass(root: Node3D, seed: int) -> void:
	# One fine-blade mesh, shared by every tile of both LOD layers.
	var mesh: ArrayMesh = _grass_card_mesh()
	# ONE ShaderMaterial (shaders/grass.gdshader): root→tip gradient + per-tuft tint +
	# tip-weighted wind sway. Shared by every tile so the material count stays at one.
	var sh: Shader = load("res://shaders/grass.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = sh
	# Cinematic palette: deep root green -> lush mid-green tip, restrained warm SSS glow.
	mat.set_shader_parameter("base_color", Color(0.10, 0.22, 0.06))  # deep root green
	mat.set_shader_parameter("tip_color", Color(0.34, 0.52, 0.18))  # lush sun-lit tip
	mat.set_shader_parameter("sss_color", Color(0.85, 0.78, 0.34))  # warm, less orange
	mat.set_shader_parameter("sss_strength", 0.40)  # subtle backlight only
	mat.set_shader_parameter("ao_strength", 0.85)
	# Multi-frequency wind (gusts + turbulence) tuned for clearly visible sway at gameplay
	# distance (a subtle single-sine read as nearly static in QA).
	mat.set_shader_parameter("sway_strength", 0.34)
	mat.set_shader_parameter("sway_speed", 2.0)
	mat.set_shader_parameter("widen_strength", 1.0)

	# NEAR layer: dense, clumped, short visibility range, fades self. Tiled.
	# DENSITY PASS: the previous 11k cap + 0.95 m grid read as scattered tufts from the
	# 3rd-person camera. We have 40+ fps of headroom (gate >=200), so push toward a solid
	# carpet: a much higher local cap (NEAR_GRASS_CAP) over a finer grid (more cells emit
	# per tile). visibility_range stays at GRASS_VIS_RANGE so only the ~45 m bubble draws —
	# tiling means the global count barely matters for per-frame cost; on-screen tile draw
	# cost is what the perf gate measures and that's bounded by the visible-tile area.
	# Graphics-quality scale (set by SettingsManager from the quality preset; read here at
	# build, so a quality change applies on the next raid). 1.0 = Ultra ceiling.
	# Grass density lever — widened to 2.0 so the beyond-Ultra density preset actually emits
	# more grass (was capped at 1.0). 0.1 floor keeps the lowest preset non-empty.
	var q: float = clampf(Settings.grass_density_scale, 0.1, 2.0)
	# Draw-distance lever (0.5..2.0, read at build) multiplies the near/far grass visibility
	# ranges; 1.0 keeps the current cutoffs.
	var dd: float = clampf(Settings.draw_distance_scale, 0.5, 2.0)
	# 4× MAP NOTE: the grass is now DENSITY-driven, not capped by a global instance budget.
	# A fixed NEAR_GRASS_CAP over the 4× area would (a) only fill the NW corner before the cap
	# bit, leaving the +X/+Z quadrants bald, and (b) under-cover. Because grass is SPATIALLY
	# TILED (each tile its own MMI with a ~GRASS_VIS_RANGE visibility bubble), only the handful
	# of tiles around the camera ever draw — so per-frame cost is bounded by the SAME visible
	# bubble no matter how big the map is. We therefore keep the SAME per-tile blade density as
	# the old map (identical weak-GPU per-frame load) and just let the total count scale with
	# the larger area. `q × NEAR_GRASS_DENSITY` is the per-cell acceptance (calibrated so q=1
	# reproduces the old budgeted per-tile density).
	var near_xforms: Array[Transform3D] = _grass_transforms(
		seed, q * NEAR_GRASS_DENSITY, NEAR_GRASS_GRID, 4099, 1.0, true
	)
	var near_root := Node3D.new()
	near_root.name = "Grass_Near"
	root.add_child(near_root)
	var near_tiles: int = _emit_grass_tiled(
		near_root, "near", mesh, mat, near_xforms, 0.0, Settings.GRASS_VIS_RANGE * dd, 8.0
	)

	# FAR layer: fewer, larger tufts, picks up where near begins to drop out. Tiled too —
	# its AABB is otherwise also map-wide, so without tiling it'd never cull either. Sparser
	# acceptance (×0.45) keeps it the thin big-tuft backdrop layer.
	var far_xforms: Array[Transform3D] = _grass_transforms(seed, q * 0.45, 2.2, 5557, 1.6, false)
	var far_root := Node3D.new()
	far_root.name = "Grass_Far"
	root.add_child(far_root)
	# begin=33 so it cross-fades in as the near layer fades out (no hard ring/line).
	var far_tiles: int = _emit_grass_tiled(
		far_root, "far", mesh, mat, far_xforms, 33.0 * dd, Settings.GRASS_FAR_RANGE * dd, 10.0
	)

	if Settings.NET_DEBUG:
		print(
			(
				"[flora] grass near=%d (%d tiles) far=%d (%d tiles) tile=%.0fm"
				% [near_xforms.size(), near_tiles, far_xforms.size(), far_tiles, GRASS_TILE_M]
			)
		)


## Partition `xforms` into GRASS_TILE_M-metre spatial tiles and emit ONE
## MultiMeshInstance3D per non-empty tile (key = "<gx>_<gz>"), each with the given
## visibility range so per-tile AABBs let visibility_range actually cull distant tiles.
## Returns the number of tiles (MMIs) emitted. `vis_begin`=0 means no begin range.
static func _emit_grass_tiled(
	parent: Node3D,
	prefix: String,
	mesh: ArrayMesh,
	mat: ShaderMaterial,
	xforms: Array[Transform3D],
	vis_begin: float,
	vis_end: float,
	end_margin: float
) -> int:
	# Bucket transforms by tile. Dictionary key = packed grid coord; value = Array[Transform3D].
	var buckets: Dictionary = {}
	for xf in xforms:
		var p: Vector3 = xf.origin
		var gx: int = int(floor((p.x - WorldBounds.X_MIN) / GRASS_TILE_M))
		var gz: int = int(floor((p.z - WorldBounds.Z_MIN) / GRASS_TILE_M))
		var key: int = gx * 1000 + gz
		if not buckets.has(key):
			buckets[key] = []
		(buckets[key] as Array).append(xf)

	var tiles: int = 0
	# Iterate sorted keys so node order is deterministic across machines.
	var keys: Array = buckets.keys()
	keys.sort()
	for key in keys:
		var tile_xforms: Array = buckets[key]
		if tile_xforms.is_empty():
			continue
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "G_%s_%d" % [prefix, int(key)]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = false
		mm.mesh = mesh
		mm.instance_count = tile_xforms.size()
		for j in range(tile_xforms.size()):
			mm.set_instance_transform(j, tile_xforms[j])
		mmi.multimesh = mm
		mmi.material_override = mat
		if vis_begin > 0.0:
			mmi.visibility_range_begin = vis_begin
			mmi.visibility_range_begin_margin = 8.0
		mmi.visibility_range_end = vis_end
		mmi.visibility_range_end_margin = end_margin
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		parent.add_child(mmi)
		tiles += 1
	return tiles


## Build a deterministic grass transform list on a jittered grid over the WHOLE world
## rectangle with CLUMPING: a coarse ~6 m hash field scales emission per cell (some patches
## denser, some sparser) so the field reads as natural patches, not a uniform lawn. `grid` =
## nominal spacing (m), `density` = base per-cell acceptance probability (the quality lever;
## 1.0 = full), `salt` separates the near/far hash streams, `scale_mul` sizes the tufts,
## `clump` toggles the patchy density variation. Keeps every keep-out / river guard.
##
## 4× MAP: spans the WorldBounds rect with EVEN per-cell acceptance (no fill-from-a-
## corner instance cap) so every quadrant is grassed; tiling in _emit_grass_tiled bounds the
## per-frame draw to the visible bubble. A high safety_cap only guards a degenerate run.
static func _grass_transforms(
	seed: int, density: float, grid: float, salt: int, scale_mul: float, clump: bool
) -> Array[Transform3D]:
	var xforms: Array[Transform3D] = []
	var nx: int = int(ceil((WorldBounds.X_MAX - WorldBounds.X_MIN) / grid))
	var nz: int = int(ceil((WorldBounds.Z_MAX - WorldBounds.Z_MIN) / grid))
	var i: int = 0
	var placed: int = 0
	var cells: int = nx * nz
	var safety_cap: int = 500000
	# FloraField memo at 6 m clump-cell granularity (groves are 25-60 m features, so the
	# coarse sample is exact enough) — bounds the field queries to ~2.8k per layer instead
	# of one per 0.7 m grass cell. Value = Vector2(meadow edge_w, grove forest_w).
	var field_memo: Dictionary = {}
	while i < cells and placed < safety_cap:
		var cx: int = i % nx
		var cz: int = i / nx
		i += 1
		var hcell: int = ProcHash.h(seed * salt + cx * 131 + cz * 71 + 3)
		var bx: float = WorldBounds.X_MIN + (float(cx) + 0.5) * grid
		var bz: float = WorldBounds.Z_MIN + (float(cz) + 0.5) * grid
		# Per-cell emission weight: base `density` × coarse clump/patch fields (near layer).
		var dens_mul: float = density
		var meadow: float = 0.0
		if clump:
			var clx: int = int(floor((bx - WorldBounds.X_MIN) / 6.0))
			var clz: int = int(floor((bz - WorldBounds.Z_MIN) / 6.0))
			var cf: float = ProcHash.hf(ProcHash.h(seed * 769 + clx * 211 + clz * 97 + 5))
			dens_mul = (GRASS_CLUMP_FLOOR + cf * GRASS_CLUMP_RANGE) * density
			# Coarse 18 m patchiness octave (large-scale density drift ×0.8..1.2).
			var ptx: int = int(floor((bx - WorldBounds.X_MIN) / GRASS_PATCH_M))
			var ptz: int = int(floor((bz - WorldBounds.Z_MIN) / GRASS_PATCH_M))
			var pf: float = ProcHash.hf(ProcHash.h(seed * 911 + ptx * 313 + ptz * 109 + 11))
			dens_mul *= 0.8 + pf * 0.4
			# Forest-field modulation at clump granularity (memoized): tall meadows at
			# the treelines, thinner forest floor under grove canopies.
			var mkey: int = clx * 4096 + clz
			var fv: Vector2
			if field_memo.has(mkey):
				fv = field_memo[mkey]
			else:
				fv = Vector2(FloraField.edge_w(bx, bz), FloraField.forest_w(bx, bz))
				field_memo[mkey] = fv
			meadow = fv.x
			dens_mul *= (
				(1.0 + GRASS_MEADOW_BOOST * meadow)
				* (1.0 - GRASS_CANOPY_THIN * smoothstep(0.6, 1.0, fv.y))
			)
		# Probabilistically skip cells per the (clumped) density (deterministic per-cell hash).
		if ProcHash.hf(hcell + 9) > dens_mul:
			continue
		var px: float = bx + ProcHash.hrange(hcell + 1, -grid * 0.5, grid * 0.5)
		var pz: float = bz + ProcHash.hrange(hcell + 2, -grid * 0.5, grid * 0.5)
		if _blocked(px, pz):
			continue
		var gy: float = _ground_y(px, pz)
		if gy < -0.05:
			continue
		var yaw: float = ProcHash.hrange(hcell + 3, 0.0, TAU)
		# Denser clumps get slightly taller tufts; meadow edges get genuinely tall grass.
		var sc: float = (
			ProcHash.hrange(hcell + 4, 0.85, 1.15)
			* scale_mul
			* (1.0 + GRASS_MEADOW_HEIGHT * meadow)
		)
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3(sc, sc, sc))
		xforms.append(Transform3D(basis, Vector3(px, gy, pz)))
		placed += 1
	return xforms


## A tuft = 5-6 FINE curved blades fanned around the vertical axis. Each blade is THIN
## (base half-width 0.045 m, tip ~0.008 m) and split into TWO segments via a mid vertex
## that is offset along the lean direction, so the silhouette is a curved arc — not a
## rigid stick. Per-blade height (0.30-0.42 m), yaw and lean vary by deterministic hash.
## ~20-24 tris/tuft. UV.y runs 0 at the root → 1 at the tip on every vertex; the grass
## shader keys both its sway weight and its colour gradient off UV.y. Single-sided faces
## are fine — the shader is render_mode cull_disabled. NO vertex colors / per-instance
## colors (the colour comes from the shader uniforms; the MultiMesh vertex-color albedo
## path is silently lossy in Godot 4.6 here).
static func _grass_card_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Use a fixed hash stream so the mesh is identical on every machine (determinism).
	# 6 blades/tuft: lighter geometry per instance (eases weak/shared GPUs) while the
	# 26k clumped instance count still reads as a solid carpet, not discrete tufts.
	var blades: int = 6
	for bi in range(blades):
		var bh: int = ProcHash.h(98731 + bi * 53)
		# Even fan + a hashed nudge so blades aren't a perfect star.
		var ang: float = (float(bi) / float(blades)) * TAU + ProcHash.hrange(bh + 1, -0.35, 0.35)
		var dx: float = cos(ang)
		var dz: float = sin(ang)
		# Tall blades so the field reads as cinematic grass from the raised 3rd-person
		# camera, not a mown lawn that vanishes into a flat ground texture.
		var hgt: float = ProcHash.hrange(bh + 2, 0.75, 1.15)
		var base_half: float = 0.055
		var tip_half: float = 0.012
		# Lean direction (mostly outward along the blade, slight sideways drift).
		var lean: float = ProcHash.hrange(bh + 3, 0.06, 0.16)
		var side: float = ProcHash.hrange(bh + 4, -0.05, 0.05)
		var sx: float = -dz  # perpendicular for the sideways drift
		var sz: float = dx
		var mid_half: float = (base_half + tip_half) * 0.5
		# Mid vertex offset along the lean → curved arc (bends partway up).
		var mlx: float = dx * lean * 0.45 + sx * side * 0.4
		var mlz: float = dz * lean * 0.45 + sz * side * 0.4
		# Tip offset (full lean) → blade tips arc over.
		var tlx: float = dx * lean + sx * side
		var tlz: float = dz * lean + sz * side
		# Vertices: base edge (b0,b1), mid edge (m0,m1), tip edge (t0,t1).
		var b0 := Vector3(-dx * base_half, 0.0, -dz * base_half)
		var b1 := Vector3(dx * base_half, 0.0, dz * base_half)
		var m0 := Vector3(-dx * mid_half + mlx, hgt * 0.5, -dz * mid_half + mlz)
		var m1 := Vector3(dx * mid_half + mlx, hgt * 0.5, dz * mid_half + mlz)
		var t0 := Vector3(-dx * tip_half + tlx, hgt, -dz * tip_half + tlz)
		var t1 := Vector3(dx * tip_half + tlx, hgt, dz * tip_half + tlz)
		# Lower segment (base → mid): two tris.
		_grass_tri(st, b0, 0.0, b1, 0.0, m1, 0.5)
		_grass_tri(st, b0, 0.0, m1, 0.5, m0, 0.5)
		# Upper segment (mid → tip): two tris.
		_grass_tri(st, m0, 0.5, m1, 0.5, t1, 1.0)
		_grass_tri(st, m0, 0.5, t1, 1.0, t0, 1.0)
	st.generate_normals()
	return st.commit()


## Emit one grass triangle with per-vertex UV.y = height fraction (0 root → 1 tip).
## UV.x is unused by the shader; left at 0.
static func _grass_tri(
	st: SurfaceTool, a: Vector3, ua: float, b: Vector3, ub: float, c: Vector3, uc: float
) -> void:
	st.set_uv(Vector2(0.0, ua))
	st.add_vertex(a)
	st.set_uv(Vector2(0.0, ub))
	st.add_vertex(b)
	st.set_uv(Vector2(0.0, uc))
	st.add_vertex(c)


# ================================================================ STONES (×400)
## TWO MultiMeshInstance3D (a 50/50 hash-split into two grey shades), low-poly squashed
## SphereMesh. NO vertex colors / per-instance colors: the grey comes straight from the
## material `albedo_color` (the MultiMesh vertex-color albedo path is silently lossy in
## Godot 4.6 here → stones rendered white-grey). No collision.
static func _build_stones(root: Node3D, seed: int) -> void:
	var mesh: Mesh = ProceduralModels._sphere(0.5, false, 4, 6)
	var mat_a := StandardMaterial3D.new()
	mat_a.albedo_color = Color(0.42, 0.42, 0.44)  # plain grey
	mat_a.vertex_color_use_as_albedo = false
	mat_a.roughness = 0.95
	mat_a.metallic = 0.0
	var mat_b := StandardMaterial3D.new()
	mat_b.albedo_color = Color(0.50, 0.50, 0.52)  # lighter grey
	mat_b.vertex_color_use_as_albedo = false
	mat_b.roughness = 0.95
	mat_b.metallic = 0.0

	# Even spread over the rectangle (probability tuned to FLORA_STONES, not a corner cap).
	var target: int = Settings.FLORA_STONES
	var xforms_a: Array[Transform3D] = []
	var xforms_b: Array[Transform3D] = []
	var step: float = 4.5
	var nx: int = int((WorldBounds.X_MAX - WorldBounds.X_MIN) / step)
	var nz: int = int((WorldBounds.Z_MAX - WorldBounds.Z_MIN) / step)
	var accept: int = clampi(int(round(float(target) * 100.0 / float(maxi(1, nx * nz)))), 1, 90)
	var i: int = 0
	var placed: int = 0
	var cells: int = nx * nz
	while i < cells:
		var cx: int = i % nx
		var cz: int = i / nx
		i += 1
		var hcell: int = ProcHash.h(seed * 3217 + cx * 149 + cz * 89 + 13)
		if (hcell % 100) >= accept:
			continue
		var bx: float = WorldBounds.X_MIN + (float(cx) + 0.5) * step
		var bz: float = WorldBounds.Z_MIN + (float(cz) + 0.5) * step
		var px: float = bx + ProcHash.hrange(hcell + 1, -step * 0.5, step * 0.5)
		var pz: float = bz + ProcHash.hrange(hcell + 2, -step * 0.5, step * 0.5)
		if _blocked(px, pz):
			continue
		var gy: float = _ground_y(px, pz)
		if gy < -0.05:
			continue
		var yaw: float = ProcHash.hrange(hcell + 3, 0.0, TAU)
		var s: float = ProcHash.hrange(hcell + 4, 0.18, 0.5)
		# Flat-ish: squash Y, slight non-uniform X/Z.
		var sx: float = s * ProcHash.hrange(hcell + 6, 0.8, 1.3)
		var sz: float = s * ProcHash.hrange(hcell + 7, 0.8, 1.3)
		var sy: float = s * ProcHash.hrange(hcell + 8, 0.35, 0.6)
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3(sx, sy, sz))
		# Stone mesh is a unit sphere centred on its origin (half-height = 0.5*sy). Sit it
		# low so it stays embedded in / flush with the ground on slopes rather than perched
		# on a flat-ground assumption (the old +0.4*sy floated on relief).
		var xf := Transform3D(basis, Vector3(px, gy + sy * 0.15, pz))
		# Deterministic 50/50 shade split.
		if (ProcHash.h(hcell + 5) % 2) == 0:
			xforms_a.append(xf)
		else:
			xforms_b.append(xf)
		placed += 1

	_emit_stone_layer(root, "Stones_A", mesh, mat_a, xforms_a)
	_emit_stone_layer(root, "Stones_B", mesh, mat_b, xforms_b)


## Build one stones MultiMeshInstance3D from a prebuilt transform list (no colors).
static func _emit_stone_layer(
	root: Node3D, nm: String, mesh: Mesh, mat: StandardMaterial3D, xforms: Array[Transform3D]
) -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for j in range(xforms.size()):
		mm.set_instance_transform(j, xforms[j])
	mmi.multimesh = mm
	mmi.material_override = mat
	root.add_child(mmi)


# ================================================================ BOULDERS (Quaternius glTF)
## BIG collidable cover rocks from the Quaternius Rock_Medium models (~2-3 m raw). One
## MultiMesh per rock model (render-only) + a StaticBody3D + SphereShape3D per instance on
## layer 1 so they join the navmesh bake and act as cover. Placed on the same golden-angle
## candidate ring as before, ≥10 m apart, with a couple allowed at the river bank.
static func _build_boulders(root: Node3D, seed: int) -> void:
	var node := Node3D.new()
	node.name = "Boulders"
	root.add_child(node)
	if not Settings.CHUNK_DESTRUCTION_ENABLED:
		_build_boulders_legacy(node, seed)  # OFF: old MMI+collider path → Flora byte-identical
		return
	# ON: each boulder is a discrete breakable STONE BreakableChunk (cover, layer 1) so it shatters
	# into rock + a collapse SFX. Plus a modest set of small shoot-only rocks ("мелкие камни").
	var target: int = Settings.FLORA_BOULDERS
	var candidates: Array = _boulder_candidates(seed)
	var placed: Array[Vector2] = []
	var idx: int = 0
	var near_river_done: int = 0
	while idx < candidates.size() and placed.size() < target:
		var c: Vector2 = candidates[idx]
		idx += 1
		if _blocked(c.x, c.y, true):
			continue
		var gy: float = _ground_y(c.x, c.y)
		var river_bank: bool = gy < -0.05 and gy > -0.30
		if gy < -0.05 and not (river_bank and near_river_done < 2):
			continue
		var ok: bool = true
		for p in placed:
			if c.distance_to(p) < 10.0:
				ok = false
				break
		if not ok:
			continue
		if river_bank:
			near_river_done += 1
		var hseed: int = ProcHash.h(seed * 7919 + placed.size() * 53 + 21)
		_place_breakable_rock(node, hseed, c.x, maxf(gy, 0.0), c.y, true)
		placed.append(c)
	_build_small_rocks(node, seed)


## The deterministic golden-angle candidate ring for boulders (shared by legacy + breakable paths).
static func _boulder_candidates(seed: int) -> Array:
	var candidates: Array = []
	for k in range(200):
		var hk: int = ProcHash.h(seed * 4099 + k * 37 + 9)
		var ang: float = float(k) * 2.39996323
		var rad: float = ProcHash.hrange(hk + 1, 20.0, 150.0)
		var cx: float = WorldBounds.CX + cos(ang) * rad + ProcHash.hrange(hk + 2, -4.0, 4.0)
		var cz: float = WorldBounds.CZ + sin(ang) * rad + ProcHash.hrange(hk + 3, -4.0, 4.0)
		candidates.append(Vector2(cx, cz))
	return candidates


## A scatter of small shoot-only breakable rocks (the user's "мелкие камни"): on the dedicated rock
## layer so the navmesh + player ignore them (no tripping / nav-fragmentation) while bullets + grenades
## still break them. Distance-culled. Deterministic (ProcHash only).
static func _build_small_rocks(node: Node3D, seed: int) -> void:
	var target: int = Settings.FLORA_SMALL_ROCKS
	var placed: Array[Vector2] = []
	var k: int = 0
	while k < 400 and placed.size() < target:
		var hk: int = ProcHash.h(seed * 5237 + k * 41 + 3)
		var ang: float = float(k) * 2.39996323
		var rad: float = ProcHash.hrange(hk + 1, 14.0, 150.0)
		var cx: float = WorldBounds.CX + cos(ang) * rad + ProcHash.hrange(hk + 2, -3.0, 3.0)
		var cz: float = WorldBounds.CZ + sin(ang) * rad + ProcHash.hrange(hk + 3, -3.0, 3.0)
		k += 1
		var c := Vector2(cx, cz)
		if _blocked(cx, cz, true):
			continue
		var gy: float = _ground_y(cx, cz)
		if gy < -0.05:
			continue
		var ok: bool = true
		for p in placed:
			if c.distance_to(p) < 4.0:
				ok = false
				break
		if not ok:
			continue
		var hseed: int = ProcHash.h(seed * 6113 + placed.size() * 47 + 5)
		_place_breakable_rock(node, hseed, cx, maxf(gy, 0.0), cz, false)
		placed.append(c)


## Build ONE rock as a discrete BreakableChunk (material_kind = STONE). `cover` rocks are big +
## block (layer 1, bake into navmesh as cover); small rocks are shoot-only (rock layer, no nav/player
## collision). The "Mesh" carries the per-instance scale so the body + sphere stay unscaled.
static func _place_breakable_rock(
	parent: Node3D, hseed: int, x: float, y: float, z: float, cover: bool
) -> void:
	var mi: int = ProcHash.h(hseed + 1) % _ROCK_MODELS.size()
	var id: String = String(_ROCK_MODELS[mi][0])
	var base_scale: float = float(_ROCK_MODELS[mi][1])
	var yaw: float = ProcHash.hrange(hseed + 2, 0.0, TAU)
	var sc: float = (
		base_scale
		* (ProcHash.hrange(hseed + 3, 0.7, 1.3) if cover else ProcHash.hrange(hseed + 3, 0.18, 0.4))
	)
	ProceduralBuildings._chunk_seq += 1
	var c := BreakableChunk.new()
	c.name = "Rock_%d" % ProceduralBuildings._chunk_seq
	c.index = ProceduralBuildings._chunk_seq
	c.material_kind = Settings.CHUNK_KIND_STONE
	c.hp = Settings.CHUNK_HP * float(Settings.CHUNK_KIND_DEFS[Settings.CHUNK_KIND_STONE]["hp_mult"])
	var r: float = maxf(1.3 * sc, 0.45)
	c.chunk_size = Vector3(r * 2.0, r * 2.0, r * 2.0)
	c.chunk_color = Color(0.42, 0.40, 0.38)
	c.collision_layer = 1 if cover else (1 << (Settings.CHUNK_ROCK_LAYER - 1))
	c.collision_mask = 0
	c.transform = Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)), Vector3(x, y, z))
	parent.add_child(c)
	var mvis := MeshInstance3D.new()
	mvis.name = "Mesh"
	mvis.mesh = FloraMeshLib.model_mesh(id)  # null on headless → invisible, collider still bakes
	mvis.scale = Vector3(sc, sc, sc)
	if not cover:
		mvis.visibility_range_end = 55.0  # cull small rocks at distance (perf)
	c.add_child(mvis)
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var sh := SphereShape3D.new()
	sh.radius = r
	col.shape = sh
	col.position = Vector3(0.0, r * 0.4, 0.0)
	c.add_child(col)


## Legacy boulders (render-only MMI per model + a discrete sphere collider per instance) — used when
## destruction is OFF so the Flora golden snapshot stays byte-identical. Verbatim of the pre-2.1 path.
static func _build_boulders_legacy(node: Node3D, seed: int) -> void:
	var colliders := Node3D.new()
	colliders.name = "BoulderColliders"
	node.add_child(colliders)

	# Per-model transform buckets, parallel to _ROCK_MODELS.
	var buckets: Array = []
	for i in range(_ROCK_MODELS.size()):
		buckets.append([] as Array[Transform3D])

	var target: int = Settings.FLORA_BOULDERS
	# Golden-angle ring of candidate positions (deterministic), centred on the world
	# rectangle (80,80) and widened to reach the new +X/+Z quadrants (rad 20..150 m).
	var candidates: Array = []
	var n_cand: int = 200
	for k in range(n_cand):
		var hk: int = ProcHash.h(seed * 4099 + k * 37 + 9)
		var ang: float = float(k) * 2.39996323  # golden angle (rad)
		var rad: float = ProcHash.hrange(hk + 1, 20.0, 150.0)
		var cx: float = WorldBounds.CX + cos(ang) * rad + ProcHash.hrange(hk + 2, -4.0, 4.0)
		var cz: float = WorldBounds.CZ + sin(ang) * rad + ProcHash.hrange(hk + 3, -4.0, 4.0)
		candidates.append(Vector2(cx, cz))

	var placed: Array[Vector2] = []
	var idx: int = 0
	var near_river_done: int = 0
	while idx < candidates.size() and placed.size() < target:
		var c: Vector2 = candidates[idx]
		idx += 1
		# Boulders may edge into the berm (|coord| up to 75) for looks.
		if _blocked(c.x, c.y, true):
			continue
		var gy: float = _ground_y(c.x, c.y)
		# Allow a couple of boulders right at the river bank (slightly negative height)
		# but never IN the water (< -0.30).
		var river_bank: bool = gy < -0.05 and gy > -0.30
		if gy < -0.05 and not (river_bank and near_river_done < 2):
			continue
		# ≥10 m spacing from accepted boulders.
		var ok: bool = true
		for p in placed:
			if c.distance_to(p) < 10.0:
				ok = false
				break
		if not ok:
			continue
		if river_bank:
			near_river_done += 1
		var hseed: int = ProcHash.h(seed * 7919 + placed.size() * 53 + 21)
		_place_boulder(colliders, buckets, hseed, c.x, maxf(gy, 0.0), c.y)
		placed.append(c)

	# Emit one MultiMesh per rock model from its bucket.
	for i in range(_ROCK_MODELS.size()):
		var id: String = String(_ROCK_MODELS[i][0])
		FloraMeshLib.emit_model_mm(
			node, "Boulder_%s" % id, FloraMeshLib.model_meshes(id), buckets[i], _flora_vis_end()
		)


## Pick a rock model by hash, append a yaw+scale-jittered Transform3D to its bucket, and
## emit a sphere collider sized to the scaled rock footprint (~1.4 m raw radius * scale).
static func _place_boulder(
	colliders: Node3D, buckets: Array, hseed: int, x: float, y: float, z: float
) -> void:
	var mi: int = ProcHash.h(hseed + 1) % _ROCK_MODELS.size()
	var base_scale: float = float(_ROCK_MODELS[mi][1])
	var yaw: float = ProcHash.hrange(hseed + 2, 0.0, TAU)
	# Cover-rock scale: raw models are ~2-3 m wide; 0.7-1.3× keeps a good cover spread.
	var sc: float = base_scale * ProcHash.hrange(hseed + 3, 0.7, 1.3)
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3(sc, sc, sc))
	(buckets[mi] as Array[Transform3D]).append(Transform3D(basis, Vector3(x, y, z)))

	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector3(x, y, z)
	colliders.add_child(body)
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	# Rock_Medium models are ~1.4 m radius before scale; hug it a touch under the visual.
	sh.radius = maxf(1.3 * sc, 0.6)
	col.shape = sh
	# Sit the sphere low so its BASE rests at/just-below the ground at the placement
	# point (mesh origin ≈ rock base). A high centre (0.7×r) left the sphere floating
	# on downhill slopes; 0.4×r keeps the base firmly grounded while the top still
	# covers the rock body for the navmesh bake.
	col.position = Vector3(0.0, sh.radius * 0.4, 0.0)
	body.add_child(col)
