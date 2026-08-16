class_name FXSprites
extends Node3D
## PER-MATERIAL bullet impact (D4.4): the burst a shot leaves in the WORLD, dressed by
## WHAT it hit and sprayed as a CONE off the surface normal. The old world impact was one
## grey 180-degree BALL for every surface — steel, concrete and dirt all read the same and
## the sparks ignored the wall they bounced off.
##
## Sprites are baked PROCEDURALLY in code (the ProcMaterials/ProcPlating discipline — no new
## art assets): a soft dust puff, a hot spark streak, an angular crumb, a 4-point glint and a
## scorch blob. Each is built ONCE per process (static cache, ProcHash grain so every peer
## bakes byte-identical pixels) and shared by every instance.
##
## POOLED through FXPool ("surface_impact"), same contract as Impact/GlassShatter: the pool
## sets `pooled`, `fire()` (re)starts it, end-of-life releases instead of freeing. Children +
## materials are built ONCE in _ready and a fire() only MUTATES properties — the per-material
## counts ride `amount_ratio`, because writing `amount` REALLOCATES the GPU particle buffer
## (exactly the per-shot allocation the pool exists to avoid).
##
## The material vocabulary (FXPool.MAT_*) deliberately lives in FXPool: the pool loads this
## script BY PATH, so the class dependency stays one-way (FXSprites -> FXPool) like every
## other pooled FX and no cyclic reference can form. Purely local/visual — never networked.

const SPRITE_GRIT := 0  # angular crumb — concrete / stone / dirt
const SPRITE_STREAK := 1  # hot tapered streak — metal sparks, wood splinters
const SPRITE_GLINT := 2  # 4-point star — glass crumbs

## D4.5 WEAK-POINT CRIT — its own recipe kind, keyed OUTSIDE the FXPool.MAT_* range (0..6)
## so it can never collide with a surface material: a crit is dressed by WHERE it landed on
## the machine, never by what the wall behind it is made of.
const KIND_WEAK := -1
const RING_TIME := 0.20  # the crit ring is a POP, not an effect you watch
const RING_R0 := 0.10
const RING_R1 := 0.60

const LIFETIME := 0.85  # outlives the longest pass (dust 0.7 + spawn spread)
const DECAL_LIFETIME := 3.0  # the surface mark lingers; the node stays busy until it fades
const FLASH_TIME := 0.07  # the metal/glass pop is a BLINK, not a light
const DUST_MAX := 16  # fixed particle buffers — per-material counts ride amount_ratio
const GRIT_MAX := 14
const DUST_SPREAD_BONUS := 20.0  # dust billows wider than the grit cone
const SURFACE_OFFSET := 0.05  # emit just OUTSIDE the surface so the burst is not half-buried

## Ground dust takes the BIOME's colour (WorldBounds.biome_at) — snow throws white powder,
## the desert throws sand. Render-only, so a plain lookup is enough (no ProcHash needed).
const _GROUND_TINT := {
	"urban": Color(0.44, 0.40, 0.34),
	"snow": Color(0.86, 0.90, 0.95),
	"desert": Color(0.78, 0.66, 0.44),
	"rain": Color(0.34, 0.32, 0.27),
}

# Baked ONCE per process, shared by every instance (the Impact._scorch_texture pattern).
static var _tex_puff: ImageTexture = null
static var _tex_streak: ImageTexture = null
static var _tex_grit: ImageTexture = null
static var _tex_glint: ImageTexture = null
static var _tex_scorch: ImageTexture = null
static var _tex_ring: ImageTexture = null
static var _recipes: Dictionary = {}

