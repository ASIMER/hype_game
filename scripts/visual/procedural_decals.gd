class_name ProceduralGrimeDecals
extends RefCounted
## Grime + CITY-GRAPHICS DECALS — scorch burns under the rubble piles, rain-leak streaks
## down the POI facades, dark SSR-catching rain puddles in the SE rain quadrant, and the
## painted signage (bay numbers / hazard chevrons / warning triangles / arrows / serial
## bands / placards / barcodes) that makes a facade read as something people BUILT and
## NUMBERED instead of a grey volume. All textures are generated ONCE in code (Image ->
## ImageTexture, cached as statics — the ProcMaterials pattern) and shared; every node is
## a Godot Decal with distance fade so far grime costs nothing.
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

const _BUDGET := 130  # hard map-wide decal cap (UNCHANGED by the signage tiers — see _streaks)
const _STREAK_THEMES: Array[String] = ["tower", "warehouse", "house"]
# Wall-top fallbacks per streaked theme (matches the builders' roof heights).
const _WALL_TOP := {"tower": 9.0, "warehouse": 5.0, "house": 6.0}
# Outward wall normals, in the order both the streaks and the signage draw from: index 3
# (+Z, the "front") is the wall a courtyard shell does NOT have, so court builds pick % 3.
const _SIDES: Array[Vector3] = [
	Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)
]

# --- city signage (see _signage) ---
const _SIGN_DEPTH := 0.55  # projection depth; the wall face sits at the decal box CENTRE
const _EDGE_MARGIN := 1.2  # keep markings off the corners (drainpipes/pilasters live there)
# Half the widest opening (the 1.6 m door) + its protruding sill ledge: the distance a sign
# must keep from a wall panel's centre to sit wholly on the solid pier beside the glass.
const _PIER_CLEAR := 1.25
const _FAR_FADE := Vector2(75.0, 25.0)  # BIG tier (begin, length) — still readable at 40-50 m
const _NEAR_FADE := Vector2(22.0, 8.0)  # SMALL tier: gone by 30 m, cheaper than the grime gate
const _NEON_ENERGY := 0.25  # constant weak decal emission (night read); 0.0 disables it
const _NEON_KINDS: Array[String] = ["placard", "number"]
# kind -> [width m, height m, band low m, band high m]. The band is where the sign's CENTRE
# may sit; _sign_place insets it by half the height and clamps it under the wall top.
const _SIGN_SPECS := {
	"number": [2.0, 2.2, 1.8, 5.4],
	"hazard": [3.0, 0.8, 1.6, 3.4],
	"arrow": [1.8, 1.2, 2.0, 4.4],
	"warn": [1.4, 1.4, 2.2, 4.4],
	"serial": [1.6, 0.4, 1.1, 2.0],
	"placard": [0.7, 0.5, 1.2, 1.9],
	"barcode": [0.6, 0.4, 1.1, 1.8],
}
const _BIG_KINDS: Array[String] = ["number", "hazard", "arrow", "warn"]
const _SMALL_KINDS: Array[String] = ["serial", "placard", "barcode"]
# Which BIG markings suit which theme (a dwelling gets no loading-bay number).
const _THEME_BIG := {
	"warehouse": ["number", "hazard", "arrow"],
	"tower": ["number", "warn", "hazard"],
	"house": ["warn", "arrow", "hazard"],
}
# Baked variants per kind — a handful so neighbouring POIs differ while the texture count
# (and so the decal atlas) stays tiny.
const _SIGN_VARIANTS := {
	"number": 6, "hazard": 1, "arrow": 1, "warn": 1, "serial": 3, "placard": 2, "barcode": 3
}
const _BAY_NUMBERS: Array[int] = [3, 7, 9, 12, 24, 41]
# Faded paint, kept LIGHT for the relight: the cold grade crushes anything under ~0.015
# screen value, so "black" markings are charcoal and hazard gaps are left BARE concrete.
const _PAINT_WHITE := Color(0.87, 0.86, 0.81)
const _PAINT_YELLOW := Color(0.92, 0.76, 0.22)
const _PAINT_DARK := Color(0.21, 0.20, 0.19)
# 7-segment masks (bit 0..6 = top, top-right, bottom-right, bottom, bottom-left, top-left,
# middle) for digits 0-9 and for the letters the serial bands use (A C E F H L P U).
const _SEG: Array[int] = [63, 6, 91, 79, 102, 109, 125, 7, 127, 111]
const _SEG_LETTERS: Array[int] = [119, 57, 121, 113, 118, 56, 115, 62]

