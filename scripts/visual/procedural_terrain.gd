extends RefCounted
class_name ProceduralTerrain
## Procedural TERRAIN for the 160×160 arena — replaces the flat Ground plane with
## gentle rolling hills, a rocky perimeter berm («скалы») + a render-only mountain
## backdrop outside the walls, and a shallow WALKABLE river with animated water and a
## footbridge. Built before the navmesh bake so the relief is pathable.
##
## CONTRACT (arena.gd `_build_terrain()` depends on these EXACT signatures):
##   static build(parent, poi_defs, extraction_points) -> Node3D  (adds itself under
##     parent, returns root; extraction_points = the ExtractionZone* XZ centres read
##     off Arena.tscn by arena.gd — the zone pads flatten there)
##   static height_at(x, z) -> float             (PURE; same math the mesh uses)
##
## DETERMINISM: ALL variation derives ONLY from Settings.TERRAIN_SEED via the shared
## ProcHash.h/hf arithmetic hash (scripts/core/proc_hash.gd). NO randf/randi/Time so
## every co-op peer bakes byte-identical geometry + collision.
##
## PADS: every building footprint / extraction zone / spawn cluster / plaza / scatter
## spot blends to EXACTLY y=0 (smoothstep falloff). `pad_w(x,z)` in [0..1]; the final
## height is `raw * (1 - pad_w)` and river depth is also `* (1 - pad_w)` so pads always
## win → buildings/markers keep their authored heights, AI walks every pad flat.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>` — all locals are typed.

# World rectangle: WorldBounds.* (scripts/core/world_bounds.gd) is the ONE source —
# the original 160×160 map is the NW quadrant; the world grows EAST (+X) and SOUTH (+Z).
# Perimeter berm rings the RECTANGLE: it ramps up as the distance to the NEAREST wall
# drops from RIM_MARGIN_INNER (start) to RIM_MARGIN_OUTER (full berm) — same 16 m..2 m feel.
const RIM_MARGIN_INNER: float = 16.0
const RIM_MARGIN_OUTER: float = 2.0


## Perimeter-berm ramp 0..1 by distance to the nearest rectangle wall (1 = at/over the wall).
static func _edge_ramp(x: float, z: float) -> float:
	var wd: float = min(
		min(x - WorldBounds.X_MIN, WorldBounds.X_MAX - x),
		min(z - WorldBounds.Z_MIN, WorldBounds.Z_MAX - z)
	)
	return 1.0 - smoothstep(RIM_MARGIN_OUTER, RIM_MARGIN_INNER, wd)


# Terrain blend colors — authored as NATURAL sRGB (the natural countryside palette).
# _color_srgb() blends these per-sample (height+slope); the rendered ground splat reads
# them via _color_linear (srgb_to_linear at the call site — the sRGB-decode trap).
const C_GRASS := Color(0.30, 0.47, 0.17)  # lowland grass (bright enough to survive the blue ambient)
const C_DIRT := Color(0.40, 0.32, 0.21)  # mid elevation dirt
const C_ROCK := Color(0.38, 0.39, 0.41)  # slope / berm rock
const C_WET := Color(0.18, 0.18, 0.14)  # wet riverbed
const C_PEBBLE := Color(0.24, 0.21, 0.17)  # wet pebble band at the waterline edge

# River centerline control points (world XZ). Enters north ~x=18, curves south between
# the plaza pad (0,0) and the warehouse/east-yard pads (45,-28)/(50,42), exits south
# ~x=10. Pad mask trick guarantees clearance regardless.
const RIVER_PTS: Array[Vector2] = [
	Vector2(18.0, -80.0),
	Vector2(22.0, -55.0),
	Vector2(26.0, -30.0),
	Vector2(20.0, -8.0),
	Vector2(14.0, 14.0),
	Vector2(16.0, 38.0),
	Vector2(10.0, 62.0),
	Vector2(10.0, 80.0),
]

# Pads, filled deterministically in build()/height_at via _collect_pads(poi_defs). Each
# rect: {kind:"rect", x,z,hw,hd, fall}; each circle: {kind:"circle", x,z, r, fall}.
# Cached so height_at (called by other systems) reuses the SAME pad set the mesh used.
static var _pads: Array[Dictionary] = []
static var _pads_ready: bool = false
# Extraction-zone XZ centres, passed by arena.build() from its OWN ExtractionZone*
# nodes (single source — Arena.tscn; this list used to be hand-duplicated here).
# Pre-build height_at fallbacks see an empty list (they already lacked POI pads).
static var _zone_pts: Array[Vector2] = []

# Seed hashing: ProcHash.h/hf (scripts/core/proc_hash.gd) — ONE copy shared with
# flora/buildings so every procedural system stays determinism-synchronized.


# ---------------------------------------------------------------- value noise
## Deterministic 2D value-noise in [-1,1], seeded from TERRAIN_SEED. Pure integer hash
## of the lattice corners → bilinear (smoothstep) interpolation. No FastNoiseLite so the
## math is identical to anything that re-implements height_at.
static func _vnoise(x: float, z: float) -> float:
	var xi: int = int(floor(x))
	var zi: int = int(floor(z))
	var xf: float = x - float(xi)
	var zf: float = z - float(zi)
	var u: float = xf * xf * (3.0 - 2.0 * xf)
	var v: float = zf * zf * (3.0 - 2.0 * zf)
	var a: float = _lattice(xi, zi)
	var b: float = _lattice(xi + 1, zi)
	var c: float = _lattice(xi, zi + 1)
	var d: float = _lattice(xi + 1, zi + 1)
	var ab: float = lerp(a, b, u)
	var cd: float = lerp(c, d, u)
	return lerp(ab, cd, v)


static func _lattice(xi: int, zi: int) -> float:
	var n: int = xi * 374761393 + zi * 668265263 + Settings.TERRAIN_SEED * 2246822519
	return ProcHash.hf(n) * 2.0 - 1.0


## Fractal value noise (4 octaves) in roughly [-1,1].
static func _fbm(x: float, z: float) -> float:
	var v: float = 0.0
	var amp: float = 0.5
	var fx: float = x
	var fz: float = z
	var total: float = 0.0
	for i in range(4):
		v += amp * _vnoise(fx, fz)
		total += amp
		fx *= 2.0
		fz *= 2.0
		amp *= 0.5
	return v / total


# ---------------------------------------------------------------- pad collection
## Builds the flat-pad list ONCE (idempotent). Reads poi_defs (footprint rects + plaza
## radius), the extraction zones (_zone_pts, from arena), the spawn cluster, and the 20
## scatter spots arena.gd `_rebuild_scatter()` places — flattened so authored heights survive.
static func _collect_pads(poi_defs: Dictionary) -> void:
	if _pads_ready:
		return
	_pads = []
	# POI footprints + 6 m margin. Plaza (w=d=0) → radius-14 circle around (0,0).
	for k in poi_defs.keys():
		var d: Dictionary = poi_defs[k]
		var px: float = float(d.get("x", 0.0))
		var pz: float = float(d.get("z", 0.0))
		var w: float = float(d.get("w", 0.0))
		var dd: float = float(d.get("d", 0.0))
		if w <= 0.1 and dd <= 0.1:
			_pads.append({"kind": "circle", "x": px, "z": pz, "r": 14.0, "fall": 9.0})
		else:
			_pads.append(
				{
					"kind": "rect",
					"x": px,
					"z": pz,
					"hw": w * 0.5 + 6.0,
					"hd": dd * 0.5 + 6.0,
					"fall": 8.0
				}
			)
	# Extraction zones (r=10) — flatten a pad under each so the evac beacon sits clean.
	# Positions come from arena via build() (_zone_pts) — read off the real
	# ExtractionZone* nodes, so Arena.tscn is the ONE source (no hand-copied list).
	for zc in _zone_pts:
		_pads.append({"kind": "circle", "x": zc.x, "z": zc.y, "r": 10.0, "fall": 8.0})
	# Player spawn cluster (r=16 at (59,60)).
	_pads.append({"kind": "circle", "x": 59.0, "z": 60.0, "r": 16.0, "fall": 9.0})
	# The 20 scatter spots from arena.gd `_rebuild_scatter()` — r=4 pads under each.
	var scatter: Array[Vector2] = [
		Vector2(-15, -20),
		Vector2(20, 8),
		Vector2(-25, 5),
		Vector2(30, -55),
		Vector2(-60, -20),
		Vector2(60, -5),
		Vector2(15, 55),
		Vector2(-10, 35),
		Vector2(5, -35),
		Vector2(-66, -60),
		Vector2(66, 60),
		Vector2(-70, 12),
		Vector2(38, 22),
		Vector2(-40, -8),
		Vector2(8, 20),
		Vector2(-18, 58),
		Vector2(48, 10),
		Vector2(-48, 56),
		Vector2(22, -10),
		Vector2(-8, -58),
	]
	for s in scatter:
		_pads.append({"kind": "circle", "x": s.x, "z": s.y, "r": 4.0, "fall": 6.0})
	_pads_ready = true


