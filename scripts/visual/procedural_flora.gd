extends RefCounted
class_name ProceduralFlora
## Procedural VEGETATION + ROCKS scattered across the 160×160 urban-ruins map:
## trees (conifer/broadleaf), bushes, a dense grass MultiMesh, a small-stone
## MultiMesh, and a handful of BIG collidable boulders used as cover.
##
## EVERYTHING is DETERMINISTIC — co-op peers each build the arena locally, so the
## geometry MUST be identical on every machine. All placement and per-instance
## variation derives ONLY from `Settings.TERRAIN_SEED` + the arithmetic-hash idiom
## (`_h`/`_hf`, copied from procedural_buildings.gd). NO randf/randi/Time.
##
## Ground height comes from procedural_terrain.gd's `height_at(x,z)` if that file
## exists (terrain-dev builds it in parallel); otherwise we fall back to y=0 so this
## works both ways. Inside the river `height_at` is NEGATIVE — we skip planting where
## height < -0.05.
##
## Collision model (so the runtime navmesh routes around cover):
##   - tree TRUNKS: StaticBody3D + CylinderShape3D (layer 1, mask 0); canopies render-only.
##   - BOULDERS: StaticBody3D + SphereShape3D (layer 1, mask 0) — gameplay cover.
##   - bushes / grass / small stones: render-only (no collision).
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; every Dictionary.get
## and ternary local below is explicitly typed.

# ---------------------------------------------------------------- seed helpers
## Cheap deterministic positive hash of an int → big positive int.
static func _h(n: int) -> int:
	var x: int = (n * 2654435761) ^ 0x27d4eb2d
	x = (x ^ (x >> 15)) * 0x85ebca6b
	x = x ^ (x >> 13)
	return abs(x)

## Deterministic float in [0,1) from seed `n`.
static func _hf(n: int) -> float:
	return float(_h(n) % 100000) / 100000.0

## Deterministic float in [lo,hi) from seed `n`.
static func _hrange(n: int, lo: float, hi: float) -> float:
	return lo + _hf(n) * (hi - lo)

# ---------------------------------------------------------------- terrain hook
## Resolved once in build(): the terrain GDScript (or null when terrain-dev's file
## isn't present yet). Stored as a plain Variant so the guarded call is cheap.
static var _terrain: GDScript = null
static var _has_terrain: bool = false

static func _ground_y(x: float, z: float) -> float:
	if _has_terrain:
		return float(_terrain.height_at(x, z))
	return 0.0

# ---------------------------------------------------------------- keep-out tests
# POI footprints (cx, cz, half-w, half-d) already widened by the +8 m margin; plus
# the plaza circle, the extraction circles, and the player-spawn cluster.
const _POI_RECTS: Array = [
	[-40.0, -45.0, 8.5 + 8.0, 7.5 + 8.0],
	[45.0, -28.0, 11.0 + 8.0, 9.0 + 8.0],
	[-52.0, 30.0, 7.5 + 8.0, 7.5 + 8.0],
	[-30.0, 50.0, 9.0 + 8.0, 8.0 + 8.0],
	[50.0, 42.0, 9.0 + 8.0, 8.0 + 8.0],
]
# Circular keep-outs (cx, cz, radius): plaza, the three extraction zones, spawn.
const _CIRCLES: Array = [
	[0.0, 0.0, 14.0],     # plaza
	[45.0, -28.0, 11.0],  # extraction
	[-30.0, 50.0, 11.0],  # extraction
	[-52.0, 30.0, 11.0],  # extraction
	[59.0, 60.0, 17.0],   # player spawn cluster
]

## True when (x,z) is inside any structure/zone/spawn keep-out OR off the playable
## field. `allow_berm` lets boulders sit a little further out (|coord| up to 75).
static func _blocked(x: float, z: float, allow_berm: bool = false) -> bool:
	var limit: float = 75.0 if allow_berm else 72.0
	if absf(x) > limit or absf(z) > limit:
		return true
	for r in _CIRCLES:
		var dx: float = x - float(r[0])
		var dz: float = z - float(r[1])
		var rad: float = float(r[2])
		if dx * dx + dz * dz < rad * rad:
			return true
	for b in _POI_RECTS:
		if absf(x - float(b[0])) < float(b[2]) and absf(z - float(b[1])) < float(b[3]):
			return true
	return false

