extends RefCounted
class_name ProcMaterials
## Shared procedural-detail material toolkit (zero external assets). Builds
## StandardMaterial3D with noise-driven weathering (grime/streaks via a cached
## FastNoiseLite -> NoiseTexture2D, triplanar so no UVs are needed) so buildings,
## ground and enemies read as worn surfaces instead of flat solid colours.
##
## StandardMaterial3D ONLY (never ShaderMaterial) so the enemy hit-flash path keeps
## working. Textures are cached so spawning many pieces doesn't rebuild noise.

static var _tex_cache: Dictionary = {}

## A grayscale weathering mask: mostly clean (white) with darker grime in the lows.
## `grime` is the dark floor (lower = heavier grime). Cached by (sid, grime).
static func grime_texture(sid: int, grime: float) -> NoiseTexture2D:
	var key := "%d_%.2f" % [sid, grime]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = sid
	n.frequency = 0.012 + float(absi(sid) % 5) * 0.004
	n.fractal_octaves = 4
	n.fractal_gain = 0.5
	var nt := NoiseTexture2D.new()
	nt.width = 256
	nt.height = 256
	nt.seamless = true
	nt.noise = n
	var g := Gradient.new()
	g.set_color(0, Color(grime, grime, grime))
	g.set_color(1, Color(1.0, 1.0, 1.0))
	nt.color_ramp = g
	_tex_cache[key] = nt
	return nt

## Weathered surface: base albedo modulated by a triplanar grime mask, with optional
## metallic/roughness. `world` triplanar keeps detail consistent across adjacent
## building pieces; pass world=false for small/moving objects (enemies) so it doesn't
## swim. `scale` is the triplanar UV scale (use a low y for vertical streaks).
static func weathered(base: Color, metallic := 0.0, roughness := 0.85, grime := 0.55,
		sid := 0, scale := Vector3(0.18, 0.18, 0.18), world := true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = base
	m.metallic = metallic
	m.roughness = roughness
	m.albedo_texture = grime_texture(sid, grime)
	m.uv1_triplanar = true
	m.uv1_world_triplanar = world
	m.uv1_scale = scale
	return m

## Rain-streaked vertical weathering (stains running down walls under windows etc.):
## a tall, narrow triplanar scale so the noise stretches into vertical streaks.
static func streaked(base: Color, metallic := 0.0, roughness := 0.88, grime := 0.45,
		sid := 0) -> StandardMaterial3D:
	return weathered(base, metallic, roughness, grime, sid, Vector3(0.3, 0.05, 0.3), true)

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