## pad_w(x,z) in [0..1] — 1 fully inside a pad, smoothstep falloff to 0 over `fall` m.
## Pads union via max() so overlapping pads stay flat.
static func _pad_w(x: float, z: float) -> float:
	var best: float = 0.0
	for p in _pads:
		var w: float = 0.0
		if p["kind"] == "circle":
			var dx: float = x - float(p["x"])
			var dz: float = z - float(p["z"])
			var dist: float = sqrt(dx * dx + dz * dz)
			var r: float = float(p["r"])
			var fall: float = float(p["fall"])
			# 1 inside r, → 0 at r+fall.
			w = 1.0 - smoothstep(r, r + fall, dist)
		else:
			var dx2: float = abs(x - float(p["x"]))
			var dz2: float = abs(z - float(p["z"]))
			var hw: float = float(p["hw"])
			var hd: float = float(p["hd"])
			var fall2: float = float(p["fall"])
			var wx: float = 1.0 - smoothstep(hw, hw + fall2, dx2)
			var wz: float = 1.0 - smoothstep(hd, hd + fall2, dz2)
			w = wx * wz
		if w > best:
			best = w
	return best


# ---------------------------------------------------------------- river geometry
## PUBLIC river-centerline distance — FloraField uses it for the riparian treeline
## band (trees hugging the banks). Same math the channel carve uses.
static func river_distance(x: float, z: float) -> float:
	return _river_dist(x, z)