static var _streak: ImageTexture = null
static var _scorch: ImageTexture = null
static var _puddle: ImageTexture = null
static var _sign_cache: Dictionary = {}
static var _wear: PackedFloat32Array = PackedFloat32Array()


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
	count = _signage(root, poi_defs, count)
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


## 1-3 dark rain-leak streaks down each tower/warehouse/house facade. Decals project
## along local -Y, so each box is pitched 90 deg + yawed to drive into its wall face;
## the streak then runs DOWN the facade (local +Z maps to world -Y).
##
## COUNT: was 2-4. Trimmed by one so the CITY-GRAPHICS tiers below fit inside the SAME
## _BUDGET — a facade gains far more from one painted bay number than from a fourth
## identical leak stain, and the map-wide decal count stays flat (perf unchanged).
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
		var n: int = 1 + ProcHash.h(s) % 3
		for k in range(n):
			var ks: int = s + 40 + k * 9
			# Outward wall normal — courtyard shells have no front (+Z) wall, and their
			# side walls only span the back half (z below the keep-clear square).
			var nrm: Vector3 = _SIDES[ProcHash.h(ks) % (3 if court else 4)]
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
			var dec := _decal(_streak_tex(), Vector3(0.8, 3.0, 2.0))
			dec.transform = Transform3D(_wall_basis(nrm), Vector3(px, py, pz))
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


# ------------------------------------------------------------------- city signage
## CITY GRAPHICS in TWO legibility TIERS, painted on the tower/warehouse/house facades:
##   BIG   (bay numbers / hazard chevrons / warning triangles / arrows) — 1.4-3.0 m across,
##         mounted 1.6-4.4 m up, with a FAR distance fade (75->100 m) because its whole job
##         is to be the thing you read while crossing the map toward a POI.
##   SMALL (serial bands / placards / barcodes) — 0.4-0.7 m, mounted 1.1-2.0 m up, with a
##         SHORT fade (22->30 m): close-up texture only, so it is CHEAPER than the 40->50 m
##         grime gate rather than an addition to it.
## WINDOWS: every wall panel carries its window (or door) opening CENTRED on the panel, so
## staying _PIER_CLEAR away from that centre is exactly what keeps paint off the glass —
## and since the opening is centred on EVERY storey, a clear pier is clear at any height.
static func _signage(root: Node3D, poi_defs: Dictionary, count: int) -> int:
	var keys: Array = poi_defs.keys()
	for i in range(keys.size()):
		var def: Dictionary = poi_defs[keys[i]]
		var theme: String = str(def["theme"])
		if not theme in _STREAK_THEMES:
			continue
		var big_pool: Array = _THEME_BIG.get(theme, [])
		if big_pool.is_empty():
			continue
		var s: int = ProcHash.h(4409 * (i + 1))
		# One face order PER BUILDING, walked forward per marking, so the two big signs
		# start on DIFFERENT walls instead of risking a same-pier overlap.
		var f0: int = ProcHash.h(s + 3)
		for k in range(1 + ProcHash.h(s + 1) % 2):  # 1-2 big markings
			var ks: int = s + 600 + k * 37
			var big_kind: String = str(big_pool[ProcHash.h(ks) % big_pool.size()])
			if _sign_place(root, def, theme, ks, big_kind, f0 + k):
				count += 1
		for k2 in range(2 + ProcHash.h(s + 2) % 2):  # 2-3 small markings
			var ks2: int = s + 900 + k2 * 41
			var small: String = _SMALL_KINDS[ProcHash.h(ks2) % _SMALL_KINDS.size()]
			if _sign_place(root, def, theme, ks2, small, f0 + 2 + k2):
				count += 1
	return count


