class_name ProcPlating
extends RefCounted
## The v2 "hull plating" material family for the model-quality overhaul — a
## generalisation of the PROVEN ProcMaterials.corrugated container bake: parametric
## panel-line albedo+normal Image bakes (panel seams with bevelled chamfers, per-panel
## value variation, rivet rows, edge wear toward bare metal, scratches, oil streaks,
## vent slats) in four archetypes × three seed variants, cached. Everything stays
## StandardMaterial3D (the enemy hit-flash contract).
##
## KEY DESIGN — NEUTRAL BAKE, TINT AT DRAW: unlike corrugated() (bakes the base colour
## in), the plate albedo is baked as a GRAYSCALE multiplier field around _MID and
## multiplied by `albedo_color` at draw — one texture pair serves every enemy hue and
## all 14 player paints, so the cache stays at 4 archetypes × 3 seeds = 12 pairs.
## Edge wear bakes toward light gray = worn paint (stylized-correct).
##
## D1.3 — THREE MAPS, NOT TWO. Each variant now bakes albedo + normal + an "ORM" pack
## (R = cavity AMBIENT OCCLUSION, G = a ROUGHNESS multiplier; B reserved — metallic stays
## the archetype's binary constant, see `arch_finish`). Both new channels ride the SAME
## uv1 triplanar projection as the albedo, which is the only way baked occlusion can land
## on the seams and vent slots that same bake drew (the full uv1-vs-uv2 argument is at the
## wiring site in `plated`).
##
## Textures are CACHED; material INSTANCES are always fresh per call — the hit-flash
## collector duplicates and mutates per-enemy materials, so sharing instances across
## models would flash every enemy at once (the invariant ProcMaterials also keeps).
## Adding maps does not touch that contract: the flash duplicates the whole
## StandardMaterial3D and only drives `emission`, and the duplicate keeps every texture
## reference by pointer.
##
## sRGB TRAP (same as ProcMaterials): runtime ImageTextures sample as LINEAR — albedo
## grays are baked through srgb_to_linear(); normal AND the ORM pack stay raw (they are
## data, and linear is exactly what the shader wants to read).
##
## REUSE: `height_to_normal` is the codebase's single height→normal Sobel, exposed as a
## pure Image→Image function so no other bake has to grow a private copy of it.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

enum Arch { ARMOR_PLATE, MECH_HULL, RUBBER, LACQUER }

# Neutral mid-gray the bake centres on; albedo_color is compensated by 1/_MID so the
# midtone renders exactly the requested base colour (wear reads brighter, seams darker).
const _MID: float = 0.72
## How hard the mask's own gradient pushes the normal (see _sobel_into_normal). Kept modest:
## the Sobel of a 256² mask is a STEEP operator, and at higher values every stain edge turns
## into a hard ridge instead of a shallow dent.
const _RELIEF_STRENGTH: float = 0.55

# --- D1.3 cavity AO ------------------------------------------------------------------
## Occlusion the bake writes into a feature (1.0 = open surface, 0.0 = fully enclosed).
## Deliberately DEEP AT THE FEATURE and shallow everywhere else: AO multiplies the ambient
## term, and the whole point of the D2 palette pass was to stop machines reading as dark
## silhouettes — so depth is bought at the seam LINE and inside the vent slot, not by
## washing a broad shadow across every bevel.
##
## MEASURED over all eight baked variants (not estimated — the channel was ported and
## summed): the finished AO channel means 0.934-0.965, with 23-40% of pixels carrying any
## occlusion at all and the darkest reaching 0.42. So an average machine pixel gives up
## ~5% of its AMBIENT (nothing of its direct light, see `ao_light_affect` in `_apply_orm`)
## while a vent slot gives up more than half of its — which is the whole trade: the plate
## keeps the brightness D2 bought it, and the holes in it finally read as holes.
const _AO_SEAM: float = 0.50  # the 2 px seam groove itself
const _AO_BEVEL: float = 0.78  # deepest point of the chamfer ramp beside a seam
const _AO_RIVET: float = 0.72  # the rivet's contact shadow ring
const _AO_VENT: float = 0.42  # inside a vent slat slot — the deepest cavity on the plate
const _AO_WEAVE: float = 0.90  # rubber weave valleys
const _AO_FLOOR: float = 0.30  # hard floor so no channel combination reaches black

# --- D1.3 roughness variation --------------------------------------------------------
## Lower bound on the roughness MULTIPLIER before normalisation (see _encode_orm). A
## scratch crossing an already-worn panel edge multiplies two polish factors together;
## without a floor those stack into a mirror.
const _ROUGH_FLOOR: float = 0.50

static var _tex_cache: Dictionary = {}