## Distance from (x,z) to the polyline river centerline (world units).
static func _river_dist(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var best: float = 1e9
	for i in range(RIVER_PTS.size() - 1):
		var a: Vector2 = RIVER_PTS[i]
		var b: Vector2 = RIVER_PTS[i + 1]
		var ab: Vector2 = b - a
		var t: float = 0.0
		var denom: float = ab.dot(ab)
		if denom > 0.0001:
			t = clamp((p - a).dot(ab) / denom, 0.0, 1.0)
		var proj: Vector2 = a + ab * t
		var dprj: float = p.distance_to(proj)
		if dprj < best:
			best = dprj
	return best


# ---------------------------------------------------------------- DEEP CHANNEL
## Real DEEP river channel (Lane A overhaul). The river is no longer a flat 0.45 m ford —
## it carves a genuine ~2.5 m channel (deep enough that a wading player's HEAD submerges →
## the underwater camera fires) with WALKABLE ~33° banks so a CharacterBody3D wades DOWN into
## it and back UP the far side (banks must NOT be cliffs → the player/AI can't cross the deep
## middle, which is why the STONE ARCH bridge is the crossing).
# 2.7 m NOMINAL so the REALIZED bed clears ≥2.0 m even after the discrete 1 m terrain grid
# samples the curved centerline off-true (the nearest grid cell can sit ~0.5-0.7 m off the
# true centerline, where the profile has already shed some depth). The flat-bottom band in
# `_river_profile` keeps the very centre at FULL depth so a wading player's FEET land ≥2.0 m
# below the water surface → head (feet+1.5) goes clearly UNDER → the underwater camera fires.
const RIVER_MAX_DEPTH: float = 2.7  # channel depth at the centerline (m)
# Horizontal run from centerline → channel edge over which the full RIVER_MAX_DEPTH drop
# happens. The walkable BANK runs from the flat-bottom edge (RIVER_FLAT_HALF=1.2) to the
# channel edge: run = 5.4 - 1.2 = 4.2 m, drop = 2.7 m ⇒ slope 0.643 ⇒ atan ≈ 32.7° banks
# (walkable by a CharacterBody3D, < the 45° climb limit — players wade DOWN the near bank and
# UP the far one, never cliff-stuck). Widened from 3.0 → 5.4 to keep the now-deeper banks ≤33°.
const RIVER_CHANNEL_HALF: float = 5.4  # centerline → where the channel meets dry bank

## Width of the FLAT BOTTOM band (each side of the centerline) held at FULL depth so the very
## centre isn't rounded/V'd away — this is what guarantees a player standing anywhere within
## ~1.4 m of the centerline gets the full RIVER_MAX_DEPTH drop (and survives the 1 m grid
## sampling: the nearest grid cell to the true centre still lands inside the flat band).
const RIVER_FLAT_HALF: float = 1.2


## Cross-channel depth PROFILE in [0,1]: 1 across the FLAT-BOTTOM band (deepest), then a LINEAR
## ramp 1→0 from the flat-band edge to the channel edge = constant-slope walkable banks. PURE.
static func _river_profile(dist: float) -> float:
	var ch: float = RIVER_CHANNEL_HALF
	if dist >= ch:
		return 0.0
	# Flat bottom: full depth out to RIVER_FLAT_HALF so the bed is a real basin, not a V — a
	# player standing within the band has feet at the full depth.
	if dist <= RIVER_FLAT_HALF:
		return 1.0
	# Linear ramp 1→0 from the flat-band edge to the channel edge = constant-slope banks. The
	# bank run is (ch - RIVER_FLAT_HALF); slope = RIVER_MAX_DEPTH / that run (see header math).
	return 1.0 - (dist - RIVER_FLAT_HALF) / (ch - RIVER_FLAT_HALF)


## River channel weight in [0,1]: how much (x,z) is "in the channel" — 1 in the deep
## centre, smoothstep to 0 just past the channel edge. Used to blend terrain toward the
## carved bed and to color the wet bed. Distinct from the DEPTH profile above.
static func _river_t(x: float, z: float) -> float:
	var dist: float = _river_dist(x, z)
	return 1.0 - smoothstep(RIVER_CHANNEL_HALF - 0.6, RIVER_CHANNEL_HALF, dist)


## Longitudinal depth scale that SHALLOWS the river's south terminus into a gentle pond. The
## centerline ends at z=80 (the OLD map edge, now MID-map): without this the channel ended in a
## full-depth ~2.7 m rounded bowl. Tapering to ×0.5 (≈1.35 m) over z∈[60,80] makes a clean
## shallowing pond while staying ABOVE the navmesh agent_max_climb (0.5 m) so the two banks stay
## disconnected exactly as before (enemies still cross only at the bridge). PURE.
static func _river_depth_scale(z: float) -> float:
	return lerp(1.0, 0.5, smoothstep(60.0, 80.0, z))


## Effective carve depth at (x,z) in METRES below the local banks (used for COLORING the
## wet bed and the riverbed material bands). PURE.
static func _river_carve(x: float, z: float) -> float:
	return RIVER_MAX_DEPTH * _river_profile(_river_dist(x, z)) * _river_depth_scale(z)


# ---------------------------------------------------------------- height field
## PURE height function. Other systems sample this; the mesh uses the identical math.
## NOTE: assumes _collect_pads has run (build() calls it; height_at falls back if not).
static func height_at(x: float, z: float) -> float:
	if not _pads_ready:
		# No poi_defs available here — populate from Settings-independent empties so the
		# function is still pure (build() will have already run in practice).
		_collect_pads({})
	var pad: float = _pad_w(x, z)
	var open: float = 1.0 - pad
	# Pads sit a hair BELOW authored y=0 so building floor slabs (top face at y=0)
	# never z-fight the terrain — the ground tucks just under them.
	const PAD_Y := -0.05
	if open <= 0.0001:
		return PAD_Y
	# --- rolling hills: FBM, wavelength ~25-45 m, amp ≤ TERRAIN_HILL_AMP.
	var freq: float = 1.0 / 32.0  # ~32 m features
	var hills: float = _fbm(x * freq, z * freq) * Settings.TERRAIN_HILL_AMP
	# --- perimeter berm: ramps up near the RECTANGLE walls (rings the whole 320×320 map),
	# with rocky noise on top. Slopes here may exceed 47° (unclimbable scenery).
	var berm: float = 0.0
	var ramp: float = _edge_ramp(x, z)
	if ramp > 0.0:
		var rock: float = _fbm(x * 0.18, z * 0.18) * 1.4
		berm = ramp * (Settings.TERRAIN_RIM_HEIGHT + rock)
	var raw: float = hills + berm
	# --- DEEP river channel: carve a real ~1.5 m channel BELOW the immediate banks, with
	# walkable ~28° banks. The carve is the cross-channel depth profile (deepest at the
	# centerline, 0 at the channel edge) subtracted from the *bank baseline* (`hills` — the
	# berm is excluded, the river never reaches the perimeter). Because the profile is the
	# local depth below the banks, the channel tracks the rolling hills instead of becoming
	# a pit where the hills dip. Pads still win via the `open` blend below → the channel
	# never crosses a building/extraction pad (it flattens to PAD_Y there).
	var depth: float = RIVER_MAX_DEPTH * _river_profile(_river_dist(x, z)) * _river_depth_scale(z)
	if depth > 0.0:
		raw = hills - depth + berm
	var h: float = lerp(PAD_Y, raw, open)
	return h


# ---------------------------------------------------------------- water surface
## How far the water plane sits BELOW the local bank top. The channel is ~2.7 m deep, so a
## ~0.22 m freeboard fills it nearly to the surrounding ground level → you SEE deep water
## in the channel (head-submerging at the centre), with the wet banks breaking the surface
## at the waterline.
const WATER_FREEBOARD: float = 0.22


## Bank-baseline height at (x,z): the dry-ground level the river channel is carved BELOW,
## i.e. `height_at` with the channel carve removed (hills + berm + pad blend). This is the
## top of the channel banks, so the water plane is derived from it. PURE.
static func _bank_top(x: float, z: float) -> float:
	if not _pads_ready:
		_collect_pads({})
	var pad: float = _pad_w(x, z)
	var open: float = 1.0 - pad
	const PAD_Y := -0.05
	if open <= 0.0001:
		return PAD_Y
	var freq: float = 1.0 / 32.0
	var hills: float = _fbm(x * freq, z * freq) * Settings.TERRAIN_HILL_AMP
	var berm: float = 0.0
	var ramp: float = _edge_ramp(x, z)
	if ramp > 0.0:
		var rock: float = _fbm(x * 0.18, z * 0.18) * 1.4
		berm = ramp * (Settings.TERRAIN_RIM_HEIGHT + rock)
	return lerp(PAD_Y, hills + berm, open)


## FROZEN CONTRACT (Lane B consumes this). Returns the world-Y of the WATER PLANE where
## (x,z) is over the river channel, else NAN. The plane sits WATER_FREEBOARD below the
## local bank top so the carved channel reads as filled with deep water up to ~ground
## level. Consistent with the water mesh built in _build_water. PURE — no time/random.
static func water_surface_at(x: float, z: float) -> float:
	# Only over the channel (within the channel half-extent + a hair for the waterline).
	if _river_dist(x, z) >= RIVER_CHANNEL_HALF:
		return NAN
	# The river never crosses a pad — if a pad fully flattens here, there's no channel.
	if not _pads_ready:
		_collect_pads({})
	if _pad_w(x, z) > 0.6:
		return NAN
	return _bank_top(x, z) - WATER_FREEBOARD


# ---------------------------------------------------------------- vertex color
## Returns the authored palette blend in **sRGB** space (the natural countryside colors).
## This is the source of truth for the ground's color; it's baked into an sRGB albedo
## TEXTURE in _build_ground (the renderer sRGB-decodes it automatically — NO manual
## srgb_to_linear here). _color_at() wraps this and linearizes for the legacy vertex-color
## path (kept for any caller), but the rendered ground uses the texture.
static func _color_srgb(x: float, z: float, h: float, slope: float) -> Color:
	var carve: float = _river_carve(x, z)
	# Submerged riverbed → wet dark. The bed is now ~1.5 m deep: darkest/wettest at the
	# centre, grading to the damp pebble band as it shallows toward the waterline.
	if carve > 0.30:
		return C_WET.lerp(C_PEBBLE, clamp(1.0 - (carve - 0.30) / 1.0, 0.0, 1.0))
	# Damp WET PEBBLE shoreline (carve ~0.06-0.30 m): the band the water laps where the
	# channel meets the dry bank — kills the hard colour seam at the river edge.
	if carve > 0.06:
		var bandw: float = smoothstep(0.06, 0.16, carve)
		var grass_edge: Color = C_GRASS.lerp(C_PEBBLE, smoothstep(0.06, 0.14, carve))
		return grass_edge.lerp(C_PEBBLE, clamp(bandw, 0.0, 1.0))
	var c: Color = C_GRASS
	# Mid elevation → dirt, but only on genuinely RAISED ground (hilltops > ~3 m), so the
	# whole rolling grassland (hill amp 3.5) stays green instead of browning to grey.
	c = c.lerp(C_DIRT, clamp((h - 3.0) / 3.0, 0.0, 1.0))
	# Rock ONLY on genuinely steep ground or the high berm — gentle rolling hills stay
	# grassy (slope on a 3.5 m / ~32 m hill is ~0.1, which must read green, not grey).
	var rock_w: float = clamp((slope - 0.45) * 1.6, 0.0, 1.0) + clamp((h - 4.5) / 3.0, 0.0, 1.0)
	c = c.lerp(C_ROCK, clamp(rock_w, 0.0, 1.0))
	# Subtle deterministic per-vertex value jitter (±0.03) to break up flat fields. Hash
	# of the integer cell coords → same idiom as the seed hashing, so every peer matches.
	var jn: int = int(round(x)) * 92837111 + int(round(z)) * 689287499 + Settings.TERRAIN_SEED
	var jitter: float = (ProcHash.hf(jn) - 0.5) * 0.06  # in [-0.03, +0.03]
	c.r = clamp(c.r + jitter, 0.0, 1.0)
	c.g = clamp(c.g + jitter, 0.0, 1.0)
	c.b = clamp(c.b + jitter, 0.0, 1.0)
	return c


## Legacy linear vertex-color (unused by the rendered ground now — texture path renders).
static func _color_at(x: float, z: float, h: float, slope: float) -> Color:
	return _color_srgb(x, z, h, slope).srgb_to_linear()


# ================================================================ BUILD
static func build(
	parent: Node3D, poi_defs: Dictionary, extraction_points: Array[Vector2] = []
) -> Node3D:
	_zone_pts = extraction_points
	_pads_ready = false
	_collect_pads(poi_defs)

	var root := Node3D.new()
	root.name = "ProceduralTerrain"
	parent.add_child(root)

	_build_ground(root)
	_build_water(root)
	_build_backdrop(root)
	_build_river_props(root)
	return root


# ---------------------------------------------------------------- ground mesh
static func _build_ground(root: Node3D) -> void:
	# DENSER MESH (Lane C): subdivide the grid by Settings.terrain_detail_scale (1.0..2.0).
	# Effective cell = TERRAIN_CELL / detail, CLAMPED so the cell never drops below ~0.5 m
	# (caps the vertex count at ~4× = (2×)² and avoids a runaway grid on weak GPUs). At
	# detail 1.0 the cell == TERRAIN_CELL exactly → the mesh is byte-identical to before
	# (height_at sampling is unchanged; only the sample DENSITY changes). Pure / deterministic.
	var detail: float = clampf(Settings.terrain_detail_scale, 1.0, 2.0)
	# Bigger map → a slightly larger min cell so the 320×320 grid stays a sane tri count.
	var cell: float = maxf(Settings.TERRAIN_CELL / detail, 0.8)
	var n: int = int(round(WorldBounds.SPAN / cell))  # cells per side over the 320 m rectangle
	var verts: int = n + 1

	# Precompute height + per-vertex color/normal grids. Building the surface from
	# EXPLICIT arrays (add_surface_from_arrays) guarantees the ARRAY_COLOR is stored —
	# a SurfaceTool set_color path rendered the terrain plain white (colors dropped).
	var heights := PackedFloat32Array()
	heights.resize(verts * verts)
	for iz in range(verts):
		for ix in range(verts):
			var x: float = WorldBounds.X_MIN + float(ix) * cell
			var z: float = WorldBounds.Z_MIN + float(iz) * cell
			heights[iz * verts + ix] = height_at(x, z)

	# Smooth per-vertex normals + UVs from central differences on the height grid.
	# COLOR is no longer stored per-vertex — the palette is BAKED into an sRGB albedo
	# texture below (the vertex-color path is silently lossy on this mesh/material combo
	# in Godot 4.6; the texture path is bulletproof and the renderer sRGB-decodes it).
	var grid_pos := PackedVector3Array()
	var grid_nrm := PackedVector3Array()
	var grid_uv := PackedVector2Array()
	grid_pos.resize(verts * verts)
	grid_nrm.resize(verts * verts)
	grid_uv.resize(verts * verts)
	for iz in range(verts):
		for ix in range(verts):
			var x: float = WorldBounds.X_MIN + float(ix) * cell
			var z: float = WorldBounds.Z_MIN + float(iz) * cell
			var hc: float = heights[iz * verts + ix]
			var hl: float = heights[iz * verts + max(ix - 1, 0)]
			var hr: float = heights[iz * verts + min(ix + 1, verts - 1)]
			var hd: float = heights[max(iz - 1, 0) * verts + ix]
			var hu: float = heights[min(iz + 1, verts - 1) * verts + ix]
			var dhdx: float = (hr - hl) / (2.0 * cell)
			var dhdz: float = (hu - hd) / (2.0 * cell)
			var nrm := Vector3(-dhdx, 1.0, -dhdz).normalized()
			var idx: int = iz * verts + ix
			grid_pos[idx] = Vector3(x, hc, z)
			grid_nrm[idx] = nrm
			# UV maps the whole rectangle 1:1 onto [0..1]² so the baked texture aligns.
			grid_uv[idx] = Vector2(
				(x - WorldBounds.X_MIN) / WorldBounds.SPAN,
				(z - WorldBounds.Z_MIN) / WorldBounds.SPAN
			)

	# Build the triangle soup (positions/normals/uvs) + collision faces in one pass.
	var mverts := PackedVector3Array()
	var mnorms := PackedVector3Array()
	var muvs := PackedVector2Array()
	var faces := PackedVector3Array()
	mverts.resize(n * n * 6)
	mnorms.resize(n * n * 6)
	muvs.resize(n * n * 6)
	faces.resize(n * n * 6)
	var fi: int = 0
	for iz in range(n):
		for ix in range(n):
			var i00: int = iz * verts + ix
			var i10: int = iz * verts + (ix + 1)
			var i01: int = (iz + 1) * verts + ix
			var i11: int = (iz + 1) * verts + (ix + 1)
			# Tri 1: 00, 11, 01   Tri 2: 00, 10, 11 — CLOCKWISE seen from ABOVE (Godot
			# front faces are CW; the previous CCW winding made the ground render only
			# from BELOW — the visible "grey ground" was the sky's lower hemisphere).
			var order: Array[int] = [i00, i11, i01, i00, i10, i11]
			for k in range(6):
				var gi: int = order[k]
				mverts[fi + k] = grid_pos[gi]
				mnorms[fi + k] = grid_nrm[gi]
				muvs[fi + k] = grid_uv[gi]
				faces[fi + k] = grid_pos[gi]
			fi += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mverts
	arrays[Mesh.ARRAY_NORMAL] = mnorms
	arrays[Mesh.ARRAY_TEX_UV] = muvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	# REAL CC0 PBR SURFACE (детализированная текстура земли). A triplanar splat
	# ShaderMaterial samples 3 ambientCG 1K sets — Ground003 (grass-dirt) low/flat,
	# Ground054 (dirt) mid elevation, Rock029 (warm cliff) steep slopes / high berm —
	# blended by world-Y (height) + the surface up-dot (slope). World-space triplanar
	# avoids UV stretch on slopes and keeps the 1K detail crisp under the close-up
	# camera-down shot. RENDER-ONLY: the mesh still owns relief/collision/height_at/river.
	mi.material_override = _build_ground_material()
	root.add_child(_make_ground_body(mi, faces))


## Builds the ground StaticBody3D (collision unchanged) wrapping the mesh + material.
## Split out only so _build_ground stays readable after the material swap; the collision
## shape / layers / backface flag are byte-identical to the original inline path.
static func _make_ground_body(mi: MeshInstance3D, faces: PackedVector3Array) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.collision_layer = 1
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	col.shape = shape
	body.add_child(col)
	body.add_child(mi)
	return body


# ---------------------------------------------------------------- PBR ground material
## The triplanar height/slope splat material. Loads the 3 ambientCG CC0 sets and feeds them
## to a custom spatial shader. sRGB handling: the _Color.jpg albedos are imported sRGB and
## the GPU sRGB-decodes them on sample → use them as linear albedo directly (NO manual
## convert — the documented trap). NormalGL + Roughness are imported LINEAR (their .import
## sidecars set srgb=0 / normal-map mode) so they sample as raw data.
const _GTEX_DIR := "res://assets/textures/ground/"


static func _gload(name: String) -> Texture2D:
	var t: Texture2D = load(_GTEX_DIR + name)
	if t == null:
		push_warning("[terrain] missing ground texture: " + name)
	return t


static func _build_ground_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = _GROUND_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	# Layer 0 = low/flat grass-dirt, 1 = mid dirt, 2 = steep warm rock.
	m.set_shader_parameter("tex0_albedo", _gload("Ground003_Color.jpg"))
	m.set_shader_parameter("tex0_normal", _gload("Ground003_NormalGL.jpg"))
	m.set_shader_parameter("tex0_rough", _gload("Ground003_Roughness.jpg"))
	m.set_shader_parameter("tex1_albedo", _gload("Ground054_Color.jpg"))
	m.set_shader_parameter("tex1_normal", _gload("Ground054_NormalGL.jpg"))
	m.set_shader_parameter("tex1_rough", _gload("Ground054_Roughness.jpg"))
	m.set_shader_parameter("tex2_albedo", _gload("Rock029_Color.jpg"))
	m.set_shader_parameter("tex2_normal", _gload("Rock029_NormalGL.jpg"))
	m.set_shader_parameter("tex2_rough", _gload("Rock029_Roughness.jpg"))
	# 4th layer: gravel/crushed-stone APRONS around the POI/zone pads (ragged mask baked
	# below) — building surrounds read as worked ground instead of lawn-to-wall.
	m.set_shader_parameter("texg_albedo", _gload("Gravel022_Color.jpg"))
	m.set_shader_parameter("texg_normal", _gload("Gravel022_NormalGL.jpg"))
	m.set_shader_parameter("texg_rough", _gload("Gravel022_Roughness.jpg"))
	m.set_shader_parameter("scaleg", 0.30)
	m.set_shader_parameter("pad_mask", _bake_pad_mask())
	m.set_shader_parameter("map_origin", Vector2(WorldBounds.X_MIN, WorldBounds.Z_MIN))
	m.set_shader_parameter("map_span", WorldBounds.SPAN)
	# World-space tiling (metres per texture repeat), retuned for the 2K sets:
	# ~4.5 m grass, ~5 m dirt, ~6.3 m rock — fewer repeats AND more texels per metre.
	m.set_shader_parameter("scale0", 0.22)
	m.set_shader_parameter("scale1", 0.20)
	m.set_shader_parameter("scale2", 0.16)
	# Height blend (world-Y, metres). Grass below ~2.5 m, dirt fades in by ~5 m.
	m.set_shader_parameter("dirt_lo", 2.5)
	m.set_shader_parameter("dirt_hi", 5.5)
	# Slope blend: rock fades in as the surface up-dot drops below ~0.86 (~31°) to ~0.66 (~49°).
	m.set_shader_parameter("rock_slope_lo", 0.66)
	m.set_shader_parameter("rock_slope_hi", 0.86)
	m.set_shader_parameter("normal_strength", 0.85)
	# PARALLAX-OCCLUSION MAPPING (Lane C). parallax_scale > 0 turns the POM march on; 0 makes
	# the shader early-out so the output is byte-identical to the pre-POM terrain. Gated on
	# Settings.terrain_parallax_enabled (read at build → applies on the next raid). Height is
	# derived from the per-layer ROUGHNESS texture luminance (ambientCG ground roughness is a
	# decent height proxy → ZERO new asset dependency); see _GROUND_SHADER. 0.04 m max relief.
	m.set_shader_parameter("parallax_scale", 0.04 if Settings.terrain_parallax_enabled else 0.0)
	return m


## Bake a 192² R8 world-rect mask of the POI/zone pad APRONS for the gravel splat:
## value = _pad_w × a per-texel hash breakup so apron rims read ragged, not stamped
## discs. Render-only (no heights/transforms change → golden-safe); ~37k pad evals,
## well under a second inside the arena-build coroutine.
static func _bake_pad_mask() -> ImageTexture:
	var n: int = 192
	var img := Image.create(n, n, false, Image.FORMAT_R8)
	for ty in range(n):
		for tx in range(n):
			var wx: float = WorldBounds.X_MIN + (float(tx) + 0.5) / float(n) * WorldBounds.SPAN
			var wz: float = WorldBounds.Z_MIN + (float(ty) + 0.5) / float(n) * WorldBounds.SPAN
			var w: float = _pad_w(wx, wz)
			if w <= 0.001:
				continue
			var rag: float = ProcHash.hf(ProcHash.h(7351 + tx * 193 + ty * 71))
			img.set_pixel(tx, ty, Color(clampf(w * (0.55 + 0.45 * rag), 0.0, 1.0), 0.0, 0.0))
	return ImageTexture.create_from_image(img)


# Embedded triplanar splat shader (kept in this file to keep Lane C self-contained — owns
# exactly this one .gd + the texture dir; no new .gdshader file added). World-space triplanar
# sampling (no UVs needed) blends 3 PBR sets by world height + slope. Deterministic / render-
# only: identical on every peer, no time/random input.
const _GROUND_SHADER := """
shader_type spatial;
render_mode cull_back;

uniform sampler2D tex0_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex0_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex0_rough : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex1_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex1_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex1_rough : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex2_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex2_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex2_rough : hint_default_white, filter_linear_mipmap, repeat_enable;
// Gravel apron layer (POI/zone pad surrounds) — weighted by the baked pad mask.
uniform sampler2D texg_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D texg_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D texg_rough : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D pad_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec2 map_origin = vec2(-80.0, -80.0);
uniform float map_span = 320.0;
uniform float scaleg = 0.30;

uniform float scale0 = 0.22;
uniform float scale1 = 0.20;
uniform float scale2 = 0.16;
uniform float dirt_lo = 2.5;
uniform float dirt_hi = 5.5;
uniform float rock_slope_lo = 0.66;
uniform float rock_slope_hi = 0.86;
uniform float normal_strength = 0.85;
// PARALLAX-OCCLUSION MAPPING. 0.0 = OFF (the fragment shader early-outs and the output is
// byte-identical to the no-POM terrain). > 0 = max relief depth in metres marched along the
// view vector. Set from Settings.terrain_parallax_enabled in _build_ground_material.
uniform float parallax_scale = 0.0;

varying vec3 v_wpos;
varying vec3 v_wnrm;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Cheap 2D hash + smooth value noise for the ANTI-TILING macro variation and the
// dry-patch tint (frequency 0.022 matches the grass shader so dry grass sits on
// dry ground). Pure functions of world position — deterministic on every peer.
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise01(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 s = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

// World-space triplanar albedo for one set. `duv` shifts ONLY the dominant plane (selected by
// `dom`: 0=YZ/x, 1=XZ/y, 2=XY/z) — single-axis POM keeps it cheap + seam-free.
vec3 tri_albedo(sampler2D t, vec3 wpos, vec3 bw, float s, int dom, vec2 duv) {
	vec2 uvx = wpos.zy * s; if (dom == 0) uvx += duv;
	vec2 uvy = wpos.xz * s; if (dom == 1) uvy += duv;
	vec2 uvz = wpos.xy * s; if (dom == 2) uvz += duv;
	return texture(t, uvx).rgb * bw.x + texture(t, uvy).rgb * bw.y + texture(t, uvz).rgb * bw.z;
}

float tri_rough(sampler2D t, vec3 wpos, vec3 bw, float s, int dom, vec2 duv) {
	vec2 uvx = wpos.zy * s; if (dom == 0) uvx += duv;
	vec2 uvy = wpos.xz * s; if (dom == 1) uvy += duv;
	vec2 uvz = wpos.xy * s; if (dom == 2) uvz += duv;
	return texture(t, uvx).r * bw.x + texture(t, uvy).r * bw.y + texture(t, uvz).r * bw.z;
}

// Triplanar tangent-space normal -> world-space (whiteout blend), then re-expressed in the
// fragment's TANGENT/BINORMAL frame for NORMAL output. `duv`/`dom` apply the POM shift.
vec3 tri_normal_world(sampler2D t, vec3 wpos, vec3 wn, vec3 bw, float s, int dom, vec2 duv) {
	vec2 uvx = wpos.zy * s; if (dom == 0) uvx += duv;
	vec2 uvy = wpos.xz * s; if (dom == 1) uvy += duv;
	vec2 uvz = wpos.xy * s; if (dom == 2) uvz += duv;
	vec3 nx = texture(t, uvx).xyz * 2.0 - 1.0;
	vec3 ny = texture(t, uvy).xyz * 2.0 - 1.0;
	vec3 nz = texture(t, uvz).xyz * 2.0 - 1.0;
	// Reorient each axis sample into world space (UDN-style) around the geometric normal.
	vec3 wnx = normalize(vec3(nx.xy + wn.zy, abs(wn.x)));
	vec3 wny = normalize(vec3(ny.xy + wn.xz, abs(wn.y)));
	vec3 wnz = normalize(vec3(nz.xy + wn.xy, abs(wn.z)));
	// Swizzle back to world axes per projection plane.
	vec3 worldN = wnx.zyx * bw.x + wny.xzy * bw.y + wnz.xyz * bw.z;
	return normalize(mix(wn, worldN, normal_strength));
}

// POM HEIGHT SOURCE: the per-layer ROUGHNESS textures are reused as a pseudo-height field
// (luminance proxy — ambientCG ground roughness reads as a decent relief map, so NO new
// displacement asset is needed). The march below blends the 3 layers' roughness with the SAME
// dirt/rock weights as the albedo splat so the marched bed matches the rendered surface.

void fragment() {
	vec3 wn = normalize(v_wnrm);
	// Triplanar blend weights from the geometric normal (sharpened).
	vec3 bw = pow(abs(wn), vec3(4.0));
	bw /= (bw.x + bw.y + bw.z + 1e-5);

	// Layer weights. Grass(0) -> dirt(1) by world height; rock(2) overrides on slope.
	float wy = v_wpos.y;
	float dirt_w = smoothstep(dirt_lo, dirt_hi, wy);
	float rock_w = 1.0 - smoothstep(rock_slope_lo, rock_slope_hi, wn.y); // 1 = steep

	// ---- PARALLAX-OCCLUSION MAPPING (gated; single dominant axis) -------------------------
	// duv is the 2D UV offset applied (only) to the dominant projection plane's samples below.
	vec2 duv = vec2(0.0);
	int dom = 1; // default dominant = Y (XZ plane), the common flat-ground case
	if (parallax_scale > 0.0001) {
		// Dominant triplanar axis = largest |normal| component → its projection plane carries
		// the relief. Pick the plane's 2D world-UV scale + the view direction projected onto it.
		float ax = abs(wn.x); float ay = abs(wn.y); float az = abs(wn.z);
		// Camera -> fragment direction in WORLD space (per-fragment, accurate at grazing).
		vec3 vdir = normalize(v_wpos - CAMERA_POSITION_WORLD);
		vec2 base_uv;
		vec2 vproj;   // view direction in the plane's 2D UV axes
		float depth_along; // |view . plane-normal|, scales how far to march
		float s;
		if (ay >= ax && ay >= az) {
			dom = 1; s = (scale0 + scale1 + scale2) / 3.0;
			base_uv = v_wpos.xz; vproj = vdir.xz; depth_along = max(ay, 0.15);
		} else if (ax >= az) {
			dom = 0; s = (scale0 + scale1 + scale2) / 3.0;
			base_uv = v_wpos.zy; vproj = vdir.zy; depth_along = max(ax, 0.15);
		} else {
			dom = 2; s = (scale0 + scale1 + scale2) / 3.0;
			base_uv = v_wpos.xy; vproj = vdir.xy; depth_along = max(az, 0.15);
		}
		// Max UV shift at full depth = parallax_scale (metres) * texel-scale, along the in-plane
		// view direction divided by the view's plane-normal component (steeper view → longer
		// march). Clamp the in-plane vector so grazing angles don't smear into long streaks.
		vec2 max_off = (vproj * s) * (parallax_scale / depth_along);
		float mlen = length(max_off);
		float cap = parallax_scale * s * 4.0; // clamp the total UV offset (anti-grazing smear)
		if (mlen > cap && mlen > 1e-6) max_off *= (cap / mlen);

		// 10-step parallax-occlusion march: walk the ray down from height=1 to 0; at each step
		// compare the ray's current height to the sampled pseudo-height (roughness). When the
		// ray dips below the surface, binary-blend the last two samples for the hit UV. The
		// per-layer roughness is blended with the SAME weights as the splat for a matching bed.
		const int STEPS = 10;
		float layer_step = 1.0 / float(STEPS);
		float ray_h = 1.0;          // ray height, walks 1 -> 0
		vec2 cur = vec2(0.0);       // accumulated UV offset at the current step
		float prev_h = 1.0;         // ray height at the previous step
		float prev_surf = 0.0;      // sampled surface at the previous step
		vec2 prev_uv = vec2(0.0);   // UV offset at the previous step
		bool hit = false;
		for (int i = 0; i < STEPS; i++) {
			vec2 uv = (base_uv * s) + cur;
			float r0 = texture(tex0_rough, uv).r;
			float r1 = texture(tex1_rough, uv).r;
			float r2 = texture(tex2_rough, uv).r;
			float surf = mix(mix(r0, r1, dirt_w), r2, rock_w);
			if (ray_h <= surf) {
				// Crossing found between prev (ray above surf) and cur (ray below surf).
				// Interpolate the crossing fraction from the two gaps for a smooth UV.
				float gap_prev = prev_h - prev_surf;   // > 0 (was above)
				float gap_cur = surf - ray_h;          // > 0 (now below)
				float t = gap_prev / max(gap_prev + gap_cur, 1e-4);
				duv = mix(prev_uv, cur, t);
				hit = true;
				break;
			}
			prev_h = ray_h;
			prev_surf = surf;
			prev_uv = cur;
			ray_h -= layer_step;
			cur += max_off * layer_step;
		}
		if (!hit) {
			duv = cur; // ray reached the bottom without intersecting → deepest offset
		}
	}
	// ---------------------------------------------------------------------------------------

	// Gravel apron weight from the baked pad mask (never on steep rock).
	vec2 map_uv = (v_wpos.xz - map_origin) / map_span;
	float gravel_w = texture(pad_mask, map_uv).r * (1.0 - rock_w);

	vec3 a0 = tri_albedo(tex0_albedo, v_wpos, bw, scale0, dom, duv);
	vec3 a1 = tri_albedo(tex1_albedo, v_wpos, bw, scale1, dom, duv);
	vec3 a2 = tri_albedo(tex2_albedo, v_wpos, bw, scale2, dom, duv);
	vec3 ag = tri_albedo(texg_albedo, v_wpos, bw, scaleg, dom, duv);
	vec3 base = mix(a0, a1, dirt_w);
	base = mix(base, ag, gravel_w);
	base = mix(base, a2, rock_w);

	// ANTI-TILING macro variation: low-frequency value-noise brightness drift breaks the
	// repeat read at mid distance; a second noise pulls the GRASS layer toward sun-dried
	// straw in ~45 m patches (matches the grass shader's dry patches).
	float macro = vnoise01(v_wpos.xz * 0.013);
	base *= mix(0.90, 1.10, macro);
	float dry = smoothstep(0.55, 0.80,
		vnoise01(v_wpos.xz * 0.022) * 0.65 + vnoise01(v_wpos.xz * 0.044) * 0.35);
	float grass_only = (1.0 - dirt_w) * (1.0 - rock_w) * (1.0 - gravel_w);
	base = mix(base, base * vec3(1.10, 1.03, 0.78), dry * 0.35 * grass_only);

	float r0 = tri_rough(tex0_rough, v_wpos, bw, scale0, dom, duv);
	float r1 = tri_rough(tex1_rough, v_wpos, bw, scale1, dom, duv);
	float r2 = tri_rough(tex2_rough, v_wpos, bw, scale2, dom, duv);
	float rg = tri_rough(texg_rough, v_wpos, bw, scaleg, dom, duv);
	float rough = mix(mix(mix(r0, r1, dirt_w), rg, gravel_w), r2, rock_w);

	vec3 n0 = tri_normal_world(tex0_normal, v_wpos, wn, bw, scale0, dom, duv);
	vec3 n1 = tri_normal_world(tex1_normal, v_wpos, wn, bw, scale1, dom, duv);
	vec3 n2 = tri_normal_world(tex2_normal, v_wpos, wn, bw, scale2, dom, duv);
	vec3 ng = tri_normal_world(texg_normal, v_wpos, wn, bw, scaleg, dom, duv);
	vec3 worldN = normalize(mix(mix(mix(n0, n1, dirt_w), ng, gravel_w), n2, rock_w));

	// ---- PER-BIOME GROUND COLOUR (golden-safe: albedo only, heights untouched) -------------
	// The 4 quadrants split at world (80, 80) — matches WorldBounds.biome_at. Recolour the
	// ground per biome so biomes read as DIFFERENT places (urban grey-concrete / desert ochre /
	// snow cool off-white / rain dark wet-slate), smooth-blended ~16 m across the seams. The
	// recolour is by LUMINANCE (keeps the texture's relief/variation) toward each biome's hue.
	float bx = smoothstep(72.0, 88.0, v_wpos.x);
	float bz = smoothstep(72.0, 88.0, v_wpos.z);
	// Saturated/distinct biome hues so each biome survives the global cold grade (desert must
	// still read WARM ochre, snow cold-bright — the grade pulls everything cool otherwise).
	vec3 bc_urban = vec3(0.32, 0.33, 0.36);
	vec3 bc_desert = vec3(0.70, 0.48, 0.20);
	// Snow capped below blowout (art-panel P3): 0.74+ ground under the 2.8 sun merged
	// with the fog/sky into one white sheet — contrast carries "snow", not albedo.
	vec3 bc_snow = vec3(0.58, 0.63, 0.74);
	vec3 bc_rain = vec3(0.24, 0.29, 0.37);
	vec3 biome_col = mix(mix(bc_urban, bc_desert, bz), mix(bc_snow, bc_rain, bz), bx);
	float bl = dot(base, vec3(0.299, 0.587, 0.114));
	base = mix(base, biome_col * bl * 2.0, 0.8);
	// Wet sheen for the rain quadrant: lower the floor roughness so it reads glossy/wet.
	float wet = bx * bz;
	rough = mix(rough, rough * 0.55, wet * 0.6);

	ALBEDO = base;
	ROUGHNESS = clamp(rough, 0.04, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.35;
	// Convert the world-space perturbed normal into the view-space NORMAL the shader expects.
	NORMAL = normalize((VIEW_MATRIX * vec4(worldN, 0.0)).xyz);
}
"""


# ---------------------------------------------------------------- water ribbon
## Catmull-Rom interpolation of the centerline at parameter (seg + t), seg in
## [0..RIVER_PTS.size()-2]. Endpoints are duplicated so the spline passes through the
## first/last control points (no overshoot off the map). PURE.
static func _catmull(seg: int, t: float) -> Vector2:
	var n: int = RIVER_PTS.size()
	var p0: Vector2 = RIVER_PTS[max(seg - 1, 0)]
	var p1: Vector2 = RIVER_PTS[seg]
	var p2: Vector2 = RIVER_PTS[min(seg + 1, n - 1)]
	var p3: Vector2 = RIVER_PTS[min(seg + 2, n - 1)]
	var t2: float = t * t
	var t3: float = t2 * t
	return (
		0.5
		* (
			(2.0 * p1)
			+ (-p0 + p2) * t
			+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
		)
	)


## Resamples the Catmull-Rom centerline at ~2.5 m arc steps → a dense list of samples.
## Returns Array of Vector2 (world XZ), 60+ for the ~270 m river.
static func _resample_centerline() -> Array[Vector2]:
	var raw: Array[Vector2] = []
	var sub: int = 24  # fine subdivision per segment for arc-length accuracy
	for seg in range(RIVER_PTS.size() - 1):
		var steps: int = sub if seg == RIVER_PTS.size() - 2 else sub
		for s in range(steps):
			raw.append(_catmull(seg, float(s) / float(sub)))
	raw.append(RIVER_PTS[RIVER_PTS.size() - 1])
	# Walk the fine polyline, emitting a sample every ~2.5 m of arc length.
	var out: Array[Vector2] = []
	out.append(raw[0])
	var acc: float = 0.0
	var arc_step: float = 2.5
	for i in range(1, raw.size()):
		var d: float = raw[i].distance_to(raw[i - 1])
		acc += d
		if acc >= arc_step:
			out.append(raw[i])
			acc = 0.0
	if out[out.size() - 1].distance_to(raw[raw.size() - 1]) > 0.5:
		out.append(raw[raw.size() - 1])
	return out


static func _build_water(root: Node3D) -> void:
	# A ribbon following a Catmull-Rom-smoothed river centerline that FILLS the deep carved
	# channel: every vertex sits at water_surface_at (≈ local bank top − WATER_FREEBOARD),
	# spanning the full channel half-extent so the surface meets the wet banks at the
	# waterline. Sampled every ~2.5 m with MITERED joints (no fold gaps at corners) and UVs
	# (U across, V = arclength/3) so the shader flows water downstream. Render-only.
	var shader: Shader = load("res://shaders/water.gdshader")
	var smat := ShaderMaterial.new()
	if shader != null:
		smat.shader = shader
	# Graphics-quality lever (set by SettingsManager from the preset; read at build, so a
	# change applies on the next raid): 0 = flat/cheap water (no SCREEN_TEXTURE refraction),
	# 0.12 = full refractive water. Default ceiling is 0.12.
	smat.set_shader_parameter("refract_amt", clampf(Settings.water_refraction, 0.0, 0.5))
	# Half-width = the channel half-extent so the plane reaches the waterline on the banks.
	var off_edge: float = RIVER_CHANNEL_HALF
	var off_mid: float = RIVER_CHANNEL_HALF * 0.42
	var samples: Array[Vector2] = _resample_centerline()
	var ns: int = samples.size()

	# Per-sample mitered perpendicular = normalize(perp(dir_prev) + perp(dir_next)),
	# clamped so the miter length stays ≤ 2× (avoids spikes at sharp corners).
	var perps: Array[Vector2] = []
	var miters: Array[float] = []
	for i in range(ns):
		var dir_prev: Vector2
		var dir_next: Vector2
		if i > 0:
			dir_prev = (samples[i] - samples[i - 1]).normalized()
		else:
			dir_prev = (samples[1] - samples[0]).normalized()
		if i < ns - 1:
			dir_next = (samples[i + 1] - samples[i]).normalized()
		else:
			dir_next = (samples[ns - 1] - samples[ns - 2]).normalized()
		var pp := Vector2(-dir_prev.y, dir_prev.x)
		var pn := Vector2(-dir_next.y, dir_next.x)
		var m: Vector2 = pp + pn
		var mlen: float = m.length()
		if mlen < 0.0001:
			m = pn
			mlen = 1.0
		m /= mlen
		# Miter scale = 1 / cos(theta/2); cos = dot(m, pn). Clamp to ≤2.
		var cosa: float = m.dot(pn)
		var scale: float = 1.0
		if cosa > 0.0001:
			scale = clamp(1.0 / cosa, 1.0, 2.0)
		perps.append(m)
		miters.append(scale)

	# Build explicit arrays (4 verts across each section). UV.V = cumulative arclength/3.
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	# 4 cross verts: offsets [-edge, -mid, +mid, +edge]; U in [0,1] = [0, 0.293, 0.707, 1].
	var offs: Array[float] = [-off_edge, -off_mid, off_mid, off_edge]
	var us: Array[float] = [
		0.0, (off_edge - off_mid) / (2.0 * off_edge), (off_edge + off_mid) / (2.0 * off_edge), 1.0
	]
	# The water plane Y comes from the FROZEN water_surface_at contract so the mesh and the
	# pure function agree exactly. The flat plane is sampled at the CENTERLINE (one Y per
	# section) so the surface is a level pool filling the channel — the edges meet the wet
	# banks at the waterline rather than tilting with the cross-section.
	# section vertex cache: store the 4 world verts per section so we stitch quads.
	var sect: Array = []  # Array of Array[Vector3] (4 each)
	for i in range(ns):
		var cy: float = _bank_top(samples[i].x, samples[i].y) - WATER_FREEBOARD
		var row: Array[Vector3] = []
		for j in range(4):
			var o: float = offs[j] * miters[i]
			var wx: float = samples[i].x + perps[i].x * o
			var wz: float = samples[i].y + perps[i].y * o
			row.append(Vector3(wx, cy, wz))
		sect.append(row)

	# Stitch 3 quads between consecutive sections (CW-from-above winding for Godot front
	# faces, matching the ground). cull_disabled in-shader anyway, but keep it consistent.
	for i in range(ns - 1):
		var a: Array = sect[i]
		var b: Array = sect[i + 1]
		var v_a: float = _arc_v(samples, i)
		var v_b: float = _arc_v(samples, i + 1)
		for j in range(3):
			var a0: Vector3 = a[j]
			var a1: Vector3 = a[j + 1]
			var b0: Vector3 = b[j]
			var b1: Vector3 = b[j + 1]
			var ua0 := Vector2(us[j], v_a)
			var ua1 := Vector2(us[j + 1], v_a)
			var ub0 := Vector2(us[j], v_b)
			var ub1 := Vector2(us[j + 1], v_b)
			# Tri 1: a0, b1, b0 ; Tri 2: a0, a1, b1  (CW from above).
			pos.append(a0)
			uv.append(ua0)
			nrm.append(Vector3.UP)
			pos.append(b1)
			uv.append(ub1)
			nrm.append(Vector3.UP)
			pos.append(b0)
			uv.append(ub0)
			nrm.append(Vector3.UP)
			pos.append(a0)
			uv.append(ua0)
			nrm.append(Vector3.UP)
			pos.append(a1)
			uv.append(ua1)
			nrm.append(Vector3.UP)
			pos.append(b1)
			uv.append(ub1)
			nrm.append(Vector3.UP)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.name = "RiverWater"
	mi.mesh = mesh
	mi.material_override = smat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


## Cumulative arclength / 3.0 at sample index i (V flow coordinate). PURE.
static func _arc_v(samples: Array[Vector2], i: int) -> float:
	var acc: float = 0.0
	for k in range(1, i + 1):
		acc += samples[k].distance_to(samples[k - 1])
	return acc / 3.0


# ---------------------------------------------------------------- backdrop
## Render-only mountain ring well OUTSIDE the walls (radius 115-170), 8-12 deterministic
## grey rocky peaks with snowy tops. NO collision. Sells «горы» on the DISTANT horizon —
## peak height scales with distance (closer ones small ~18-25 m, far ones up to ~45 m) so
## the ring reads as a far-off range, never a wall-side pyramid looming over the player.
static func _build_backdrop(root: Node3D) -> void:
	var container := Node3D.new()
	container.name = "MountainBackdrop"
	# Ring the bigger 320×320 map: centre on the world centre (80,80), well outside the walls.
	container.position = Vector3(WorldBounds.CX, 0.0, WorldBounds.CZ)
	root.add_child(container)
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.32, 0.33, 0.36)
	rock_mat.roughness = 1.0
	var count: int = 14
	for i in range(count):
		var ang: float = (TAU * float(i) / float(count)) + ProcHash.hf(i * 7 + 1) * 0.4
		# rad ≥ 235 keeps every peak OUTSIDE the rectangle even toward a corner (the SE/etc.
		# corners sit ~226 m from the centre 80,80); 235..335 rings the whole 320 m world.
		var rad: float = 235.0 + ProcHash.hf(i * 13 + 3) * 100.0  # 235..335 (beyond the corner wall dist)
		# Height scales with distance: near ring ≈30 m, far ring up to ~68 m (taller — farther).
		var dist_t: float = clamp((rad - 235.0) / 100.0, 0.0, 1.0)
		var height: float = lerp(30.0, 68.0, dist_t) + (ProcHash.hf(i * 17 + 5) - 0.5) * 10.0
		var base_r: float = height * (0.7 + ProcHash.hf(i * 19 + 2) * 0.4)
		var px: float = cos(ang) * rad
		var pz: float = sin(ang) * rad
		var peak := MeshInstance3D.new()
		peak.name = "Peak%d" % i
		var cone := CylinderMesh.new()
		cone.top_radius = base_r * 0.04
		cone.bottom_radius = base_r
		cone.height = height
		cone.radial_segments = 7
		peak.mesh = cone
		peak.material_override = rock_mat
		# Sit the cone so its base is near the ground level (slightly sunk).
		peak.position = Vector3(px, height * 0.5 - 4.0, pz)
		# Slight tilt + scale jitter so the ring isn't a uniform fan.
		peak.rotation = Vector3(
			0.0, ProcHash.hf(i * 23 + 9) * TAU, deg_to_rad((ProcHash.hf(i * 29 + 4) - 0.5) * 10.0)
		)
		peak.scale = Vector3(1.0, 1.0 + ProcHash.hf(i * 31) * 0.3, 0.85 + ProcHash.hf(i * 37) * 0.4)
		peak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(peak)
		# Snowy cap: a smaller white cone near the top.
		var snow := MeshInstance3D.new()
		var scone := CylinderMesh.new()
		scone.top_radius = base_r * 0.03
		scone.bottom_radius = base_r * 0.32
		scone.height = height * 0.34
		scone.radial_segments = 7
		snow.mesh = scone
		var snow_mat := StandardMaterial3D.new()
		snow_mat.albedo_color = Color(0.85, 0.87, 0.90)
		snow_mat.roughness = 0.85
		snow.material_override = snow_mat
		snow.position = Vector3(px, height * 0.5 - 4.0 + height * 0.33, pz)
		snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(snow)