# ================================================================ entry point
## Construct all flora, add a single root under `parent`, and return it.
static func build(parent: Node3D) -> Node3D:
	var ts: GDScript = load("res://scripts/visual/procedural_terrain.gd")
	_terrain = ts
	_has_terrain = ts != null

	var root := Node3D.new()
	root.name = "Flora"
	parent.add_child(root)

	var seed: int = Settings.TERRAIN_SEED

	# Shared materials (a small handful, reused by every tree/bush — NOT one per tree).
	var mats: Dictionary = _make_materials(seed)

	_build_trees(root, seed, mats)
	_build_bushes(root, seed, mats)
	_build_grass(root, seed)
	_build_stones(root, seed)
	_build_boulders(root, seed)
	return root

# ---------------------------------------------------------------- shared materials
## ~7 shared StandardMaterial3D reused across all trees/bushes so we never build 80
## unique materials. Keyed by name in the returned Dictionary.
static func _make_materials(seed: int) -> Dictionary:
	var d: Dictionary = {}
	# Bark — two subtle tones so conifer/broadleaf trunks differ.
	d["bark"] = ProceduralModels._mat(Color(0.35, 0.26, 0.18), 0.0, 0.95)
	d["bark2"] = ProceduralModels._mat(Color(0.30, 0.23, 0.17), 0.0, 0.95)
	# Conifer canopy — three dark-green shades for per-tree variation.
	d["conifer_a"] = ProceduralModels._mat(Color(0.14, 0.28, 0.16), 0.0, 0.9)
	d["conifer_b"] = ProceduralModels._mat(Color(0.17, 0.32, 0.19), 0.0, 0.9)
	d["conifer_c"] = ProceduralModels._mat(Color(0.13, 0.25, 0.15), 0.0, 0.9)
	# Broadleaf canopy — three mid-green shades.
	d["broad_a"] = ProceduralModels._mat(Color(0.24, 0.38, 0.20), 0.0, 0.88)
	d["broad_b"] = ProceduralModels._mat(Color(0.27, 0.42, 0.22), 0.0, 0.88)
	d["broad_c"] = ProceduralModels._mat(Color(0.21, 0.34, 0.18), 0.0, 0.88)
	# Bush — DARK shrub greens (kept low + slightly darker so squashed spheres don't
	# read as bright blocky blobs next to the fine grass).
	d["bush_a"] = ProceduralModels._mat(Color(0.15, 0.26, 0.14), 0.0, 0.93)
	d["bush_b"] = ProceduralModels._mat(Color(0.18, 0.29, 0.16), 0.0, 0.93)
	return d

# ================================================================ TREES (×80)
## Deterministic jittered-grid scatter: walk a coarse grid over the field, hash-decide
## presence per cell + hash-jitter the position inside the cell. The grid spacing gives
## the ≥4 m min-spacing between trees for free and stays fully deterministic.
static func _build_trees(root: Node3D, seed: int, mats: Dictionary) -> int:
	var trees := Node3D.new()
	trees.name = "Trees"
	root.add_child(trees)

	var target: int = Settings.FLORA_TREES
	var placed: int = 0
	# Coarse grid ~7 m cells over the ~[-72,72] field → plenty of candidate cells;
	# we hash-skip most so we land near `target` with good spread (>=4 m apart).
	var step: float = 7.0
	var half: float = 70.0
	var gx: int = 0
	var x: float = -half
	while x <= half and placed < target:
		var gz: int = 0
		var z: float = -half
		while z <= half and placed < target:
			var cell: int = _h(seed * 911 + gx * 257 + gz * 31 + 7)
			# Accept ~62% of cells; jitter keeps them off a visible lattice.
			if (cell % 100) < 62:
				var jx: float = _hrange(cell + 1, -2.6, 2.6)
				var jz: float = _hrange(cell + 2, -2.6, 2.6)
				var px: float = x + jx
				var pz: float = z + jz
				if not _blocked(px, pz):
					var gy: float = _ground_y(px, pz)
					if gy >= -0.05:  # not in the river
						_make_tree(trees, cell, px, gy, pz, mats)
						placed += 1
			gz += 1
			z += step
		gx += 1
		x += step
	return placed

