extends RefCounted
class_name ProcMaterials
## Shared procedural-detail material toolkit (zero external assets). Builds
## StandardMaterial3D with noise-driven weathering (grime/streaks via a cached
## FastNoiseLite -> NoiseTexture2D, triplanar so no UVs are needed) so buildings,
## ground and enemies read as worn surfaces instead of flat solid colours.
##
## StandardMaterial3D ONLY (never ShaderMaterial) so the enemy hit-flash path keeps
## working. Textures are cached so spawning many pieces doesn't rebuild noise.
##
## DETAIL STACK (Godot 4 has NO hardware tessellation — these are the equivalents,
## all on StandardMaterial3D): fine grime detail layer + NORMAL maps (fine relief),
## plus a bespoke CORRUGATED metal builder (real baked normal/albedo ribs) for
## containers. NB: Godot's parallax heightmap (the POM "тесселляция" stand-in) is
## hard-disabled on triplanar materials, so apparent depth here is carried by the
## normal maps (every building surface is triplanar — no UVs on the primitive meshes).
##
## RUNTIME-IMAGETEXTURE sRGB TRAP: ImageTextures built at runtime are read by the GPU
## as LINEAR (no sRGB format variant), so ALBEDO image colours are baked through
## `Color.srgb_to_linear()` (matching the terrain code). NORMAL/height images stay raw.

## How strongly the fine-grime detail-albedo speckle blends over the tinted base, in the
## grimiest lows (clean areas stay at 0). See `grime_fine_texture` — this used to be an
## effective 1.0, which erased every building's albedo.
const FINE_DETAIL_ALPHA := 0.26

## D3.1 REAL FACADE PBR. `assets/textures/facade/<family>_albedo.jpg` is NOT a colour map:
## it is a bounded modulation map with a mean of 1.0, baked by
## `tools/art/fetch_facade_textures.py` from a CC0 ambientCG scan and encoded at half scale
## so a value can exceed 1.0 (mortar joints, bare metal) inside an 8-bit file. Multiplying it
## by `tint * ALBEDO_SCALE` therefore leaves the AVERAGE surface colour exactly as authored —
## every `mat_*` tint stays balanced against the cold grade and the D1 relight — while the
## texture contributes what noise never could: brick courses, plank seams, concrete pours.
## The normal map is the other half, and the bigger half: real grazing-angle relief.
##
## Missing files are NOT an error. `apply_pbr` returns the material untouched, which keeps the
## project's "runs with zero art assets" rule (AssetRegistry's fallback chain) intact.
const FACADE_DIR := "res://assets/textures/facade/"
const ALBEDO_SCALE := 2.0

## Isotropic world-triplanar scale per family, in tiles per metre — chosen so the features
## land at real-world size (brick courses ~18 cm, planks ~28 cm, steel panels ~1 m). This
## OVERRIDES the caller's `uv1_scale`, including the anisotropic squash that `streaked()`
## uses: a rain-streak stretch applied to a real brick scan smears the courses into ribbons,
## and real masonry structure is worth more than noise streaks (the vertical read survives
## through the ground-grime skirt and the scans' own grain).
const FACADE_TILE := {
	"concrete": 0.22,
	"plaster": 0.22,
	"metal": 0.50,
	"rust": 0.35,
	"stone": 0.25,
	"brick": 0.62,
	"timber": 0.45,
}

static var _tex_cache: Dictionary = {}
static var _pbr_cache: Dictionary = {}


# ---------------------------------------------------------------- noise masks
## A grayscale weathering mask: mostly clean (white) with darker grime in the lows.
## `grime` is the dark floor (lower = heavier grime). Cached by (sid, grime).
## 512² + 5 octaves for crisper, more detailed weathering than the old 256²/4.
static func grime_texture(sid: int, grime: float) -> NoiseTexture2D:
	var key := "grime_%d_%.2f" % [sid, grime]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = sid
	n.frequency = 0.012 + float(absi(sid) % 5) * 0.004
	n.fractal_octaves = 5
	n.fractal_gain = 0.5
	var nt := NoiseTexture2D.new()
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	nt.noise = n
	var g := Gradient.new()
	g.set_color(0, Color(grime, grime, grime))
	g.set_color(1, Color(1.0, 1.0, 1.0))
	# Warm dirt mid-tone (texture-quality pass): a third stop keeps large surfaces from
	# reading as a flat two-tone mask — subtle temperature variation under the cold grade.
	g.add_point(0.55, Color(grime * 1.18, grime * 1.06, grime * 0.92))
	nt.color_ramp = g
	_tex_cache[key] = nt
	return nt