# ---------------------------------------------------------------- river props
## A collidable footbridge across the river + a few collidable stepping stones at a ford.
static func _build_river_props(root: Node3D) -> void:
	var container := Node3D.new()
	container.name = "RiverProps"
	root.add_child(container)

	# --- footbridge: pick a scenic mid-river crossing (~z = -8, near the plaza arm).
	var cross := Vector2(20.0, -8.0)
	# Tangent of the river there → bridge spans perpendicular to flow.
	var idx: int = 0
	var bestd: float = 1e9
	for i in range(RIVER_PTS.size()):
		var dd: float = RIVER_PTS[i].distance_to(cross)
		if dd < bestd:
			bestd = dd
			idx = i
	var ni: int = clamp(idx + 1, 0, RIVER_PTS.size() - 1)
	var flow: Vector2 = (RIVER_PTS[ni] - RIVER_PTS[max(idx - 1, 0)]).normalized()
	if flow.length() < 0.01:
		flow = Vector2(0.0, 1.0)
	var span_dir := Vector2(-flow.y, flow.x)
	var ang_deg: float = rad_to_deg(atan2(span_dir.y, span_dir.x))
	# Anchor the bridge at the local bank-top Y so its ramps meet the dry banks and its arch
	# clears the water surface in the channel below.
	var bridge_y: float = _bank_top(cross.x, cross.y)
	_build_bridge(container, Vector3(cross.x, bridge_y, cross.y), ang_deg, span_dir)

	# --- stepping stones at a ford further down (~z = 38).
	var ford := Vector2(16.0, 38.0)
	var plank_mat := StandardMaterial3D.new()
	plank_mat.albedo_color = Color(0.50, 0.50, 0.52)  # weathered grey stone
	plank_mat.roughness = 0.95
	# Perpendicular row of 4 stones across the channel.
	var fidx: int = 0
	var fbest: float = 1e9
	for i in range(RIVER_PTS.size()):
		var dd2: float = RIVER_PTS[i].distance_to(ford)
		if dd2 < fbest:
			fbest = dd2
			fidx = i
	var fni: int = clamp(fidx + 1, 0, RIVER_PTS.size() - 1)
	var fflow: Vector2 = (RIVER_PTS[fni] - RIVER_PTS[max(fidx - 1, 0)]).normalized()
	if fflow.length() < 0.01:
		fflow = Vector2(0.0, 1.0)
	var fperp := Vector2(-fflow.y, fflow.x)
	# Water surface at the ford → stones are tall blocks rising from the deep bed and
	# breaking ~0.35 m above the surface so they're a real (if precarious) 2nd crossing.
	var ford_surf: float = _bank_top(ford.x, ford.y) - WATER_FREEBOARD
	var stone_top: float = ford_surf + 0.35
	var stone_h: float = 3.2  # tall enough to rise from the now ~2.7 m-deep bed and break the surface
	for s in range(5):
		var off: float = (float(s) - 2.0) * (RIVER_CHANNEL_HALF * 2.0 / 4.6)
		var sp: Vector2 = ford + fperp * off
		_solid_box(
			container,
			Vector3(1.4, stone_h, 1.4),
			plank_mat,
			Vector3(sp.x, stone_top - stone_h * 0.5, sp.y)
		)