# ---------------------------------------------------------------- public recipes
## Core factory: fresh StandardMaterial3D carrying the cached (arch, sid) plate bake,
## tinted by `base`. Triplanar object-local by default (matches the enemy convention —
## world-space would swim on movers).
static func plated(
	base: Color,
	arch: int,
	sid: int,
	metallic: float = -1.0,
	roughness: float = -1.0,
	scale: Vector3 = Vector3(0.55, 0.55, 0.55),
	world: bool = false,
	normal_scale: float = 1.0
) -> StandardMaterial3D:
	var pair: Array = _bake_cached(arch, absi(sid) % 3)
	var m := StandardMaterial3D.new()
	# pair[2] is the finished mask's measured MEAN (see _bake) — compensating by it is what
	# makes `base` the plate's true average albedo instead of an over-optimistic target.
	var comp: float = 1.0 / float(pair[2])
	var finish: Vector2 = arch_finish(arch)
	m.albedo_color = Color(base.r * comp, base.g * comp, base.b * comp, 1.0)
	m.metallic = finish.x if metallic < 0.0 else metallic
	m.albedo_texture = pair[0]
	m.uv1_triplanar = true
	m.uv1_world_triplanar = world
	m.uv1_scale = scale
	m.normal_enabled = true
	m.normal_texture = pair[1]
	m.normal_scale = normal_scale
	# NO detail-albedo layer here: BLEND_MODE_MIX keys off the detail texture's alpha
	# and the alpha-less gray NoiseTexture2D replaces the tinted albedo with near-white
	# (found in render QA — the plate bake already carries fine variation anyway).
	_apply_orm(m, pair, finish.y if roughness < 0.0 else roughness)
	if arch == Arch.LACQUER:
		m.clearcoat_enabled = true
		m.clearcoat = 0.6
		m.clearcoat_roughness = 0.25
	return m


## Wire the baked ORM pack (pair[3], mean roughness in pair[4]) onto a plate material and
## set the roughness scalar so `rough_req` stays the plate's AVERAGE roughness.
##
## WHICH CHANNEL IS SAFE — the uv2 question, answered: AO stays on UV1 (`ao_on_uv2 = false`,
## i.e. sampled through the very same triplanar projection as albedo and normal). Two
## independent reasons, either one decisive:
##   * REGISTRATION. The occlusion only means anything if it lands EXACTLY on the seams,
##     rivet rings and vent slots this same bake drew. UV2 is a second, independently scaled
##     mapping — offset it by a texel and every shadow slides off its own geometry.
##   * UV2 IS ALREADY SPOKEN FOR, and not by machines: `ProceduralBuildings._ground_grime`
##     owns the uv2 slot (AO on uv2 + uv2 world-triplanar with an X/Z scale of zero) for the
##     world-height grime skirt. Worse, machine parts are Godot PrimitiveMeshes built with
##     `add_uv2` at its default false, so they carry no UV2 ATTRIBUTE at all: anything read
##     through a non-triplanar uv2 collapses onto texel (0,0). Reaching for uv2 here would
##     mean paying for a second triplanar projection to reproduce the mapping we already have.
## `ao_light_affect = 0.0` (the default, set explicitly because it is load-bearing) keeps this
## an AMBIENT-ONLY term: cavities gain depth in shade without re-darkening the lit faces the
## D2 palette pass just spent its budget brightening.
##
## ROUGHNESS: Godot MULTIPLIES this map into the scalar, so a map can only ever make a
## surface GLOSSIER. The bake therefore normalises its matte extreme to 1.0 and the scalar is
## lifted by 1/mean — the same discipline the albedo compensation uses, and for the same
## reason: the number a caller passes has to mean what it says. Wear, rivet crowns and
## scratches then sit below it; grimy seams, vent slots and wet oil streaks above it.
##
## MEASURED spans (mean is the requested value by construction; these are the extremes a
## pixel can actually reach): ARMOR_PLATE 0.52 → 0.26..0.64, MECH_HULL 0.46 → 0.23..0.59,
## LACQUER 0.35 → 0.26..0.38, RUBBER 0.90 → 0.89..0.90. Wide swings are safe here for a
## reason worth writing down: these plates are DIELECTRIC (metallic ~0.08, see
## `arch_finish`), so even the glossiest scratch reflects ~4% and reads as sheen — it is
## `steel`, at metallic 0.85, where a gloss swing would actually flare, and that one is
## deliberately kept to a gentle noise ramp.
## CLAMP NOTE: a request above ~0.93 cannot be lifted any further (1.0 is the ceiling) and
## lands on the map's mean instead — which is why the matte archetypes bake a deliberately
## narrow spread (`_arch_rough_spread`); RUBBER's 0.9 needs a scalar of 0.903, comfortably
## inside the range.
static func _apply_orm(m: StandardMaterial3D, pair: Array, rough_req: float) -> void:
	var orm: Texture2D = pair[3]
	m.ao_enabled = true
	m.ao_texture = orm
	m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.ao_on_uv2 = false
	m.ao_light_affect = 0.0
	m.roughness_texture = orm
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	m.roughness = clampf(rough_req / float(pair[4]), 0.0, 1.0)


