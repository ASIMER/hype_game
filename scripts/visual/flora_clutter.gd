class_name FloraClutter
extends RefCounted
## Ground-clutter layers for the vegetation overhaul: ferns inside groves, flowers
## and clover on clearings/edges, mushrooms on the forest floor, biome ground plants
## (rain undergrowth / desert succulents), textured PEBBLES (replacing the old plain
## grey spheres) and a few flagstones ringing each POI. All Quaternius MegaKit CC0.
##
## Every layer is RENDER-ONLY (no collision, no navmesh input) and emitted as a
## handful of map-wide MultiMeshInstance3D via FloraMeshLib — a layer costs 1-2 draw
## calls total, never N nodes. Counts are small enough that always-on (no visibility
## range) is correct: one map-wide MMI never range-culls anyway (the grass-AABB lesson).
##
## DETERMINISM: ProcHash with fresh per-layer salts; placement reads
## ProceduralFlora.blocked_at + ProceduralTerrain.height_at, so co-op peers build
## byte-identical worlds. Golden snapshot: these containers hash — re-capture is part
## of the vegetation-overhaul intended change.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

# [id, base_scale] model tables (raw MegaKit sizes normalised to world scale).
const _FERN: Array = [["Fern_1", 0.22]]
const _FLOWERS: Array = [["Flower_3_Group", 0.35], ["Flower_4_Group", 0.35]]
const _CLOVER: Array = [["Clover_1", 0.5], ["Clover_2", 0.5]]
const _MUSHROOMS: Array = [["Mushroom_Common", 1.0], ["Mushroom_Laetiporus", 0.8]]
const _PEBBLES: Array = [
	["Pebble_Round_1", 1.6],
	["Pebble_Round_3", 1.6],
	["Pebble_Round_5", 1.6],
	["Pebble_Square_2", 1.6],
	["Pebble_Square_4", 1.6],
]
const _FLAGSTONES: Array = [["RockPath_Round_Wide", 1.0], ["RockPath_Square_Wide", 1.0]]


## Build every clutter layer under one "Clutter" node. `poi_defs` = arena._POI_DEFS
## (flagstone rings derive from the same single POI source the structures use).
static func build(parent: Node3D, seed: int, poi_defs: Dictionary = {}) -> void:
	var root := Node3D.new()
	root.name = "Clutter"
	parent.add_child(root)
	_layer_ferns(root, seed)
	_layer_flowers(root, seed)
	_layer_clover(root, seed)
	_layer_mushrooms(root, seed)
	_layer_plants(root, seed)
	_layer_pebbles(root, seed)
	_layer_flagstones(root, seed, poi_defs)


# ---------------------------------------------------------------- grove/clearing layers
## Ferns carpet GROVE interiors (forest_w high): lush in rain, normal urban, rare snow.
static func _layer_ferns(root: Node3D, seed: int) -> void:
	var xforms: Array[Transform3D] = _scatter(
		seed,
		6151,
		3.0,
		func(px: float, pz: float, w: float) -> float:
			if w < 0.45:
				return 0.0
			var bm: float = _biome_factor(px, pz, 1.0, 0.2, 0.0, 1.5)
			return 0.30 * w * bm,
		0.8,
		1.3
	)
	_emit(root, "Ferns", _FERN, seed * 11, xforms, 64.0)


## Flowers prefer open CLEARINGS and edges (1-w), urban + rain only.
static func _layer_flowers(root: Node3D, seed: int) -> void:
	var xforms: Array[Transform3D] = _scatter(
		seed,
		6553,
		4.0,
		func(px: float, pz: float, w: float) -> float:
			var bm: float = _biome_factor(px, pz, 1.0, 0.0, 0.0, 1.2)
			return 0.10 * (1.0 - w) * bm,
		0.8,
		1.2
	)
	_emit(root, "Flowers", _FLOWERS, seed * 13, xforms)