var pooled := false  # set by FXPool; end-of-life releases instead of freeing
var _t := 0.0
var _decal_t := 0.0
var _decal_alpha := 0.0
var _mat_kind := 0  # FXPool.MAT_* — what was hit
var _weak := false  # weak-point hit → the gold crit recipe replaces the material one
var _ring_scale := 0.0
var _normal: Vector3 = Vector3.ZERO  # world-space surface normal (ZERO = unknown -> up)
var _incoming: Vector3 = Vector3.ZERO  # world-space shot direction (ZERO = unknown)
var _dust: GPUParticles3D
var _dust_pm: ParticleProcessMaterial
var _grit: GPUParticles3D
var _grit_pm: ParticleProcessMaterial
var _grit_mat: StandardMaterial3D
var _flash: MeshInstance3D
var _flash_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _decal: Decal


func _ready() -> void:
	_build_dust()
	_build_grit()
	_build_flash()
	_build_ring()
	# The surface mark is a PERMANENT child toggled per use — the create/free-per-hit
	# pattern fights the pool (Impact learned this the hard way).
	_decal = Decal.new()
	_decal.size = Vector3(0.5, 0.6, 0.5)
	_decal.albedo_mix = 1.0
	_decal.texture_albedo = _scorch_texture()
	_decal.distance_fade_enabled = true
	_decal.distance_fade_begin = 28.0
	_decal.distance_fade_length = 12.0
	_decal.visible = false
	add_child(_decal)
	# Parked until fire(): an idle tick before the first use would age (and free) a burst
	# the caller is still configuring.
	set_process(false)


## Dust/smoke puff: soft, slow, hangs in place (damped) instead of flying away.
func _build_dust() -> void:
	_dust = GPUParticles3D.new()
	_dust.name = "Dust"
	_dust.one_shot = true
	_dust.explosiveness = 0.9
	_dust.amount = DUST_MAX
	_dust.lifetime = 0.7
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dust_pm = ParticleProcessMaterial.new()
	_dust_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_dust_pm.emission_sphere_radius = 0.07
	_dust_pm.direction = Vector3(0, 1, 0)
	_dust_pm.spread = 50.0
	_dust_pm.gravity = Vector3(0, -0.7, 0)  # dust hangs and settles, it does not fall
	_dust_pm.damping_min = 1.5
	_dust_pm.damping_max = 3.5
	_dust_pm.angle_min = -180.0
	_dust_pm.angle_max = 180.0
	_dust.process_material = _dust_pm
	_dust.draw_pass_1 = _sprite_quad(0.24, _puff_texture())
	add_child(_dust)
	_dust.emitting = false


## Grit pass: the material's SOLID bits — sparks, crumbs, shards, splinters.
func _build_grit() -> void:
	_grit = GPUParticles3D.new()
	_grit.name = "Grit"
	_grit.one_shot = true
	_grit.explosiveness = 1.0
	_grit.amount = GRIT_MAX
	_grit.lifetime = 0.5
	_grit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_grit_pm = ParticleProcessMaterial.new()
	_grit_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_grit_pm.emission_sphere_radius = 0.05
	_grit_pm.direction = Vector3(0, 1, 0)
	_grit_pm.spread = 34.0
	_grit_pm.gravity = Vector3(0, -11.0, 0)
	_grit_pm.damping_min = 0.5
	_grit_pm.damping_max = 2.0
	_grit_pm.angular_velocity_min = -540.0
	_grit_pm.angular_velocity_max = 540.0
	_grit.process_material = _grit_pm
	var quad := _sprite_quad(0.13, _grit_texture())
	_grit_mat = quad.material as StandardMaterial3D
	_grit.draw_pass_1 = quad
	add_child(_grit)
	_grit.emitting = false


## Additive pop at the hit point — metal sparks and glass glints only.
func _build_flash() -> void:
	var fq := QuadMesh.new()
	fq.size = Vector2(0.4, 0.4)
	_flash = MeshInstance3D.new()
	_flash.name = "Flash"
	_flash.mesh = fq
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_flash_mat.albedo_texture = _glint_texture()
	_flash.material_override = _flash_mat
	_flash.visible = false
	add_child(_flash)