## (metallic, roughness) that an ARCHETYPE implies — the single source for plate finish.
##
## D2 — METALLIC IS A BINARY, AND THIS IS WHY MACHINES READ DARK.
## These plates are PAINTED, and paint is a dielectric: metallic belongs at ~0, with 1.0
## reserved for bare metal (see `steel`). At the old 0.45/0.6 the shader threw away most of
## the diffuse response and asked the environment for a reflection instead — so the hull
## colour barely mattered, and in any view without a bright surround (the isolated hero
## render, a shaded side, an overcast biome) the plate collapsed to dark grey.
##
## The reason this lived in the WRAPPERS before and did nothing: `ProcEnemyKits.kit()` calls
## `plated(base, arch, sid)` directly, so every enemy silently took the function's DEFAULT
## 0.45 metallic and the archetype only ever selected which texture got baked. Finish now
## comes from the archetype itself, so "ARMOR_PLATE" means a look and not just a noise seed.
static func arch_finish(arch: int) -> Vector2:
	match arch:
		Arch.MECH_HULL:
			return Vector2(0.12, 0.46)  # painted industrial hull, slightly glossier
		Arch.RUBBER:
			return Vector2(0.03, 0.9)  # cable/joint boot: matte, no metal at all
		Arch.LACQUER:
			return Vector2(0.04, 0.35)  # coated dielectric — gloss is the clearcoat
		_:
			return Vector2(0.08, 0.52)  # ARMOR_PLATE: painted armour


## Painted armour plates (panel seams + rivets + worn edges).
## These plates are PAINTED, and paint is a dielectric: metallic belongs at ~0, with 1.0
## reserved for bare metal (see `steel`). At the old 0.45/0.6 the shader threw away most of
## the diffuse response and asked the environment for a reflection instead — so the hull
## colour barely mattered, and in any view without a bright surround (the isolated hero
## render, a shaded side, an overcast biome) the plate collapsed to dark grey. Dropping to a
## paint-like metallic is what actually lets an albedo change be visible at all; the plate
## keeps its sheen through roughness and the baked normal, not through fake metalness.
static func armor_plate(
	base: Color, sid: int, scale: Vector3 = Vector3(0.55, 0.55, 0.55)
) -> StandardMaterial3D:
	return plated(base, Arch.ARMOR_PLATE, sid, -1.0, -1.0, scale)


## Industrial mech hull (panels + vents + oil streaks, slightly glossier paint than armour).
static func mech_hull(
	base: Color, sid: int, scale: Vector3 = Vector3(0.55, 0.55, 0.55)
) -> StandardMaterial3D:
	return plated(base, Arch.MECH_HULL, sid, -1.0, -1.0, scale)


## Rubber/cable joints and under-suits (woven micro-normal, near-zero metallic).
static func rubber(base: Color, sid: int) -> StandardMaterial3D:
	return plated(base, Arch.RUBBER, sid, -1.0, -1.0, Vector3(0.8, 0.8, 0.8))


## Lacquered panels (oni/urushi look): wide soft panels + clearcoat.
static func lacquer(base: Color, sid: int) -> StandardMaterial3D:
	# Lacquer is a coated dielectric — the gloss is the CLEARCOAT, not metalness (see the
	# note on armor_plate); 0.25 was just dimming the colour it exists to show off.
	return plated(base, Arch.LACQUER, sid)


## Bare worn steel (no plate bake — fine noise relief only): barrels, claws, blades.
##
## D1.3: this role is the one kit material with no plate bake behind it, and a single
## roughness value across a barrel or a blade is exactly what makes bare metal read as grey
## plastic — real steel is burnished where it is handled and dulled where it has pitted. The
## same noise that drives its relief drives the gloss (so the two agree), sampled through the
## SAME uv1 the normal map uses, with the scalar lifted by the empirical 1.18 that
## `ProcMaterials.weathered` established for this exact recipe: the texture only multiplies
## DOWN, so the scalar becomes the dull end of the range and the clean lands glide to gloss.
static func steel(tone: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.40 * tone, 0.42 * tone, 0.45 * tone)
	m.metallic = 0.85
	m.normal_enabled = true
	m.normal_texture = ProcMaterials.noise_normal_texture(31, 0.8, 0.15)
	m.normal_scale = 0.5
	m.roughness_texture = ProcMaterials.grime_texture(37, 0.62)
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
	m.roughness = clampf(0.3 * 1.18, 0.0, 1.0)
	return m


## Emissive glow — the v2 default energy is 3.0 (down from the old neon 6.0); keep
## gameplay-signage cores (worm maw / weak domes / arming blinks) at ~3.5.
static func glow(color: Color, energy: float = 3.0) -> StandardMaterial3D:
	return ProcMaterials.emissive(color, energy)


static func clear_cache() -> void:
	_tex_cache.clear()


