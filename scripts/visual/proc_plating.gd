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
## Textures are CACHED; material INSTANCES are always fresh per call — the hit-flash
## collector duplicates and mutates per-enemy materials, so sharing instances across
## models would flash every enemy at once (the invariant ProcMaterials also keeps).
##
## sRGB TRAP (same as ProcMaterials): runtime ImageTextures sample as LINEAR — albedo
## grays are baked through srgb_to_linear(); normal data stays raw.
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
	m.roughness = finish.y if roughness < 0.0 else roughness
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
	if arch == Arch.LACQUER:
		m.clearcoat_enabled = true
		m.clearcoat = 0.6
		m.clearcoat_roughness = 0.25
	return m


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
static func steel(tone: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.40 * tone, 0.42 * tone, 0.45 * tone)
	m.metallic = 0.85
	m.roughness = 0.3
	m.normal_enabled = true
	m.normal_texture = ProcMaterials.noise_normal_texture(31, 0.8, 0.15)
	m.normal_scale = 0.5
	return m


## Emissive glow — the v2 default energy is 3.0 (down from the old neon 6.0); keep
## gameplay-signage cores (worm maw / weak domes / arming blinks) at ~3.5.
static func glow(color: Color, energy: float = 3.0) -> StandardMaterial3D:
	return ProcMaterials.emissive(color, energy)


static func clear_cache() -> void:
	_tex_cache.clear()


# ---------------------------------------------------------------- the bake
static func _bake_cached(arch: int, sid: int) -> Array:
	# 2 seed variants per archetype (not 3): each bake is a GDScript per-pixel loop
	# (~0.5-1 s main-thread) — 8 total warm during the boot icon prewarm; 12 made the
	# first minutes hitch while late spawns warmed the tail.
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


## Bake one (arch, sid) albedo+normal pair. Albedo = grayscale multipliers around
## _MID (srgb_to_linear-encoded); normal = tangent-space (nx, ny, 1) accumulated in
## float buffers, encoded in a final pass.
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
	var hs: int = arch * 7919 + sid * 104729 + 13

	if arch == Arch.RUBBER:
		_bake_weave(val, nx, ny, size)
	else:
		_bake_panels(val, nx, ny, size, arch, hs)
		_bake_scratches(val, nx, size, hs + 71)
		if arch == Arch.ARMOR_PLATE:
			_bake_rivets(val, nx, ny, size, hs + 37)
		if arch == Arch.MECH_HULL:
			_bake_stains(val, size, hs + 53)
			_bake_vents(val, ny, size, hs + 91)

	# D2.2: derive a COHERENT relief from the finished mask before encoding. Until now the
	# normal carried only the slopes each pass wrote by hand (a seam bevel here, a rivet dome
	# there), so features that darken the plate — stains, vents, panel seams, worn edges —
	# had no depth at all, and the ones that did were not consistent with each other. In this
	# bake the value mask IS a depth proxy: every pass that recesses a feature multiplies the
	# value DOWN and every pass that raises one multiplies it UP. Taking its gradient gives a
	# relief that agrees with what the eye already reads in the albedo, and it is ADDED to the
	# authored slopes rather than replacing them, so the deliberate bevels survive.
	_sobel_into_normal(val, nx, ny, size, _RELIEF_STRENGTH)

	# Encode. The MEAN of the finished mask is measured here and returned as the third
	# element: every pass above only ever MULTIPLIES the _MID starting value DOWN (seams,
	# stains, vents, per-panel variation), so the finished plate averages well below _MID.
	# Compensating by 1/_MID — the value the bake STARTED at — therefore under-shot, and a
	# hull painted at 0.76 landed on screen around 0.5. Compensating by 1/mean instead makes
	# `base` mean exactly what it says: the plate's average albedo IS the colour in the kit.
	var alb := Image.create(size, size, false, Image.FORMAT_RGB8)
	var nrm := Image.create(size, size, false, Image.FORMAT_RGB8)
	var acc: float = 0.0
	for y in range(size):
		for x in range(size):
			var i: int = y * size + x
			var g: float = clampf(val[i], 0.0, 1.0)
			acc += g
			alb.set_pixel(x, y, Color(g, g, g).srgb_to_linear())
			var nv := Vector3(clampf(nx[i], -1.0, 1.0), clampf(ny[i], -1.0, 1.0), 1.0).normalized()
			nrm.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5))
	alb.generate_mipmaps()
	nrm.generate_mipmaps()
	var mean_val: float = maxf(acc / float(size * size), 0.05)
	return [ImageTexture.create_from_image(alb), ImageTexture.create_from_image(nrm), mean_val]