## Clover patches on clearings (urban + rain).
static func _layer_clover(root: Node3D, seed: int) -> void:
	var xforms: Array[Transform3D] = _scatter(
		seed,
		6907,
		5.0,
		func(px: float, pz: float, w: float) -> float:
			var bm: float = _biome_factor(px, pz, 1.0, 0.0, 0.0, 1.2)
			return 0.08 * (1.0 - w) * bm,
		0.9,
		1.1
	)
	_emit(root, "Clover", _CLOVER, seed * 17, xforms)


## Mushrooms deep on the forest floor (grove interiors; rain/urban/snow).
static func _layer_mushrooms(root: Node3D, seed: int) -> void:
	var xforms: Array[Transform3D] = _scatter(
		seed,
		7211,
		4.0,
		func(px: float, pz: float, w: float) -> float:
			if w < 0.55:
				return 0.0
			var bm: float = _biome_factor(px, pz, 1.0, 0.7, 0.0, 1.3)
			return 0.06 * w * bm,
		0.8,
		1.2
	)
	_emit(root, "Mushrooms", _MUSHROOMS, seed * 19, xforms)


## Biome ground plants: Plant_1 = rain-quadrant undergrowth; Plant_7 = the desert
## ground succulent (the SW quadrant's flora identity — its tree field is ×0.30).
static func _layer_plants(root: Node3D, seed: int) -> void:
	var rain_xf: Array[Transform3D] = _scatter(
		seed,
		7507,
		4.0,
		func(px: float, pz: float, w: float) -> float:
			return (0.18 * maxf(w, 0.2)) if WorldBounds.biome_at(px, pz) == "rain" else 0.0,
		0.8,
		1.2
	)
	_emit(root, "Plants_Rain", [["Plant_1", 0.9]], seed * 23, rain_xf, 64.0)
	var desert_xf: Array[Transform3D] = _scatter(
		seed,
		7639,
		4.0,
		func(px: float, pz: float, _w: float) -> float:
			return 0.10 if WorldBounds.biome_at(px, pz) == "desert" else 0.0,
		0.8,
		1.4
	)
	_emit(root, "Plants_Desert", [["Plant_7", 1.0]], seed * 29, desert_xf, 64.0)


## Textured pebbles — replaces the old plain grey squashed spheres. Even map-wide
## spread tuned to FLORA_STONES, doubled within 10 m of the river (washed stones).
static func _layer_pebbles(root: Node3D, seed: int) -> void:
	var cells: int = int(WorldBounds.SPAN / 4.5) * int(WorldBounds.SPAN / 4.5)
	var base: float = float(Settings.FLORA_STONES) / float(maxi(1, cells))
	var xforms: Array[Transform3D] = _scatter(
		seed,
		7901,
		4.5,
		func(px: float, pz: float, _w: float) -> float:
			var river_mul: float = 2.0 if ProceduralTerrain.river_distance(px, pz) < 10.0 else 1.0
			return base * river_mul,
		0.7,
		1.6
	)
	_emit(root, "Pebbles", _PEBBLES, seed * 31, xforms)


## A few sunken flagstones ringing each POI at its keep-out rim (worn approach paths).
static func _layer_flagstones(root: Node3D, seed: int, poi_defs: Dictionary) -> void:
	var xforms: Array[Transform3D] = []
	var pi: int = 0
	for k in poi_defs.keys():
		var d: Dictionary = poi_defs[k]
		var cx: float = float(d.get("x", 0.0))
		var cz: float = float(d.get("z", 0.0))
		var w: float = float(d.get("w", 0.0))
		var dd: float = float(d.get("d", 0.0))
		var ring: float = maxf(maxf(w, dd) * 0.5 + 9.0, 15.0)
		var hp: int = ProcHash.h(seed * 8009 + pi * 97 + 3)
		var n: int = 3 + ProcHash.h(hp + 1) % 4
		for s in range(n):
			var ang: float = ProcHash.hrange(hp + 5 + s * 7, 0.0, TAU)
			var px: float = cx + cos(ang) * ring
			var pz: float = cz + sin(ang) * ring
			if ProceduralFlora.blocked_at(px, pz):
				continue
			var gy: float = ProceduralTerrain.height_at(px, pz)
			if gy < -0.05:
				continue
			var yaw: float = ProcHash.hrange(hp + 6 + s * 7, 0.0, TAU)
			var sc: float = ProcHash.hrange(hp + 7 + s * 7, 0.85, 1.15)
			var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3(sc, sc, sc))
			xforms.append(Transform3D(basis, Vector3(px, gy - 0.03, pz)))
		pi += 1
	_emit(root, "Flagstones", _FLAGSTONES, seed * 37, xforms)