## The crit RING (D4.5): a thin additive annulus that snaps outward on the surface plane.
## Deliberately a ring and not a disc — an additive disc this size whites the frame out at
## point-blank range, which is the exact failure the extraction beacon's god-ray taught us.
## Built (hidden) for every pooled node so a crit never allocates mid-firefight; a normal
## surface impact just leaves it invisible and pays nothing but one parked MeshInstance3D.
func _build_ring() -> void:
	var rq := QuadMesh.new()
	rq.size = Vector2(RING_R0, RING_R0)
	_ring = MeshInstance3D.new()
	_ring.name = "CritRing"
	_ring.mesh = rq
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # the ring is a flat sheet, seen from both sides
	_ring_mat.albedo_texture = _ring_texture()
	_ring.material_override = _ring_mat
	_ring.visible = false
	add_child(_ring)


## One camera-facing sprite quad (mesh + its material). `vertex_color_use_as_albedo` lets
## the ParticleProcessMaterial's colour tint the shared texture, so one baked sprite serves
## every material without a per-hit material allocation. Blending starts at MIX; the grit
## pass flips its own to ADD per material (sparks/glints) in _apply_grit.
static func _sprite_quad(size: float, tex: Texture2D) -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # reads in the cold grade's shadows
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.albedo_texture = tex
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	quad.material = mat
	return quad


## Configure the burst BEFORE fire(): `normal` is the world-space surface normal (the cone
## axis), `material` an FXPool.MAT_* (use FXPool.material_of(hit_node)), `incoming` the
## shot direction, which reflects the spark cone off the surface when the caller knows it,
## and `weak` marks a WEAK-POINT hit — that swaps the ENTIRE material recipe for the gold
## crit burst (D4.5), so the call site only has to pass the flag it already knows.
## Every argument but the normal has a default — an old-style call still gets a sane burst,
## and omitting `weak` CLEARS a previous use's crit flag, which is what stops a pooled node
## from carrying gold sparks into the next wall it dresses.
func setup(
	normal: Vector3,
	material: int = FXPool.MAT_DEFAULT,
	incoming: Vector3 = Vector3.ZERO,
	weak: bool = false
) -> void:
	_normal = normal
	_mat_kind = material
	_incoming = incoming
	_weak = weak


## The crit flag on its own, for a call site that already configured the burst — the
## duck-typed `has_method("set_weakpoint")` shape FXPool already uses for `set_enemy_hit`.
## Call it AFTER setup(), which resets the flag.
func set_weakpoint(on: bool) -> void:
	_weak = on


## (Re)start at the current transform/config — the pool calls this on every reuse. The node
## must already be POSITIONED (the dirt recipe samples the biome at global_position).
func fire() -> void:
	_t = 0.0
	_decal_t = 0.0
	visible = true
	set_process(true)
	_apply()
	if _dust.amount_ratio > 0.0:
		_dust.restart()
	if _grit.amount_ratio > 0.0:
		_grit.restart()


## Write the material recipe into the (already built) emitters. Property writes only.
func _apply() -> void:
	# A crit OVERRIDES the surface material outright (KIND_WEAK is outside the MAT_* range,
	# so the biome-tint branch below is skipped for free — gold sparks, never sand).
	var kind: int = KIND_WEAK if _weak else _mat_kind
	var r := _recipe(kind)
	var n := _surface_normal()
	var dust_col: Color = r["dust_col"]
	var grit_col: Color = r["grit_col"]
	if kind == FXPool.MAT_DIRT:
		var biome := WorldBounds.biome_at(global_position.x, global_position.z)
		var tint: Color = _GROUND_TINT.get(biome, Color(0.44, 0.40, 0.34))
		dust_col = Color(tint.r, tint.g, tint.b, dust_col.a)
		grit_col = Color(tint.r * 0.65, tint.g * 0.65, tint.b * 0.65, grit_col.a)
	_apply_dust(r, n, dust_col)
	_apply_grit(r, n, grit_col)
	_apply_marks(r, n, grit_col)
	_apply_ring(r, n, grit_col)