# ---------------------------------------------------------------- shared height→normal
## HEIGHT → TANGENT-SPACE NORMAL: the codebase's ONE Sobel, as a pure function.
##
## `height` is any UNCOMPRESSED Image; its RED channel is read as the height field (so an
## L8/RGB8 grayscale bake works unchanged, and an RGBA depth pass can hand over just its R).
## Returns a FRESH `FORMAT_RGB8` normal map with mipmaps, the input untouched. `strength`
## scales the gradient — 0.5 is already a firm relief, because the Sobel of a small mask is a
## STEEP operator (the same reason `_RELIEF_STRENGTH` sits at 0.55 rather than 1).
##
## TILEABLE BY CONSTRUCTION: neighbour lookups WRAP. These bakes are sampled triplanar, and a
## clamped border would draw a visible seam line on every surface the texture lands on.
##
## COLOUR-SPACE: the output is DATA, not colour — it is written raw, never through
## `srgb_to_linear()` (runtime ImageTextures are sampled linear; see the class docstring).
##
## SIGN CONVENTION: +X of the normal follows the height's own +X gradient, which is what the
## authored bevels in `_bake_panels` already assume. Under triplanar mapping the tangent
## frame belongs to the MESH, not to the projection, so apparent convexity is
## face-orientation dependent either way — the convention only has to be self-consistent,
## and this is the one the shipped bake was tuned against.
static func height_to_normal(height: Image, strength: float = 1.0) -> Image:
	var flat := Image.create(4, 4, false, Image.FORMAT_RGB8)
	flat.fill(Color(0.5, 0.5, 1.0))
	if height == null or height.is_compressed():
		push_warning("ProcPlating.height_to_normal: needs an uncompressed Image")
		return flat
	var w: int = height.get_width()
	var h: int = height.get_height()
	if w < 2 or h < 2:
		return flat
	var val := PackedFloat32Array()
	val.resize(w * h)
	var nx := PackedFloat32Array()
	nx.resize(w * h)
	var ny := PackedFloat32Array()
	ny.resize(w * h)
	for y in range(h):
		for x in range(w):
			val[y * w + x] = height.get_pixel(x, y).r
	_sobel_into_normal(val, nx, ny, w, h, strength)
	return _encode_normal_image(nx, ny, w, h)


# ---------------------------------------------------------------- the bake
## The cached bake for one (arch, seed): [albedo_tex, normal_tex, albedo_mean, orm_tex,
## roughness_mean]. Only `plated` reads it, so the tuple can grow without a caller edit.
static func _bake_cached(arch: int, sid: int) -> Array:
	# 2 seed variants per archetype (not 3): each bake is a GDScript per-pixel loop
	# (~0.5-1 s main-thread) — 8 total warm during the boot icon prewarm; 12 made the
	# first minutes hitch while late spawns warmed the tail. The D1.3 ORM pack adds one
	# more 256² encode per variant (~15% on a bake that already walks the image three
	# times) and 8 × 256² × 3 B ≈ 1.5 MB of VRAM across the whole cache.
	var key := "plate_%d_%d" % [arch, sid % 2]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var pair: Array = _bake(arch, sid % 2)
	_tex_cache[key] = pair
	return pair


## Deterministic integer hash (the container-bake idiom — no randf).
static func _hh(n: int) -> int:
	return absi((n * 2654435761) ^ 0x5bd1e995)


static func _hf(n: int) -> float:
	return float(_hh(n) % 10000) / 10000.0