# ---------------------------------------------------------------- shared scatter core
## Jittered-grid scatter: `accept_fn(px, pz, forest_w) -> probability` decides emission
## per cell. Returns the transform list (yaw + uniform scale jitter in [s_lo, s_hi]).
static func _scatter(
	seed: int, salt: int, grid: float, accept_fn: Callable, s_lo: float, s_hi: float
) -> Array[Transform3D]:
	var xforms: Array[Transform3D] = []
	var nx: int = int((WorldBounds.X_MAX - WorldBounds.X_MIN) / grid)
	var nz: int = int((WorldBounds.Z_MAX - WorldBounds.Z_MIN) / grid)
	var i: int = 0
	var cells: int = nx * nz
	while i < cells:
		var cx: int = i % nx
		var cz: int = i / nx
		i += 1
		var hcell: int = ProcHash.h(seed * salt + cx * 137 + cz * 61 + 7)
		var bx: float = WorldBounds.X_MIN + (float(cx) + 0.5) * grid
		var bz: float = WorldBounds.Z_MIN + (float(cz) + 0.5) * grid
		var px: float = bx + ProcHash.hrange(hcell + 1, -grid * 0.45, grid * 0.45)
		var pz: float = bz + ProcHash.hrange(hcell + 2, -grid * 0.45, grid * 0.45)
		var w: float = FloraField.forest_w(px, pz)
		var p: float = float(accept_fn.call(px, pz, w))
		if p <= 0.0 or ProcHash.hf(hcell + 9) > p:
			continue
		if ProceduralFlora.blocked_at(px, pz):
			continue
		var gy: float = ProceduralTerrain.height_at(px, pz)
		if gy < -0.05:
			continue
		var yaw: float = ProcHash.hrange(hcell + 3, 0.0, TAU)
		var sc: float = ProcHash.hrange(hcell + 4, s_lo, s_hi)
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3(sc, sc, sc))
		xforms.append(Transform3D(basis, Vector3(px, gy, pz)))
	return xforms


## Split `xforms` across the layer's model table by hash and emit one MMI per model.
## `tile_m` > 0 spatially tiles the layer (leafy high-count layers like ferns/plants —
## map-wide AABBs never cull; see FloraMeshLib.emit_model_mm_tiled).
static func _emit(
	root: Node3D,
	nm: String,
	models: Array,
	salt: int,
	xforms: Array[Transform3D],
	tile_m: float = 0.0
) -> void:
	if xforms.is_empty():
		return
	var buckets: Array = []
	for i in range(models.size()):
		buckets.append([] as Array[Transform3D])
	for j in range(xforms.size()):
		var mi: int = ProcHash.h(salt + j * 41) % models.size()
		var xf: Transform3D = xforms[j]
		var bs: float = float(models[mi][1])
		xf.basis = xf.basis.scaled(Vector3(bs, bs, bs))
		(buckets[mi] as Array[Transform3D]).append(xf)
	for i in range(models.size()):
		var id: String = String(models[i][0])
		if tile_m > 0.0:
			FloraMeshLib.emit_model_mm_tiled(
				root, "%s_%s" % [nm, id], FloraMeshLib.model_meshes(id), buckets[i], tile_m, 90.0
			)
		else:
			FloraMeshLib.emit_model_mm(
				root, "%s_%s" % [nm, id], FloraMeshLib.model_meshes(id), buckets[i]
			)


## Per-biome multiplier helper: urban / snow / desert / rain factors.
static func _biome_factor(x: float, z: float, ur: float, sn: float, de: float, ra: float) -> float:
	var b: String = WorldBounds.biome_at(x, z)
	if b == "urban":
		return ur
	if b == "snow":
		return sn
	if b == "desert":
		return de
	return ra
