class_name FXSprites
extends Node3D
## PER-MATERIAL bullet impact (D4.4): the burst a shot leaves in the WORLD, dressed by
## WHAT it hit and sprayed as a CONE off the surface normal. The old world impact was one
## grey 180-degree BALL for every surface — steel, concrete and dirt all read the same and
## the sparks ignored the wall they bounced off.
##
## Sprites are baked PROCEDURALLY in code (the ProcMaterials/ProcPlating discipline — no new
## art assets): a hot spark streak, an angular crumb, a wood sliver, a glass shard, a 4-point
## glint, a scorch blob, a ring — and the FLIPBOOK SHEETS (D4.4), a 4x4 grid of a growing,
## boiling, dissipating puff that turns every smoke/dust/fire pass in the game from a static
## blob that merely scales up into something that actually rolls. Each is built ONCE per
## process (static cache, ProcHash/FastNoiseLite grain → every peer bakes identical pixels)
## and shared by every instance.
##
## THIS FILE HOSTS THREE FX CLASSES, because they share that one bakery:
##   FXSprites  — the per-material bullet impact          (pool kind "surface_impact")
##   Boom       — the composite grenade blast, per type   (pool kind "explosion")
##   Streak     — the tracer v2 (hot head, fading tail)   (pool kind "tracer")
## All three are POOLED through FXPool with the same contract as Impact/GlassShatter: the
## pool sets `pooled`, `fire()` (re)starts it, end-of-life releases instead of freeing.
## Children + materials are built ONCE in _ready and a fire() only MUTATES properties — the
## per-recipe counts ride `amount_ratio`, because writing `amount` REALLOCATES the GPU
## particle buffer (exactly the per-shot allocation the pool exists to avoid).
##
## The material vocabulary (FXPool.MAT_*) deliberately lives in FXPool: the pool loads this
## script BY PATH (and its inner classes by NAME through that path), so the class dependency
## stays one-way (FXSprites -> FXPool) like every other pooled FX and no cyclic reference can
## form. Purely local/visual — never networked.

const SPRITE_GRIT := 0  # angular crumb — concrete / stone / dirt
const SPRITE_STREAK := 1  # hot tapered streak — metal sparks, embers
const SPRITE_GLINT := 2  # 4-point star — sparkles, ice crystals
const SPRITE_SPLINTER := 3  # long bent tapering sliver — wood
const SPRITE_SHARD := 4  # angular glass sliver with a sparkle core

## FLIPBOOK (D4.4). A 4x4 sheet of a puff's whole life: it expands, boils and dissipates
## across 16 frames, so ONE emitted particle plays an animation instead of being a frozen
## blob. Fed to the GPU via BaseMaterial3D.particles_anim_* (frame grid) + the process
## material's anim_speed/anim_offset (playhead) — see `animate_quad`.
## 40 px frames (a 160² sheet) is the deliberate size: these are 4-40 px on screen and the
## bake is a per-pixel GDScript loop that runs during the arena build, behind the loading
## screen (the pool is constructed there), not mid-firefight.
const SHEET_GRID := 4
const SHEET_FRAME := 40
const _NOISE_SZ := 64  # the seamless noise field the frames are carved out of

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
static var _tex_streak: ImageTexture = null
static var _tex_grit: ImageTexture = null
static var _tex_glint: ImageTexture = null
static var _tex_splinter: ImageTexture = null
static var _tex_shard: ImageTexture = null
static var _tex_scorch: ImageTexture = null
static var _tex_ring: ImageTexture = null
static var _tex_smoke_sheet: ImageTexture = null
static var _tex_fire_sheet: ImageTexture = null
static var _recipes: Dictionary = {}

var pooled := false  # set by FXPool; end-of-life releases instead of freeing
var _t := 0.0
var _life := LIFETIME  # LIFETIME, or the material's longer-hanging dust — see _apply_dust
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


## Dust/smoke puff: soft, slow, hangs in place (damped) instead of flying away, and since
## D4.4 it PLAYS the flipbook — a puff that rolls and thins out, not a quad that scales up.
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
	# Playhead: one pass through the 16 frames over the particle's own lifetime. The small
	# offset spread stops a burst's puffs from boiling in lockstep (they'd read as one sprite).
	_dust_pm.anim_speed_min = 1.0
	_dust_pm.anim_speed_max = 1.0
	_dust_pm.anim_offset_min = 0.0
	_dust_pm.anim_offset_max = 0.10
	_dust.process_material = _dust_pm
	# 0.30, not the 0.24 of the static blob: a flipbook frame only fills its quad at the END
	# of the roll, so the same authored scale reads smaller than the old always-full sprite.
	var quad := sprite_quad(0.30, smoke_sheet())
	animate_quad(quad)
	_dust.draw_pass_1 = quad
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
	var quad := sprite_quad(0.13, _grit_texture())
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
	_ring_mat.albedo_texture = ring_texture()
	_ring.material_override = _ring_mat
	_ring.visible = false
	add_child(_ring)


## One camera-facing sprite quad (mesh + its material). `vertex_color_use_as_albedo` lets
## the ParticleProcessMaterial's colour tint the shared texture, so one baked sprite serves
## every material without a per-hit material allocation. Blending starts at MIX; the grit
## pass flips its own to ADD per material (sparks/glints) in _apply_grit.
## PUBLIC because the two sibling FX classes at the foot of this file build their passes the
## same way — one quad recipe, not three copies (the AUDIT-F1 rule).
static func sprite_quad(size: float, tex: Texture2D) -> QuadMesh:
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