## STONE ARCH bridge — replaces the flat wooden footbridge. A raised arched deck of stone
## blocks rises in an arc above the water with low parapet walls and GENTLE RAMP APPROACHES
## from both banks up to the crown, so the navmesh bakes a continuous walkable path
## bank→crown→bank (the ONLY AI crossing of the deep channel). Centered at `pos` (the local
## bank top), rotated `ang_deg` about Y so local +Z spans the river. `span_world` is the
## world-XZ span unit vector, used to anchor each ramp end to its bank's real ground height.
static func _build_bridge(
	parent: Node3D, pos: Vector3, ang_deg: float, span_world: Vector2
) -> void:
	var bridge := Node3D.new()
	bridge.name = "StoneArchBridge"
	bridge.transform = Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(ang_deg), 0.0)), pos)
	parent.add_child(bridge)

	# Weathered grey stone (ProcMaterials gives noise/triplanar relief). Fallback-safe: if
	# the helper is unavailable the call still returns a StandardMaterial3D.
	var stone: StandardMaterial3D = ProcMaterials.weathered(Color(0.50, 0.50, 0.52), 0.0, 0.9, 0.6)
	var stone_dark: StandardMaterial3D = ProcMaterials.weathered(
		Color(0.40, 0.40, 0.43), 0.0, 0.92, 0.7
	)

	var width: float = 3.2  # deck width (generous so AI paths cross easily)
	var half_len: float = 8.0  # local Z ∈ [-8, +8] — ramps reach onto both banks
	var crown_rise: float = 1.15  # crown height above `pos.y` (≈ bank top)
	var seg_len: float = 1.6  # deck segment length along the span
	var deck_th: float = 0.45  # deck slab thickness

	# Arch height profile along local Z (parabola): 0 at the ends (bank level), crown_rise at
	# the centre. Rise 1.15 m over 8 m run ⇒ max ramp slope ≈ atan(2*1.15/8)=16° (≤30°, no
	# steps > 0.5 m) so the deck is one continuous walkable surface bank→crown→bank.
	# Anchor each END to its bank's real ground height so the ramp foot meets the terrain.
	var end_a_world: Vector2 = Vector2(pos.x, pos.z) - span_world * half_len
	var end_b_world: Vector2 = Vector2(pos.x, pos.z) + span_world * half_len
	var drop_a: float = _bank_top(end_a_world.x, end_a_world.y) - pos.y  # bank height vs centre
	var drop_b: float = _bank_top(end_b_world.x, end_b_world.y) - pos.y

	# Lay overlapping deck segments. Each segment is tilted to follow the local arch slope so
	# the top faces form a smooth continuous ramp (collidable layer-1 blocks → navmesh bakes).
	var n_seg: int = int(round((half_len * 2.0) / seg_len))
	for s in range(n_seg):
		var z0: float = -half_len + float(s) * seg_len
		var z1: float = z0 + seg_len
		var zc: float = (z0 + z1) * 0.5
		var y0: float = _arch_y(z0, half_len, crown_rise, drop_a, drop_b)
		var y1: float = _arch_y(z1, half_len, crown_rise, drop_a, drop_b)
		var yc: float = (y0 + y1) * 0.5
		var dy: float = y1 - y0
		var seg_pitch: float = atan2(dy, seg_len)  # tilt to follow the slope
		# Segment slightly longer than seg_len so consecutive blocks overlap (no gap seam the
		# navmesh could reject). Box centred at (0, yc, zc), pitched about local X.
		var bm := BoxMesh.new()
		bm.size = Vector3(width, deck_th, seg_len * 1.18)
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.material_override = stone
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.transform = Transform3D(
			Basis.from_euler(Vector3(-seg_pitch, 0.0, 0.0)), Vector3(0.0, yc, zc)
		)
		mi.transform = Transform3D.IDENTITY
		body.add_child(mi)
		var col := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = bm.size
		col.shape = sh
		body.add_child(col)
		bridge.add_child(body)

	# Two ABUTMENT/PILLAR blocks dropping into the channel under the crown — pure look (and
	# they read as a stone arch's supports). Taller now (3.8 m) so they reach the deeper
	# ~2.7 m bed instead of floating above it.
	for pzc in [-half_len * 0.45, half_len * 0.45]:
		var py: float = _arch_y(pzc, half_len, crown_rise, drop_a, drop_b)
		_solid_box(
			bridge,
			Vector3(width * 0.7, 3.8, 1.1),
			stone_dark,
			Vector3(0.0, py - deck_th * 0.5 - 1.9, pzc)
		)
	# A central keystone pier under the crown for the classic arch silhouette — extended down
	# to the deep bed (crown ≈ +1.15 above bank, bed ≈ -2.7 below ⇒ ~4.4 m of pier).
	_solid_box(
		bridge,
		Vector3(width * 0.55, 4.4, 1.4),
		stone_dark,
		Vector3(0.0, crown_rise - deck_th * 0.5 - 2.2, 0.0)
	)

	# Low parapet walls on BOTH sides, following the arch so they ride the deck. Built from
	# short segments so they curve with the crown and never block the walkable top.
	for sgn in [-1.0, 1.0]:
		var rx: float = sgn * (width * 0.5 - 0.18)
		for s in range(n_seg):
			var z0p: float = -half_len + float(s) * seg_len
			var zcp: float = z0p + seg_len * 0.5
			var yp: float = _arch_y(zcp, half_len, crown_rise, drop_a, drop_b)
			_solid_box(
				bridge,
				Vector3(0.36, 0.7, seg_len * 1.05),
				stone_dark,
				Vector3(rx, yp + deck_th * 0.5 + 0.35, zcp)
			)


## Arch height profile (local Z → local Y) for the stone bridge. Parabola peaking at the
## crown (z=0), descending to each bank end's real ground height (drop_a/drop_b at z=∓len).
## PURE. The slope stays ≤ ~16° given crown_rise≈1.15 over len≈8 ⇒ walkable for AI + player.
static func _arch_y(
	z: float, half_len: float, crown_rise: float, drop_a: float, drop_b: float
) -> float:
	var t: float = clamp(abs(z) / half_len, 0.0, 1.0)
	var arch: float = crown_rise * (1.0 - t * t)  # parabola: crown at z=0, 0 at ends
	# Blend the end anchor (so the ramp foot sits on the actual bank) toward the arch crown.
	var end_drop: float = drop_b if z >= 0.0 else drop_a
	return arch + end_drop * (t * t)


## Local copy of the ProceduralBuildings `_solid` idiom: a box that BOTH renders and
## collides (StaticBody3D + BoxShape3D on layer 1) so the navmesh bakes around it.
static func _solid_box(
	parent: Node3D, size: Vector3, mat: StandardMaterial3D, offset: Vector3
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.transform = Transform3D(Basis.IDENTITY, offset)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	parent.add_child(body)
	return body
