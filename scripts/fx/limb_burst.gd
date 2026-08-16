class_name LimbBurst
extends RefCounted
## M1 feel — the dying machine BREAKS APART, and the spawning machine ARRIVES.
##
## D2.6 v2 (gibs from the REAL body): the 3-5 BIGGEST MeshInstance3D of the corpse's
## own model are cloned (mesh + every material slot) into physics debris, the originals
## are hidden, and the wreck literally comes to pieces — a bastion sheds bastion plates,
## a worm sheds worm segments. The old generic skill-family limb burst is kept as the
## FALLBACK for bodies with too few usable parts (single-mesh .glb, merged models).
## Gibs live LONGER up close and are damped by distance (fewer parts, shorter life,
## nothing at all past GIB_CULL) — the corpse pop already carries the far-away read.
##
## D6.2 (spawn polish): the assemble beat gets a burning DROP-POD streak falling from
## the sky with an ember trail plus an impact DUST WAVE on landing.
##
## Everything here is render-only and per-peer (robot_enemy._start_death_fx / _ready,
## player_body_feel._drop_pod_intro); debris is parked in the FX-safe container so it
## survives the enemy's queue_free. Extracted here for robot_enemy's 1800-line ceiling.

# --- D2.6 gibs ------------------------------------------------------------------
const GIB_MIN_PARTS := 2  # fewer real parts than this → generic-limb fallback
const GIB_MAX_PARTS := 5
const GIB_MIN_VOL := 0.0016  # m³ — below this a part is a rivet/antenna, not a gib
const GIB_NEAR := 18.0  # m — full part count inside this
const GIB_CULL := 55.0  # m — beyond this no physics bodies at all (distance damping)
const GIB_LIFE_NEAR := 5.5
const GIB_LIFE_FAR := 1.8
const GIB_SINK := 0.45  # scale-out tail before the free (never a hard pop)
const GIB_CAP := 48  # global concurrent gib budget (RigidBody is the expensive bit)
# --- D6.2 drop pod --------------------------------------------------------------
const POD_DIST := 60.0  # m — no pod FX for spawns farther than this from the camera
const POD_HEIGHT := 26.0
const POD_FALL := 0.32  # s — lands just before the body finishes assembling (0.38)
const POD_CAP := 6  # a 10-strong wave must not drop 10 pods at once

# Live-body counters so a mass wipe / a wave spawn stays bounded.
static var _gibs_live: int = 0
static var _pods_live: int = 0


## M1 SPAWN ASSEMBLY — a machine doesn't pop into existence: its body scales up
## from the ground with a quick spin-settle + a spawn ring, reading as «собралась
## из деталей». D6.2 adds the drop-pod arrival. Render-only, runs on every peer
## from robot_enemy._ready (and player_body_feel on deploy).
static func assemble(model_root: Node3D, host: Node3D) -> void:
	if model_root == null or DisplayServer.get_name() == "headless":
		return
	model_root.scale = Vector3.ONE * 0.05
	model_root.rotation.y = 2.4
	var tw := model_root.create_tween()
	tw.set_parallel(true)
	tw.tween_property(model_root, "scale", Vector3.ONE, 0.38).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	tw.tween_property(model_root, "rotation:y", 0.0, 0.34).set_trans(Tween.TRANS_CUBIC)
	# Spawn ring at the feet (unshaded, self-freeing).
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.5
	tm.outer_radius = 0.62
	ring.mesh = tm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(0.9, 0.75, 0.35, 0.8)
	ring.material_override = m
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(ring)
	ring.global_position = host.global_position + Vector3(0, 0.15, 0)
	var rtw := ring.create_tween()
	rtw.set_parallel(true)
	rtw.tween_property(ring, "scale", Vector3.ONE * 3.2, 0.4)
	rtw.tween_property(m, "albedo_color", Color(0.9, 0.75, 0.35, 0.0), 0.4)
	rtw.set_parallel(false)
	rtw.tween_callback(ring.queue_free)
	_drop_pod(host)


# ------------------------------------------------------------------ D6.2 drop pod