## Bake one (arch, sid) variant. Albedo = grayscale multipliers around _MID
## (srgb_to_linear-encoded); normal = tangent-space (nx, ny, 1) accumulated in float
## buffers, encoded in a final pass; ORM = cavity AO in R and a roughness multiplier in G.
## Returns [albedo_tex, normal_tex, albedo_mean, orm_tex, roughness_mean].
static func _bake(arch: int, sid: int) -> Array:
	# 256² across the board: at enemy scale (triplanar ~1.8 m/repeat) the texel density
	# is ample, and 512² cost 4× the bake time (a visible mid-session hitch per variant).
	var size: int = 256
	var val := PackedFloat32Array()
	val.resize(size * size)
	val.fill(_MID)
	var nx := PackedFloat32Array()
	nx.resize(size * size)
	var ny := PackedFloat32Array()
	ny.resize(size * size)
	# D1.3 — two more mask channels the same passes write into.
	# `cav` is CAVITY OCCLUSION (1 = open surface) and `rgh` a ROUGHNESS MULTIPLIER around
	# the archetype's base finish (1 = the archetype's own value). They are separate buffers
	# rather than functions of `val` on purpose: albedo darkness, geometric depth and gloss
	# are three different things here. An oil streak is dark but FLAT — and glossier, because
	# it is wet; a worn panel edge is BRIGHT and slightly polished; a vent slot is dark,
	# deep AND matte. Deriving either channel from the value mask would collapse all three
	# into one, which is exactly the "everything is the same material" look this pass exists
	# to break.
	var cav := PackedFloat32Array()
	cav.resize(size * size)
	cav.fill(1.0)
	var rgh := PackedFloat32Array()
	rgh.resize(size * size)
	rgh.fill(1.0)
	var hs: int = arch * 7919 + sid * 104729 + 13

	if arch == Arch.RUBBER:
		_bake_weave(val, nx, ny, cav, rgh, size)
	else:
		_bake_panels(val, nx, ny, cav, rgh, size, arch, hs)
		_bake_scratches(val, nx, rgh, size, hs + 71)
		if arch == Arch.ARMOR_PLATE:
			_bake_rivets(val, nx, ny, cav, rgh, size, hs + 37)
		if arch == Arch.MECH_HULL:
			_bake_stains(val, rgh, size, hs + 53)
			_bake_vents(val, ny, cav, rgh, size, hs + 91)

	# D2.2: derive a COHERENT relief from the finished mask before encoding. Until now the
	# normal carried only the slopes each pass wrote by hand (a seam bevel here, a rivet dome
	# there), so features that darken the plate — stains, vents, panel seams, worn edges —
	# had no depth at all, and the ones that did were not consistent with each other. In this
	# bake the value mask IS a depth proxy: every pass that recesses a feature multiplies the
	# value DOWN and every pass that raises one multiplies it UP. Taking its gradient gives a
	# relief that agrees with what the eye already reads in the albedo, and it is ADDED to the
	# authored slopes rather than replacing them, so the deliberate bevels survive.
	_sobel_into_normal(val, nx, ny, size, size, _RELIEF_STRENGTH)

	# Encode. The MEAN of the finished mask is measured here and returned as the third
	# element: every pass above only ever MULTIPLIES the _MID starting value DOWN (seams,
	# stains, vents, per-panel variation), so the finished plate averages well below _MID.
	# Compensating by 1/_MID — the value the bake STARTED at — therefore under-shot, and a
	# hull painted at 0.76 landed on screen around 0.5. Compensating by 1/mean instead makes
	# `base` mean exactly what it says: the plate's average albedo IS the colour in the kit.
	var alb := Image.create(size, size, false, Image.FORMAT_RGB8)
	var acc: float = 0.0
	for y in range(size):
		for x in range(size):
			var i: int = y * size + x
			var g: float = clampf(val[i], 0.0, 1.0)
			acc += g
			alb.set_pixel(x, y, Color(g, g, g).srgb_to_linear())
	alb.generate_mipmaps()
	var nrm: Image = _encode_normal_image(nx, ny, size, size)
	# [texture, measured mean] — the mean is what lets `plated` keep the caller's roughness
	# honest, exactly as the albedo mean does for the caller's colour.
	var orm: Array = _encode_orm(cav, rgh, size, arch)
	var mean_val: float = maxf(acc / float(size * size), 0.05)
	return [
		ImageTexture.create_from_image(alb),
		ImageTexture.create_from_image(nrm),
		mean_val,
		orm[0],
		orm[1],
	]


## Sobel a height/value field into the tangent-space normal accumulators, ADDING to whatever
## authored slopes are already there (the deliberate bevels in `_bake_panels` and the rivet
## domes must survive). The public `height_to_normal` is the same operator with zeroed
## accumulators — this is the single implementation both go through.
## Wrapping indices keep the result tileable — the bake is sampled triplanar and a clamped
## edge would show as a seam line on every surface it lands on.
static func _sobel_into_normal(
	val: PackedFloat32Array,
	nx: PackedFloat32Array,
	ny: PackedFloat32Array,
	w: int,
	h: int,
	k: float
) -> void:
	for y in range(h):
		var ym: int = (y - 1 + h) % h
		var yp: int = (y + 1) % h
		for x in range(w):
			var xm: int = (x - 1 + w) % w
			var xp: int = (x + 1) % w
			var tl: float = val[ym * w + xm]
			var tc: float = val[ym * w + x]
			var tr: float = val[ym * w + xp]
			var ml: float = val[y * w + xm]
			var mr: float = val[y * w + xp]
			var bl: float = val[yp * w + xm]
			var bc: float = val[yp * w + x]
			var br: float = val[yp * w + xp]
			var gx: float = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl)
			var gy: float = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr)
			var i: int = y * w + x
			nx[i] += gx * k
			ny[i] += gy * k


## Encode tangent-space (nx, ny, 1) accumulators into an RGB8 normal map (raw, mipmapped).
## Shared by the plate bake and by `height_to_normal` so the encode math has exactly one
## home — a second copy is how two bakes end up disagreeing about the Y sign.
static func _encode_normal_image(
	nx: PackedFloat32Array, ny: PackedFloat32Array, w: int, h: int
) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in range(h):
		for x in range(w):
			var i: int = y * w + x
			var nv := Vector3(clampf(nx[i], -1.0, 1.0), clampf(ny[i], -1.0, 1.0), 1.0).normalized()
			img.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5))
	img.generate_mipmaps()
	return img