func _apply_dust(r: Dictionary, n: Vector3, col: Color) -> void:
	var speed: float = r["dust_v"]
	var scale: float = r["dust_scale"]
	_dust.position = n * SURFACE_OFFSET
	_dust_pm.direction = n
	_dust_pm.spread = minf(float(r["spread"]) + DUST_SPREAD_BONUS, 85.0)
	_dust_pm.color = col
	_dust_pm.initial_velocity_min = speed * 0.3
	_dust_pm.initial_velocity_max = speed
	_dust_pm.scale_min = scale * 0.55
	_dust_pm.scale_max = scale * 1.5
	_dust.amount_ratio = _ratio(int(r["dust"]), DUST_MAX)


func _apply_grit(r: Dictionary, n: Vector3, col: Color) -> void:
	var speed: float = r["grit_v"]
	var scale: float = r["grit_scale"]
	var sprite := int(r["sprite"])
	_grit.position = n * SURFACE_OFFSET
	_grit_pm.direction = _spray_direction(n)
	_grit_pm.spread = float(r["spread"])
	_grit_pm.color = col
	_grit_pm.initial_velocity_min = speed * 0.4
	_grit_pm.initial_velocity_max = speed
	_grit_pm.gravity = Vector3(0.0, float(r["grit_g"]), 0.0)
	_grit_pm.scale_min = scale * 0.6
	_grit_pm.scale_max = scale * 1.3
	# A streak only reads as a streak when its long axis follows the velocity.
	_grit_pm.particle_flag_align_y = sprite == SPRITE_STREAK
	_grit.amount_ratio = _ratio(int(r["grit"]), GRIT_MAX)
	_grit_mat.albedo_texture = _sprite_texture(sprite)
	# Sparks/glints are ADDITIVE (they glow); crumbs and splinters are solid.
	if bool(r["add"]):
		_grit_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	else:
		_grit_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX


## The flash pop + the lingering surface mark. The decal is projected ALONG THE NORMAL —
## the old impact always projected straight down, which is right for floors and wrong for
## every wall (the scorch smeared across the ground below the hole).
func _apply_marks(r: Dictionary, n: Vector3, col: Color) -> void:
	var flash: float = r["flash"]
	_flash.visible = flash > 0.0
	if _flash.visible:
		(_flash.mesh as QuadMesh).size = Vector2(flash, flash)
		_flash.position = n * (SURFACE_OFFSET + 0.02)
		_flash_mat.albedo_color = Color(col.r, col.g, col.b, 1.0)
	var mark: Color = r["decal_col"]
	_decal_alpha = mark.a
	_decal.visible = _decal_alpha > 0.0
	if _decal.visible:
		var size: float = r["decal"]
		_decal.size = Vector3(size, 0.6, size)
		_decal.modulate = mark
		_decal.basis = _surface_basis(n)


## The crit ring is OPT-IN per recipe (the "ring" scale key, absent from every material
## recipe), so a normal surface impact costs exactly what it did before D4.5.
func _apply_ring(r: Dictionary, n: Vector3, col: Color) -> void:
	var ring: float = float(r.get("ring", 0.0))
	_ring_scale = ring
	_ring.visible = ring > 0.0
	if not _ring.visible:
		return
	# Sits proud of the flash quad so the two additive sheets never z-fight at the hit point.
	_ring.position = n * (SURFACE_OFFSET + 0.03)
	_ring.basis = _facing_basis(n)
	_ring_mat.albedo_color = Color(col.r, col.g, col.b, 1.0)
	(_ring.mesh as QuadMesh).size = Vector2.ONE * RING_R0 * ring