## Paints ONE sign of `kind` on this building, starting from face `face0` and walking the
## walls until one has pier room (a short wall can be all window/door and no pier), so a
## sign is skipped rather than smeared across glass. Returns true if one was placed.
static func _sign_place(
	root: Node3D, def: Dictionary, theme: String, ks: int, kind: String, face0: int
) -> bool:
	var spec: Array = _SIGN_SPECS[kind]
	var sw: float = float(spec[0])
	var sh: float = float(spec[1])
	var court: bool = bool(def["court"])
	var faces: int = 3 if court else 4
	for t in range(faces):
		var nrm: Vector3 = _SIDES[(face0 + t) % faces]
		# Vertical band, clamped under THIS face's wall top (a courtyard house keeps only
		# its back wall upstairs — higher up its side walls are open air).
		var lo: float = float(spec[2]) + sh * 0.5
		var hi: float = minf(float(spec[3]), _face_top(theme, court, nrm) - 0.7) - sh * 0.5
		if hi < lo:
			continue
		var along: float = _pier_offset(
			_wall_span(def, nrm, court), _panel_center(def, nrm, court), sw * 0.5, ks + t * 7
		)
		if not is_finite(along):
			continue
		var py: float = ProcHash.hrange(ks + 61, lo, hi)
		var big: bool = kind in _BIG_KINDS
		var dec := _decal(_sign_tex(kind, ks), Vector3(sw, _SIGN_DEPTH, sh))
		dec.albedo_mix = 1.0  # painted marking REPLACES the wall albedo (its alpha is the wear)
		dec.distance_fade_begin = _FAR_FADE.x if big else _NEAR_FADE.x
		dec.distance_fade_length = _FAR_FADE.y if big else _NEAR_FADE.y
		if kind in _NEON_KINDS and _NEON_ENERGY > 0.0:
			# Optional night read: a CONSTANT weak emission is washed out by the 2.8 sun
			# by day and reads as faintly self-lit retroreflective paint after dusk — the
			# night driver only walks Groups.NIGHT_LIGHTS OmniLights, so a decal cannot be
			# animated from here without touching world_atmosphere. Unpainted texels are
			# RGB 0, so only the paint glows (decal emission samples RGB, not alpha).
			dec.texture_emission = dec.texture_albedo
			dec.emission_energy = _NEON_ENERGY
		dec.transform = Transform3D(_wall_basis(nrm), _face_point(def, nrm, along, py))
		root.add_child(dec)
		return true
	return false


## The wall top for one face: a COURTYARD house is a 3-sided ground-floor shell whose upper
## storey is the back wall only, so its side walls end at the ground-storey ceiling.
static func _face_top(theme: String, court: bool, nrm: Vector3) -> float:
	if court and theme == "house" and absf(nrm.x) > 0.5:
		return 3.0
	return float(_WALL_TOP.get(theme, 5.0))


## The [lo, hi] LOCAL along-wall offsets a sign may occupy on this face: the footprint minus
## a corner margin (drainpipes hug the corners), and for a courtyard side wall only the back
## span that actually exists (the front half is the keep-clear courtyard mouth).
static func _wall_span(def: Dictionary, nrm: Vector3, court: bool) -> Vector2:
	if absf(nrm.z) > 0.5:
		var w: float = float(def["w"])
		return Vector2(-w * 0.5 + _EDGE_MARGIN, w * 0.5 - _EDGE_MARGIN)
	var d: float = float(def["d"])
	var hi: float = -(ProceduralBuildings.COURT_CLEAR + 0.6) if court else d * 0.5 - _EDGE_MARGIN
	return Vector2(-d * 0.5 + _EDGE_MARGIN, hi)


## LOCAL along-wall offset of this face's opening: ProceduralBuildings.wall() centres the
## window/door on the PANEL, and a courtyard side wall is a short panel centred on the back
## span — so that panel's centre, not the building's, is what a sign must clear.
static func _panel_center(def: Dictionary, nrm: Vector3, court: bool) -> float:
	if not court or absf(nrm.z) > 0.5:
		return 0.0
	var seg: float = float(def["d"]) * 0.5 - ProceduralBuildings.COURT_CLEAR
	return -ProceduralBuildings.COURT_CLEAR - seg * 0.5