## Pack the cavity + roughness fields into one RGB8 map: R = AO, G = roughness multiplier,
## B = 0 (reserved — metallic deliberately stays a per-archetype constant, see `arch_finish`:
## a metallic MAP could only ever scale that constant DOWN, and the D2 finding is that the
## number wants to be binary, not smeared).
## Written RAW — this is data, and runtime ImageTextures are sampled linear.
## Returns [texture, mean roughness multiplier].
##
## The roughness field is NORMALISED BY ITS MAXIMUM first. Godot multiplies a roughness map
## into the scalar, so the map's ceiling has to be exactly 1.0 or the archetype's matte end
## is unreachable; the scalar then carries the base up by 1/mean (done in `_apply_orm`).
static func _encode_orm(
	cav: PackedFloat32Array, rgh: PackedFloat32Array, size: int, arch: int
) -> Array:
	var ao_k: float = _arch_ao_strength(arch)
	var spread: float = _arch_rough_spread(arch)
	var scaled := PackedFloat32Array()
	scaled.resize(size * size)
	var rmax: float = 0.001
	for i in range(size * size):
		var r: float = maxf(1.0 + (rgh[i] - 1.0) * spread, _ROUGH_FLOOR)
		scaled[i] = r
		rmax = maxf(rmax, r)
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var acc: float = 0.0
	for y in range(size):
		for x in range(size):
			var i: int = y * size + x
			var ao: float = clampf(1.0 - (1.0 - cav[i]) * ao_k, _AO_FLOOR, 1.0)
			var rn: float = scaled[i] / rmax
			acc += rn
			img.set_pixel(x, y, Color(ao, rn, 0.0))
	img.generate_mipmaps()
	return [ImageTexture.create_from_image(img), maxf(acc / float(size * size), 0.05)]


## How deep the cavity mask is allowed to occlude, per archetype (1.0 = the authored depth).
## A lacquered panel is a smooth coated shell with almost nothing to trap light, and a rubber
## boot's weave is millimetres deep — full-strength AO on either reads as dirt, not as form.
static func _arch_ao_strength(arch: int) -> float:
	match arch:
		Arch.LACQUER:
			return 0.55
		Arch.RUBBER:
			return 0.7
		_:
			return 1.0


## How far roughness may swing around `arch_finish`, per archetype — the "within the
## archetype" clamp. Painted armour and industrial hulls are the surfaces that genuinely
## carry burnished wear next to grimy recesses; a lacquer coat and a rubber boot are near
## uniform by definition, and a wide swing there would just read as a different material.
## Keeping RUBBER narrow is also what stops its 0.9 base from needing a scalar above 1.0.
static func _arch_rough_spread(arch: int) -> float:
	match arch:
		Arch.LACQUER:
			return 0.5
		Arch.RUBBER:
			return 0.35
		_:
			return 1.0