## Sobel the value mask into the tangent-space normal accumulators (see the call site).
## Wrapping indices keeps the plate tileable — the bake is sampled triplanar and a clamped
## edge would show as a seam line on every surface it lands on.
static func _sobel_into_normal(
	val: PackedFloat32Array, nx: PackedFloat32Array, ny: PackedFloat32Array, size: int, k: float
) -> void:
	for y in range(size):
		var ym: int = (y - 1 + size) % size
		var yp: int = (y + 1) % size
		for x in range(size):
			var xm: int = (x - 1 + size) % size
			var xp: int = (x + 1) % size
			var tl: float = val[ym * size + xm]
			var tc: float = val[ym * size + x]
			var tr: float = val[ym * size + xp]
			var ml: float = val[y * size + xm]
			var mr: float = val[y * size + xp]
			var bl: float = val[yp * size + xm]
			var bc: float = val[yp * size + x]
			var br: float = val[yp * size + xp]
			var gx: float = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl)
			var gy: float = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr)
			var i: int = y * size + x
			nx[i] += gx * k
			ny[i] += gy * k


## Panel grid: 3-5 jittered seams per axis. Seam = 2 px darken + a 4 px (8 px lacquer)
## normal chamfer each side; per-panel value variation; edge wear dither near seams
## (ARMOR_PLATE/MECH_HULL only — lacquer stays clean).
static func _bake_panels(
	val: PackedFloat32Array,
	nx: PackedFloat32Array,
	ny: PackedFloat32Array,
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
			# Distance to nearest seam (wrapping ignored — tiles hide it).
			var dvx: float = 1e9
			for sx in vx:
				dvx = minf(dvx, absf(float(x - sx)))
			var dhy: float = 1e9
			for sy in hy:
				dhy = minf(dhy, absf(float(y - sy)))
			# Chamfer bevels tilt INTO the seam.
			if dvx < chamfer:
				var sgn: float = 1.0
				for sx in vx:
					if absf(float(x - sx)) == dvx:
						sgn = 1.0 if x >= sx else -1.0
						break
				nx[i] += sgn * 0.45 * (1.0 - dvx / chamfer)
			if dhy < chamfer:
				var sgn2: float = 1.0
				for sy in hy:
					if absf(float(y - sy)) == dhy:
						sgn2 = 1.0 if y >= sy else -1.0
						break
				ny[i] += sgn2 * 0.45 * (1.0 - dhy / chamfer)
			# Seam darkening.
			if dvx < 1.5 or dhy < 1.5:
				val[i] *= seam_mul
			elif wear and (dvx < 3.5 or dhy < 3.5):
				# Edge wear: hash-dithered lighten toward bare metal at panel edges.
				if _hf(hs + i) < 0.30:
					val[i] = lerpf(val[i], 1.0, 0.5)


## Rivet rows along ~40% of seams: hemispherical normal bump + albedo ring/highlight.
static func _bake_rivets(
	val: PackedFloat32Array, nx: PackedFloat32Array, ny: PackedFloat32Array, size: int, hs: int
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
					elif d < 1.0:
						val[i] = minf(val[i] * 1.15, 1.0)  # top highlight
			pos += step


## 8-14 short hash-seeded scratches: 1 px lighten (bare metal) + a small normal nick.
static func _bake_scratches(
	val: PackedFloat32Array, nx: PackedFloat32Array, size: int, hs: int
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


## 4-6 dark streaks running DOWN with vertical falloff (the container rust-streak loop,
## oil-toned since the bake is neutral).
static func _bake_stains(val: PackedFloat32Array, size: int, hs: int) -> void:
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
				val[iy * size + ix] *= 1.0 - 0.28 * fall * fx


## 1-2 vent slat blocks: 5 horizontal slats with strong normal ramps — free
## "tessellated" vents on every hull without geometry.
static func _bake_vents(
	val: PackedFloat32Array, ny: PackedFloat32Array, size: int, hs: int
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
					elif y < 5:
						val[i] *= 0.55
					else:
						ny[i] += 0.7


## RUBBER: high-frequency diagonal cross-weave in the normal + a faint albedo ripple.
static func _bake_weave(
	val: PackedFloat32Array, nx: PackedFloat32Array, ny: PackedFloat32Array, size: int
) -> void:
	var f: float = 40.0 / float(size) * TAU
	for y in range(size):
		for x in range(size):
			var i: int = y * size + x
			nx[i] += cos(float(x) * f) * 0.25
			ny[i] += cos(float(y) * f) * 0.25
			val[i] *= 0.985 + 0.03 * sin(float(x) * f) * sin(float(y) * f)