## FINE grime: ~8-10× the base frequency of `grime` → 1-3 m features (the base mask is
## 30-80 m blobs). Used as a low-blend detail-albedo speckle so surfaces read sharp up
## close. Cached by sid. Higher contrast ramp than the broad mask so the speckle pops.
##
## ALPHA IS LOAD-BEARING (D1 relight fix): a detail-albedo layer in BLEND_MODE_MIX blends
## by the DETAIL TEXTURE'S ALPHA. This ramp used to be fully opaque (Color defaults to a=1),
## so the speckle REPLACED the albedo outright — `albedo_color` and the broad grime mask were
## both thrown away and every building rendered as this grey noise regardless of its authored
## palette (concrete / plaster / sandstone / snow / rust all looked like the same grey stone).
## That is the exact defect already documented and removed on the machine side
## (`proc_plating.gd` "NO detail-albedo layer here"). Here the layer is KEPT — it is what makes
## surfaces read crisp up close — but the alpha now ramps so it only tints the grimy lows and
## leaves clean areas untouched, which is what "low blend" meant all along.
static func grime_fine_texture(sid: int, grime: float) -> NoiseTexture2D:
	var key := "grimefine_%d_%.2f" % [sid, grime]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = sid * 3 + 11
	n.frequency = (0.012 + float(absi(sid) % 5) * 0.004) * 9.0
	n.fractal_octaves = 4
	n.fractal_gain = 0.55
	var nt := NoiseTexture2D.new()
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	nt.noise = n
	var g := Gradient.new()
	g.set_color(0, Color(grime, grime, grime, FINE_DETAIL_ALPHA))
	g.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	nt.color_ramp = g
	_tex_cache[key] = nt
	return nt


## A tangent-space NORMAL map from FastNoiseLite (NoiseTexture2D's built-in normal-map
## mode). `freq` should be ~10× the albedo grime so the relief is FINE; `strength` is the
## bump depth. Cached by (sid, strength, freq). 512² for crisp relief.
static func noise_normal_texture(sid: int, strength: float, freq: float) -> NoiseTexture2D:
	var key := "nrm_%d_%.3f_%.4f" % [sid, strength, freq]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = sid * 5 + 7
	n.frequency = freq
	n.fractal_octaves = 4
	n.fractal_gain = 0.5
	var nt := NoiseTexture2D.new()
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	nt.as_normal_map = true
	nt.bump_strength = strength
	nt.noise = n
	_tex_cache[key] = nt
	return nt


## BROAD grime carrying an ALPHA ramp, for the detail slot. `weathered` puts the broad mask on
## `albedo_texture`; once a real scan takes that slot the weathering has to move to the detail
## layer, which blends by ALPHA (the trap documented on `grime_fine_texture`) — so the same
## noise is re-ramped: opaque grime colour in the lows, fully transparent where it is clean.
static func grime_detail_texture(sid: int, grime: float) -> NoiseTexture2D:
	var key := "grimedet_%d_%.2f" % [sid, grime]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = sid
	n.frequency = 0.012 + float(absi(sid) % 5) * 0.004
	n.fractal_octaves = 5
	n.fractal_gain = 0.5
	var nt := NoiseTexture2D.new()
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	nt.noise = n
	var g := Gradient.new()
	g.set_color(0, Color(grime, grime * 0.96, grime * 0.9, 0.85))
	g.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	nt.color_ramp = g
	_tex_cache[key] = nt
	return nt


## The [albedo, normal] pair for a facade family, or an empty array when the files are absent.
## Cached per family — seven families are shared by every building on the map.
static func pbr_surface(family: String) -> Array:
	if _pbr_cache.has(family):
		return _pbr_cache[family]
	var out: Array = []
	var albedo_path: String = FACADE_DIR + family + "_albedo.jpg"
	var normal_path: String = FACADE_DIR + family + "_normal.jpg"
	if ResourceLoader.exists(albedo_path) and ResourceLoader.exists(normal_path):
		var albedo: Texture2D = load(albedo_path)
		var normal: Texture2D = load(normal_path)
		if albedo != null and normal != null:
			out = [albedo, normal]
	_pbr_cache[family] = out
	return out


## Re-surface a `weathered`/`streaked` material with a real scanned facade family. Mutates and
## returns the SAME material (callers wrap their ProcMaterials result), so the material COUNT
## per building — and therefore the ChunkMeshMerger grouping and its ChunkMesh_N node names —
## is unchanged. World-triplanar throughout, which is what makes it safe on merged chunks.
static func apply_pbr(m: StandardMaterial3D, family: String) -> StandardMaterial3D:
	var pair: Array = pbr_surface(family)
	if pair.is_empty():
		return m
	var sid: int = int(m.get_meta("proc_sid", 0))
	var grime: float = float(m.get_meta("proc_grime", 0.5))
	var c: Color = m.albedo_color
	m.albedo_color = Color(c.r * ALBEDO_SCALE, c.g * ALBEDO_SCALE, c.b * ALBEDO_SCALE, c.a)
	m.albedo_texture = pair[0]
	m.normal_enabled = true
	m.normal_texture = pair[1]
	var tile: float = float(FACADE_TILE.get(family, 0.25))
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(tile, tile, tile)
	# Weathering moves off the albedo slot onto the alpha-blended detail layer.
	m.detail_enabled = true
	m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.detail_albedo = grime_detail_texture(sid, grime)
	m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_1
	return m