## A deterministic along-wall offset that lands the sign wholly on a PIER (one side of the
## opening, hash-picked, falling back to the other). INF when neither pier has room.
static func _pier_offset(span: Vector2, pc: float, half_w: float, ks: int) -> float:
	var clear: float = _PIER_CLEAR + half_w
	for t in range(2):
		var right: bool = (ProcHash.h(ks) + t) % 2 == 0
		var lo: float = pc + clear if right else span.x + half_w
		var hi: float = span.y - half_w if right else pc - clear
		if hi - lo >= 0.05:
			return ProcHash.hrange(ks + 5 + t, lo, hi)
	return INF


## World point on a wall FACE (the decal box is centred ON the surface: _SIGN_DEPTH then
## projects half its depth each way, which is short enough to miss the interior face).
static func _face_point(def: Dictionary, nrm: Vector3, along: float, py: float) -> Vector3:
	var x: float = float(def["x"])
	var z: float = float(def["z"])
	if absf(nrm.z) > 0.5:
		return Vector3(x + along, py, z + nrm.z * float(def["d"]) * 0.5)
	return Vector3(x + nrm.x * float(def["w"]) * 0.5, py, z + along)


## Shared Decal factory: albedo texture + the common distance fade.
static func _decal(tex: Texture2D, size: Vector3) -> Decal:
	var dec := Decal.new()
	dec.texture_albedo = tex
	dec.size = size
	dec.distance_fade_enabled = true
	dec.distance_fade_begin = 40.0
	dec.distance_fade_length = 10.0
	return dec


## Basis that drives a decal INTO a wall face: yaw to the outward normal, then pitch 90 deg
## so the projection axis (local -Y) points into the wall and local +Z runs DOWN the facade
## (i.e. the texture's top row is the top of the marking in the world).
static func _wall_basis(nrm: Vector3) -> Basis:
	return (
		Basis.from_euler(Vector3(0.0, atan2(nrm.x, nrm.z), 0.0))
		* Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
	)


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


# ------------------------------------------------------- generated signage textures
## The painted marking for `kind`, picking one of its baked variants from the placement
## seed. Cached by "kind_variant" — a facade's paint is a shared texture, never a per-node
## bake. NOTE there is no runtime FONT available for drawing into an Image, so every glyph
## in here is GEOMETRY (7-segment rectangles), which also happens to be the right look for
## stencilled industrial markings.
static func _sign_tex(kind: String, ks: int) -> ImageTexture:
	var variant: int = ProcHash.h(ks + 17) % maxi(1, int(_SIGN_VARIANTS.get(kind, 1)))
	var key: String = "%s_%d" % [kind, variant]
	if _sign_cache.has(key):
		return _sign_cache[key]
	var tex: ImageTexture = _bake_sign(kind, variant)
	_sign_cache[key] = tex
	return tex


static func _bake_sign(kind: String, variant: int) -> ImageTexture:
	match kind:
		"number":
			return _number_img(variant)
		"hazard":
			return _hazard_img()
		"arrow":
			return _arrow_img()
		"warn":
			return _warn_img()
		"serial":
			return _serial_img(variant)
		"placard":
			return _placard_img(variant)
	return _barcode_img(variant)


## BIG tier — a stencilled two-digit BAY NUMBER over a painted underline bar. 128² at a
## ~2 m sign is ~1 texel per cm; the digit is 1.3 m tall, which still resolves at 50 m.
static func _number_img(v: int) -> ImageTexture:
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	var num: int = _BAY_NUMBERS[v % _BAY_NUMBERS.size()]
	_glyph(img, Rect2i(14, 14, 44, 78), _SEG[(num / 10) % 10], _PAINT_WHITE, 0.5)
	_glyph(img, Rect2i(70, 14, 44, 78), _SEG[num % 10], _PAINT_WHITE, 0.5)
	_rect(img, Rect2i(12, 104, 104, 9), _PAINT_WHITE, 0.65)
	return _finish(img)


