class_name NemesisEntrance
extends Node3D
## D6.5 — the Machine Nemesis ENTRANCE: a ~2.6 s staging that turns the returning rival's
## arrival from "one more hunter spawn" into an EVENT.
##
## Four beats, all render-only and built LOCALLY on every peer (zero RPC, zero new signals):
##   1. a red signature flash + two expanding ground rings + a short light column at the exit;
##   2. a "heartbeat" pulse (two thumps per ~0.86 s) that drives the rival's body glow AND a
##      red screen vignette, decaying to nothing over the staging;
##   3. a silhouette read-through — GHOST copies of the rival's meshes with an x-ray fresnel
##      rim, so it stays legible through smoke/grass/geometry FOR THESE SECONDS ONLY (the
##      ghosts are freed with this node — there is no lasting wallhack);
##   4. dust + sparks at its feet.
##
## ARCHITECTURE: two instances of this class per entrance, both purely local —
##   MODE_GROUND: parented to the ARENA at the exit point (the flash/rings/decal stay put
##                while the rival walks off);
##   MODE_BODY:   parented to the RIVAL BODY (ghosts, glow light, foot dust, vignette) so it
##                rides the machine for free and dies with it.
## Nothing is written into robot_enemy's own nodes/materials: the silhouette is MY child
## MeshInstance3D per source mesh (it inherits the source's animated transform for free and
## never touches material_override, which the hit-flash owns).
##
## Trigger: NemesisDirector stages it from Events.nemesis_returned (host, exact frame) and
## from a local Groups.NEMESIS watch tick (every peer, incl. clients — the return signal is
## server-only). `stage()` is idempotent via a node meta so both paths can call it.

## Staging length (s). Also the hard lifetime of both nodes.
const ENTRANCE_TIME := 2.6
## Beyond this from the LOCAL camera the whole staging is skipped (mirrors FXPool's gate;
## kept local so Settings stays untouched — the lead may promote it to Settings.NEMESIS_*).
const FX_DIST := 110.0
## The screen vignette only builds/reads inside this distance (it is a "it is HERE" cue).
const VIGNETTE_DIST := 55.0
const VIGNETTE_MAX := 0.55  # peak vignette alpha at the first thump, point blank
const HEART_PERIOD := 0.86  # s per heartbeat cycle (lub-dub)
const HEART_SECOND := 0.19  # phase of the second (weaker) thump
const MAX_GHOSTS := 48  # cap on silhouette copies (a mech is ~20-40 meshes)
const RING2_DELAY := 0.18
const FOOT_Y := -0.85  # body origin -> feet (the enemy capsule origin sits mid-body)
const RED := Color(0.95, 0.09, 0.10)
## Deliberately PURE red: the rim is additive and up to MAX_GHOSTS parts overlap, so the
## accumulation must saturate the R channel long before G/B — that is what keeps a
## point-blank entrance red instead of the white-out the beacon-ray lesson warns about.
const GHOST_TINT := Color(1.0, 0.05, 0.05)
const CANVAS_LAYER := 3  # above raid_vignette (2), below the fx_overlay veil (90)
# Local mirrors so a static FX file keeps zero dependencies (the SkillVFX convention). Group
# names are frozen contracts (Groups.ARENA), the meta key is this effect's own.
const _ARENA_GROUP := "arena"
const _META_STAGED := "nem_entrance"

enum { MODE_GROUND, MODE_BODY }

# One compiled Shader per process, shared by every entrance (a fresh Shader per node would
# recompile the same source on each raid).
static var _ghost_shader: Shader = null
static var _vig_shader: Shader = null

var _mode: int = MODE_GROUND
var _age: float = 0.0
var _ghost_mat: ShaderMaterial = null
var _vig_mat: ShaderMaterial = null
var _vig_rect: ColorRect = null
var _glow: OmniLight3D = null
var _ghosts: Array[MeshInstance3D] = []


## THE entry point: build the entrance for `body` (the rival) on THIS peer. Idempotent —
## the host's signal path and every peer's group-watch path both call it. No-ops headless,
## out of FX range, or when already staged for this body.
static func stage(body: Node3D) -> void:
	if body == null or not is_instance_valid(body) or not body.is_inside_tree():
		return
	if DisplayServer.get_name() == "headless" or body.has_meta(_META_STAGED):
		return
	body.set_meta(_META_STAGED, true)
	var pos: Vector3 = body.global_position
	if not _within_range(body, pos, FX_DIST):
		return
	var arena: Node = body.get_tree().get_first_node_in_group(_ARENA_GROUP)
	if arena != null:
		var ground := NemesisEntrance.new()
		ground._mode = MODE_GROUND
		arena.add_child(ground)
		ground.global_position = pos + Vector3(0.0, FOOT_Y, 0.0)
	var rider := NemesisEntrance.new()
	rider._mode = MODE_BODY
	body.add_child(rider)
	rider.position = Vector3.ZERO