func _process(delta: float) -> void:
	_t += delta
	if _flash.visible:
		var pop := maxf(0.0, 1.0 - _t / FLASH_TIME)
		_flash_mat.albedo_color.a = pop
		if pop <= 0.0:
			_flash.visible = false  # a spent additive quad is still a transparent draw
	if _ring.visible:
		# Ease-OUT: the ring leaves fast and settles, the way a shock front does. A linear
		# expand reads as an inflating balloon and loses the "snap" the crit is there to sell.
		var rk: float = clampf(_t / RING_TIME, 0.0, 1.0)
		var span: float = lerpf(RING_R0, RING_R1, rk * (2.0 - rk)) * _ring_scale
		(_ring.mesh as QuadMesh).size = Vector2.ONE * span
		_ring_mat.albedo_color.a = (1.0 - rk) * (1.0 - rk)
		if rk >= 1.0:
			_ring.visible = false
	var decal_live := _decal != null and _decal.visible
	if decal_live:
		_decal_t += delta
		var k: float = clampf(_decal_t / DECAL_LIFETIME, 0.0, 1.0)
		_decal.modulate.a = _decal_alpha * (1.0 - k * k)  # holds, then fades off fast
		if _decal_t >= DECAL_LIFETIME:
			_decal.visible = false
			decal_live = false
	# Stay alive while either the burst or its mark still has work, then return to the pool.
	if _t >= LIFETIME and not decal_live:
		_finish()


func _finish() -> void:
	# Belt-and-braces: the pool can also STEAL a busy node (park, no _finish), but every
	# FXSprites call site goes through setup(), which resets the flag on its own.
	_weak = false
	if pooled and FXPool.active != null:
		FXPool.active.release(self)
	else:
		queue_free()


func _surface_normal() -> Vector3:
	if _normal.length() > 0.001:
		return _normal.normalized()
	return Vector3.UP


## Solid bits fly along the REFLECTION of the shot when the caller knows the incoming
## direction, blended halfway back to the normal so nothing ever sprays INTO the surface.
## With no incoming vector this is plain "out along the normal" (the documented default).
func _spray_direction(n: Vector3) -> Vector3:
	if _incoming.length() < 0.001:
		return n
	var i := _incoming.normalized()
	var refl := i - 2.0 * i.dot(n) * n
	var dir := (refl + n).normalized()
	if not dir.is_finite() or dir.dot(n) < 0.15:
		return n
	return dir


## Basis whose +Y is the surface normal: a Decal projects along its LOCAL -Y, so this aims
## the mark INTO the surface it was left on, wall or floor alike.
static func _surface_basis(n: Vector3) -> Basis:
	var up := n.normalized()
	var seed_axis := Vector3.RIGHT if absf(up.y) > 0.9 else Vector3.UP
	var x_axis := seed_axis.cross(up).normalized()
	return Basis(x_axis, up, x_axis.cross(up))


## Basis whose +Z is the surface normal — a QuadMesh faces its local +Z, so this STANDS the
## crit ring up on the surface instead of billboarding it. On a weak point the normal already
## points back down the shot, so it reads as a flat pop that still has real depth when the
## player strafes; a billboard would slide against the body it is supposed to be stuck to.
static func _facing_basis(n: Vector3) -> Basis:
	var fwd := n.normalized()
	var seed_axis := Vector3.RIGHT if absf(fwd.y) > 0.9 else Vector3.UP
	var x_axis := seed_axis.cross(fwd).normalized()
	return Basis(x_axis, fwd.cross(x_axis), fwd)


## Per-material count as an amount_ratio (never `amount` — that reallocates the buffer),
## thinned by the user's Particle Density slider like every other FX in the game. Floored
## at 0.15 of the recipe: an impact that renders NOTHING reads as a missed shot.
static func _ratio(count: int, cap: int) -> float:
	if count <= 0:
		return 0.0
	var density: Variant = SettingsManager.get_value("particle_density")
	var mult := 1.0
	if density != null:
		mult = clampf(float(density), 0.15, 1.0)
	return clampf(float(count) / float(cap), 0.0, 1.0) * mult


static func _sprite_texture(sprite: int) -> Texture2D:
	if sprite == SPRITE_STREAK:
		return _streak_texture()
	if sprite == SPRITE_GLINT:
		return _glint_texture()
	return _grit_texture()