## A burning pod screams down onto the spawn point, then the ground coughs dust.
## Coroutine on purpose: a MultiplayerSpawner writes a replicated body's position AFTER
## its _ready, so the landing point is only trustworthy a frame later — and waiting on
## the PHYSICS frame (not the idle one) is also the only safe place to query the space
## state for the roof check below.
static func _drop_pod(host: Node3D) -> void:
	if host == null or not host.is_inside_tree() or _pods_live >= POD_CAP:
		return
	var tree := host.get_tree()
	if tree == null:
		return
	await tree.physics_frame
	if not is_instance_valid(host) or not host.is_inside_tree():
		return
	var parent: Node = tree.current_scene
	if parent == null:
		return
	var cam := host.get_viewport().get_camera_3d()
	if cam == null:
		return
	var ground: Vector3 = host.global_position
	if cam.global_position.distance_to(ground) > POD_DIST:
		return
	if not _sky_clear(host, ground):
		return
	var pod := Node3D.new()
	parent.add_child(pod)
	pod.global_position = ground + Vector3(0, POD_HEIGHT, 0)
	_pods_live += 1
	pod.tree_exited.connect(func() -> void: _pod_freed())
	# The streak is ALPHA, never additive: it ends exactly where the camera can be
	# standing (own deploy), and an additive volume you are INSIDE whites out the frame.
	var streak := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.26
	cyl.height = 2.4
	cyl.radial_segments = 8
	streak.mesh = cyl
	streak.material_override = _fx_mat(Color(1.0, 0.63, 0.28), 0.7, 2.6, 1.6)
	streak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pod.add_child(streak)
	pod.add_child(_ember_trail())
	var tw := pod.create_tween()
	var land: Vector3 = ground + Vector3(0, 0.25, 0)
	tw.tween_property(pod, "global_position", land, POD_FALL).set_trans(Tween.TRANS_QUAD).set_ease(
		Tween.EASE_IN
	)
	tw.tween_callback(func() -> void: _land(pod, parent, ground))
	tw.tween_interval(1.4)
	tw.tween_callback(pod.queue_free)


## No pod through a roof: a burning streak spearing an interior ceiling reads as a bug,
## so a spawn with anything solid overhead simply skips it (the spawn ring + assembly
## still play). World layer only — machines and players must not block the sky.
static func _sky_clear(host: Node3D, ground: Vector3) -> bool:
	var world := host.get_world_3d()
	if world == null or world.direct_space_state == null:
		return true
	var q := PhysicsRayQueryParameters3D.create(
		ground + Vector3(0, 2.5, 0), ground + Vector3(0, POD_HEIGHT, 0), 1
	)
	return world.direct_space_state.intersect_ray(q).is_empty()


## Touchdown: kill the streak + stop the trail (its live embers finish in place),
## then throw the impact dust wave.
static func _land(pod: Node3D, parent: Node, ground: Vector3) -> void:
	if not is_instance_valid(pod):
		return
	for c in pod.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).queue_free()
		elif c is GPUParticles3D:
			(c as GPUParticles3D).emitting = false
	impact_dust(parent, ground)


## World-space ember trail (local_coords = false) so the fire hangs in the sky behind
## the falling pod instead of riding down with it.
static func _ember_trail() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 34
	p.lifetime = 0.7
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-4, -POD_HEIGHT, -4), Vector3(8, POD_HEIGHT + 8, 8))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.22
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 2.2
	pm.gravity = Vector3(0, -1.5, 0)
	pm.scale_min = 0.4
	pm.scale_max = 1.0
	pm.color = Color(1.0, 0.6, 0.25, 0.9)
	p.process_material = pm
	# A BOX, not a quad: a non-billboarded quad turns invisible edge-on (the skill_vfx
	# spark pattern) and an ember has no orientation worth defending.
	var ember := BoxMesh.new()
	ember.size = Vector3(0.13, 0.13, 0.13)
	ember.material = _fx_mat(Color(1.0, 0.6, 0.25), 0.9, 3.0, 0.9)
	p.draw_pass_1 = ember
	p.emitting = true
	return p


