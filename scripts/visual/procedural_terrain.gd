extends RefCounted
class_name ProceduralTerrain
## Procedural TERRAIN for the 160×160 arena — replaces the flat Ground plane with
## gentle rolling hills, a rocky perimeter berm («скалы») + a render-only mountain
## backdrop outside the walls, and a shallow WALKABLE river with animated water and a
## footbridge. Built before the navmesh bake so the relief is pathable.
##
## CONTRACT (arena.gd `_build_terrain()` depends on these EXACT signatures):
##   static build(parent, poi_defs) -> Node3D   (adds itself under parent, returns root)
##   static height_at(x, z) -> float             (PURE; same math the mesh uses)
##
## DETERMINISM: ALL variation derives ONLY from Settings.TERRAIN_SEED via the `_h`/`_hf`
## arithmetic-hash idiom (copied from procedural_buildings.gd). NO randf/randi/Time so
## every co-op peer bakes byte-identical geometry + collision.
##
## PADS: every building footprint / extraction zone / spawn cluster / plaza / scatter
## spot blends to EXACTLY y=0 (smoothstep falloff). `pad_w(x,z)` in [0..1]; the final
## height is `raw * (1 - pad_w)` and river depth is also `* (1 - pad_w)` so pads always
## win → buildings/markers keep their authored heights, AI walks every pad flat.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>` — all locals are typed.

const HALF: float = 80.0          # playable half-extent (±80 X/Z)
const RIM_INNER: float = 64.0     # berm starts ramping up here
const RIM_OUTER: float = 78.0     # berm reaches full height by here (just inside walls)

# Terrain blend colors — authored as NATURAL sRGB. The ground albedo is a BAKED sRGB
# TEXTURE (_bake_ground_texture): _color_srgb() writes these straight into an FORMAT_RGB8
# Image and the renderer sRGB-decodes the albedo texture automatically — NO manual
# linearization on the rendered path (the old per-vertex ARRAY_COLOR path was silently
# lossy on this mesh/material combo in Godot 4.6, rendering grey-white). These are the
# natural countryside palette in sRGB space.
const C_GRASS := Color(0.30, 0.47, 0.17)   # lowland grass (bright enough to survive the blue ambient)
const C_DIRT := Color(0.40, 0.32, 0.21)    # mid elevation dirt
const C_ROCK := Color(0.38, 0.39, 0.41)    # slope / berm rock
const C_WET := Color(0.18, 0.18, 0.14)     # wet riverbed
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

# ---------------------------------------------------------------- seed hashing
static func _h(n: int) -> int:
	var x: int = (n * 2654435761) ^ 0x27d4eb2d
	x = (x ^ (x >> 15)) * 0x85ebca6b
	x = x ^ (x >> 13)
	return abs(x)