## Turn a sprite quad into a FLIPBOOK reader (the sheet's frame grid). GOTCHA: Godot only
## honours particles_anim_* under BILLBOARD_PARTICLES — under any other billboard mode the
## animation is silently ignored and you get frame 0 forever. `sprite_quad` already sets it;
## this stays a separate call so the non-animated passes (grit/sparks) pay nothing.
static func animate_quad(quad: QuadMesh) -> void:
	var mat := quad.material as StandardMaterial3D
	if mat == null:
		return
	mat.particles_anim_h_frames = SHEET_GRID
	mat.particles_anim_v_frames = SHEET_GRID
	mat.particles_anim_loop = false  # one pass through the puff's life, then it is gone


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
	# HOW LONG the dust hangs is per material and is half of what tells concrete from steel:
	# a concrete strike leaves a cloud you have to shoot through, a metal strike is over before
	# you blink. The node's own life follows it, or the burst would be released mid-cloud.
	var dust_life: float = float(r.get("dust_life", 0.7))
	_dust.lifetime = dust_life
	_life = maxf(LIFETIME, dust_life + 0.15)
	_dust.position = n * SURFACE_OFFSET
	_dust_pm.direction = n
	_dust_pm.spread = minf(float(r["spread"]) + DUST_SPREAD_BONUS, 85.0)
	_dust_pm.color = col
	_dust_pm.initial_velocity_min = speed * 0.3
	_dust_pm.initial_velocity_max = speed
	_dust_pm.scale_min = scale * 0.55
	_dust_pm.scale_max = scale * 1.5
	_dust.amount_ratio = density_ratio(int(r["dust"]), DUST_MAX)


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
	# Size VARIANCE is per material and is most of what makes debris identifiable: dirt throws
	# fat clods alongside fine grains (var 0.85), machined metal throws near-uniform sparks
	# (0.25). One emitter, two читаемых size classes — cheaper than a second particle pass.
	var spread_k: float = float(r.get("grit_var", 0.3))
	_grit_pm.scale_min = scale * maxf(0.15, 1.0 - spread_k)
	_grit_pm.scale_max = scale * (1.0 + spread_k)
	# A sliver only reads as a sliver when its long axis follows the velocity; crumbs, shards
	# and glints tumble instead (the angular velocity set in _build_grit).
	_grit_pm.particle_flag_align_y = sprite == SPRITE_STREAK or sprite == SPRITE_SPLINTER
	_grit.amount_ratio = density_ratio(int(r["grit"]), GRIT_MAX)
	_grit_mat.albedo_texture = sprite_texture(sprite)
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
		# The pop is WHITE-hot on struck metal even though its sparks are orange, and cold on
		# glass — a blik that takes the debris colour reads as "more sparks", not as a strike.
		var flash_col: Color = r.get("flash_col", Color(col.r, col.g, col.b, 1.0))
		_flash_mat.albedo_color = Color(flash_col.r, flash_col.g, flash_col.b, 1.0)
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
	if _t >= _life and not decal_live:
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


## Per-recipe count as an amount_ratio (never `amount` — that reallocates the buffer),
## thinned by the user's Particle Density slider like every other FX in the game. Floored
## at 0.15 of the recipe: an impact that renders NOTHING reads as a missed shot.
## PUBLIC: Boom/Streak thin their passes through this same one implementation.
static func density_ratio(count: int, cap: int) -> float:
	if count <= 0:
		return 0.0
	var density: Variant = SettingsManager.get_value("particle_density")
	var mult := 1.0
	if density != null:
		mult = clampf(float(density), 0.15, 1.0)
	return clampf(float(count) / float(cap), 0.0, 1.0) * mult


## SPRITE_* -> the baked sprite. Public: the blast's spark cone picks its debris shape from
## the same five sprites the impacts do (embers = streak, ice = glint, ...).
static func sprite_texture(sprite: int) -> Texture2D:
	if sprite == SPRITE_STREAK:
		return _streak_texture()
	if sprite == SPRITE_GLINT:
		return _glint_texture()
	if sprite == SPRITE_SPLINTER:
		return _splinter_texture()
	if sprite == SPRITE_SHARD:
		return _shard_texture()
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
		"grit_var": 0.30,
		"spread": 34.0,
		"flash": 0.0,
		"decal_col": Color(0.05, 0.05, 0.05, 0.50),
		"decal": 0.50,
	}
	# Concrete: a BILLOWING pale dust cloud (the widest, longest-lived of the six) plus a lot
	# of fine crumbs with a couple of bigger chips, and a chalky dust smudge.
	_recipes[FXPool.MAT_CONCRETE] = {
		"dust": 16,
		"dust_life": 1.15,
		"dust_col": Color(0.80, 0.78, 0.73, 0.66),
		"dust_v": 2.6,
		"dust_scale": 1.55,
		"grit": 12,
		"grit_col": Color(0.72, 0.70, 0.65, 1.0),
		"grit_v": 4.6,
		"grit_scale": 0.55,
		"grit_g": -12.0,
		"sprite": SPRITE_GRIT,
		"add": false,
		"grit_var": 0.50,
		"spread": 40.0,
		"flash": 0.0,
		"decal_col": Color(0.60, 0.58, 0.54, 0.55),
		"decal": 0.60,
	}
	# Metal: a tight SHEAF of hot additive spark streaks (uniform size, the fastest of the six)
	# + a white-hot blik, almost no dust, small scorch.
	_recipes[FXPool.MAT_METAL] = {
		"dust": 4,
		"dust_life": 0.35,
		"dust_col": Color(0.35, 0.33, 0.31, 0.35),
		"dust_v": 1.4,
		"dust_scale": 0.7,
		"grit": 14,
		"grit_col": Color(1.0, 0.72, 0.28, 1.0),
		"grit_v": 9.0,
		"grit_scale": 0.85,
		"grit_g": -9.0,
		"sprite": SPRITE_STREAK,
		"add": true,
		"grit_var": 0.22,
		"spread": 26.0,
		"flash": 0.42,
		"flash_col": Color(1.0, 0.96, 0.88, 1.0),
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
		"dust_life": 0.95,
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
		"grit_var": 0.55,  # rock breaks into a few big shards among the dust
		"spread": 44.0,
		"flash": 0.0,
		"decal_col": Color(0.10, 0.09, 0.08, 0.50),
		"decal": 0.55,
	}
	# Ground: a wide low splash of CLODS (grit_var 0.85 = fat lumps next to fine grains) under
	# a soft dust skirt; dust_col/grit_col are OVERRIDDEN by the biome tint in _apply.
	_recipes[FXPool.MAT_DIRT] = {
		"dust": 16,
		"dust_life": 0.85,
		"dust_col": Color(0.42, 0.36, 0.28, 0.60),
		"dust_v": 1.8,
		"dust_scale": 1.6,
		"grit": 10,
		"grit_col": Color(0.30, 0.26, 0.20, 1.0),
		"grit_v": 3.4,
		"grit_scale": 1.0,
		"grit_g": -14.0,
		"sprite": SPRITE_GRIT,
		"add": false,
		"grit_var": 0.85,
		"spread": 55.0,
		"flash": 0.0,
		"decal_col": Color(0.06, 0.05, 0.04, 0.45),
		"decal": 0.65,
	}