func _ready() -> void:
	if _mode == MODE_GROUND:
		_build_ground()
	else:
		_build_body()


func _process(delta: float) -> void:
	_age += delta
	if _age >= ENTRANCE_TIME:
		_cleanup()
		queue_free()
		return
	if _mode != MODE_BODY:
		return
	# Envelope: the whole staging fades out; the heartbeat rides on top of it.
	var env: float = 1.0 - _age / ENTRANCE_TIME
	env *= env
	var pulse: float = env * (0.3 + 0.7 * _heartbeat(_age))
	if _ghost_mat != null:
		# A low floor keeps the outline readable between thumps; the thump doubles it.
		_ghost_mat.set_shader_parameter("power", 0.18 * env + 0.5 * pulse)
	if _glow != null:
		_glow.light_energy = 7.0 * pulse
	if _vig_mat != null:
		var amount: float = VIGNETTE_MAX * pulse * _vignette_falloff()
		_vig_mat.set_shader_parameter("amount", amount)
		# A silent vignette still costs a full-screen fragment pass — hide it outright.
		_vig_rect.visible = amount > 0.002


func _exit_tree() -> void:
	_cleanup()


# ------------------------------------------------------------------ beat 1: the exit burst
## Ground node: signature flash + light + two expanding rings + a short column + a decal.
func _build_ground() -> void:
	var flash := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.55
	sm.height = 1.1
	flash.mesh = sm
	var fm := _unshaded(Color(1.0, 0.32, 0.26, 0.9), true)
	flash.material_override = fm
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flash)
	flash.position = Vector3(0.0, 1.0, 0.0)
	var ft := flash.create_tween()
	ft.set_parallel(true)
	ft.tween_property(flash, "scale", Vector3.ONE * 3.4, 0.3)
	ft.tween_property(fm, "albedo_color", Color(1.0, 0.32, 0.26, 0.0), 0.3)
	ft.set_parallel(false)
	ft.tween_callback(flash.queue_free)

	var light := OmniLight3D.new()
	light.light_color = RED
	light.light_energy = 16.0
	light.omni_range = 15.0
	add_child(light)
	light.position = Vector3(0.0, 1.2, 0.0)
	light.create_tween().tween_property(light, "light_energy", 0.0, 0.55)

	_spawn_ring(9.0, 0.75, 0.34)
	var t: SceneTreeTimer = get_tree().create_timer(RING2_DELAY)
	t.timeout.connect(_spawn_ring_late)
	_signature_column()
	_ground_decal()


## Flat expanding shockwave ring. ALPHA/MIX on purpose — an additive ring this close to the
## camera washes the frame white (the "beacon ray" lesson); MIX keeps it RED.
func _spawn_ring(max_r: float, life: float, thickness: float) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.outer_radius = 0.9
	tm.inner_radius = maxf(0.1, 0.9 - thickness)
	ring.mesh = tm
	var m := _unshaded(Color(RED.r, RED.g, RED.b, 0.8), false)
	ring.material_override = m
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	ring.position = Vector3(0.0, 0.22, 0.0)
	ring.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	ring.scale = Vector3.ONE * 0.25
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * max_r, life)
	tw.tween_property(m, "albedo_color", Color(RED.r, RED.g, RED.b, 0.0), life)
	tw.set_parallel(false)
	tw.tween_callback(ring.queue_free)


## Second ring, one beat later (a single shockwave reads as a bubble; two read as a pulse).
func _spawn_ring_late() -> void:
	if is_inside_tree():
		_spawn_ring(15.0, 0.95, 0.2)


## A brief low column of red haze marking WHERE it came out. MIX, short, and only 5 m tall —
## a tall additive shaft is exactly the beacon mistake.
func _signature_column() -> void:
	var col := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.15
	cm.bottom_radius = 0.75
	cm.height = 5.0
	col.mesh = cm
	var m := _unshaded(Color(RED.r, RED.g, RED.b, 0.34), false)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	col.material_override = m
	col.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(col)
	col.position = Vector3(0.0, 2.5, 0.0)
	col.scale = Vector3(0.4, 0.2, 0.4)
	var tw := col.create_tween()
	tw.set_parallel(true)
	tw.tween_property(col, "scale", Vector3(1.0, 1.0, 1.0), 0.35)
	tw.tween_property(m, "albedo_color", Color(RED.r, RED.g, RED.b, 0.0), 0.9)
	tw.set_parallel(false)
	tw.tween_callback(col.queue_free)