static func _hf(n: int) -> float:
	return float(_h(n) % 100000) / 100000.0

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
	return _hf(n) * 2.0 - 1.0

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
## radius), the 3 extraction zones, the spawn cluster, and the 20 scatter spots that
## arena.gd `_rebuild_scatter()` places — flattening each so authored heights survive.
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
			_pads.append({"kind": "rect", "x": px, "z": pz,
				"hw": w * 0.5 + 6.0, "hd": dd * 0.5 + 6.0, "fall": 8.0})
	# Extraction zones (r=10) — already inside POI pads but enforced.
	for zc in [Vector2(45.0, -28.0), Vector2(-30.0, 50.0), Vector2(-52.0, 30.0)]:
		_pads.append({"kind": "circle", "x": zc.x, "z": zc.y, "r": 10.0, "fall": 8.0})
	# Player spawn cluster (r=16 at (59,60)).
	_pads.append({"kind": "circle", "x": 59.0, "z": 60.0, "r": 16.0, "fall": 9.0})
	# The 20 scatter spots from arena.gd `_rebuild_scatter()` — r=4 pads under each.
	var scatter: Array[Vector2] = [
		Vector2(-15, -20), Vector2(20, 8), Vector2(-25, 5),
		Vector2(30, -55), Vector2(-60, -20), Vector2(60, -5),
		Vector2(15, 55), Vector2(-10, 35), Vector2(5, -35),
		Vector2(-66, -60), Vector2(66, 60), Vector2(-70, 12),
		Vector2(38, 22), Vector2(-40, -8), Vector2(8, 20),
		Vector2(-18, 58), Vector2(48, 10), Vector2(-48, 56),
		Vector2(22, -10), Vector2(-8, -58),
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

## River channel weight in [0,1]: 1 at the centerline, smoothstep to 0 across a ~3 m
## bank. Used both to lower the bed (relative to the local banks, so the ford stays a
## shallow RIVER_DEPTH step regardless of the underlying hills) and to color the bed.
static func _river_t(x: float, z: float) -> float:
	var dist: float = _river_dist(x, z)
	var halfw: float = Settings.RIVER_WIDTH * 0.5
	var bank: float = 3.0
	return 1.0 - smoothstep(halfw, halfw + bank, dist)

## Effective carve depth at (x,z) (for COLORING the wet bed only).
static func _river_carve(x: float, z: float) -> float:
	return Settings.RIVER_DEPTH * _river_t(x, z)

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
	var freq: float = 1.0 / 32.0   # ~32 m features
	var hills: float = _fbm(x * freq, z * freq) * Settings.TERRAIN_HILL_AMP
	# --- perimeter berm: ramp 0→RIM_HEIGHT between RIM_INNER..RIM_OUTER on |x| or |z|,
	# with rocky noise on top. Slopes here may exceed 47° (unclimbable scenery).
	var edge: float = max(abs(x), abs(z))
	var berm: float = 0.0
	if edge > RIM_INNER:
		var ramp: float = smoothstep(RIM_INNER, RIM_OUTER, edge)
		var rock: float = _fbm(x * 0.18, z * 0.18) * 1.4
		berm = ramp * (Settings.TERRAIN_RIM_HEIGHT + rock)
	var raw: float = hills + berm
	# --- river: lower the bed to RIVER_DEPTH BELOW the immediate banks (lerp toward
	# `hills - RIVER_DEPTH`), so the channel is always a shallow walkable step relative to
	# the surrounding ground — never a deep pit where the hills already dip. The berm is
	# excluded from the bank baseline (the river never reaches the perimeter interior).
	var rt: float = _river_t(x, z)
	if rt > 0.0:
		var bed: float = hills - Settings.RIVER_DEPTH
		raw = lerp(raw, bed, rt)
	var h: float = lerp(PAD_Y, raw, open)
	return h

# ---------------------------------------------------------------- vertex color
## Returns the authored palette blend in **sRGB** space (the natural countryside colors).
## This is the source of truth for the ground's color; it's baked into an sRGB albedo
## TEXTURE in _build_ground (the renderer sRGB-decodes it automatically — NO manual
## srgb_to_linear here). _color_at() wraps this and linearizes for the legacy vertex-color
## path (kept for any caller), but the rendered ground uses the texture.
static func _color_srgb(x: float, z: float, h: float, slope: float) -> Color:
	var carve: float = _river_carve(x, z)
	# Riverbed → wet dark.
	if carve > 0.20:
		return C_WET.lerp(C_DIRT, clamp(1.0 - carve / Settings.RIVER_DEPTH, 0.0, 1.0))
	# Narrow WET PEBBLE band at the waterline edge (carve ~0.05-0.20 m): the damp,
	# darker grey-brown shoreline where the channel meets the dry bank — kills the hard
	# colour seam («провалы в текстурах на границе реки») the old code showed.
	if carve > 0.05:
		var bandw: float = smoothstep(0.05, 0.13, carve) * (1.0 - smoothstep(0.16, 0.20, carve))
		var grass_edge: Color = C_GRASS.lerp(C_PEBBLE, smoothstep(0.05, 0.10, carve))
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
	var jitter: float = (_hf(jn) - 0.5) * 0.06   # in [-0.03, +0.03]
	c.r = clamp(c.r + jitter, 0.0, 1.0)
	c.g = clamp(c.g + jitter, 0.0, 1.0)
	c.b = clamp(c.b + jitter, 0.0, 1.0)
	return c

## Legacy linear vertex-color (unused by the rendered ground now — texture path renders).
static func _color_at(x: float, z: float, h: float, slope: float) -> Color:
	return _color_srgb(x, z, h, slope).srgb_to_linear()

# ================================================================ BUILD
static func build(parent: Node3D, poi_defs: Dictionary) -> Node3D:
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
	var cell: float = Settings.TERRAIN_CELL
	var n: int = int(round((HALF * 2.0) / cell))   # cells per side (80)
	var verts: int = n + 1                          # 81 verts per side

	# Precompute height + per-vertex color/normal grids. Building the surface from
	# EXPLICIT arrays (add_surface_from_arrays) guarantees the ARRAY_COLOR is stored —
	# a SurfaceTool set_color path rendered the terrain plain white (colors dropped).
	var heights := PackedFloat32Array()
	heights.resize(verts * verts)
	for iz in range(verts):
		for ix in range(verts):
			var x: float = -HALF + float(ix) * cell
			var z: float = -HALF + float(iz) * cell
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
			var x: float = -HALF + float(ix) * cell
			var z: float = -HALF + float(iz) * cell
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
			# UV maps the whole ±HALF map 1:1 onto [0..1]² so the baked texture aligns.
			grid_uv[idx] = Vector2((x + HALF) / (HALF * 2.0), (z + HALF) / (HALF * 2.0))

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
	root.add_child(_make_ground_body(mesh, mi, faces))


## Builds the ground StaticBody3D (collision unchanged) wrapping the mesh + material.
## Split out only so _build_ground stays readable after the material swap; the collision
## shape / layers / backface flag are byte-identical to the original inline path.
static func _make_ground_body(mesh: ArrayMesh, mi: MeshInstance3D, faces: PackedVector3Array) -> StaticBody3D:
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
	# World-space tiling (metres per texture repeat). ~3.5 m grass, ~4 m dirt, ~5 m rock.
	m.set_shader_parameter("scale0", 0.285)   # 1/3.5
	m.set_shader_parameter("scale1", 0.25)    # 1/4
	m.set_shader_parameter("scale2", 0.20)    # 1/5
	# Height blend (world-Y, metres). Grass below ~2.5 m, dirt fades in by ~5 m.
	m.set_shader_parameter("dirt_lo", 2.5)
	m.set_shader_parameter("dirt_hi", 5.5)
	# Slope blend: rock fades in as the surface up-dot drops below ~0.86 (~31°) to ~0.66 (~49°).
	m.set_shader_parameter("rock_slope_lo", 0.66)
	m.set_shader_parameter("rock_slope_hi", 0.86)
	m.set_shader_parameter("normal_strength", 0.85)
	return m

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

uniform float scale0 = 0.285;
uniform float scale1 = 0.25;
uniform float scale2 = 0.20;
uniform float dirt_lo = 2.5;
uniform float dirt_hi = 5.5;
uniform float rock_slope_lo = 0.66;
uniform float rock_slope_hi = 0.86;
uniform float normal_strength = 0.85;

varying vec3 v_wpos;
varying vec3 v_wnrm;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// World-space triplanar albedo for one set.
vec3 tri_albedo(sampler2D t, vec3 wpos, vec3 bw, float s) {
	vec3 cx = texture(t, wpos.zy * s).rgb;
	vec3 cy = texture(t, wpos.xz * s).rgb;
	vec3 cz = texture(t, wpos.xy * s).rgb;
	return cx * bw.x + cy * bw.y + cz * bw.z;
}

float tri_rough(sampler2D t, vec3 wpos, vec3 bw, float s) {
	float rx = texture(t, wpos.zy * s).r;
	float ry = texture(t, wpos.xz * s).r;
	float rz = texture(t, wpos.xy * s).r;
	return rx * bw.x + ry * bw.y + rz * bw.z;
}

// Triplanar tangent-space normal -> world-space (whiteout blend), then re-expressed in the
// fragment's TANGENT/BINORMAL frame for NORMAL output.
vec3 tri_normal_world(sampler2D t, vec3 wpos, vec3 wn, vec3 bw, float s) {
	vec3 nx = texture(t, wpos.zy * s).xyz * 2.0 - 1.0;
	vec3 ny = texture(t, wpos.xz * s).xyz * 2.0 - 1.0;
	vec3 nz = texture(t, wpos.xy * s).xyz * 2.0 - 1.0;
	// Reorient each axis sample into world space (UDN-style) around the geometric normal.
	vec3 wnx = normalize(vec3(nx.xy + wn.zy, abs(wn.x)));
	vec3 wny = normalize(vec3(ny.xy + wn.xz, abs(wn.y)));
	vec3 wnz = normalize(vec3(nz.xy + wn.xy, abs(wn.z)));
	// Swizzle back to world axes per projection plane.
	vec3 worldN = wnx.zyx * bw.x + wny.xzy * bw.y + wnz.xyz * bw.z;
	return normalize(mix(wn, worldN, normal_strength));
}

void fragment() {
	vec3 wn = normalize(v_wnrm);
	// Triplanar blend weights from the geometric normal (sharpened).
	vec3 bw = pow(abs(wn), vec3(4.0));
	bw /= (bw.x + bw.y + bw.z + 1e-5);

	// Layer weights. Grass(0) -> dirt(1) by world height; rock(2) overrides on slope.
	float wy = v_wpos.y;
	float dirt_w = smoothstep(dirt_lo, dirt_hi, wy);
	float rock_w = 1.0 - smoothstep(rock_slope_lo, rock_slope_hi, wn.y); // 1 = steep

	vec3 a0 = tri_albedo(tex0_albedo, v_wpos, bw, scale0);
	vec3 a1 = tri_albedo(tex1_albedo, v_wpos, bw, scale1);
	vec3 a2 = tri_albedo(tex2_albedo, v_wpos, bw, scale2);
	vec3 base = mix(a0, a1, dirt_w);
	base = mix(base, a2, rock_w);

	float r0 = tri_rough(tex0_rough, v_wpos, bw, scale0);
	float r1 = tri_rough(tex1_rough, v_wpos, bw, scale1);
	float r2 = tri_rough(tex2_rough, v_wpos, bw, scale2);
	float rough = mix(mix(r0, r1, dirt_w), r2, rock_w);

	vec3 n0 = tri_normal_world(tex0_normal, v_wpos, wn, bw, scale0);
	vec3 n1 = tri_normal_world(tex1_normal, v_wpos, wn, bw, scale1);
	vec3 n2 = tri_normal_world(tex2_normal, v_wpos, wn, bw, scale2);
	vec3 worldN = normalize(mix(mix(n0, n1, dirt_w), n2, rock_w));

	ALBEDO = base;
	ROUGHNESS = clamp(rough, 0.04, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.35;
	// Convert the world-space perturbed normal into the view-space NORMAL the shader expects.
	NORMAL = normalize((VIEW_MATRIX * vec4(worldN, 0.0)).xyz);
}
"""

# ---------------------------------------------------------------- ground texture bake
## Bakes the authored sRGB palette (grass/dirt/rock/wet) into an albedo TEXTURE that maps
## 1:1 over the ±HALF map. Resolution is 2× the vertex grid (161×161 for the 81-vert grid)
## sampled at half-cell steps for smoothness. Writes sRGB color directly (NO linearization —
## the renderer sRGB-decodes the albedo texture). Slope is computed by central differences
## of height_at at the sample point so the rock/dirt blend matches the mesh shading exactly.
## Bakes the authored sRGB palette into a 481×481 albedo texture from a PRE-SAMPLED quarter-
## cell height grid `th` (tex_n × tex_n). Slope comes from grid central differences (no extra
## height_at calls). Per-texel high-freq grain (±0.04) breaks the low-res wash. Linearized at
## write-time (runtime ImageTextures are read LINEAR by the GPU — the sRGB-decode trap).
static func _bake_ground_texture(th: PackedFloat32Array, tex_n: int, step: float) -> ImageTexture:
	var img := Image.create(tex_n, tex_n, false, Image.FORMAT_RGB8)
	for ty in range(tex_n):
		var z: float = -HALF + float(ty) * step
		for tx in range(tex_n):
			var x: float = -HALF + float(tx) * step
			var hc: float = th[ty * tex_n + tx]
			var hl: float = th[ty * tex_n + max(tx - 1, 0)]
			var hr: float = th[ty * tex_n + min(tx + 1, tex_n - 1)]
			var hd: float = th[max(ty - 1, 0) * tex_n + tx]
			var hu: float = th[min(ty + 1, tex_n - 1) * tex_n + tx]
			var dhdx: float = (hr - hl) / (2.0 * step)
			var dhdz: float = (hu - hd) / (2.0 * step)
			var slope: float = sqrt(dhdx * dhdx + dhdz * dhdz)
			var col: Color = _color_srgb(x, z, hc, slope)
			# Per-texel high-frequency value grain (±0.04) — deterministic hash of the texel
			# coords (same _hf idiom) so every peer bakes identical bytes.
			var gn: int = tx * 1973471149 + ty * 912839821 + Settings.TERRAIN_SEED * 39847
			var grain: float = (_hf(gn) - 0.5) * 0.08   # in [-0.04, +0.04]
			col.r = clamp(col.r + grain, 0.0, 1.0)
			col.g = clamp(col.g + grain, 0.0, 1.0)
			col.b = clamp(col.b + grain, 0.0, 1.0)
			img.set_pixel(tx, ty, col.srgb_to_linear())
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## Bakes a tangent-space NORMAL map (tex_n×tex_n) from the SAME pre-sampled height grid via
## central differences. For a flat-up ground the OpenGL convention is R=nx*0.5+0.5,
## G=ny*0.5+0.5, B≈1. Slope is exaggerated ×1.5 so the relief reads. RAW FORMAT_RGB8 — NEVER
## srgb-linearized (a normal map is data; the StandardMaterial samples it as a linear normal).
static func _bake_ground_normal(th: PackedFloat32Array, tex_n: int, step: float) -> ImageTexture:
	var exaggerate: float = 1.5
	var img := Image.create(tex_n, tex_n, false, Image.FORMAT_RGB8)
	for ty in range(tex_n):
		for tx in range(tex_n):
			var hl: float = th[ty * tex_n + max(tx - 1, 0)]
			var hr: float = th[ty * tex_n + min(tx + 1, tex_n - 1)]
			var hd: float = th[max(ty - 1, 0) * tex_n + tx]
			var hu: float = th[min(ty + 1, tex_n - 1) * tex_n + tx]
			var dhdx: float = (hr - hl) / (2.0 * step) * exaggerate
			var dhdz: float = (hu - hd) / (2.0 * step) * exaggerate
			# Tangent-space for a flat-up ground (T=+X, B=+Z, N=+Y): nx=-dhdx, ny(green)=-dhdz.
			var wn := Vector3(-dhdx, -dhdz, 1.0).normalized()
			img.set_pixel(tx, ty, Color(wn.x * 0.5 + 0.5, wn.y * 0.5 + 0.5, wn.z * 0.5 + 0.5))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## Small high-frequency tiling NoiseTexture2D for the StandardMaterial detail-albedo slot —
## crisp ~0.4 m grain at close range. Seamless + small so it tiles cheaply over the 160 m
## ground UV (0..1). Cached so a rebuild reuses one instance.
static var _detail_tex: NoiseTexture2D = null
static func _ground_detail_texture() -> NoiseTexture2D:
	if _detail_tex != null:
		return _detail_tex
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = Settings.TERRAIN_SEED
	noise.frequency = 0.08            # high freq → fine ~0.4 m grain when tiled over 160 m
	noise.fractal_octaves = 3
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true               # tiles without a visible seam at the 0..1 UV wrap
	tex.noise = noise
	# Greyscale centred ~mid so a MIX detail blend nudges albedo lighter/darker subtly.
	tex.color_ramp = _detail_ramp()
	_detail_tex = tex
	return tex

## A subtle grey ramp WITH LOW ALPHA: the StandardMaterial MIX detail blend uses the detail
## texture's alpha as the overlay strength, so low alpha (~0.18) means the grain only gently
## modulates the baked palette instead of flooding it grey. Dark→light grey breaks up flats.
static func _detail_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(0.30, 0.28, 0.24, 0.18))
	g.set_offset(1, 1.0)
	g.set_color(1, Color(0.70, 0.68, 0.62, 0.18))
	return g

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
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)

## Resamples the Catmull-Rom centerline at ~2.5 m arc steps → a dense list of samples.
## Returns Array of Vector2 (world XZ), 60+ for the ~270 m river.
static func _resample_centerline() -> Array[Vector2]:
	var raw: Array[Vector2] = []
	var sub: int = 24   # fine subdivision per segment for arc-length accuracy
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
	# A ribbon following a Catmull-Rom-smoothed river centerline at y≈-0.12, sampled
	# every ~2.5 m with MITERED joints (no fold gaps at corners) and UVs (U across,
	# V = arclength/3) so the shader can flow water downstream. Render-only (no collision).
	var shader: Shader = load("res://shaders/water.gdshader")
	var smat := ShaderMaterial.new()
	if shader != null:
		smat.shader = shader
	# Half-width 2.9 m: edge sits where the carve still has ~0.3 m of depth, never over
	# the dry bank (the old 3.1 overhang made floating water).
	var off_edge: float = 2.9
	var off_mid: float = 1.2
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
	var us: Array[float] = [0.0, (off_edge - off_mid) / (2.0 * off_edge),
		(off_edge + off_mid) / (2.0 * off_edge), 1.0]
	# Edge verts y=-0.10, center verts y=-0.14 (subtle camber). |U-0.5| → camber.
	# section vertex cache: store the 4 world verts per section so we stitch quads.
	var sect: Array = []   # Array of Array[Vector3] (4 each)
	for i in range(ns):
		var row: Array[Vector3] = []
		for j in range(4):
			var o: float = offs[j] * miters[i]
			var wx: float = samples[i].x + perps[i].x * o
			var wz: float = samples[i].y + perps[i].y * o
			# Camber: edges (-0.10) → center (-0.14). U=0/1 → edge, U=0.5 → center.
			var camber: float = 1.0 - abs(us[j] - 0.5) * 2.0   # 0 at edge, 1 at center
			var wy: float = lerp(-0.10, -0.14, camber)
			row.append(Vector3(wx, wy, wz))
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
			pos.append(a0); uv.append(ua0); nrm.append(Vector3.UP)
			pos.append(b1); uv.append(ub1); nrm.append(Vector3.UP)
			pos.append(b0); uv.append(ub0); nrm.append(Vector3.UP)
			pos.append(a0); uv.append(ua0); nrm.append(Vector3.UP)
			pos.append(a1); uv.append(ua1); nrm.append(Vector3.UP)
			pos.append(b1); uv.append(ub1); nrm.append(Vector3.UP)

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
	root.add_child(container)
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.32, 0.33, 0.36)
	rock_mat.roughness = 1.0
	var count: int = 10
	for i in range(count):
		var ang: float = (TAU * float(i) / float(count)) + _hf(i * 7 + 1) * 0.4
		var rad: float = 115.0 + _hf(i * 13 + 3) * 55.0          # 115..170
		# Height scales with distance: near edge (115) ≈18-25 m, far edge (170) up to ~45 m.
		var dist_t: float = clamp((rad - 115.0) / 55.0, 0.0, 1.0)
		var height: float = lerp(18.0, 45.0, dist_t) + (_hf(i * 17 + 5) - 0.5) * 6.0
		var base_r: float = height * (0.7 + _hf(i * 19 + 2) * 0.4)
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
		peak.rotation = Vector3(0.0, _hf(i * 23 + 9) * TAU, deg_to_rad((_hf(i * 29 + 4) - 0.5) * 10.0))
		peak.scale = Vector3(1.0, 1.0 + _hf(i * 31) * 0.3, 0.85 + _hf(i * 37) * 0.4)
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
	_build_bridge(container, Vector3(cross.x, 0.0, cross.y), ang_deg)

	# --- stepping stones at a ford further down (~z = 38).
	var ford := Vector2(16.0, 38.0)
	var plank_mat := StandardMaterial3D.new()
	plank_mat.albedo_color = Color(0.36, 0.36, 0.38)
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
	for s in range(4):
		var off: float = (float(s) - 1.5) * (Settings.RIVER_WIDTH / 3.2)
		var sp: Vector2 = ford + fperp * off
		var sy: float = -Settings.RIVER_DEPTH + 0.10   # just breaking the surface
		_solid_box(container, Vector3(1.4, 0.5, 1.4), plank_mat,
			Vector3(sp.x, sy, sp.y))

## Collidable footbridge — deck planks + two side rails, centered at `pos`, rotated
## `ang_deg` about Y so it spans the river. Uses a local _solid_box copy (Procedural
## Buildings._solid not imported to keep this lane self-contained).
static func _build_bridge(parent: Node3D, pos: Vector3, ang_deg: float) -> void:
	var bridge := Node3D.new()
	bridge.name = "Footbridge"
	bridge.transform = Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(ang_deg), 0.0)), pos)
	parent.add_child(bridge)

	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.30, 0.22, 0.14)
	wood.roughness = 0.95
	var wood_dark := StandardMaterial3D.new()
	wood_dark.albedo_color = Color(0.20, 0.15, 0.10)
	wood_dark.roughness = 0.95

	var length: float = Settings.RIVER_WIDTH + 5.0   # spans the channel + banks
	var width: float = 2.4
	var deck_y: float = 0.18
	# Deck (single solid slab so AI/raycasts treat it as ground).
	_solid_box(bridge, Vector3(width, 0.25, length), wood, Vector3(0.0, deck_y, 0.0))
	# Two side rails (posts + top rail).
	for sgn in [-1.0, 1.0]:
		var rx: float = sgn * (width * 0.5 - 0.1)
		_solid_box(bridge, Vector3(0.12, 0.9, length), wood_dark,
			Vector3(rx, deck_y + 0.55, 0.0))
		# A couple of vertical posts for silhouette.
		for pz in [-length * 0.3, 0.0, length * 0.3]:
			_solid_box(bridge, Vector3(0.16, 0.9, 0.16), wood_dark,
				Vector3(rx, deck_y + 0.55, pz))

## Local copy of the ProceduralBuildings `_solid` idiom: a box that BOTH renders and
## collides (StaticBody3D + BoxShape3D on layer 1) so the navmesh bakes around it.
static func _solid_box(parent: Node3D, size: Vector3, mat: StandardMaterial3D,
		offset: Vector3) -> StaticBody3D:
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