## Glass / wood — the two "it shatters or splinters" surfaces.
static func _build_recipes_brittle() -> void:
	# Glass: tumbling ADDITIVE SHARDS (angular slivers with a sparkle core) thrown wide, a cold
	# blik, and NO mark (the pane is gone — a scorch would hang in an empty window frame).
	_recipes[FXPool.MAT_GLASS] = {
		"dust": 3,
		"dust_life": 0.40,
		"dust_col": Color(0.80, 0.88, 0.95, 0.28),
		"dust_v": 1.2,
		"dust_scale": 0.6,
		"grit": 14,
		"grit_col": Color(0.85, 0.93, 1.0, 1.0),
		"grit_v": 5.5,
		"grit_scale": 0.75,
		"grit_g": -11.0,
		"sprite": SPRITE_SHARD,
		"add": true,
		"grit_var": 0.45,
		"spread": 52.0,
		"flash": 0.30,
		"flash_col": Color(0.86, 0.95, 1.0, 1.0),
		"decal_col": Color(0.0, 0.0, 0.0, 0.0),
		"decal": 0.0,
	}
	# Wood: SPLINTERS — long bent slivers flying tip-first (align_y) in a narrow cone, with a
	# puff of tan sawdust. Solid, never additive: wood does not spark.
	_recipes[FXPool.MAT_WOOD] = {
		"dust": 8,
		"dust_life": 0.60,
		"dust_col": Color(0.55, 0.44, 0.30, 0.50),
		"dust_v": 1.8,
		"dust_scale": 0.9,
		"grit": 11,
		"grit_col": Color(0.48, 0.35, 0.20, 1.0),
		"grit_v": 4.4,
		"grit_scale": 1.15,
		"grit_g": -12.0,
		"sprite": SPRITE_SPLINTER,
		"add": false,
		"grit_var": 0.50,
		"spread": 30.0,
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
# All of them are WHITE with the shape in ALPHA: the particle colour (or the Decal modulate)
# supplies the tint, so one bake serves every material — and one flipbook serves concrete
# dust, a frag's smoke column and a cryo bloom alike. ProcHash/FastNoiseLite keep the grain
# identical on every peer/run — same discipline as the rest of the procedural pipeline.


## The SMOKE flipbook: 16 frames of a puff expanding, boiling and thinning out. Baked once
## per process. Used by the impact dust and by every Boom smoke column.
static func smoke_sheet() -> ImageTexture:
	if _tex_smoke_sheet == null:
		_tex_smoke_sheet = _bake_sheet(false)
	return _tex_smoke_sheet


## The FIRE flipbook: the same construction, but it blows out fast and keeps a hard hot core
## instead of billowing. White + alpha like everything else here, so ONE bake serves an orange
## frag fireball, a blue EMP bloom and a white cryo burst — the emitter supplies the hue.
static func fire_sheet() -> ImageTexture:
	if _tex_fire_sheet == null:
		_tex_fire_sheet = _bake_sheet(true)
	return _tex_fire_sheet


## Carve the 4x4 sheet out of one seamless noise field: per frame the blob GROWS, its edge
## gets noisier and softer, the pattern drifts upward (so the puff appears to roll), and the
## dissipation is baked into the alpha — a particle that simply dies at lifetime end would pop.
static func _bake_sheet(hot: bool) -> ImageTexture:
	var n := SHEET_FRAME
	var img := Image.create(SHEET_GRID * n, SHEET_GRID * n, false, Image.FORMAT_RGBA8)
	var nseed := 3117
	var freq := 0.050  # fire tears into finer tongues than smoke does
	if not hot:
		nseed = 8629
		freq = 0.035
	var field := _noise_field(nseed, freq)
	var frames := SHEET_GRID * SHEET_GRID
	for fy in SHEET_GRID:
		for fx in SHEET_GRID:
			var idx := fy * SHEET_GRID + fx
			_bake_frame(img, field, fx * n, fy * n, float(idx) / float(frames - 1), hot)
	return ImageTexture.create_from_image(img)


## One flipbook frame at age `t` (0 = born, 1 = gone), written into the sheet at (ox, oy).
static func _bake_frame(
	img: Image, field: PackedByteArray, ox: int, oy: int, t: float, hot: bool
) -> void:
	var n := SHEET_FRAME
	var half := n * 0.5
	var grow := 1.0 - pow(1.0 - t, 2.0)  # ease-out: fast bloom, slow drift
	var rad: float = lerpf(0.22, 0.94, grow) if not hot else lerpf(0.20, 0.78, grow)
	var edge: float = lerpf(0.12, 0.42, t) if not hot else lerpf(0.16, 0.55, t)
	var turb: float = lerpf(0.06, 0.30, t)
	var age: float = pow(1.0 - t, 1.15) if not hot else pow(1.0 - t, 1.9)
	var zoom := 1.0 / (0.55 + grow * 0.95)  # features grow WITH the puff, not with the quad
	var rise := t * 26.0  # the pattern climbs => the smoke reads as rolling upward
	for y in n:
		for x in n:
			var px := (x + 0.5 - half) / half
			var py := (y + 0.5 - half) / half
			var w := _nsample(field, px * zoom * 21.0 + 9.0, py * zoom * 21.0 - rise)
			var d := sqrt(px * px + py * py) + (w - 0.5) * turb * 2.0
			var a := 1.0 - smoothstep(rad - edge, rad + edge, d)
			a *= 0.42 + 0.58 * w  # holes and boils, so the blob is not a solid disc
			if hot:
				# The core stays white-hot while the shell tears apart around it.
				a = maxf(a, maxf(0.0, 1.0 - d / maxf(rad * 0.5, 0.01)) * pow(1.0 - t, 1.3))
			var shade: float = 1.0 if hot else 0.60 + 0.40 * w
			img.set_pixel(ox + x, oy + y, Color(shade, shade, shade, clampf(a * age, 0.0, 1.0)))


## A seamless grayscale noise field as raw bytes — FastNoiseLite does the octaves in C++ and
## `get_data()` hands back a flat array we can index, which is what keeps the 16-frame bake
## from becoming 25k GDScript noise calls. Fixed seed => byte-identical on every peer.
static func _noise_field(nseed: int, freq: float) -> PackedByteArray:
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.seed = nseed
	fn.frequency = freq
	fn.fractal_octaves = 3
	fn.fractal_gain = 0.5
	var img := fn.get_seamless_image(_NOISE_SZ, _NOISE_SZ)
	img.convert(Image.FORMAT_L8)
	return img.get_data()


## Bilinear sample of the wrapped noise field, in [0,1].
static func _nsample(field: PackedByteArray, fx: float, fy: float) -> float:
	var x0 := floori(fx)
	var y0 := floori(fy)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var a := lerpf(_nfetch(field, x0, y0), _nfetch(field, x0 + 1, y0), tx)
	var b := lerpf(_nfetch(field, x0, y0 + 1), _nfetch(field, x0 + 1, y0 + 1), tx)
	return lerpf(a, b, ty)


## One wrapped texel of the noise field, in [0,1]. `& (_NOISE_SZ - 1)` needs a power-of-two
## field — 64 is exactly that, and the seamless bake means the wrap has no visible seam.
static func _nfetch(field: PackedByteArray, x: int, y: int) -> float:
	var i := (y & (_NOISE_SZ - 1)) * _NOISE_SZ + (x & (_NOISE_SZ - 1))
	if i < 0 or i >= field.size():
		return 0.5
	return float(field[i]) / 255.0


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


## Wood SPLINTER (8x32): a long sliver that TAPERS to a point along a slight S-bend, with a
## ragged edge. Deliberately not the spark streak — a splinter has no hot head, and reusing
## the streak was why a shot into a tree read as "sparks off metal, but brown".
static func _splinter_texture() -> ImageTexture:
	if _tex_splinter != null:
		return _tex_splinter
	var w := 8
	var h := 32
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var along := (y + 0.5) / float(h)
			var bend := sin(along * PI * 1.25) * 0.20
			var across := (x + 0.5) / float(w) * 2.0 - 1.0 - bend
			var wide := lerpf(0.80, 0.10, along) * (0.72 + 0.28 * _grain(x, y, 3, 613))
			var a := clampf((wide - absf(across)) * float(w) * 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_tex_splinter = ImageTexture.create_from_image(img)
	return _tex_splinter


## Glass SHARD (24x24): an angular tapering sliver at ~30 degrees with a sparkle at its
## centre — a crumb of glass is a FLAKE that catches the light, so it needs both the flat
## body (which the 4-point glint lacks) and the highlight (which a plain crumb lacks).
static func _shard_texture() -> ImageTexture:
	if _tex_shard != null:
		return _tex_shard
	var size := 24
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := size * 0.5
	for y in size:
		for x in size:
			var v := Vector2((x + 0.5 - half) / half, (y + 0.5 - half) / half)
			var rx := v.x * 0.866 - v.y * 0.5
			var ry := v.x * 0.5 + v.y * 0.866
			var wide := lerpf(0.66, 0.04, clampf(ry * 0.5 + 0.5, 0.0, 1.0))
			var body := clampf((wide - absf(rx)) * half * 0.6, 0.0, 1.0)
			body *= 1.0 - smoothstep(0.72, 1.0, absf(ry))
			var spark := maxf(0.0, 1.0 - v.length() * 2.4)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(body * 0.85 + spark * spark, 0.0, 1.0)))
	_tex_shard = ImageTexture.create_from_image(img)
	return _tex_shard