## Radial red stain on the ground under the exit, fading across the staging.
func _ground_decal() -> void:
	var dec := Decal.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(RED.r, RED.g, RED.b, 0.8))
	grad.set_color(1, Color(RED.r, RED.g, RED.b, 0.0))
	grad.set_offset(0, 0.15)
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 128
	tex.height = 128
	dec.texture_albedo = tex
	dec.size = Vector3(9.0, 3.0, 9.0)
	dec.modulate = RED
	add_child(dec)
	dec.position = Vector3(0.0, 0.6, 0.0)
	var tw := dec.create_tween()
	tw.tween_interval(0.6)
	tw.tween_property(dec, "albedo_mix", 0.0, 1.6)


# ------------------------------------------------------ beats 2-4: the rival's own staging
## Body node: silhouette ghosts + heartbeat glow + foot dust/sparks + the screen vignette.
func _build_body() -> void:
	_build_ghosts()
	_glow = OmniLight3D.new()
	_glow.light_color = RED
	_glow.light_energy = 0.0
	_glow.omni_range = 8.0
	add_child(_glow)
	_glow.position = Vector3(0.0, 1.05, 0.0)
	_foot_dust()
	_foot_sparks()
	_build_vignette()


## Silhouette read-through: one ghost MeshInstance3D per source mesh, parented UNDER that
## mesh so it inherits its animated transform with no per-frame sync and no write into the
## enemy's own material slots. The shader is depth-test-disabled fresnel, so only the RIM
## shows through cover — a readable outline, not a solid see-through body.
func _build_ghosts() -> void:
	var src: Array[MeshInstance3D] = []
	_collect_meshes(get_parent(), src)
	if src.is_empty():
		return
	_ghost_mat = ShaderMaterial.new()
	_ghost_mat.shader = _get_ghost_shader()
	_ghost_mat.set_shader_parameter("tint", Vector3(GHOST_TINT.r, GHOST_TINT.g, GHOST_TINT.b))
	_ghost_mat.set_shader_parameter("power", 0.0)
	for mi in src:
		var g := MeshInstance3D.new()
		g.mesh = mi.mesh
		g.material_override = _ghost_mat
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		g.layers = mi.layers
		mi.add_child(g)
		g.transform = Transform3D.IDENTITY
		# Skinned source (a .glb archetype): re-point the copy at the SAME skeleton, else it
		# would render frozen in bind pose next to the animated body.
		if mi.skin != null:
			var skel: Node = mi.get_node_or_null(mi.skeleton)
			if skel == null:
				g.queue_free()
				continue
			g.skin = mi.skin
			g.skeleton = g.get_path_to(skel)
		_ghosts.append(g)


## Depth-first walk of the rival's visual tree, capped. Skips already-hidden parts (blown-off
## plates from the scar pass) so the silhouette matches what is actually on screen.
func _collect_meshes(root: Node, out: Array[MeshInstance3D]) -> void:
	if root == null:
		return
	for c in root.get_children():
		if out.size() >= MAX_GHOSTS:
			return
		if c == self:
			continue
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			if mi.mesh != null and mi.visible:
				out.append(mi)
		_collect_meshes(c, out)


## Kicked-up dust at the feet — ALPHA/MIX, deliberately NOT additive.
func _foot_dust() -> void:
	var p := GPUParticles3D.new()
	p.amount = 24
	p.lifetime = 1.2
	p.explosiveness = 0.4
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.7
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 55.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 2.2
	pm.gravity = Vector3(0.0, 0.5, 0.0)
	pm.scale_min = 0.5
	pm.scale_max = 1.5
	pm.color = Color(0.3, 0.24, 0.24, 0.45)
	p.process_material = pm
	var mesh := SphereMesh.new()
	mesh.radius = 0.3
	mesh.height = 0.6
	mesh.material = _unshaded(Color(0.32, 0.24, 0.24, 0.4), false)
	p.draw_pass_1 = mesh
	add_child(p)
	p.position = Vector3(0.0, FOOT_Y + 0.2, 0.0)
	p.emitting = true


## Sparks — the ONE additive element down here (tiny, short-lived, per the FX rule).
func _foot_sparks() -> void:
	var p := GPUParticles3D.new()
	p.amount = 30
	p.lifetime = 0.7
	p.one_shot = true
	p.explosiveness = 0.85
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.5
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 70.0
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 7.0
	pm.gravity = Vector3(0.0, -9.0, 0.0)
	pm.scale_min = 0.12
	pm.scale_max = 0.3
	pm.color = Color(1.0, 0.45, 0.3, 1.0)
	p.process_material = pm
	var mesh := SphereMesh.new()
	mesh.radius = 0.09
	mesh.height = 0.18
	mesh.material = _unshaded(Color(1.0, 0.45, 0.3, 1.0), true)
	p.draw_pass_1 = mesh
	add_child(p)
	p.position = Vector3(0.0, FOOT_Y + 0.25, 0.0)
	p.emitting = true