## Panel grid: 3-5 jittered seams per axis. Seam = 2 px darken + a 4 px (8 px lacquer)
## normal chamfer each side; per-panel value variation; edge wear dither near seams
## (ARMOR_PLATE/MECH_HULL only — lacquer stays clean).
## D1.3 also writes the seam groove + its bevel into the cavity mask, and gives every panel
## its own gloss (plates are repainted at different times) with worn edges burnished.
static func _bake_panels(
	val: PackedFloat32Array,
	nx: PackedFloat32Array,
	ny: PackedFloat32Array,
	cav: PackedFloat32Array,
	rgh: PackedFloat32Array,
	size: int,
	arch: int,
	hs: int
) -> void:
	var n_v: int = 3 + _hh(hs + 1) % 3
	var n_h: int = 3 + _hh(hs + 2) % 3
	var vx: Array[int] = []
	var hy: Array[int] = []
	for i in range(n_v):
		vx.append(int((float(i) + 0.3 + 0.4 * _hf(hs + 10 + i)) / float(n_v) * float(size)))
	for i in range(n_h):
		hy.append(int((float(i) + 0.3 + 0.4 * _hf(hs + 20 + i)) / float(n_h) * float(size)))
	var chamfer: float = 8.0 if arch == Arch.LACQUER else 4.0
	var seam_mul: float = 0.80 if arch == Arch.LACQUER else 0.62
	var var_lo: float = 0.97 if arch == Arch.LACQUER else 0.92
	var var_hi: float = 1.03 if arch == Arch.LACQUER else 1.06
	var wear: bool = arch != Arch.LACQUER
	for y in range(size):
		for x in range(size):
			var i: int = y * size + x
			# Panel cell index = count of seams below this coordinate.
			var cx: int = 0
			for sx in vx:
				if x >= sx:
					cx += 1
			var cy: int = 0
			for sy in hy:
				if y >= sy:
					cy += 1
			var pv: float = lerpf(var_lo, var_hi, _hf(hs + 100 + cx * 31 + cy * 7))
			val[i] *= pv
			# Per-panel gloss, hashed independently of the value jitter: panels get replaced
			# and repainted at different times, so a fresh coat sits beside a chalked one.
			rgh[i] *= lerpf(0.94, 1.06, _hf(hs + 400 + cx * 13 + cy * 29))
			# Distance to nearest seam (wrapping ignored — tiles hide it).
			var dvx: float = 1e9
			for sx in vx:
				dvx = minf(dvx, absf(float(x - sx)))
			var dhy: float = 1e9
			for sy in hy:
				dhy = minf(dhy, absf(float(y - sy)))
			# Chamfer bevels tilt INTO the seam. The same ramp writes the bevel's cavity:
			# `minf` (never a multiply) so a pixel that is close to BOTH a vertical and a
			# horizontal seam is occluded once by the deeper of the two, not twice — stacking
			# multiplies is how corner pixels turn into black dots.
			if dvx < chamfer:
				var sgn: float = 1.0
				for sx in vx:
					if absf(float(x - sx)) == dvx:
						sgn = 1.0 if x >= sx else -1.0
						break
				nx[i] += sgn * 0.45 * (1.0 - dvx / chamfer)
				cav[i] = minf(cav[i], lerpf(1.0, _AO_BEVEL, 1.0 - dvx / chamfer))
			if dhy < chamfer:
				var sgn2: float = 1.0
				for sy in hy:
					if absf(float(y - sy)) == dhy:
						sgn2 = 1.0 if y >= sy else -1.0
						break
				ny[i] += sgn2 * 0.45 * (1.0 - dhy / chamfer)
				cav[i] = minf(cav[i], lerpf(1.0, _AO_BEVEL, 1.0 - dhy / chamfer))
			# Seam darkening.
			if dvx < 1.5 or dhy < 1.5:
				val[i] *= seam_mul
				# The groove is the deepest cavity on a flat plate and it is where grit
				# collects — dark, occluded and MATTE, all three at once.
				cav[i] = minf(cav[i], _AO_SEAM)
				rgh[i] *= 1.10
			elif wear and (dvx < 3.5 or dhy < 3.5):
				# Edge wear: hash-dithered lighten toward bare metal at panel edges.
				if _hf(hs + i) < 0.30:
					val[i] = lerpf(val[i], 1.0, 0.5)
					rgh[i] *= 0.80  # paint rubbed off leaves burnished metal, not chalk


## Rivet rows along ~40% of seams: hemispherical normal bump + albedo ring/highlight, with
## the contact ring occluded (a rivet sits ON the plate — the shadow it casts into its own
## seating is most of what sells it) and its crown burnished by decades of being the first
## thing anything scrapes against.
static func _bake_rivets(
	val: PackedFloat32Array,
	nx: PackedFloat32Array,
	ny: PackedFloat32Array,
	cav: PackedFloat32Array,
	rgh: PackedFloat32Array,
	size: int,
	hs: int
) -> void:
	var n_rows: int = 2 + _hh(hs) % 3
	for row in range(n_rows):
		var vertical: bool = (_hh(hs + row * 3) % 2) == 0
		var coord: int = 16 + _hh(hs + row * 5 + 1) % (size - 32)
		var step: int = 28
		var pos: int = 10 + _hh(hs + row * 7 + 2) % step
		while pos < size - 6:
			var cx: int = coord if vertical else pos
			var cy: int = pos if vertical else coord
			for dy in range(-3, 4):
				for dx in range(-3, 4):
					var d: float = sqrt(float(dx * dx + dy * dy))
					if d > 3.0:
						continue
					var px: int = cx + dx
					var py: int = cy + dy
					if px < 0 or px >= size or py < 0 or py >= size:
						continue
					var i: int = py * size + px
					var prof: float = sqrt(maxf(0.0, 1.0 - (d / 3.0) * (d / 3.0)))
					nx[i] += float(dx) / 3.0 * 0.8 * prof
					ny[i] += float(dy) / 3.0 * 0.8 * prof
					if d > 2.4:
						val[i] *= 0.8  # shadow ring
						cav[i] = minf(cav[i], _AO_RIVET)
						rgh[i] *= 1.06
					elif d < 1.0:
						val[i] = minf(val[i] * 1.15, 1.0)  # top highlight
						rgh[i] *= 0.78
			pos += step


## 8-14 short hash-seeded scratches: 1 px lighten (bare metal) + a small normal nick, and
## the sharpest gloss on the plate — a scratch is polished metal by definition, and these
## thin bright specular lines are what make a hull look like it has been somewhere.
## No cavity write: a scratch is far too fine to trap ambient light at this texel density.
static func _bake_scratches(
	val: PackedFloat32Array, nx: PackedFloat32Array, rgh: PackedFloat32Array, size: int, hs: int
) -> void:
	var n: int = 8 + _hh(hs) % 7
	for s in range(n):
		var px: float = _hf(hs + s * 11 + 1) * float(size)
		var py: float = _hf(hs + s * 11 + 2) * float(size)
		var ang: float = _hf(hs + s * 11 + 3) * TAU
		var ln: int = 12 + _hh(hs + s * 11 + 4) % 36
		var dx: float = cos(ang)
		var dy: float = sin(ang)
		for k in range(ln):
			var ix: int = int(px + dx * float(k))
			var iy: int = int(py + dy * float(k))
			if ix < 0 or ix >= size or iy < 0 or iy >= size:
				break
			var i: int = iy * size + ix
			val[i] = minf(val[i] * 1.22, 1.0)
			nx[i] += 0.2 * -dy
			rgh[i] *= 0.72