## 4-point glint (32x32) — the shiny sparkle / ice crystal / muzzle-blik sprite.
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
## PUBLIC: the blast shock-front is the same annulus at a much larger scale (an additive DISC
## that size whites the frame out at point-blank — the extraction beacon's god-ray lesson).
static func ring_texture() -> ImageTexture:
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


# --- the grenade blast (D4.4) ------------------------------------------------


## THE COMPOSITE BLAST — pooled through FXPool as the "explosion" kind, keyed by the thrower's
## own `grenade_type` string ("frag"/"emp"/"smoke"/"incendiary"/"cryo"/"decoy"), so no new
## vocabulary has to be invented or kept in sync.
##
## Why a composite: the old one-scene explosion fired the SAME orange spark ball + grey puff
## for every grenade, so at a glance an EMP, a cryo and a frag were indistinguishable — you
## could not tell what had just gone off at your feet, which is the one thing a blast FX
## exists to communicate. Here each type owns colour, shape, count AND duration across three
## separately-tuned passes:
##   fireball  — SHORT and (usually) additive, the flipbook fire sheet: the detonation itself
##   smoke     — LONG and always ALPHA/MIX, the flipbook smoke sheet: what it leaves behind
##   sparks    — the debris cone, drawing its shape from the shared sprite set
## plus a rate-limited flash light and one thin shock RING.
##
## Two hard rules encoded here. The smoke column is MIX and never additive — a big additive
## volume in front of the camera whites the whole frame out (the extraction beacon's god-ray
## lesson), and smoke is the one pass that lives long enough to end up in your face. And the
## light asks FXPool.claim_light() first: a cluster of grenades must cost ONE light, not six
## (BreakableChunk's crumble-flash stamp, generalized).
class Boom:
	extends Node3D

	const FIRE_MAX := 22  # fixed GPU buffers — per-type counts ride amount_ratio
	const SMOKE_MAX := 26
	const SPARK_MAX := 30
	const BASE_RADIUS := 5.5  # the radius the recipes are authored at; a call site scales it
	const RING_TIME := 0.36
	const RING_R0 := 0.6
	const LIGHT_TIME := 0.16
	const LIGHT_GAP_MS := 60  # a 3-grenade cluster inside 60 ms is ONE light, not three
	const LIGHT_DIST := 70.0

	static var _recipes: Dictionary = {}

	var pooled := false  # set by FXPool; end-of-life releases instead of freeing
	var _t := 0.0
	var _life := 2.6
	var _scale := 1.0  # blast radius / BASE_RADIUS
	var _r: Dictionary = {}
	var _fire: GPUParticles3D
	var _fire_pm: ParticleProcessMaterial
	var _fire_mat: StandardMaterial3D
	var _smoke: GPUParticles3D
	var _smoke_pm: ParticleProcessMaterial
	var _sparks: GPUParticles3D
	var _sparks_pm: ParticleProcessMaterial
	var _sparks_mat: StandardMaterial3D
	var _light: OmniLight3D
	var _light_e := 0.0
	var _ring: MeshInstance3D
	var _ring_mat: StandardMaterial3D
	var _ring_span := 0.0

	func _ready() -> void:
		_fire = _build_pass(FIRE_MAX, 0.4, 1.0, FXSprites.fire_sheet())
		_fire_pm = _fire.process_material as ParticleProcessMaterial
		_fire_mat = (_fire.draw_pass_1 as QuadMesh).material as StandardMaterial3D
		_smoke = _build_pass(SMOKE_MAX, 2.0, 0.75, FXSprites.smoke_sheet())
		_smoke_pm = _smoke.process_material as ParticleProcessMaterial
		_sparks = _build_sparks()
		_build_light()
		_build_ring()
		# Parked until fire(): an idle tick would age (and release) a blast the caller is
		# still configuring — the same trap FXSprites documents.
		set_process(false)

	## One flipbook particle pass (fireball or smoke column). `explos` staggers the emission:
	## the fireball is instant (1.0), the smoke rolls out over a beat (0.75).
	func _build_pass(cap: int, life: float, explos: float, sheet: Texture2D) -> GPUParticles3D:
		var p := GPUParticles3D.new()
		p.one_shot = true
		p.explosiveness = explos
		p.amount = cap
		p.lifetime = life
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.5
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 180.0
		pm.damping_min = 0.4
		pm.damping_max = 1.6
		pm.angle_min = -180.0
		pm.angle_max = 180.0
		pm.anim_speed_min = 1.0
		pm.anim_speed_max = 1.0
		pm.anim_offset_min = 0.0
		pm.anim_offset_max = 0.18
		p.process_material = pm
		var quad := FXSprites.sprite_quad(1.0, sheet)
		FXSprites.animate_quad(quad)
		p.draw_pass_1 = quad
		add_child(p)
		p.emitting = false
		return p

	## The debris cone — solid sprites, no flipbook (a spark is a shape, not a puff).
	func _build_sparks() -> GPUParticles3D:
		var p := GPUParticles3D.new()
		p.one_shot = true
		p.explosiveness = 1.0
		p.amount = SPARK_MAX
		p.lifetime = 0.7
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_sparks_pm = ParticleProcessMaterial.new()
		_sparks_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		_sparks_pm.emission_sphere_radius = 0.25
		_sparks_pm.direction = Vector3(0, 1, 0)
		_sparks_pm.spread = 180.0
		_sparks_pm.damping_min = 0.2
		_sparks_pm.damping_max = 1.2
		_sparks_pm.angular_velocity_min = -420.0
		_sparks_pm.angular_velocity_max = 420.0
		p.process_material = _sparks_pm
		var quad := FXSprites.sprite_quad(0.22, FXSprites.sprite_texture(FXSprites.SPRITE_STREAK))
		_sparks_mat = quad.material as StandardMaterial3D
		_sparks_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		p.draw_pass_1 = quad
		add_child(p)
		p.emitting = false
		return p

	func _build_light() -> void:
		_light = OmniLight3D.new()
		_light.shadow_enabled = false
		_light.light_energy = 0.0
		add_child(_light)

	## The shock front: a thin billboarded ANNULUS, never a disc (see the class docs).
	func _build_ring() -> void:
		var rq := QuadMesh.new()
		rq.size = Vector2(RING_R0, RING_R0)
		_ring = MeshInstance3D.new()
		_ring.mesh = rq
		_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ring_mat = StandardMaterial3D.new()
		_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_ring_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_ring_mat.albedo_texture = FXSprites.ring_texture()
		_ring.material_override = _ring_mat
		_ring.visible = false
		add_child(_ring)

	## Configure BEFORE fire(). `kind` is the grenade's own `grenade_type`; `radius` is the
	## gameplay blast radius (<= 0 keeps the recipe's authored size).
	func setup(kind: String, radius: float = 0.0) -> void:
		_r = _recipe(kind)
		_scale = 1.0
		if radius > 0.0:
			_scale = clampf(radius / BASE_RADIUS, 0.35, 3.0)
		# The node must outlive its LONGEST pass. With explosiveness < 1 the emitter keeps
		# emitting for (1 - explosiveness) of its lifetime, so the last smoke puff is still
		# being BORN a beat after `smoke_life` — releasing on the authored life alone snips
		# the stragglers off mid-air. Derived, not hand-tuned per recipe, so a future tuning
		# pass cannot reintroduce the bug by raising smoke_life and forgetting `life`.
		_life = maxf(float(_r["life"]), float(_r["smoke_life"]) * 1.3 + 0.15)

	## (Re)start at the current transform/config — the pool calls this on every reuse.
	func fire() -> void:
		if _r.is_empty():
			setup("frag")
		_t = 0.0
		visible = true
		set_process(true)
		_apply()
		# ALWAYS restart, even a pass this type does not use (fire/sparks are 0 for a smoke
		# grenade): restart CLEARS the buffer, and a node STOLEN by the pool mid-life would
		# otherwise carry the previous blast's live particles into the next detonation.
		_fire.restart()
		_smoke.restart()
		_sparks.restart()

	## Write the type recipe into the (already built) emitters. Property writes only.
	func _apply() -> void:
		_apply_fire()
		_apply_smoke()
		_apply_sparks()
		_apply_light()
		_apply_ring()

	func _apply_fire() -> void:
		var v: float = float(_r["fire_v"]) * _scale
		_fire.lifetime = float(_r["fire_life"])
		_fire.amount_ratio = FXSprites.density_ratio(int(_r["fire"]), FIRE_MAX)
		_fire_pm.emission_sphere_radius = 0.35 * _scale
		_fire_pm.spread = float(_r["fire_spread"])
		_fire_pm.color = _r["fire_col"]
		_fire_pm.initial_velocity_min = v * 0.35
		_fire_pm.initial_velocity_max = v
		_fire_pm.gravity = Vector3(0.0, float(_r["fire_g"]), 0.0)
		_fire_pm.scale_min = float(_r["fire_scale"]) * 0.6 * _scale
		_fire_pm.scale_max = float(_r["fire_scale"]) * 1.4 * _scale
		# Cryo's "fireball" is a frost bloom: a CLOUD, so it blends MIX like the smoke does.
		if bool(_r["fire_add"]):
			_fire_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		else:
			_fire_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX

	func _apply_smoke() -> void:
		var v: float = float(_r["smoke_v"]) * _scale
		_smoke.lifetime = float(_r["smoke_life"])
		_smoke.amount_ratio = FXSprites.density_ratio(int(_r["smoke"]), SMOKE_MAX)
		_smoke_pm.emission_sphere_radius = 0.45 * _scale
		_smoke_pm.spread = 110.0
		_smoke_pm.color = _r["smoke_col"]
		_smoke_pm.initial_velocity_min = v * 0.3
		_smoke_pm.initial_velocity_max = v
		_smoke_pm.gravity = Vector3(0.0, float(_r["smoke_g"]), 0.0)
		_smoke_pm.scale_min = float(_r["smoke_scale"]) * 0.55 * _scale
		_smoke_pm.scale_max = float(_r["smoke_scale"]) * 1.35 * _scale

	func _apply_sparks() -> void:
		var v: float = float(_r["spark_v"]) * _scale
		_sparks.lifetime = float(_r["spark_life"])
		_sparks.amount_ratio = FXSprites.density_ratio(int(_r["spark"]), SPARK_MAX)
		_sparks_pm.color = _r["spark_col"]
		_sparks_pm.initial_velocity_min = v * 0.4
		_sparks_pm.initial_velocity_max = v
		_sparks_pm.gravity = Vector3(0.0, float(_r["spark_g"]), 0.0)
		_sparks_pm.scale_min = float(_r["spark_scale"]) * 0.7
		_sparks_pm.scale_max = float(_r["spark_scale"]) * 1.4
		var sprite := int(_r["spark_sprite"])
		_sparks_pm.particle_flag_align_y = sprite == FXSprites.SPRITE_STREAK
		_sparks_mat.albedo_texture = FXSprites.sprite_texture(sprite)

	## The flash. Rate-limited AND distance-gated: real lights are the most expensive thing a
	## per-event FX can ask for, and a blast 70 m away lights nothing the player can see.
	func _apply_light() -> void:
		_light_e = float(_r["light_e"])
		if _light_e > 0.0 and _camera_dist() > LIGHT_DIST:
			_light_e = 0.0
		if _light_e > 0.0 and not FXPool.claim_light(LIGHT_GAP_MS):
			_light_e = 0.0
		_light.light_color = _r["light_col"]
		_light.omni_range = float(_r["light_r"]) * _scale
		_light.light_energy = _light_e

	func _apply_ring() -> void:
		_ring_span = float(_r["ring_span"]) * _scale
		_ring.visible = _ring_span > 0.0
		if not _ring.visible:
			return
		_ring_mat.albedo_color = _r["ring_col"]
		(_ring.mesh as QuadMesh).size = Vector2.ONE * RING_R0

	func _process(delta: float) -> void:
		_t += delta
		if _light_e > 0.0:
			# Blow-out then hard decay — a blast lights the room for a sixth of a second.
			var lk := clampf(_t / LIGHT_TIME, 0.0, 1.0)
			_light.light_energy = _light_e * (1.0 - lk) * (1.0 - lk)
			if lk >= 1.0:
				_light_e = 0.0
				_light.light_energy = 0.0
		if _ring.visible:
			# Ease-OUT: the front leaves fast and settles. A linear expand reads as a balloon.
			var rk := clampf(_t / RING_TIME, 0.0, 1.0)
			var span: float = lerpf(RING_R0, _ring_span, rk * (2.0 - rk))
			(_ring.mesh as QuadMesh).size = Vector2.ONE * span
			_ring_mat.albedo_color.a = (1.0 - rk) * (1.0 - rk)
			if rk >= 1.0:
				_ring.visible = false
		if _t >= _life:
			_finish()

	func _finish() -> void:
		_light.light_energy = 0.0
		if pooled and FXPool.active != null:
			FXPool.active.release(self)
		else:
			queue_free()

	## Distance to the LOCAL camera; 0.0 when there is no camera yet (a boot frame is not a
	## reason to swallow the flash) — mirrors FXPool._within_fx_range's "unknown => allow".
	func _camera_dist() -> float:
		var vp := get_viewport()
		if vp == null:
			return 0.0
		var cam := vp.get_camera_3d()
		if cam == null:
			return 0.0
		return cam.global_position.distance_to(global_position)

	static func _recipe(kind: String) -> Dictionary:
		if _recipes.is_empty():
			_build_recipes()
		var r: Variant = _recipes.get(kind)
		if r is Dictionary:
			return r
		return _recipes["frag"]

	## Every key a blast recipe needs, at the FRAG values. Each type then overrides ONLY what
	## makes it that type — so the override block below IS the readable answer to "how does a
	## cryo blast differ from a frag", instead of six near-identical 28-line tables.
	static func _base() -> Dictionary:
		return {
			"fire": 18,
			"fire_col": Color(1.0, 0.72, 0.34, 1.0),
			"fire_life": 0.40,
			"fire_v": 9.0,
			"fire_scale": 2.0,
			"fire_g": 2.0,
			"fire_add": true,
			"fire_spread": 180.0,
			"smoke": 22,
			"smoke_col": Color(0.17, 0.16, 0.15, 0.62),
			"smoke_life": 2.0,
			"smoke_v": 2.6,
			"smoke_scale": 3.4,
			"smoke_g": 0.8,
			"spark": 26,
			"spark_col": Color(1.0, 0.78, 0.36, 1.0),
			"spark_life": 0.75,
			"spark_v": 15.0,
			"spark_g": -12.0,
			"spark_scale": 1.1,
			"spark_sprite": FXSprites.SPRITE_STREAK,
			"light_col": Color(1.0, 0.72, 0.38),
			"light_e": 9.0,
			"light_r": 12.0,
			"ring_col": Color(1.0, 0.82, 0.50, 1.0),
			"ring_span": 6.5,
			"life": 2.4,
		}

	## A blast type = the FRAG base with its own keys written over the top.
	static func _variant(over: Dictionary) -> Dictionary:
		var d := _base()
		d.merge(over, true)  # overwrite = true, else the base would WIN and every type look alike
		return d

	static func _build_recipes() -> void:
		# FRAG is the reference blast: orange fireball, oily column, hot shrapnel.
		_recipes["frag"] = _base()
		# EMP — no fire, almost no smoke: an electric-blue CRACK, a wide ring and a lot of very
		# fast, very thin arcs. Short on purpose, so it reads as a pulse and not as a fire.
		_recipes["emp"] = _variant(
			{
				"fire": 10,
				"fire_col": Color(0.55, 0.85, 1.0, 1.0),
				"fire_life": 0.22,
				"fire_v": 12.0,
				"fire_scale": 1.4,
				"fire_g": 0.0,
				"smoke": 5,
				"smoke_col": Color(0.62, 0.74, 0.85, 0.26),
				"smoke_life": 1.0,
				"smoke_v": 1.6,
				"smoke_scale": 1.8,
				"smoke_g": 1.4,
				"spark": 30,
				"spark_col": Color(0.72, 0.92, 1.0, 1.0),
				"spark_life": 0.55,
				"spark_v": 20.0,
				"spark_g": -3.0,
				"spark_scale": 0.85,
				"light_col": Color(0.50, 0.80, 1.0),
				"light_e": 11.0,
				"light_r": 14.0,
				"ring_col": Color(0.60, 0.90, 1.0, 1.0),
				"ring_span": 8.0,
				"life": 1.5,
			}
		)
		_build_recipes_elemental()
		_build_recipes_utility()

	## The chemistry pair — both are about what LINGERS, so both spend their budget on the
	## long MIX pass: incendiary keeps burning (rising embers, sooty column), cryo settles (a
	## white mist and ice crystals that tumble DOWN instead of arcing up, and a 'fireball'
	## that is a frost CLOUD — hence fire_add false, an additive bloom would read as a flash).
	static func _build_recipes_elemental() -> void:
		_recipes["incendiary"] = _variant(
			{
				"fire": 20,
				"fire_col": Color(1.0, 0.46, 0.13, 1.0),
				"fire_life": 0.85,
				"fire_v": 7.0,
				"fire_scale": 2.2,
				"fire_g": 2.6,
				"fire_spread": 150.0,
				"smoke": 18,
				"smoke_col": Color(0.14, 0.11, 0.09, 0.60),
				"smoke_life": 2.4,
				"smoke_v": 2.0,
				"smoke_scale": 3.2,
				"smoke_g": 1.0,
				"spark": 22,
				"spark_col": Color(1.0, 0.60, 0.20, 1.0),
				"spark_life": 1.5,
				"spark_v": 5.0,
				"spark_g": -2.0,
				"spark_scale": 0.8,
				"light_col": Color(1.0, 0.50, 0.18),
				"light_e": 8.0,
				"light_r": 11.0,
				"ring_col": Color(1.0, 0.55, 0.20, 1.0),
				"ring_span": 5.5,
				"life": 2.8,
			}
		)
		_recipes["cryo"] = _variant(
			{
				"fire": 14,
				"fire_col": Color(0.78, 0.93, 1.0, 0.80),
				"fire_life": 0.70,
				"fire_v": 5.0,
				"fire_scale": 2.4,
				"fire_g": -0.4,
				"fire_add": false,
				"smoke": 16,
				"smoke_col": Color(0.86, 0.93, 0.98, 0.50),
				"smoke_life": 2.0,
				"smoke_v": 1.8,
				"smoke_scale": 3.0,
				"smoke_g": 0.3,
				"spark": 20,
				"spark_col": Color(0.80, 0.95, 1.0, 1.0),
				"spark_life": 1.1,
				"spark_v": 6.5,
				"spark_g": -9.0,
				"spark_scale": 0.7,
				"spark_sprite": FXSprites.SPRITE_GLINT,
				"light_col": Color(0.60, 0.85, 1.0),
				"light_e": 5.0,
				"light_r": 9.0,
				"ring_col": Color(0.70, 0.92, 1.0, 1.0),
				"ring_span": 6.0,
				"life": 2.4,
			}
		)

	## The two that are not blasts at all: smoke is ONLY the column (no flash, no ring, no
	## sparks — a flash would defeat the point of breaking contact), decoy is a small bright
	## pop whose whole job is to say "the noise came from HERE".
	static func _build_recipes_utility() -> void:
		_recipes["smoke"] = _variant(
			{
				"fire": 0,
				"smoke": 26,
				"smoke_col": Color(0.74, 0.74, 0.72, 0.55),
				"smoke_life": 2.4,
				"smoke_v": 3.2,
				"smoke_scale": 4.6,
				"smoke_g": 0.5,
				"spark": 0,
				"light_e": 0.0,
				"ring_span": 0.0,
				"life": 2.8,
			}
		)
		_recipes["decoy"] = _variant(
			{
				"fire": 6,
				"fire_col": Color(0.60, 0.90, 1.0, 1.0),
				"fire_life": 0.25,
				"fire_v": 6.0,
				"fire_scale": 1.0,
				"fire_g": 0.0,
				"smoke": 4,
				"smoke_col": Color(0.60, 0.70, 0.80, 0.30),
				"smoke_life": 1.2,
				"smoke_v": 1.4,
				"smoke_scale": 1.6,
				"smoke_g": 1.2,
				"spark": 18,
				"spark_col": Color(0.70, 0.95, 1.0, 1.0),
				"spark_life": 0.9,
				"spark_v": 9.0,
				"spark_g": -6.0,
				"spark_scale": 0.6,
				"spark_sprite": FXSprites.SPRITE_GLINT,
				"light_col": Color(0.55, 0.85, 1.0),
				"light_e": 4.0,
				"light_r": 7.0,
				"ring_col": Color(0.60, 0.90, 1.0, 1.0),
				"ring_span": 3.5,
				"life": 1.6,
			}
		)