## BIG tier — a HAZARD band of diagonal chevrons. The gaps are left BARE (no paint) so the
## concrete reads through: a black stripe would sink under the cold grade. 128x32 stretched
## to 3.0 x 0.8 m keeps the texel roughly square, so the stripes stay at ~45 deg in world.
static func _hazard_img() -> ImageTexture:
	var w: int = 128
	var h: int = 32
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var lin: Color = _PAINT_YELLOW.srgb_to_linear()
	for y in range(h):
		for x in range(w):
			if (x + y) % 22 < 11:
				_px(img, x, y, lin, 0.5)
	_rect(img, Rect2i(0, 0, w, 3), _PAINT_WHITE, 0.45)
	_rect(img, Rect2i(0, h - 3, w, 3), _PAINT_WHITE, 0.45)
	return _finish(img)


## BIG tier — a painted directional ARROW (shaft + solid head), the floor-marking yellow.
static func _arrow_img() -> ImageTexture:
	var img := Image.create(128, 64, false, Image.FORMAT_RGBA8)
	_rect(img, Rect2i(10, 24, 62, 16), _PAINT_YELLOW, 0.45)
	var lin: Color = _PAINT_YELLOW.srgb_to_linear()
	for x in range(72, 120):
		var half: int = int(float(120 - x) * 0.58)
		for y in range(32 - half, 32 + half):
			_px(img, x, y, lin, 0.45)
	return _finish(img)


## BIG tier — the WARNING triangle: yellow field, charcoal rim and bang. The rim is the
## only dark mass in the whole atlas and it is thin by design (relight: no black slabs).
static func _warn_img() -> ImageTexture:
	var n: int = 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var field: Color = _PAINT_YELLOW.srgb_to_linear()
	var rim: Color = _PAINT_DARK.srgb_to_linear()
	for y in range(12, 113):
		var outer: float = float(y - 12) / 100.0 * 54.0
		var inner: float = (float(y - 27) / 79.0) * 43.0 if y > 27 else -1.0
		for x in range(64 - int(outer), 65 + int(outer)):
			var dx: float = absf(float(x) - 64.0)
			var solid: bool = dx <= inner and y < 106
			_px(img, x, y, field if solid else rim, 0.4)
	_rect(img, Rect2i(59, 46, 10, 34), _PAINT_DARK, 0.4)
	_rect(img, Rect2i(59, 86, 10, 10), _PAINT_DARK, 0.4)
	return _finish(img)


## SMALL tier — a stencilled SERIAL band ("AEC-4718"): 3 letters, a dash, 4 digits.
static func _serial_img(v: int) -> ImageTexture:
	var img := Image.create(128, 32, false, Image.FORMAT_RGBA8)
	var s: int = 6101 + v * 137
	var x: int = 5
	for i in range(8):
		if i == 3:
			_rect(img, Rect2i(x + 1, 15, 8, 3), _PAINT_WHITE, 0.5)
			x += 12
			continue
		var mask: int = (
			_SEG_LETTERS[ProcHash.h(s + i) % _SEG_LETTERS.size()]
			if i < 3
			else _SEG[ProcHash.h(s + i) % 10]
		)
		_glyph(img, Rect2i(x, 6, 11, 20), mask, _PAINT_WHITE, 0.5)
		x += 15
	return _finish(img)


## SMALL tier — a bolted PLACARD: pale plate, coloured edge tab, three lines of "text".
static func _placard_img(v: int) -> ImageTexture:
	var img := Image.create(96, 64, false, Image.FORMAT_RGBA8)
	var s: int = 7307 + v * 211
	_rect(img, Rect2i(2, 2, 92, 60), _PAINT_WHITE, 0.28)
	_rect(img, Rect2i(2, 2, 10, 60), _PAINT_YELLOW, 0.32)
	for r in range(3):
		_rect(img, Rect2i(18, 12 + r * 16, 30 + ProcHash.h(s + r) % 40, 7), _PAINT_DARK, 0.35)
	return _finish(img)