## One tree = one Node3D: a trunk (collidable) + canopy (render-only). Species picked
## by hash. Heights 4-7 m.
static func _make_tree(parent: Node3D, hseed: int, x: float, y: float, z: float,
		mats: Dictionary) -> void:
	var node := Node3D.new()
	node.position = Vector3(x, y, z)
	# Whole-tree yaw so foliage doesn't all face the same way.
	node.rotation.y = _hrange(hseed + 11, 0.0, TAU)
	parent.add_child(node)

	var height: float = _hrange(hseed + 3, 4.0, 7.0)
	var conifer: bool = (_h(hseed + 5) % 2) == 0

	# --- trunk (collidable) ---
	var trunk_h: float = height * (0.5 if conifer else 0.46)
	var trunk_r: float = _hrange(hseed + 7, 0.16, 0.26)
	var bark: StandardMaterial3D = mats["bark"] if conifer else mats["bark2"]
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	node.add_child(body)
	# Slight upward taper for the trunk mesh.
	var tm := CylinderMesh.new()
	tm.top_radius = trunk_r * 0.6
	tm.bottom_radius = trunk_r
	tm.height = trunk_h
	tm.radial_segments = 8
	var tmi := MeshInstance3D.new()
	tmi.mesh = tm
	tmi.material_override = bark
	tmi.position = Vector3(0.0, trunk_h * 0.5, 0.0)
	body.add_child(tmi)
	var col := CollisionShape3D.new()
	var cs := CylinderShape3D.new()
	cs.radius = maxf(trunk_r, 0.22)
	cs.height = trunk_h
	col.shape = cs
	col.position = Vector3(0.0, trunk_h * 0.5, 0.0)
	body.add_child(col)

	# --- canopy (render-only) ---
	if conifer:
		_conifer_canopy(node, hseed, trunk_h, height, trunk_r, mats)
	else:
		_broadleaf_canopy(node, hseed, trunk_h, height, trunk_r, mats)

## 2-3 stacked cones, narrowing upward, dark-green.
static func _conifer_canopy(node: Node3D, hseed: int, trunk_h: float, height: float,
		trunk_r: float, mats: Dictionary) -> void:
	var pick: int = _h(hseed + 21) % 3
	var leaf: StandardMaterial3D = mats["conifer_a"]
	if pick == 1:
		leaf = mats["conifer_b"]
	elif pick == 2:
		leaf = mats["conifer_c"]
	var tiers: int = 2 + (_h(hseed + 23) % 2)  # 2 or 3
	var canopy_h: float = height - trunk_h * 0.6
	var base_r: float = _hrange(hseed + 25, 1.3, 1.9)
	var bottom: float = trunk_h * 0.55
	var tier_h: float = canopy_h / float(tiers)
	for i in range(tiers):
		var frac: float = float(i) / float(maxi(tiers, 1))
		var r: float = base_r * (1.0 - frac * 0.55)
		var cone_h: float = tier_h * 1.55
		var cy: float = bottom + tier_h * float(i) + cone_h * 0.5
		ProceduralModels._part(node, ProceduralModels._cone(r, cone_h, 9), leaf,
			Vector3(0.0, cy, 0.0))

## 2-3 overlapping spheres, mid-green.
static func _broadleaf_canopy(node: Node3D, hseed: int, trunk_h: float, height: float,
		trunk_r: float, mats: Dictionary) -> void:
	var pick: int = _h(hseed + 31) % 3
	var leaf: StandardMaterial3D = mats["broad_a"]
	if pick == 1:
		leaf = mats["broad_b"]
	elif pick == 2:
		leaf = mats["broad_c"]
	var blobs: int = 2 + (_h(hseed + 33) % 2)  # 2 or 3
	var crown_r: float = _hrange(hseed + 35, 1.4, 2.1)
	var crown_y: float = trunk_h + crown_r * 0.55
	for i in range(blobs):
		var ox: float = _hrange(hseed + 41 + i * 3, -crown_r * 0.5, crown_r * 0.5)
		var oz: float = _hrange(hseed + 42 + i * 3, -crown_r * 0.5, crown_r * 0.5)
		var oy: float = _hrange(hseed + 43 + i * 3, -crown_r * 0.25, crown_r * 0.45)
		var br: float = crown_r * _hrange(hseed + 44 + i * 3, 0.7, 1.0)
		ProceduralModels._part(node, ProceduralModels._sphere(br, false, 7, 9), leaf,
			Vector3(ox, crown_y + oy, oz))