## The ground kicks a low outward dust ring at `ground` — the impact beat of the
## drop-pod landing, and reused by BossBrain for the intro stomps (never copy an FX
## helper between systems; AUDIT F1).
static func impact_dust(parent: Node, ground: Vector3) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	var p := GPUParticles3D.new()
	p.amount = 26
	p.lifetime = 0.95
	p.one_shot = true
	p.explosiveness = 0.92
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 1.0
	pm.emission_ring_inner_radius = 0.35
	pm.emission_ring_height = 0.12
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 30.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.6
	pm.radial_accel_min = 4.0
	pm.radial_accel_max = 8.5
	pm.gravity = Vector3(0, -1.4, 0)
	pm.scale_min = 0.6
	pm.scale_max = 1.5
	pm.color = Color(0.82, 0.79, 0.74, 0.5)
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.45, 0.45)
	quad.material = dust_mat()
	p.draw_pass_1 = quad
	parent.add_child(p)
	p.global_position = ground + Vector3(0, 0.12, 0)
	p.emitting = true
	var tw := p.create_tween()
	tw.tween_interval(1.4)
	tw.tween_callback(p.queue_free)


# ---------------------------------------------------------------------- D2.6 gibs


## The corpse comes apart. `body` is the dying node when the caller has it; when it is
## null the body is resolved by proximity (robot_enemy calls with its own position, so
## the DEAD enemy standing on that exact point is unambiguous).
static func burst(
	enemy_id: String, pos: Vector3, container: Node, scale_hint: float, body: Node3D = null
) -> void:
	if container == null or DisplayServer.get_name() == "headless":
		return
	var cam_d: float = _cam_dist(container, pos)
	if cam_d > GIB_CULL:
		return
	var want: int = _gib_count(cam_d)
	if want < GIB_MIN_PARTS:
		return
	var src: Node3D = body if body != null else _find_body(container, pos)
	var parts: Array[MeshInstance3D] = _real_parts(src, want)
	if parts.size() >= GIB_MIN_PARTS:
		_real_burst(parts, pos, container, cam_d)
	else:
		_generic_burst(enemy_id, pos, container, scale_hint, cam_d, want)


## Distance damping + the global budget: how many chunks this death may throw.
static func _gib_count(cam_d: float) -> int:
	var want: int = GIB_MAX_PARTS
	if cam_d > GIB_NEAR * 2.0:
		want = 3
	elif cam_d > GIB_NEAR:
		want = 4
	return mini(want, maxi(0, GIB_CAP - _gibs_live))


static func _gib_life(cam_d: float) -> float:
	return lerpf(GIB_LIFE_NEAR, GIB_LIFE_FAR, clampf(cam_d / GIB_CULL, 0.0, 1.0))


## The dead enemy sitting on `pos`. Requires Health.is_dead so a LIVE machine standing
## on the same tile can never get its plates hidden by someone else's death.
static func _find_body(container: Node, pos: Vector3) -> Node3D:
	if not container.is_inside_tree():
		return null
	var tree := container.get_tree()
	if tree == null:
		return null
	var best: Node3D = null
	var best_d: float = 0.0625  # (0.25 m)² — the caller passes the body's own position
	for n in tree.get_nodes_in_group(Groups.ENEMIES):
		var e := n as Node3D
		if e == null or not e.is_inside_tree():
			continue
		var d: float = e.global_position.distance_squared_to(pos)
		if d >= best_d:
			continue
		var hp: Node = e.get_node_or_null(Groups.NODE_HEALTH)
		if hp == null or not bool(hp.get("is_dead")):
			continue
		best_d = d
		best = e
	return best