## SMALL tier — a stuck-on BARCODE label: hash-width bars over a pale sticker.
static func _barcode_img(v: int) -> ImageTexture:
	var img := Image.create(96, 64, false, Image.FORMAT_RGBA8)
	var s: int = 8419 + v * 173
	_rect(img, Rect2i(2, 2, 92, 60), _PAINT_WHITE, 0.25)
	var x: int = 8
	var i: int = 0
	while x < 86:
		var bw: int = 1 + ProcHash.h(s + i) % 4
		if ProcHash.h(s + i + 500) % 3 != 0:
			_rect(img, Rect2i(x, 8, bw, 38), _PAINT_DARK, 0.3)
		x += bw + 1 + ProcHash.h(s + i + 900) % 3
		i += 1
	for k in range(4):
		_rect(img, Rect2i(14 + k * 18, 50, 8, 6), _PAINT_DARK, 0.35)
	return _finish(img)


## Wraps a finished signage bake. THE FLIP IS LOAD-BEARING: a decal's texture U axis runs
## along local +X, which _wall_basis maps to the viewer's LEFT — so a glyph baked normally
## would appear MIRRORED on the facade. (Vertically it is already right: local +Z is world
## down, matching image rows top-to-bottom, which is why the leak streaks fade downward.)
static func _finish(img: Image) -> ImageTexture:
	img.flip_x()
	return ImageTexture.create_from_image(img)


## One 7-segment glyph inside `box`, drawn as rectangles (no runtime font exists for an
## Image bake). `mask` bits: top, top-right, bottom-right, bottom, bottom-left, top-left, mid.
static func _glyph(img: Image, box: Rect2i, mask: int, col: Color, wear: float) -> void:
	var x: int = box.position.x
	var y: int = box.position.y
	var w: int = box.size.x
	var h: int = box.size.y
	var t: int = maxi(2, int(round(float(w) * 0.22)))
	var hh: int = h / 2
	if mask & 1:
		_rect(img, Rect2i(x + t, y, w - 2 * t, t), col, wear)
	if mask & 2:
		_rect(img, Rect2i(x + w - t, y + t, t, hh - t), col, wear)
	if mask & 4:
		_rect(img, Rect2i(x + w - t, y + hh, t, hh - t), col, wear)
	if mask & 8:
		_rect(img, Rect2i(x + t, y + h - t, w - 2 * t, t), col, wear)
	if mask & 16:
		_rect(img, Rect2i(x, y + hh, t, hh - t), col, wear)
	if mask & 32:
		_rect(img, Rect2i(x, y + t, t, hh - t), col, wear)
	if mask & 64:
		_rect(img, Rect2i(x + t, y + hh - t / 2, w - 2 * t, t), col, wear)


## Fills `r` with sRGB `col` (converted ONCE — the runtime-ImageTexture sRGB trap), chipped
## by the shared worn-paint mask. `wear` is how much of the coat the weather took.
static func _rect(img: Image, r: Rect2i, col: Color, wear: float) -> void:
	var lin: Color = col.srgb_to_linear()
	for y in range(maxi(r.position.y, 0), mini(r.end.y, img.get_height())):
		for x in range(maxi(r.position.x, 0), mini(r.end.x, img.get_width())):
			_px(img, x, y, lin, wear)


## Writes one paint texel (colour already LINEAR). Alpha carries the paint coverage, so a
## worn hole simply lets the wall's own material through — no dark smear.
static func _px(img: Image, x: int, y: int, lin: Color, wear: float) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	var m: float = _wear_mask()[(y & 63) * 64 + (x & 63)]
	img.set_pixel(x, y, Color(lin.r, lin.g, lin.b, clampf(1.0 - (1.0 - m) * wear, 0.0, 1.0)))


## Shared 64² worn-paint mask in [0,1], built once: every signage bake samples this table
## instead of hashing per texel (4 ProcHash calls per pixel across 13 bakes is seconds).
static func _wear_mask() -> PackedFloat32Array:
	if _wear.size() == 4096:
		return _wear
	_wear.resize(4096)
	for y in range(64):
		for x in range(64):
			var n: float = _vnoise(float(x) / 9.0, float(y) / 9.0, 991)
			_wear[y * 64 + x] = clampf((n - 0.2) * 2.6, 0.0, 1.0)
	return _wear


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