# ================================================================ BUSHES (×60)
## 1-2 squashed spheres, no collision. Scattered on a finer jittered grid, separate
## hash stream so they don't collide with the tree lattice.
static func _build_bushes(root: Node3D, seed: int, mats: Dictionary) -> int:
	var bushes := Node3D.new()
	bushes.name = "Bushes"
	root.add_child(bushes)

	var target: int = Settings.FLORA_BUSHES
	var placed: int = 0
	var step: float = 6.5
	var half: float = 70.0
	var gx: int = 0
	var x: float = -half + 3.0
	while x <= half and placed < target:
		var gz: int = 0
		var z: float = -half + 3.0
		while z <= half and placed < target:
			var cell: int = _h(seed * 1303 + gx * 193 + gz * 47 + 17)
			if (cell % 100) < 40:
				var px: float = x + _hrange(cell + 1, -2.4, 2.4)
				var pz: float = z + _hrange(cell + 2, -2.4, 2.4)
				if not _blocked(px, pz):
					var gy: float = _ground_y(px, pz)
					if gy >= -0.05:
						_make_bush(bushes, cell, px, gy, pz, mats)
						placed += 1
			gz += 1
			z += step
		gx += 1
		x += step
	return placed

static func _make_bush(parent: Node3D, hseed: int, x: float, y: float, z: float,
		mats: Dictionary) -> void:
	var node := Node3D.new()
	node.position = Vector3(x, y, z)
	parent.add_child(node)
	var leaf: StandardMaterial3D = mats["bush_a"] if (_h(hseed + 51) % 2) == 0 else mats["bush_b"]
	# Slightly smaller than before so squashed-sphere bushes read less as blocky blobs.
	var size: float = _hrange(hseed + 53, 0.5, 1.0)
	var blobs: int = 1 + (_h(hseed + 55) % 2)  # 1 or 2
	for i in range(blobs):
		var r: float = size * _hrange(hseed + 57 + i * 3, 0.6, 0.85)
		var ox: float = _hrange(hseed + 58 + i * 3, -size * 0.4, size * 0.4)
		var oz: float = _hrange(hseed + 59 + i * 3, -size * 0.4, size * 0.4)
		# Squash vertically so it reads as a low shrub, not a green ball.
		ProceduralModels._part(parent, ProceduralModels._sphere(r, false, 6, 8), leaf,
			Vector3(x + ox, y + r * 0.30, z + oz), Vector3.ZERO,
			Vector3(1.0, 0.55, 1.0))

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