# ---------------------------------------------------------------- materials
## Weathered surface: base albedo modulated by a triplanar grime mask, with optional
## metallic/roughness. `world` triplanar keeps detail consistent across adjacent
## building pieces; pass world=false for small/moving objects (enemies) so it doesn't
## swim. `scale` is the triplanar UV scale (use a low y for vertical streaks).
##
## Now carries a FINE NORMAL map (relief at ~10× the albedo grime frequency) + a low-blend
## fine grime detail-albedo speckle so the surface reads crisp up close.
##
## "тесселляция"/POM HONEST NOTE: Godot 4 has no hardware tessellation, and its parallax
## heightmap (the POM stand-in) is HARD-DISABLED on triplanar materials (the renderer logs
## "Height mapping is not supported on triplanar materials" and ignores it). Since every
## building surface needs triplanar (no UVs on the procedural primitive meshes), real depth
## comes from the NORMAL map instead — which on a strong `normal_scale` gives convincing
## grazing-angle relief without the heightmap. The `relief` arg just biases normal_scale up
## for the surfaces that want more apparent depth.
static func weathered(
	base: Color,
	metallic := 0.0,
	roughness := 0.85,
	grime := 0.55,
	sid := 0,
	scale := Vector3(0.18, 0.18, 0.18),
	world := true,
	normal_scale := 0.6,
	relief := false
) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = base
	m.metallic = metallic
	m.roughness = roughness
	m.albedo_texture = grime_texture(sid, grime)
	m.uv1_triplanar = true
	m.uv1_world_triplanar = world
	m.uv1_scale = scale
	# Fine relief: normal-map frequency ~10× the broad albedo grime so the bumps are small.
	var grime_freq: float = 0.012 + float(absi(sid * 7) % 5) * 0.004
	m.normal_enabled = true
	m.normal_texture = noise_normal_texture(sid, 1.0, grime_freq * 10.0)
	m.normal_scale = normal_scale * (1.4 if relief else 1.0)
	# Fine grime speckle as a detail-albedo MIX at low blend so it doesn't muddy the base.
	m.detail_enabled = true
	m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.detail_albedo = grime_fine_texture(sid, clampf(grime + 0.25, 0.0, 1.0))
	m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_1
	# D1.3: ROUGHNESS VARIATION. A single roughness value over a whole facade is the reason
	# large surfaces read as plastic no matter how good the albedo is — real materials are
	# polished where they are touched and rained on, matte where the grime sits. The same
	# grime mask drives it, so gloss lands exactly where the surface LOOKS clean, and it is
	# sampled through the very same triplanar UV, which keeps it safe for merged chunk
	# rendering (no size-dependent tiling).
	m.roughness_texture = grime_texture(sid, grime)
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
	# The texture MULTIPLIES the scalar, so the scalar becomes the ROUGH end of the range and
	# clean areas glide toward gloss. Lift it a little so the average stays where it was.
	m.roughness = clampf(roughness * 1.18, 0.0, 1.0)
	# Carried so `apply_pbr` can rebuild the weathering on the detail layer without every
	# caller having to repeat the two numbers it already passed here.
	m.set_meta("proc_sid", sid)
	m.set_meta("proc_grime", grime)
	return m


## Rain-streaked vertical weathering (stains running down walls under windows etc.):
## a tall, narrow triplanar scale so the noise stretches into vertical streaks. `relief`
## passes through to bias the normal depth up.
static func streaked(
	base: Color,
	metallic := 0.0,
	roughness := 0.88,
	grime := 0.45,
	sid := 0,
	normal_scale := 0.6,
	relief := false
) -> StandardMaterial3D:
	return weathered(
		base, metallic, roughness, grime, sid, Vector3(0.3, 0.05, 0.3), true, normal_scale, relief
	)