## The per-material recipe. Built ONCE per process instead of living in a `const` so the
## FXPool.MAT_* keys stay a RUNTIME lookup (fx_pool loads this script by path — the class
## dependency must stay one-way). Tuned against the cold-cinematic grade: everything is
## unshaded, and the dark materials lean on count/size rather than brightness.
static func _recipe(kind: int) -> Dictionary:
	if _recipes.is_empty():
		_build_recipes()
	var r: Variant = _recipes.get(kind)
	if r is Dictionary:
		return r
	return _recipes[FXPool.MAT_DEFAULT]


static func _build_recipes() -> void:
	# Unknown surface: the pre-D4.4 neutral dust, only directional now.
	_recipes[FXPool.MAT_DEFAULT] = {
		"dust": 10,
		"dust_col": Color(0.62, 0.60, 0.55, 0.50),
		"dust_v": 2.2,
		"dust_scale": 1.0,
		"grit": 6,
		"grit_col": Color(0.55, 0.52, 0.47, 1.0),
		"grit_v": 4.0,
		"grit_scale": 0.8,
		"grit_g": -11.0,
		"sprite": SPRITE_GRIT,
		"add": false,
		"spread": 34.0,
		"flash": 0.0,
		"decal_col": Color(0.05, 0.05, 0.05, 0.50),
		"decal": 0.50,
	}
	# Concrete: a PALE dust cloud plus a lot of fine crumbs, and a chalky dust smudge.
	_recipes[FXPool.MAT_CONCRETE] = {
		"dust": 16,
		"dust_col": Color(0.78, 0.76, 0.71, 0.60),
		"dust_v": 2.6,
		"dust_scale": 1.35,
		"grit": 12,
		"grit_col": Color(0.72, 0.70, 0.65, 1.0),
		"grit_v": 4.6,
		"grit_scale": 0.55,
		"grit_g": -12.0,
		"sprite": SPRITE_GRIT,
		"add": false,
		"spread": 40.0,
		"flash": 0.0,
		"decal_col": Color(0.60, 0.58, 0.54, 0.55),
		"decal": 0.60,
	}
	# Metal: hot ADDITIVE spark streaks + a blink of a flash, almost no dust, small scorch.
	_recipes[FXPool.MAT_METAL] = {
		"dust": 4,
		"dust_col": Color(0.35, 0.33, 0.31, 0.35),
		"dust_v": 1.4,
		"dust_scale": 0.7,
		"grit": 14,
		"grit_col": Color(1.0, 0.72, 0.28, 1.0),
		"grit_v": 8.0,
		"grit_scale": 0.85,
		"grit_g": -9.0,
		"sprite": SPRITE_STREAK,
		"add": true,
		"spread": 30.0,
		"flash": 0.42,
		"decal_col": Color(0.04, 0.04, 0.045, 0.70),
		"decal": 0.35,
	}
	_build_recipes_earth()
	_build_recipes_brittle()
	_build_recipe_weak()


## Stone / dirt — the "dark dust" family (rock shards vs a soft biome-tinted ground splash).
static func _build_recipes_earth() -> void:
	_recipes[FXPool.MAT_STONE] = {
		"dust": 14,
		"dust_col": Color(0.44, 0.41, 0.37, 0.60),
		"dust_v": 2.0,
		"dust_scale": 1.25,
		"grit": 10,
		"grit_col": Color(0.40, 0.37, 0.33, 1.0),
		"grit_v": 4.2,
		"grit_scale": 1.1,
		"grit_g": -13.0,
		"sprite": SPRITE_GRIT,
		"add": false,
		"spread": 44.0,
		"flash": 0.0,
		"decal_col": Color(0.10, 0.09, 0.08, 0.50),
		"decal": 0.55,
	}
	# Ground: a wide low splash; dust_col/grit_col are OVERRIDDEN by the biome tint in _apply.
	_recipes[FXPool.MAT_DIRT] = {
		"dust": 16,
		"dust_col": Color(0.42, 0.36, 0.28, 0.60),
		"dust_v": 1.8,
		"dust_scale": 1.5,
		"grit": 8,
		"grit_col": Color(0.30, 0.26, 0.20, 1.0),
		"grit_v": 3.4,
		"grit_scale": 0.9,
		"grit_g": -14.0,
		"sprite": SPRITE_GRIT,
		"add": false,
		"spread": 55.0,
		"flash": 0.0,
		"decal_col": Color(0.06, 0.05, 0.04, 0.45),
		"decal": 0.65,
	}