static func _build_grass(root: Node3D, seed: int) -> void:
	# One fine-blade mesh, shared by every tile of both LOD layers.
	var mesh: ArrayMesh = _grass_card_mesh()
	# ONE ShaderMaterial (shaders/grass.gdshader): root→tip gradient + per-tuft tint +
	# tip-weighted wind sway. Shared by every tile so the material count stays at one.
	var sh: Shader = load("res://shaders/grass.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("base_color", Color(0.20, 0.34, 0.13))  # dark root green
	mat.set_shader_parameter("tip_color", Color(0.44, 0.60, 0.25))   # lighter tip
	# Sway tuned for clearly visible wind on the short fine blades (subtle 0.08 read as
	# nearly static in QA at gameplay distance).
	mat.set_shader_parameter("sway_strength", 0.16)
	mat.set_shader_parameter("sway_speed", 2.2)

	# NEAR layer: dense, clumped, short visibility range, fades self. Tiled.
	# Cap slightly below the Settings budget so on-screen tiles stay cheap (the perf gate
	# is per-tile draw cost, not the global count) — keeps ~11k near.
	var near_target: int = mini(Settings.FLORA_GRASS_PATCHES, 11000)
	var near_xforms: Array[Transform3D] = _grass_transforms(
		seed, near_target, 0.95, 4099, 1.0, true)
	var near_root := Node3D.new()
	near_root.name = "Grass_Near"
	root.add_child(near_root)
	var near_tiles: int = _emit_grass_tiled(near_root, "near", mesh, mat, near_xforms,
		0.0, Settings.GRASS_VIS_RANGE, 8.0)

	# FAR layer: fewer, larger tufts, picks up where near begins to drop out. Tiled too —
	# its AABB is otherwise also map-wide, so without tiling it'd never cull either.
	var far_target: int = mini(Settings.FLORA_GRASS_FAR, 2000)
	var far_xforms: Array[Transform3D] = _grass_transforms(
		seed, far_target, 2.2, 5557, 1.6, false)
	var far_root := Node3D.new()
	far_root.name = "Grass_Far"
	root.add_child(far_root)
	# begin=33 so it cross-fades in as the near layer fades out (no hard ring/line).
	var far_tiles: int = _emit_grass_tiled(far_root, "far", mesh, mat, far_xforms,
		33.0, Settings.GRASS_FAR_RANGE, 10.0)

	if Settings.NET_DEBUG:
		print("[flora] grass near=%d (%d tiles) far=%d (%d tiles) tile=%.0fm" % [
			near_xforms.size(), near_tiles, far_xforms.size(), far_tiles, GRASS_TILE_M])

## Partition `xforms` into GRASS_TILE_M-metre spatial tiles and emit ONE
## MultiMeshInstance3D per non-empty tile (key = "<gx>_<gz>"), each with the given
## visibility range so per-tile AABBs let visibility_range actually cull distant tiles.
## Returns the number of tiles (MMIs) emitted. `vis_begin`=0 means no begin range.
static func _emit_grass_tiled(parent: Node3D, prefix: String, mesh: ArrayMesh,
		mat: ShaderMaterial, xforms: Array[Transform3D], vis_begin: float,
		vis_end: float, end_margin: float) -> int:
	# Bucket transforms by tile. Dictionary key = packed grid coord; value = Array[Transform3D].
	var buckets: Dictionary = {}
	for xf in xforms:
		var p: Vector3 = xf.origin
		var gx: int = int(floor((p.x + 80.0) / GRASS_TILE_M))
		var gz: int = int(floor((p.z + 80.0) / GRASS_TILE_M))
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

## Build a deterministic grass transform list on a jittered grid with CLUMPING: a coarse
## ~6 m hash field scales emission per cell (some patches 1.6× denser, some 0.4× sparser)
## so the field reads as natural patches, not a uniform lawn. `grid` = nominal spacing (m),
## `salt` separates the near/far hash streams, `scale_mul` sizes the tufts, `clump`
## toggles the density variation. Keeps every existing keep-out / river guard.
static func _grass_transforms(seed: int, target: int, grid: float, salt: int,
		scale_mul: float, clump: bool) -> Array[Transform3D]:
	var xforms: Array[Transform3D] = []
	var half: float = 70.0
	var side: int = int(ceil((half * 2.0) / grid))
	# We over-provide grid cells; clumping + keep-out loss thin them. Emit until budget.
	var i: int = 0
	var placed: int = 0
	var cells: int = side * side
	while i < cells and placed < target:
		var cx: int = i % side
		var cz: int = i / side
		i += 1
		var hcell: int = _h(seed * salt + cx * 131 + cz * 71 + 3)
		var bx: float = -half + (float(cx) + 0.5) * grid
		var bz: float = -half + (float(cz) + 0.5) * grid
		# Clumping: coarse ~6 m field decides this cell's emission probability/scale.
		var dens_mul: float = 1.0
		if clump:
			var clx: int = int(floor((bx + half) / 6.0))
			var clz: int = int(floor((bz + half) / 6.0))
			var cf: float = _hf(_h(seed * 769 + clx * 211 + clz * 97 + 5))
			# Map the field → 0.4× (sparse) .. 1.6× (dense) emission weight.
			dens_mul = 0.4 + cf * 1.2
			# Probabilistically skip cells in sparse clumps (deterministic per-cell hash).
			if _hf(hcell + 9) > dens_mul:
				continue
		var px: float = bx + _hrange(hcell + 1, -grid * 0.5, grid * 0.5)
		var pz: float = bz + _hrange(hcell + 2, -grid * 0.5, grid * 0.5)
		if _blocked(px, pz):
			continue
		var gy: float = _ground_y(px, pz)
		if gy < -0.05:
			continue
		var yaw: float = _hrange(hcell + 3, 0.0, TAU)
		# Denser clumps get slightly taller tufts too.
		var sc: float = _hrange(hcell + 4, 0.85, 1.15) * scale_mul
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
	var blades: int = 6
	for bi in range(blades):
		var bh: int = _h(98731 + bi * 53)
		# Even fan + a hashed nudge so blades aren't a perfect star.
		var ang: float = (float(bi) / float(blades)) * TAU + _hrange(bh + 1, -0.35, 0.35)
		var dx: float = cos(ang)
		var dz: float = sin(ang)
		var hgt: float = _hrange(bh + 2, 0.30, 0.42)
		var base_half: float = 0.045
		var tip_half: float = 0.008
		# Lean direction (mostly outward along the blade, slight sideways drift).
		var lean: float = _hrange(bh + 3, 0.06, 0.16)
		var side: float = _hrange(bh + 4, -0.05, 0.05)
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
static func _grass_tri(st: SurfaceTool, a: Vector3, ua: float, b: Vector3, ub: float,
		c: Vector3, uc: float) -> void:
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

	var target: int = Settings.FLORA_STONES
	var xforms_a: Array[Transform3D] = []
	var xforms_b: Array[Transform3D] = []
	var side: int = int(ceil(sqrt(float(target) * 2.8)))
	var span: float = 140.0
	var ystep: float = span / float(side)
	var i: int = 0
	var placed: int = 0
	while i < side * side and placed < target:
		var cx: int = i % side
		var cz: int = i / side
		var hcell: int = _h(seed * 3217 + cx * 149 + cz * 89 + 13)
		var bx: float = -70.0 + (float(cx) + 0.5) * ystep
		var bz: float = -70.0 + (float(cz) + 0.5) * ystep
		var px: float = bx + _hrange(hcell + 1, -ystep * 0.5, ystep * 0.5)
		var pz: float = bz + _hrange(hcell + 2, -ystep * 0.5, ystep * 0.5)
		i += 1
		if _blocked(px, pz):
			continue
		var gy: float = _ground_y(px, pz)
		if gy < -0.05:
			continue
		var yaw: float = _hrange(hcell + 3, 0.0, TAU)
		var s: float = _hrange(hcell + 4, 0.18, 0.5)
		# Flat-ish: squash Y, slight non-uniform X/Z.
		var sx: float = s * _hrange(hcell + 6, 0.8, 1.3)
		var sz: float = s * _hrange(hcell + 7, 0.8, 1.3)
		var sy: float = s * _hrange(hcell + 8, 0.35, 0.6)
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3(sx, sy, sz))
		var xf := Transform3D(basis, Vector3(px, gy + sy * 0.4, pz))
		# Deterministic 50/50 shade split.
		if (_h(hcell + 5) % 2) == 0:
			xforms_a.append(xf)
		else:
			xforms_b.append(xf)
		placed += 1

	_emit_stone_layer(root, "Stones_A", mesh, mat_a, xforms_a)
	_emit_stone_layer(root, "Stones_B", mesh, mat_b, xforms_b)