## The heartbeat vignette. Own CanvasLayer so no existing UI file is touched; respects the
## ui_fx_enabled setting exactly like the other shader overlays.
## Built with a 1.6x slack on the falloff distance so walking TOWARD the rival mid-staging
## still lights it up, while a 100 m sighting never pays for a full-screen pass.
func _build_vignette() -> void:
	if not Settings.ui_fx_enabled or not _within_range(self, global_position, VIGNETTE_DIST * 1.6):
		return
	var layer := CanvasLayer.new()
	layer.layer = CANVAS_LAYER
	_vig_rect = ColorRect.new()
	# A code-built Control under a CanvasLayer needs anchors AND offsets, else it is a 0x0 root.
	_vig_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vig_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vig_rect.visible = false
	_vig_mat = ShaderMaterial.new()
	_vig_mat.shader = _get_vig_shader()
	_vig_mat.set_shader_parameter("tint", Vector3(0.62, 0.03, 0.04))
	_vig_mat.set_shader_parameter("amount", 0.0)
	_vig_rect.material = _vig_mat
	layer.add_child(_vig_rect)
	add_child(layer)


# ------------------------------------------------------------------------------- helpers
## Two thumps per cycle (lub-dub), wrapped so the cycle seam stays smooth.
func _heartbeat(t: float) -> float:
	var ph: float = fmod(t, HEART_PERIOD) / HEART_PERIOD
	return maxf(_thump(ph, 0.0), _thump(ph, HEART_SECOND) * 0.62)


func _thump(ph: float, at: float) -> float:
	var d: float = absf(ph - at)
	d = minf(d, 1.0 - d)
	return exp(-(d * d) / 0.0022)


## 1 at point-blank -> 0 at VIGNETTE_DIST (the vignette is a proximity cue, not a global one).
func _vignette_falloff() -> float:
	var cam: Camera3D = null
	var vp := get_viewport()
	if vp != null:
		cam = vp.get_camera_3d()
	if cam == null:
		return 0.0
	var d: float = cam.global_position.distance_to(global_position)
	return clampf(1.0 - d / VIGNETTE_DIST, 0.0, 1.0)


## Free the silhouette copies explicitly: they live under the ENEMY's meshes, not under this
## node, so they would outlive it (and become a permanent wallhack) if we only queue_free'd.
func _cleanup() -> void:
	for g in _ghosts:
		if is_instance_valid(g):
			g.queue_free()
	_ghosts.clear()


func _unshaded(col: Color, additive: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return m


## Distance gate against the LOCAL camera (FXPool discipline). A missing viewport/camera is a
## boot frame, not a reason to swallow the signature moment -> allow.
static func _within_range(probe: Node, pos: Vector3, dist: float) -> bool:
	if probe == null or not probe.is_inside_tree():
		return false
	var vp := probe.get_viewport()
	if vp == null:
		return true
	var cam := vp.get_camera_3d()
	if cam == null:
		return true
	return cam.global_position.distance_squared_to(pos) <= dist * dist


static func _get_ghost_shader() -> Shader:
	if _ghost_shader == null:
		_ghost_shader = Shader.new()
		_ghost_shader.code = GHOST_SHADER_SRC
	return _ghost_shader


static func _get_vig_shader() -> Shader:
	if _vig_shader == null:
		_vig_shader = Shader.new()
		_vig_shader.code = VIGNETTE_SHADER_SRC
	return _vig_shader


# Built in code (not a .gdshader) so this effect stays ONE self-contained file.
const GHOST_SHADER_SRC := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_back;

// Plain vec3 (no source_color): the tint is pushed as a Vector3 from code, so no sRGB
// hint-conversion can sit between the constant and what the rim actually adds.
uniform vec3 tint = vec3(1.0, 0.06, 0.07);
uniform float power : hint_range(0.0, 2.0) = 0.0;

void fragment() {
	float rim = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	rim = pow(clamp(rim, 0.0, 1.0), 2.6);
	ALBEDO = tint;
	ALPHA = clamp(rim * power, 0.0, 1.0);
}
"""

const VIGNETTE_SHADER_SRC := """
shader_type canvas_item;
render_mode blend_mix;

uniform vec3 tint = vec3(0.62, 0.03, 0.04);
uniform float amount : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 d = (UV - vec2(0.5)) * vec2(1.15, 1.0);
	float v = smoothstep(0.18, 0.62, length(d));
	COLOR = vec4(tint, v * amount);
}
"""