## Glass / wood — the two "it shatters or splinters" surfaces.
static func _build_recipes_brittle() -> void:
	# Glass: bright ADDITIVE glinting crumbs + a tiny sparkle, and NO mark (the pane is gone).
	_recipes[FXPool.MAT_GLASS] = {
		"dust": 3,
		"dust_col": Color(0.80, 0.88, 0.95, 0.28),
		"dust_v": 1.2,
		"dust_scale": 0.6,
		"grit": 14,
		"grit_col": Color(0.85, 0.93, 1.0, 1.0),
		"grit_v": 5.5,
		"grit_scale": 0.7,
		"grit_g": -11.0,
		"sprite": SPRITE_GLINT,
		"add": true,
		"spread": 50.0,
		"flash": 0.30,
		"decal_col": Color(0.0, 0.0, 0.0, 0.0),
		"decal": 0.0,
	}
	_recipes[FXPool.MAT_WOOD] = {
		"dust": 8,
		"dust_col": Color(0.55, 0.44, 0.30, 0.50),
		"dust_v": 1.8,
		"dust_scale": 0.9,
		"grit": 10,
		"grit_col": Color(0.48, 0.35, 0.20, 1.0),
		"grit_v": 4.4,
		"grit_scale": 0.95,
		"grit_g": -12.0,
		"sprite": SPRITE_STREAK,
		"add": false,
		"spread": 32.0,
		"flash": 0.0,
		"decal_col": Color(0.08, 0.06, 0.04, 0.50),
		"decal": 0.40,
	}


## WEAK POINT (D4.5) — the crit read. GOLD, hotter/faster/wider than any surface burst, plus
## the snap ring, so a player knows they found the soft spot from peripheral vision alone
## without reading a damage number. The three deliberate departures from a material recipe:
## `add` sparks at nearly double the metal recipe's velocity (a crit should out-run its own
## impact), NO decal (this lands on a machine that is about to move or die — a scorch would
## hang in the air where the body used to be), and the "ring" key, which is what turns the
## generic burst into a crit and is absent from every other recipe.
static func _build_recipe_weak() -> void:
	_recipes[KIND_WEAK] = {
		"dust": 5,
		"dust_col": Color(1.0, 0.86, 0.55, 0.42),
		"dust_v": 2.6,
		"dust_scale": 0.85,
		"grit": 14,
		"grit_col": Color(1.0, 0.82, 0.34, 1.0),
		"grit_v": 10.5,
		"grit_scale": 1.15,
		"grit_g": -7.0,
		"sprite": SPRITE_STREAK,
		"add": true,
		"spread": 48.0,
		"flash": 0.55,
		"decal_col": Color(0.0, 0.0, 0.0, 0.0),
		"decal": 0.0,
		"ring": 1.0,
	}


# --- procedural sprites ------------------------------------------------------
# All five are WHITE with the shape in ALPHA: the particle colour (or the Decal modulate)
# supplies the tint, so one bake serves every material. ProcHash keeps the grain identical
# on every peer/run — same discipline as the rest of the procedural pipeline.


## Soft grainy smoke puff (32x32).
static func _puff_texture() -> ImageTexture:
	if _tex_puff != null:
		return _tex_puff
	var size := 32
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var d := _radius(x, y, size)
			var a := 1.0 - smoothstep(0.25, 1.0, d)
			a *= 0.6 + 0.4 * _grain(x, y, 4, 17)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	_tex_puff = ImageTexture.create_from_image(img)
	return _tex_puff