## The `want` biggest solid meshes of the body's model, largest first.
static func _real_parts(src: Node3D, want: int) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if src == null or not is_instance_valid(src) or not src.is_inside_tree():
		return out
	var mr := src.get_node_or_null(Groups.NODE_MODEL_ROOT) as Node3D
	if mr == null:
		return out
	var cand: Array[MeshInstance3D] = []
	var ranked: Array[Vector2] = []  # (volume, index into cand) — sorted, no Dictionary
	for n in mr.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		if not _is_solid(mi):
			continue
		var vol: float = _part_volume(mi)
		if vol < GIB_MIN_VOL:
			continue
		cand.append(mi)
		ranked.append(Vector2(vol, float(cand.size() - 1)))
	ranked.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x > b.x)
	for i in mini(ranked.size(), want):
		out.append(cand[int(ranked[i].y)])
	return out


## Real geometry only. Every FX bit welded onto a machine in this project (weak-point
## marker, elite/nemesis glow ring, chemistry aura, boss crown) is an ADDITIVE unshaded
## mesh — the blend mode is the one honest test, and a flying additive shard would also
## break the relight rule about additive volumes.
static func _is_solid(mi: MeshInstance3D) -> bool:
	if mi.mesh.get_surface_count() <= 0:
		return false
	var mat: Material = mi.material_override
	if mat == null:
		mat = mi.get_surface_override_material(0)
	if mat == null:
		mat = mi.mesh.surface_get_material(0)
	var bm := mat as BaseMaterial3D
	if bm == null:
		return true  # ShaderMaterial / none — assume it is real geometry
	return bm.blend_mode == BaseMaterial3D.BLEND_MODE_MIX


static func _part_volume(mi: MeshInstance3D) -> float:
	var s: Vector3 = mi.global_transform.basis.get_scale()
	var e: Vector3 = mi.get_aabb().size * s
	return absf(e.x * e.y * e.z)


## Clone each chosen part (mesh + materials by reference — nothing is duplicated or
## mutated, so the shared ProcPlating/flash materials are untouched) into a rigid body
## sitting exactly where the part was, then HIDE the original so the plate really left.
static func _real_burst(
	parts: Array[MeshInstance3D], pos: Vector3, container: Node, cam_d: float
) -> void:
	var life: float = _gib_life(cam_d)
	var core: Vector3 = pos + Vector3.UP * 0.9
	for mi in parts:
		var xf: Transform3D = mi.global_transform
		var sc: Vector3 = xf.basis.get_scale()
		var aabb: AABB = mi.get_aabb()
		var ctr: Vector3 = aabb.get_center()
		var world_c: Vector3 = xf * ctr
		var ext: Vector3 = aabb.size * sc
		var gib := RigidBody3D.new()
		gib.collision_layer = 0  # nothing collides INTO a gib
		gib.collision_mask = 1  # gibs fall onto the WORLD only (never shove actors)
		gib.mass = 0.8
		gib.gravity_scale = 1.15
		gib.can_sleep = true
		var clone := MeshInstance3D.new()
		clone.mesh = mi.mesh
		clone.material_override = mi.material_override
		for i in mi.get_surface_override_material_count():
			clone.set_surface_override_material(i, mi.get_surface_override_material(i))
		clone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The body pivots on the part's VISUAL centre (an off-origin mesh would otherwise
		# orbit its own node origin and read as a wobbling ghost).
		clone.scale = sc
		clone.position = -(ctr * sc)
		gib.add_child(clone)
		var shape := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = clampf(maxf(ext.x, maxf(ext.y, ext.z)) * 0.35, 0.12, 0.7)
		shape.shape = sph
		gib.add_child(shape)
		container.add_child(gib)
		gib.global_transform = Transform3D(xf.basis.orthonormalized(), world_c)
		_launch(gib, world_c - core)
		_track(gib, clone, sc, life)
		mi.visible = false