## 4-6 dark streaks running DOWN with vertical falloff (the container rust-streak loop,
## oil-toned since the bake is neutral).
## D1.3: a stain is the one dark feature that must NOT be occluded or matte — leaked oil sits
## ON the plate, so it is flat (no cavity write) and WETTER than the paint around it. This is
## the case that proves roughness cannot simply be read off the value mask: here dark means
## glossy, while three passes up dark means matte.
static func _bake_stains(
	val: PackedFloat32Array, rgh: PackedFloat32Array, size: int, hs: int
) -> void:
	var n: int = 4 + _hh(hs) % 3
	for s in range(n):
		var px: int = _hh(hs + s * 13 + 1) % size
		var py: int = _hh(hs + s * 13 + 2) % (size / 2)
		var ln: int = 60 + _hh(hs + s * 13 + 3) % 90
		var half_w: int = 3 + _hh(hs + s * 13 + 4) % 4
		for dy in range(ln):
			var fall: float = 1.0 - float(dy) / float(ln)
			var iy: int = py + dy
			if iy >= size:
				break
			for dx in range(-half_w, half_w + 1):
				var ix: int = px + dx
				if ix < 0 or ix >= size:
					continue
				var fx: float = 1.0 - absf(float(dx)) / float(half_w + 1)
				var si: int = iy * size + ix
				val[si] *= 1.0 - 0.28 * fall * fx
				rgh[si] *= 1.0 - 0.18 * fall * fx


## 1-2 vent slat blocks: 5 horizontal slats with strong normal ramps — free
## "tessellated" vents on every hull without geometry.
## D1.3: the slot between the slats is the DEEPEST cavity the bake owns, and the payoff for
## having an AO channel at all — a vent whose gap merely goes dark reads as a painted stripe,
## while one whose gap stops receiving ambient reads as a hole. Grimy inside, so also matte.
static func _bake_vents(
	val: PackedFloat32Array,
	ny: PackedFloat32Array,
	cav: PackedFloat32Array,
	rgh: PackedFloat32Array,
	size: int,
	hs: int
) -> void:
	var n: int = 1 + _hh(hs) % 2
	for v in range(n):
		var bx: int = 24 + _hh(hs + v * 17 + 1) % (size - 88)
		var by: int = 24 + _hh(hs + v * 17 + 2) % (size - 64)
		for slat in range(5):
			var sy: int = by + slat * 8
			for y in range(8):
				var iy: int = sy + y
				if iy >= size:
					break
				for x in range(64):
					var ix: int = bx + x
					if ix >= size:
						break
					var i: int = iy * size + ix
					if y < 3:
						ny[i] += -0.7
						cav[i] = minf(cav[i], 0.78)  # slat's shaded upper face
					elif y < 5:
						val[i] *= 0.55
						cav[i] = minf(cav[i], _AO_VENT)
						rgh[i] *= 1.12
					else:
						ny[i] += 0.7
						cav[i] = minf(cav[i], 0.88)  # lower lip, mostly open to the sky


## RUBBER: high-frequency diagonal cross-weave in the normal + a faint albedo ripple.
## D1.3: the weave gets a shallow cavity in its valleys and a touch of sheen on its crests —
## rubber is matte, but the raised threads are the part that gets handled and they catch a
## soft highlight. Both channels are deliberately tiny and further scaled down by RUBBER's
## archetype factors: this is the material whose whole identity is "no specular event".
static func _bake_weave(
	val: PackedFloat32Array,
	nx: PackedFloat32Array,
	ny: PackedFloat32Array,
	cav: PackedFloat32Array,
	rgh: PackedFloat32Array,
	size: int
) -> void:
	var f: float = 40.0 / float(size) * TAU
	for y in range(size):
		for x in range(size):
			var i: int = y * size + x
			nx[i] += cos(float(x) * f) * 0.25
			ny[i] += cos(float(y) * f) * 0.25
			# -1 = the valley between threads, +1 = a crest.
			var wv: float = sin(float(x) * f) * sin(float(y) * f)
			val[i] *= 0.985 + 0.03 * wv
			cav[i] = minf(cav[i], lerpf(1.0, _AO_WEAVE, 0.5 - 0.5 * wv))
			rgh[i] *= 1.0 - 0.05 * maxf(wv, 0.0)
