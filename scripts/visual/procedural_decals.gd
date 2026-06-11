class_name ProceduralGrimeDecals
extends RefCounted
## Grime DECALS — scorch burns under the rubble piles, rain-leak streaks down the POI
## facades, and dark SSR-catching rain puddles in the SE rain quadrant. All textures are
## generated ONCE in code (Image -> ImageTexture, cached as statics — the ProcMaterials
## pattern) and shared; every node is a Godot Decal with distance fade so far grime
## costs nothing.
##
## RENDER-ONLY + PER-PEER COSMETIC (the ProceduralClimateZones discipline):
##   - NO collision, NO nav impact, NO netcode. Everything lives under the ARENA ROOT
##     ("GrimeDecals"), NEVER under NavigationRegion3D — the golden determinism snapshot
##     folds only NavigationRegion3D children and must not move.
##   - DETERMINISTIC via ProcHash (no randf/randi/Time); headless-skipped.
##   - Budget: <= _BUDGET decals map-wide; a push_warning fires ONLY if exceeded.
##
## Godot Decal has no roughness override — the puddles' wet read is the near-black
## albedo (dark = low diffuse, so sky/SSR reflections dominate).
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

const _BUDGET := 130  # hard map-wide decal cap
const _STREAK_THEMES: Array[String] = ["tower", "warehouse", "house"]
# Wall-top fallbacks per streaked theme (matches the builders' roof heights).
const _WALL_TOP := {"tower": 9.0, "warehouse": 5.0, "house": 6.0}

static var _streak: ImageTexture = null
static var _scorch: ImageTexture = null
static var _puddle: ImageTexture = null


## Adds a "GrimeDecals" Node3D under `arena_root`. `rubble_spots` = the arena's scatter
## pile positions (one scorch each). No-op on headless.
static func build(arena_root: Node3D, poi_defs: Dictionary, rubble_spots: Array[Vector3]) -> void:
	if arena_root == null:
		return
	if DisplayServer.get_name() == "headless":
		return
	var root := Node3D.new()
	root.name = "GrimeDecals"
	arena_root.add_child(root)
	var count: int = 0
	count = _scorches(root, rubble_spots, count)
	count = _streaks(root, poi_defs, count)
	count = _puddles(root, poi_defs, count)
	if count > _BUDGET:
		push_warning("[GrimeDecals] decal budget exceeded: %d > %d" % [count, _BUDGET])


## One scorch burn under every rubble-pile spot (the arena passes its scatter list).
static func _scorches(root: Node3D, rubble_spots: Array[Vector3], count: int) -> int:
	for i in range(rubble_spots.size()):
		var sp: Vector3 = rubble_spots[i]
		var dec := _decal(_scorch_tex(), Vector3(3.5, 2.0, 3.5))
		dec.position = sp + Vector3(0.0, 0.6, 0.0)
		dec.rotation.y = ProcHash.hf(i * 31 + 7) * TAU
		root.add_child(dec)
		count += 1
	return count


## 2-4 dark rain-leak streaks down each tower/warehouse/house facade. Decals project
## along local -Y, so each box is pitched 90 deg + yawed to drive into its wall face;
## the streak then runs DOWN the facade (local +Z maps to world -Y).
static func _streaks(root: Node3D, poi_defs: Dictionary, count: int) -> int:
	var keys: Array = poi_defs.keys()
	for i in range(keys.size()):
		var def: Dictionary = poi_defs[keys[i]]
		var theme: String = str(def["theme"])
		if not theme in _STREAK_THEMES:
			continue
		var s: int = ProcHash.h(6271 * (i + 1))
		var w: float = float(def["w"])
		var d: float = float(def["d"])
		var court: bool = bool(def["court"])
		var top: float = float(_WALL_TOP.get(theme, 5.0))
		var n: int = 2 + ProcHash.h(s) % 3
		for k in range(n):
			var ks: int = s + 40 + k * 9
			# Outward wall normal — courtyard shells have no front (+Z) wall, and their
			# side walls only span the back half (z below the keep-clear square).
			var sides: Array[Vector3] = [
				Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)
			]
			var nrm: Vector3 = sides[ProcHash.h(ks) % (3 if court else 4)]
			var px: float
			var pz: float
			if absf(nrm.z) > 0.5:  # front/back wall: streak slides along X
				px = float(def["x"]) + ProcHash.hrange(ks + 1, -w * 0.5 + 0.8, w * 0.5 - 0.8)
				pz = float(def["z"]) + nrm.z * (d * 0.5 + 0.25)
			else:  # side wall: slides along Z
				var z_hi: float = (
					-(ProceduralBuildings.COURT_CLEAR + 0.5) if court else d * 0.5 - 0.8
				)
				pz = float(def["z"]) + ProcHash.hrange(ks + 1, -d * 0.5 + 0.8, z_hi)
				px = float(def["x"]) + nrm.x * (w * 0.5 + 0.25)
			var py: float = ProcHash.hrange(ks + 2, 1.8, maxf(2.6, top - 1.6))
			var basis: Basis = (
				Basis.from_euler(Vector3(0.0, atan2(nrm.x, nrm.z), 0.0))
				* Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
			)
			var dec := _decal(_streak_tex(), Vector3(0.8, 3.0, 2.0))
			dec.transform = Transform3D(basis, Vector3(px, py, pz))
			root.add_child(dec)
			count += 1
	return count


