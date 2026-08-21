class_name FloraField
extends RefCounted
## The forest/clearing DENSITY FIELD for the vegetation overhaul: a deterministic
## low-frequency noise field that shapes WHERE trees/bushes/meadows go, so the map
## reads as groves, forest edges and natural clearings instead of a uniform sprinkle.
##
##   forest_w(x,z) -> [0,1]  0 = open clearing, 1 = grove core. Built from a
##     3-octave value noise (~25-60 m features), a riparian treeline boost along the
##     river, smooth per-biome multipliers (lush rain / sparse desert), and authored
##     corridor cuts (spawn->plaza->bridge->landmarks) so the navmesh always keeps
##     walkable combat lanes through the woods.
##   edge_w(x,z) -> [0,1]  peaks at FOREST EDGES (the ecotone) — drives bushes,
##     tall meadows and flowers hugging the treelines.
##
## FAIRNESS: this field is part of the deterministic world build — identical for
## every player on every preset (vegetation is concealment).
## DETERMINISM: ProcHash only, with a salted lattice DISTINCT from the terrain's
## (groves must not correlate with hills). NO randf/Time.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

# Grove/clearing feature size: 1/56 m base frequency => 25-60 m blobs over 3 octaves.
const _FREQ: float = 1.0 / 56.0
# Distinct lattice salt (offset from TERRAIN_SEED) so groves don't follow terrain hills.
const _SALT: int = 7717

# Per-biome density multipliers (smoothly blended over +/-20 m at the centre lines —
# no hard quadrant seam): lush SE rain, near-barren SW desert.
const _MULT_URBAN: float = 0.9
const _MULT_SNOW: float = 0.95
const _MULT_DESERT: float = 0.30
const _MULT_RAIN: float = 1.2
const _BIOME_BLEND_M: float = 20.0

# Authored corridor segments (XZ): forest density is carved to ~10% within 7 m of
# these lanes (full again by 12 m) so spawn->POI approaches and the bridge crossing
# stay open for pathing and combat flow.
const _CORRIDORS: Array = [
	[Vector2(59, 60), Vector2(0, 0)],  # spawn cluster -> plaza
	[Vector2(0, 0), Vector2(20, -8)],  # plaza -> the stone bridge
	[Vector2(20, -8), Vector2(-40, -45)],  # bridge -> NorthTower
	[Vector2(0, 0), Vector2(16, 38)],  # plaza -> the south river ford
	[Vector2(80, 80), Vector2(160, -10)],  # crossroads -> SnowLodge (NE)
	[Vector2(80, 80), Vector2(0, 158)],  # crossroads -> DesertRuins (SW)
	[Vector2(80, 80), Vector2(160, 158)],  # crossroads -> Temple (SE)
	[Vector2(59, 60), Vector2(80, 80)],  # spawn cluster -> crossroads
]


## Forest weight in [0,1]: 0 = clearing, 1 = grove core. See header.
static func forest_w(x: float, z: float) -> float:
	var f01: float = _fbm(x, z)
	var w: float = smoothstep(0.46, 0.62, f01)
	# Riparian treeline: a band 7.5-9 m off the river centerline gets trees even in
	# clearings (zero inside the channel itself — half-width 5.4 m).
	var rd: float = ProceduralTerrain.river_distance(x, z)
	var riparian: float = 0.85 * smoothstep(14.0, 9.0, rd) * smoothstep(5.5, 7.5, rd)
	w = maxf(w, riparian)
	w *= biome_mult(x, z)
	w *= _corridor_mult(x, z)
	return clampf(w, 0.0, 1.0)


## Ecotone weight: peaks at forest EDGES (low inside groves and in open clearings).
static func edge_w(x: float, z: float) -> float:
	var w: float = forest_w(x, z)
	return smoothstep(0.05, 0.25, w) * (1.0 - smoothstep(0.55, 0.85, w))


## Smoothly-blended per-biome density multiplier (urban NW / snow NE / desert SW / rain SE).
static func biome_mult(x: float, z: float) -> float:
	var ux: float = smoothstep(WorldBounds.CX - _BIOME_BLEND_M, WorldBounds.CX + _BIOME_BLEND_M, x)
	var uz: float = smoothstep(WorldBounds.CZ - _BIOME_BLEND_M, WorldBounds.CZ + _BIOME_BLEND_M, z)
	var north: float = lerpf(_MULT_URBAN, _MULT_SNOW, ux)  # z < CZ row
	var south: float = lerpf(_MULT_DESERT, _MULT_RAIN, ux)  # z >= CZ row
	return lerpf(north, south, uz)


static func _corridor_mult(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var m: float = 1.0
	for seg in _CORRIDORS:
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		var d: float = p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))
		m *= 1.0 - 0.9 * (1.0 - smoothstep(7.0, 12.0, d))
	return m


# ---------------------------------------------------------------- value noise
## 3-octave value noise in [0,1] on the salted lattice.
static func _fbm(x: float, z: float) -> float:
	var sum: float = 0.0
	var amp: float = 0.5
	var freq: float = _FREQ
	var total: float = 0.0
	for o in range(3):
		sum += _vnoise(x * freq, z * freq, _SALT + o * 131) * amp
		total += amp
		amp *= 0.5
		freq *= 2.0
	return sum / total


## Smooth bilinear value noise at integer lattice points (deterministic, salted).
static func _vnoise(x: float, z: float, salt: int) -> float:
	var ix: int = int(floor(x))
	var iz: int = int(floor(z))
	var fx: float = x - float(ix)
	var fz: float = z - float(iz)
	var sx: float = fx * fx * (3.0 - 2.0 * fx)
	var sz: float = fz * fz * (3.0 - 2.0 * fz)
	var a: float = _lattice(ix, iz, salt)
	var b: float = _lattice(ix + 1, iz, salt)
	var c: float = _lattice(ix, iz + 1, salt)
	var d: float = _lattice(ix + 1, iz + 1, salt)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sz)


static func _lattice(ix: int, iz: int, salt: int) -> float:
	return ProcHash.hf(
		(Settings.TERRAIN_SEED + salt) * 2246822519 + ix * 374761393 + iz * 668265263
	)