## CORRUGATED shipping-container metal: a baked tangent-space NORMAL map of vertical ribs
## (sin stripes, ~24 ribs across the 512 tile, faint panel seams every ~96 px) + a baked
## ALBEDO image (base colour, darker rib valleys, rust streaks running DOWN from hash-seeded
## rib tops with vertical falloff, edge wear). Triplanar-scaled so ribs read VERTICAL and
## ~8 cm apart on real container walls. Albedo baked through srgb_to_linear (runtime
## ImageTexture trap); the normal map stays raw. Cached by (base, sid).
static func corrugated(base: Color, sid: int) -> StandardMaterial3D:
	var key := "corr_%.2f_%.2f_%.2f_%d" % [base.r, base.g, base.b, sid]
	var m := StandardMaterial3D.new()
	m.metallic = 0.25
	m.roughness = 0.65
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	# Triplanar scale tuned so the 512 tile maps to ~2 m of wall → 24 ribs over 2 m ≈ 8 cm
	# rib pitch. Vertical (y) kept matched so streaks run cleanly down.
	m.uv1_scale = Vector3(0.5, 0.5, 0.5)
	if _tex_cache.has(key):
		var pair: Array = _tex_cache[key]
		m.albedo_texture = pair[0]
		m.normal_enabled = true
		m.normal_texture = pair[1]
		m.normal_scale = 1.0
		return m
	var size := 512
	var ribs := 24.0
	var seam_px := 96
	var alb := Image.create(size, size, false, Image.FORMAT_RGB8)
	var nrm := Image.create(size, size, false, Image.FORMAT_RGB8)
	# Pre-roll per-rib rust intensity from the hash so some rib tops streak heavily, others not.
	var rust_col := Color(0.32, 0.13, 0.07)
	for x in range(size):
		var u: float = float(x) / float(size)
		# Vertical ribs: phase across X. sin gives the rib cross-section.
		var phase: float = u * ribs * TAU
		var rib: float = sin(phase)  # -1 (valley) .. 1 (crest)
		# Slope of the rib (cos) drives the tangent-space normal X tilt.
		var slope: float = cos(phase)
		var rib_idx: int = int(floor(u * ribs))
		var rust_amt: float = float((rib_idx * 2654435761) & 0xff) / 255.0
		rust_amt = clampf((rust_amt - 0.55) * 2.2, 0.0, 1.0)  # only some ribs rust
		# Faint horizontal panel seam every ~seam_px (a slight darken + normal notch).
		for y in range(size):
			var v: float = float(y) / float(size)
			# --- albedo ---
			# Wider rib shading range so the corrugation READS even on the shaded side
			# under the cold grade (0.72..1.0 was near-flat once the geometric decor ribs
			# were removed in Destruction 2.3) + a per-rib brightness jitter so long
			# container walls don't band uniformly.
			var shade: float = 0.52 + 0.55 * (rib * 0.5 + 0.5)  # valleys clearly darker
			shade += (float((rib_idx * 40503) & 0xff) / 255.0 - 0.5) * 0.10
			var col: Color = base * shade
			# Rust streak running DOWN from this rib's top with vertical falloff.
			if rust_amt > 0.0:
				var streak: float = rust_amt * clampf(1.0 - v * 1.1, 0.0, 1.0)
				# only on/near a crest so it follows the raised rib
				streak *= clampf(rib, 0.0, 1.0)
				col = col.lerp(rust_col, streak * 0.7)
			# Edge wear: lighten extreme crests (paint rubbed to bare metal).
			if rib > 0.92:
				col = col.lerp(Color(0.55, 0.56, 0.58), (rib - 0.92) / 0.08 * 0.4)
			# Panel seam darken.
			var seam_d: int = y % seam_px
			if seam_d < 2 or seam_d > seam_px - 2:
				col = col * 0.6
			alb.set_pixel(x, y, col.srgb_to_linear())
			# --- normal (tangent space: R=x, G=y, B=z, encoded 0..1) ---
			var nx: float = -slope * 0.9
			var ny: float = 0.0
			# Seam adds a small horizontal crease in the normal's Y.
			if seam_d < 2:
				ny = -0.5
			elif seam_d > seam_px - 2:
				ny = 0.5
			var nv := Vector3(nx, ny, 1.0).normalized()
			nrm.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5))
	alb.generate_mipmaps()
	nrm.generate_mipmaps()
	var alb_tex := ImageTexture.create_from_image(alb)
	var nrm_tex := ImageTexture.create_from_image(nrm)
	_tex_cache[key] = [alb_tex, nrm_tex]
	m.albedo_texture = alb_tex
	m.normal_enabled = true
	m.normal_texture = nrm_tex
	m.normal_scale = 1.0
	return m


## Plain emissive material (for glowing cores/beacons). Energy is animated by the
## caller at runtime (enemy core pulse / beacon).
static func emissive(color: Color, energy := 3.0, albedo := Color.BLACK) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo if albedo != Color.BLACK else color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.roughness = 0.4
	return m


static func clear_cache() -> void:
	_tex_cache.clear()
	# NOT _pbr_cache: those are loaded resources shared by every building on the map, and
	# dropping them on an arena rebuild would re-decode 14 JPEGs for no benefit.