## Build one stones MultiMeshInstance3D from a prebuilt transform list (no colors).
static func _emit_stone_layer(root: Node3D, nm: String, mesh: Mesh,
		mat: StandardMaterial3D, xforms: Array[Transform3D]) -> void:
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

# ================================================================ BOULDERS (×14)
## BIG collidable cover rocks (1.2-2.6 m). Mesh = a low-poly sphere whose vertices are
## displaced deterministically by hash noise (±~25%), so each boulder is a unique
## lumpy rock. StaticBody3D + SphereShape3D on layer 1 → joins the navmesh bake.
static func _build_boulders(root: Node3D, seed: int) -> void:
	var node := Node3D.new()
	node.name = "Boulders"
	root.add_child(node)

	var rock_mat: StandardMaterial3D = ProcMaterials.weathered(
		Color(0.44, 0.45, 0.47), 0.0, 0.95, 0.6, seed * 5 + 1)

	var target: int = Settings.FLORA_BOULDERS
	# Hand-spread anchor ring of candidate positions (deterministic), plus a couple
	# near the river bank for looks. We accept the first `target` valid ones, keeping
	# each ≥10 m from the previously accepted boulders.
	var candidates: Array = []
	# Golden-angle ring of candidates across the open field.
	var n_cand: int = 64
	for k in range(n_cand):
		var hk: int = _h(seed * 4099 + k * 37 + 9)
		var ang: float = float(k) * 2.39996323  # golden angle (rad)
		var rad: float = _hrange(hk + 1, 18.0, 68.0)
		var cx: float = cos(ang) * rad + _hrange(hk + 2, -4.0, 4.0)
		var cz: float = sin(ang) * rad + _hrange(hk + 3, -4.0, 4.0)
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
		# Allow a couple of boulders right at the river bank (height slightly negative)
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
		var hseed: int = _h(seed * 7919 + placed.size() * 53 + 21)
		_make_boulder(node, hseed, c.x, maxf(gy, 0.0), c.y, rock_mat)
		placed.append(c)