## FALLBACK — too few real parts (single-mesh .glb / merged model): throw the
## recognizable limbs of the enemy's skill family, as v1 always did.
static func _generic_burst(
	enemy_id: String, pos: Vector3, container: Node, scale_hint: float, cam_d: float, want: int
) -> void:
	var sid: String = Settings.skill_for_enemy(enemy_id)
	var def: Dictionary = Settings.skill_def(sid)
	var col: Color = def["color"]
	var life: float = _gib_life(cam_d)
	var count: int = mini(2 + randi() % 2, want)
	for i in count:
		var gib := RigidBody3D.new()
		gib.collision_layer = 0
		gib.collision_mask = 1
		gib.mass = 1.2
		var limb: Node3D = ProceduralAbsorbed.build_limb_model(sid, col)
		var s: float = clampf(scale_hint, 0.7, 1.4)
		limb.scale = Vector3.ONE * s
		gib.add_child(limb)
		var shape := CollisionShape3D.new()
		var cs := SphereShape3D.new()
		cs.radius = 0.24
		shape.shape = cs
		gib.add_child(shape)
		container.add_child(gib)
		gib.global_position = pos + Vector3(0, 0.9, 0)
		var ang: float = randf() * TAU
		_launch(gib, Vector3(cos(ang), 0.0, sin(ang)))
		_track(gib, limb, Vector3.ONE * s, life)


## Fling a gib outward (away from the corpse core) + up, with a tumble.
static func _launch(gib: RigidBody3D, away: Vector3) -> void:
	var dir: Vector3 = Vector3(away.x, 0.0, away.z)
	if dir.length() < 0.05:
		var ang: float = randf() * TAU
		dir = Vector3(cos(ang), 0.0, sin(ang))
	dir = dir.normalized()
	gib.apply_impulse(dir * (1.6 + randf() * 2.2) + Vector3.UP * (3.0 + randf() * 2.2))
	gib.angular_velocity = Vector3(
		randf_range(-9.0, 9.0), randf_range(-9.0, 9.0), randf_range(-9.0, 9.0)
	)


## Budget bookkeeping + the timed exit: the debris shrinks away instead of popping
## (no material is touched, so nothing shared with the living models can be dirtied).
static func _track(gib: RigidBody3D, view: Node3D, rest: Vector3, life: float) -> void:
	_gibs_live += 1
	gib.tree_exited.connect(func() -> void: _gib_freed())
	var tw := gib.create_tween()
	tw.tween_interval(maxf(0.25, life - GIB_SINK))
	tw.tween_property(view, "scale", rest * 0.05, GIB_SINK)
	tw.tween_callback(gib.queue_free)


static func _gib_freed() -> void:
	_gibs_live = maxi(0, _gibs_live - 1)


static func _pod_freed() -> void:
	_pods_live = maxi(0, _pods_live - 1)


# ------------------------------------------------------------------------- shared


## Distance from THIS peer's camera to a world point; INF when there is no camera
## (hub/menu/headless) so every FX here damps itself out of existence.
static func _cam_dist(container: Node, pos: Vector3) -> float:
	if not container.is_inside_tree():
		return INF
	var vp: Viewport = container.get_viewport()
	if vp == null:
		return INF
	var cam := vp.get_camera_3d()
	if cam == null:
		return INF
	return cam.global_position.distance_to(pos)


## Unshaded ALPHA material with emission — bright enough to read under the cold grade,
## never additive (see the drop-pod note). `fade_from` > 0 makes it FADE IN WITH DISTANCE
## (invisible up close, full strength far): the pod lands exactly where the camera stands
## on your own deploy, and a hot surface filling the frame is the beacon-pillar lesson
## (extraction_zone._additive) — the fix is the same distance_fade_min/max pair.
static func _fx_mat(
	color: Color, alpha: float, glow: float, fade_from: float = 0.0
) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = glow
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if fade_from > 0.0:
		m.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
		m.distance_fade_min_distance = fade_from
		m.distance_fade_max_distance = fade_from * 2.6
	return m


## Billboarded dust: matte, light and slightly warm so it reads against the relit
## (bright) palette without adding a dark surface.
static func dust_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# BILLBOARD_PARTICLES (not _ENABLED) is the particle-system mode, and keep_scale is
	# mandatory — billboarding rebuilds the basis and would otherwise DISCARD each
	# particle's scale_min/max, flattening the puff into same-sized specks.
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	# White base: the ParticleProcessMaterial colour (light warm grey, alpha 0.5) is the
	# vertex colour and does the tinting — albedo only trims the final opacity.
	m.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