## Rain puddles in the SE rain quadrant ONLY: 12-18 around the Temple + 6 by the shrine
## house, near-black discs conformed to the terrain (albedo_mix 1, the wet-dark read).
static func _puddles(root: Node3D, poi_defs: Dictionary, count: int) -> int:
	var tdef: Dictionary = poi_defs.get("POI_Temple", {"x": 160.0, "z": 158.0})
	var sdef: Dictionary = poi_defs.get("POI_ShrineHouse", {"x": 205.0, "z": 205.0})
	var n_temple: int = 12 + ProcHash.h(8101) % 7
	var tc := Vector2(float(tdef["x"]), float(tdef["z"]))
	var sc := Vector2(float(sdef["x"]), float(sdef["z"]))
	count = _puddle_cluster(root, tc, 30.0, n_temple, 8200, count)
	count = _puddle_cluster(root, sc, 14.0, 6, 8400, count)
	return count


static func _puddle_cluster(
	root: Node3D, c: Vector2, radius: float, n: int, s: int, count: int
) -> int:
	var placed: int = 0
	for k in range(n * 2):
		if placed >= n:
			break
		var ks: int = s + k * 11
		var ang: float = ProcHash.hf(ks) * TAU
		var rr: float = sqrt(ProcHash.hf(ks + 1)) * radius
		var px: float = c.x + cos(ang) * rr
		var pz: float = c.y + sin(ang) * rr
		if px <= WorldBounds.CX or pz <= WorldBounds.CZ:
			continue  # the rain climate (and so its puddles) is SE-quadrant only
		var sz: float = ProcHash.hrange(ks + 2, 1.5, 3.5)
		var dec := _decal(_puddle_tex(), Vector3(sz, 2.0, sz * ProcHash.hrange(ks + 3, 0.7, 1.2)))
		dec.albedo_mix = 1.0
		dec.position = Vector3(px, ProceduralTerrain.height_at(px, pz) + 0.4, pz)
		dec.rotation.y = ProcHash.hf(ks + 4) * TAU
		root.add_child(dec)
		placed += 1
		count += 1
	return count


## Shared Decal factory: albedo texture + the common distance fade.
static func _decal(tex: Texture2D, size: Vector3) -> Decal:
	var dec := Decal.new()
	dec.texture_albedo = tex
	dec.size = size
	dec.distance_fade_enabled = true
	dec.distance_fade_begin = 40.0
	dec.distance_fade_length = 10.0
	return dec


# ---------------------------------------------------------------- generated textures
## 64x128 vertical dark leak streak: per-column ProcHash strength (streaky lines),
## alpha fading to 0 at the sides + the bottom.
static func _streak_tex() -> ImageTexture:
	if _streak != null:
		return _streak
	var w: int = 64
	var h: int = 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for x in range(w):
		var cs: float = 0.35 + ProcHash.hf(x * 7 + 1) * 0.65
		for y in range(h):
			var u: float = absf(float(x) / float(w - 1) - 0.5) * 2.0
			var v: float = float(y) / float(h - 1)
			var a: float = (1.0 - smoothstep(0.45, 1.0, u)) * (1.0 - smoothstep(0.35, 1.0, v))
			img.set_pixel(x, y, Color(0.08, 0.07, 0.06, clampf(a * cs * 0.85, 0.0, 1.0)))
	_streak = ImageTexture.create_from_image(img)
	return _streak


## 128x128 radial scorch burn: near-black centre, noise-roughened rim, alpha 0 at edge.
static func _scorch_tex() -> ImageTexture:
	if _scorch != null:
		return _scorch
	var n: int = 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var dx: float = (float(x) / float(n - 1) - 0.5) * 2.0
			var dy: float = (float(y) / float(n - 1) - 0.5) * 2.0
			var r: float = sqrt(dx * dx + dy * dy)
			var nz: float = (_vnoise(float(x) / 14.0, float(y) / 14.0, 3) - 0.5) * 0.3
			var a: float = clampf(1.0 - smoothstep(0.35, 1.0, r + nz), 0.0, 1.0) * 0.9
			img.set_pixel(x, y, Color(0.05, 0.045, 0.04, a))
	_scorch = ImageTexture.create_from_image(img)
	return _scorch


## 128x128 irregular puddle blob: radial base + 2-octave hash value-noise threshold,
## near-black wet albedo with a soft alpha edge.
static func _puddle_tex() -> ImageTexture:
	if _puddle != null:
		return _puddle
	var n: int = 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var nx: float = float(x) / float(n - 1)
			var ny: float = float(y) / float(n - 1)
			var dx: float = (nx - 0.5) * 2.0
			var dy: float = (ny - 0.5) * 2.0
			var r: float = sqrt(dx * dx + dy * dy)
			var n2: float = (
				_vnoise(nx * 5.0, ny * 5.0, 11) * 0.6 + _vnoise(nx * 11.0, ny * 11.0, 23) * 0.3
			)
			var v: float = r + (n2 - 0.45) * 0.55
			var a: float = clampf((0.78 - v) * 5.0, 0.0, 1.0)
			img.set_pixel(x, y, Color(0.02, 0.025, 0.03, a))
	_puddle = ImageTexture.create_from_image(img)
	return _puddle


## Deterministic 2D value noise in [0,1) — bilinear-smoothed ProcHash lattice.
static func _vnoise(x: float, y: float, oct_seed: int) -> float:
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	var fx: float = x - float(xi)
	var fy: float = y - float(yi)
	var a: float = ProcHash.hf(xi * 131 + yi * 517 + oct_seed * 7919)
	var b: float = ProcHash.hf((xi + 1) * 131 + yi * 517 + oct_seed * 7919)
	var c: float = ProcHash.hf(xi * 131 + (yi + 1) * 517 + oct_seed * 7919)
	var d: float = ProcHash.hf((xi + 1) * 131 + (yi + 1) * 517 + oct_seed * 7919)
	var sx: float = fx * fx * (3.0 - 2.0 * fx)
	var sy: float = fy * fy * (3.0 - 2.0 * fy)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)