static func _make_boulder(parent: Node3D, hseed: int, x: float, y: float, z: float,
		mat: StandardMaterial3D) -> void:
	var size: float = _hrange(hseed + 1, 1.2, 2.6)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector3(x, y, z)
	body.rotation.y = _hrange(hseed + 2, 0.0, TAU)
	parent.add_child(body)

	var mi := MeshInstance3D.new()
	mi.mesh = _boulder_mesh(hseed, size)
	mi.material_override = mat
	# Sit so most of the rock is above ground; sink the base a touch.
	mi.position = Vector3(0.0, size * 0.35, 0.0)
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	# Slightly smaller than visual radius so the navmesh hugs the rock, not its hull.
	sh.radius = size * 0.8
	col.shape = sh
	col.position = Vector3(0.0, size * 0.35, 0.0)
	body.add_child(col)

## A lumpy rock: take a low-poly SphereMesh's vertex arrays and push each vertex along
## its normal by a deterministic per-vertex hash (±~25%), then re-commit. Squashed a
## bit on Y so it reads as a grounded boulder, not a ball.
static func _boulder_mesh(hseed: int, size: float) -> ArrayMesh:
	var base := SphereMesh.new()
	base.radius = size
	base.height = size * 2.0
	base.radial_segments = 8
	base.rings = 6
	var arrays: Array = base.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var out := PackedVector3Array()
	out.resize(verts.size())
	for i in range(verts.size()):
		var v: Vector3 = verts[i]
		var nrm: Vector3 = v.normalized()
		# Hash from the rounded position so shared vertices on the sphere seam move
		# together (keeps the mesh watertight).
		var key: int = hseed * 131 \
			+ int(round(v.x * 17.0)) * 73 \
			+ int(round(v.y * 17.0)) * 131 \
			+ int(round(v.z * 17.0)) * 197
		var disp: float = _hrange(key, -0.25, 0.25)
		var nv: Vector3 = v + nrm * size * disp
		nv.y *= 0.78  # squash for a grounded look
		out[i] = nv
	arrays[Mesh.ARRAY_VERTEX] = out
	# Drop stale normals/tangents so SurfaceTool recomputes them from the new verts.
	arrays[Mesh.ARRAY_NORMAL] = null
	arrays[Mesh.ARRAY_TANGENT] = null
	var tmp := ArrayMesh.new()
	tmp.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Recompute smooth normals via SurfaceTool.
	var st := SurfaceTool.new()
	st.create_from(tmp, 0)
	st.generate_normals()
	return st.commit()