## Tapered spark streak (8x32): a white-hot head fading down a thin tail.
static func _streak_texture() -> ImageTexture:
	if _tex_streak != null:
		return _tex_streak
	var w := 8
	var h := 32
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var across := absf((x + 0.5) / float(w) * 2.0 - 1.0)
			var along := (y + 0.5) / float(h)
			var core := 1.0 - smoothstep(0.0, 0.85, across)
			var tail := 1.0 - smoothstep(0.05, 1.0, along)
			var a := core * core * tail
			a += (1.0 - smoothstep(0.0, 0.18, along)) * core * 0.6  # the hot head
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	_tex_streak = ImageTexture.create_from_image(img)
	return _tex_streak


## Angular crumb (16x16): a blob with 8 jittered facets so debris is not a circle.
static func _grit_texture() -> ImageTexture:
	if _tex_grit != null:
		return _tex_grit
	var size := 16
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := size * 0.5
	for y in size:
		for x in size:
			var v := Vector2((x + 0.5 - half) / half, (y + 0.5 - half) / half)
			var facet := int((atan2(v.y, v.x) + PI) / TAU * 8.0)
			var rad := 0.55 + 0.35 * ProcHash.hf(facet * 7919)
			var a := clampf((rad - v.length()) * half, 0.0, 1.0)
			a *= 0.8 + 0.2 * _grain(x, y, 2, 53)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_tex_grit = ImageTexture.create_from_image(img)
	return _tex_grit


## 4-point glint (32x32) — the shiny glass crumb / metal flash sprite.
static func _glint_texture() -> ImageTexture:
	if _tex_glint != null:
		return _tex_glint
	var size := 32
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := size * 0.5
	for y in size:
		for x in size:
			var v := Vector2((x + 0.5 - half) / half, (y + 0.5 - half) / half)
			var ax := absf(v.x)
			var ay := absf(v.y)
			var bar_h := maxf(1.0 - ay * 9.0, 0.0) * maxf(1.0 - ax * 1.15, 0.0)
			var bar_v := maxf(1.0 - ax * 9.0, 0.0) * maxf(1.0 - ay * 1.15, 0.0)
			var core := maxf(1.0 - v.length() * 3.4, 0.0)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(bar_h + bar_v + core * core, 0.0, 1.0)))
	_tex_glint = ImageTexture.create_from_image(img)
	return _tex_glint


## Soft grainy blob for the surface mark (32x32).
static func _scorch_texture() -> ImageTexture:
	if _tex_scorch != null:
		return _tex_scorch
	var size := 32
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var a := pow(clampf(1.0 - _radius(x, y, size), 0.0, 1.0), 1.7)
			a *= 0.55 + 0.45 * _grain(x, y, 4, 311)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	_tex_scorch = ImageTexture.create_from_image(img)
	return _tex_scorch


## Thin annulus (48²) for the crit ring — a soft two-sided falloff around r=0.70 plus a very
## faint core, so the sprite still has a centre at spawn size and never reads as a hole.
static func _ring_texture() -> ImageTexture:
	if _tex_ring != null:
		return _tex_ring
	var size := 48
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var d := _radius(x, y, size)
			var band := 1.0 - smoothstep(0.0, 0.30, absf(d - 0.70))
			var a := band * band
			a *= 0.72 + 0.28 * _grain(x, y, 3, 907)
			a += maxf(0.0, 1.0 - d * 1.7) * 0.10
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	_tex_ring = ImageTexture.create_from_image(img)
	return _tex_ring


## Normalized distance from the texture centre (1.0 at the edge midpoints).
static func _radius(x: int, y: int, size: int) -> float:
	var half := size * 0.5
	return Vector2(x + 0.5 - half, y + 0.5 - half).length() / half


## Blocky deterministic grain in [0,1] — `cell` px per block keeps it low-frequency (a
## per-pixel hash would read as TV static once the sprite is a few pixels on screen).
static func _grain(x: int, y: int, cell: int, seed_salt: int) -> float:
	var bx := floori(float(x) / float(cell))
	var by := floori(float(y) / float(cell))
	return ProcHash.hf(bx * 131 + by * 977 + seed_salt)