# --- the tracer (D4.4) -------------------------------------------------------


## TRACER v2 — pooled through FXPool as the "tracer" kind. ONE MultiMesh per shot draws the
## whole ballistic arc in a single draw call (the TracerPool discipline), but the segments are
## no longer identical: radius and brightness RAMP from a dim hair at the muzzle to a fat
## white-hot head at the far end, so a shot reads as a bolt travelling away from you instead
## of a uniform laser line switched on for two frames. A small additive glint sits on the head
## and one rate-limited OmniLight sits mid-arc (it does not travel — the whole streak is drawn
## at once, so a light crawling along it would contradict the geometry).
##
## Per-instance colour (MultiMesh.use_colors + vertex_color_use_as_albedo) is what buys the
## ramp for free — the alternative, a material per segment, is the exact per-shot allocation
## the pools exist to delete. Per frame this node writes THREE properties and allocates
## nothing; the whole arc is written once in setup().
##
## GEOMETRY GOTCHA (bug found while writing this): `Basis(x, y, z).scaled(v)` scales in the
## PARENT frame (rows: S*M), not along the segment. Stretching a cylinder along its own axis
## that way only works when the axis happens to be world-Y — a horizontal shot comes out
## unstretched (1 m segments with gaps between them). The columns are therefore pre-scaled
## here: Basis(x * rad, dir * len, z * rad).
class Streak:
	extends Node3D

	const SEG_MAX := 40  # ~32 arc points is the weapon's cap; 40 leaves headroom
	const LIFETIME := 0.11
	const RADIUS := 0.020
	const HEAD_RADIUS := 2.2  # the head segment is this much fatter than the tail
	const HEAD_SIZE := 0.26
	const LIGHT_GAP_MS := 110  # sustained fire lights the room ~9x/second, not 600x
	const LIGHT_DIST := 55.0
	const LIGHT_ENERGY := 3.2
	const LIGHT_RANGE := 5.5

	var pooled := false  # set by FXPool; end-of-life releases instead of freeing
	var _t := 0.0
	var _mmi: MultiMeshInstance3D
	var _mm: MultiMesh
	var _mat: StandardMaterial3D
	var _head: MeshInstance3D
	var _head_mat: StandardMaterial3D
	var _head_size := HEAD_SIZE
	var _light: OmniLight3D
	var _light_e := 0.0

	func _ready() -> void:
		_mm = MultiMesh.new()
		_mm.transform_format = MultiMesh.TRANSFORM_3D
		# use_colors MUST be set before instance_count — that write allocates the buffers.
		_mm.use_colors = true
		var cyl := CylinderMesh.new()
		cyl.top_radius = RADIUS
		cyl.bottom_radius = RADIUS
		cyl.height = 1.0
		cyl.radial_segments = 5
		cyl.rings = 0
		_mm.mesh = cyl
		_mm.instance_count = SEG_MAX
		_mm.visible_instance_count = 0
		_mmi = MultiMeshInstance3D.new()
		_mmi.multimesh = _mm
		_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mat = StandardMaterial3D.new()
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_mat.vertex_color_use_as_albedo = true  # the per-instance head->tail ramp
		_mat.disable_receive_shadows = true
		_mmi.material_override = _mat
		add_child(_mmi)
		_build_head()
		_light = OmniLight3D.new()
		_light.shadow_enabled = false
		_light.light_color = Color(1.0, 0.86, 0.55)
		_light.light_energy = 0.0
		add_child(_light)
		set_process(false)

	func _build_head() -> void:
		var q := QuadMesh.new()
		q.size = Vector2(HEAD_SIZE, HEAD_SIZE)
		_head = MeshInstance3D.new()
		_head.mesh = q
		_head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_head_mat = StandardMaterial3D.new()
		_head_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_head_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_head_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_head_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_head_mat.albedo_texture = FXSprites.sprite_texture(FXSprites.SPRITE_GLINT)
		_head.material_override = _head_mat
		_head.visible = false
		add_child(_head)

	## Write the arc. `points` are the shot's ballistic samples in WORLD space and `muzzle`
	## replaces points[0] so the streak leaves the actual barrel (the TracerPool contract).
	## Call BEFORE fire(); it positions the node itself, so the caller must not.
	func setup(
		points: PackedVector3Array,
		muzzle: Vector3,
		tint: Color = Color(1.0, 0.9, 0.62),
		width: float = 1.0
	) -> void:
		var n := mini(points.size(), SEG_MAX + 1)
		if n < 2:
			_mm.visible_instance_count = 0
			_head.visible = false
			return
		global_transform = Transform3D(Basis(), muzzle)
		var used := 0
		var last := Vector3.ZERO
		for i in range(n - 1):
			var a: Vector3 = (muzzle if i == 0 else points[i]) - muzzle
			var b: Vector3 = points[i + 1] - muzzle
			var seg := b - a
			var dist := seg.length()
			if dist < 0.0001:
				continue
			var dir := seg / dist
			var arb := Vector3.RIGHT if absf(dir.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD
			var side := arb.cross(dir).normalized()
			var other := side.cross(dir).normalized()
			# Head-to-tail ramp: k = 0 at the muzzle, 1 at the far end.
			var k := float(i + 1) / float(n - 1)
			var rad: float = lerpf(0.5, HEAD_RADIUS, pow(k, 1.7)) * width
			_mm.set_instance_transform(
				used, Transform3D(Basis(side * rad, dir * dist, other * rad), (a + b) * 0.5)
			)
			var glow: float = lerpf(0.45, 1.35, pow(k, 2.0))
			var alpha: float = lerpf(0.10, 1.0, pow(k, 2.2))
			_mm.set_instance_color(used, Color(tint.r * glow, tint.g * glow, tint.b * glow, alpha))
			last = b
			used += 1
		_mm.visible_instance_count = used
		# A fixed custom AABB from the two ENDS (+ margin for the ballistic sag): the MultiMesh
		# would otherwise recompute its bounds from ALL SEG_MAX slots, including the stale ones
		# left over from the previous, longer shot.
		var lo := Vector3(minf(0.0, last.x), minf(0.0, last.y), minf(0.0, last.z))
		var hi := Vector3(maxf(0.0, last.x), maxf(0.0, last.y), maxf(0.0, last.z))
		_mmi.custom_aabb = AABB(lo - Vector3.ONE * 3.0, (hi - lo) + Vector3.ONE * 6.0)
		_head_size = HEAD_SIZE * width
		_head.visible = used > 0
		_head.position = last
		_head_mat.albedo_color = Color(tint.r, tint.g, tint.b, 1.0)
		_place_light(last)

	## The mid-arc glow, at ~55% along the shot — far enough to light a wall the bullet
	## passes, never doubling the muzzle flash's own light. Rate-limited through the pool's
	## shared budget (a real light per bullet is the most expensive thing this FX could do)
	## and skipped entirely when the shot is far from the camera.
	func _place_light(head_local: Vector3) -> void:
		_light_e = 0.0
		_light.light_energy = 0.0
		_light.position = head_local * 0.55
		if head_local.length() < 2.0:
			return
		if _camera_dist() > LIGHT_DIST:
			return
		if not FXPool.claim_light(LIGHT_GAP_MS):
			return
		_light_e = LIGHT_ENERGY
		_light.omni_range = LIGHT_RANGE
		_light.light_energy = _light_e

	## (Re)start at the current arc — the pool calls this on every reuse.
	func fire() -> void:
		_t = 0.0
		visible = true
		set_process(true)
		_mat.albedo_color = Color(1, 1, 1, 1)
		if _head_mat != null:
			_head_mat.albedo_color.a = 1.0
		(_head.mesh as QuadMesh).size = Vector2.ONE * _head_size

	func _process(delta: float) -> void:
		_t += delta
		var k := clampf(_t / LIFETIME, 0.0, 1.0)
		var fade := pow(1.0 - k, 1.4)  # holds bright, then goes — a tracer does not linger
		_mat.albedo_color.a = fade
		if _head.visible:
			(_head.mesh as QuadMesh).size = Vector2.ONE * _head_size * (1.0 + k * 0.8)
			_head_mat.albedo_color.a = fade
		if _light_e > 0.0:
			_light.light_energy = _light_e * fade
		if k >= 1.0:
			_finish()

	func _finish() -> void:
		_light.light_energy = 0.0
		_light_e = 0.0
		_mm.visible_instance_count = 0
		_head.visible = false
		if pooled and FXPool.active != null:
			FXPool.active.release(self)
		else:
			queue_free()

	## Distance to the LOCAL camera; 0.0 (= "close") when there is no camera yet.
	func _camera_dist() -> float:
		var vp := get_viewport()
		if vp == null:
			return 0.0
		var cam := vp.get_camera_3d()
		if cam == null:
			return 0.0
		return cam.global_position.distance_to(global_position)
