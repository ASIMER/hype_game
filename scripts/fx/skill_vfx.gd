class_name SkillVFX
extends RefCounted
## Distinct, render-only cast effects for the Mutant-Harvest active skills (one look per ABILITY,
## not the old single torus ring). Spawned by SkillDirector._cast_vfx on every peer (call_local),
## headless-skipped + FX-distance-gated upstream. Pure visuals — no gameplay, no networking, no
## determinism contract (randf is fine here). Nodes self-free via tweens/timers under `arena`.

const _ENEMIES := "enemies"  # local mirror to avoid a Groups dependency in a static FX file


## Build the effect for `ability` at the caster `pos` (ground), aimed at `aim`, facing `facing`.
static func play(
	ability: String, color: Color, pos: Vector3, aim: Vector3, facing: Vector3, arena: Node
) -> void:
	if arena == null:
		return
	match ability:
		"leap_slam":
			_leap_slam(arena, pos, aim, color)
		"meteor":
			_meteor(arena, aim, color)
		"storm":
			_storm(arena, pos, color)
		"blink":
			_blink_fx(arena, pos, facing, color)
		"shield":
			_shield_fx(arena, pos, color)
		"dash":
			_dash_fx(arena, pos, facing, color)
		"recon_dash":
			_recon_fx(arena, pos, color)
		"breach":
			_breach_fx(arena, pos, facing, color)
		"bite_cone":
			_bite_fx(arena, pos, facing, color)
		"chain":
			_chain_fx(arena, pos)
		_:
			_ring(arena, pos, color, 6.0)


## A bright white shock-ring overlay for an EVOLVED / COMBO-empowered cast (the "payoff" pop).
static func emphasis(pos: Vector3, arena: Node) -> void:
	if arena == null or DisplayServer.get_name() == "headless":
		return
	_ring(arena, pos, Color(1.0, 1.0, 1.0), 9.0, 0.45)
	_flash(arena, pos + Vector3(0.0, 0.8, 0.0), Color(1.0, 0.95, 0.7), 7.0)


## Camera-shake trauma appropriate to the ability (big slams punch harder).
static func shake_for(ability: String) -> float:
	match ability:
		"meteor":
			return 0.65
		"leap_slam", "breach":
			return 0.5
		"storm", "bite_cone", "chain":
			return 0.32
		_:
			return 0.18


# ------------------------------------------------------------ ability composites
## LEAP SLAM: launch pop at the take-off + the LANDING shockwave at the aim point,
## delayed to the touchdown (matches the server's SKILL_LEAP_TIME AoE).
static func _leap_slam(arena: Node, pos: Vector3, aim: Vector3, color: Color) -> void:
	_ring(arena, pos, color, 4.0, 0.3)
	_particles(arena, pos + Vector3(0, 0.2, 0), color, 16, 0.4, 7.0, -12.0, Vector3(0, 1, 0), 0.3)
	var t: SceneTreeTimer = arena.get_tree().create_timer(Settings.SKILL_LEAP_TIME)
	t.timeout.connect(
		func() -> void:
			if not is_instance_valid(arena):
				return
			_ring(arena, aim, color, 12.0, 0.45)
			_ring(arena, aim, Color(1, 1, 1), 7.0, 0.3)
			_particles(
				arena, aim + Vector3(0, 0.2, 0), color, 28, 0.5, 10.0, -16.0, Vector3(0, 1, 0), 0.35
			)
			_dust(arena, aim)
			_flash(arena, aim + Vector3(0, 0.4, 0), color, 9.0)
	)


## METEOR: a pulsing telegraph ring at the aim point, then a flaming rock DROPS from
## the sky (fire trail) and detonates — flash, double ring, embers, smoke.
static func _meteor(arena: Node, aim: Vector3, color: Color) -> void:
	# Telegraph — two nested rings that live until impact.
	_ring(arena, aim, color, 5.2, Settings.SKILL_METEOR_DELAY)
	_ring(arena, aim, Color(1.0, 0.9, 0.6), 2.4, Settings.SKILL_METEOR_DELAY)
	# The rock: a dark sphere with a fire-emissive core, falling on a tween.
	var rock := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.9
	sm.height = 1.8
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(0.12, 0.08, 0.06)
	rm.emission_enabled = true
	rm.emission = Color(1.0, 0.45, 0.1)
	rm.emission_energy_multiplier = 2.6
	rm.roughness = 0.9
	sm.material = rm
	rock.mesh = sm
	arena.add_child(rock)
	var drop_t: float = maxf(0.25, Settings.SKILL_METEOR_DELAY * 0.35)
	var start: Vector3 = aim + Vector3(3.0, 34.0, -2.0)
	rock.global_position = start
	# Fire trail rides the rock.
	var trail := GPUParticles3D.new()
	trail.amount = 60
	trail.lifetime = 0.5
	trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tpm := ParticleProcessMaterial.new()
	tpm.direction = Vector3(0, 1, 0)
	tpm.spread = 25.0
	tpm.initial_velocity_min = 2.0
	tpm.initial_velocity_max = 5.0
	tpm.gravity = Vector3.ZERO
	tpm.scale_min = 0.25
	tpm.scale_max = 0.6
	tpm.color = Color(1.0, 0.55, 0.15)
	trail.process_material = tpm
	var tmesh := BoxMesh.new()
	tmesh.size = Vector3(0.16, 0.16, 0.16)
	tmesh.material = _emat(Color(1.0, 0.55, 0.15), 1.0)
	trail.draw_pass_1 = tmesh
	rock.add_child(trail)
	trail.emitting = true
	# Fall starts so the rock ARRIVES exactly at SKILL_METEOR_DELAY (server impact).
	var wait: float = maxf(0.0, Settings.SKILL_METEOR_DELAY - drop_t)
	var tw := rock.create_tween()
	tw.tween_interval(wait)
	(
		tw
		. tween_property(rock, "global_position", aim + Vector3(0, 0.4, 0), drop_t)
		. set_trans(Tween.TRANS_QUAD)
		. set_ease(Tween.EASE_IN)
	)
	tw.tween_callback(
		func() -> void:
			if not is_instance_valid(arena):
				return
			_flash(arena, aim + Vector3(0, 0.6, 0), Color(1.0, 0.8, 0.4), 14.0)
			_ring(arena, aim, Color(1.0, 0.55, 0.15), 11.0, 0.5)
			_ring(arena, aim, Color(1.0, 0.9, 0.6), 6.0, 0.35)
			_particles(
				arena,
				aim + Vector3(0, 0.3, 0),
				Color(1.0, 0.5, 0.12),
				42,
				0.7,
				12.0,
				-16.0,
				Vector3(0, 1, 0),
				0.4
			)
			_dust(arena, aim)
	)
	tw.tween_callback(rock.queue_free)


## STORM (Crystal-Maiden field): a swirling ring vortex around the cast point for
## SKILL_STORM_TIME + random explosion pops raining inside the ring the whole time.
static func _storm(arena: Node, pos: Vector3, color: Color) -> void:
	var p := GPUParticles3D.new()
	p.amount = 140
	p.lifetime = 1.1
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0, 1, 0)
	pm.emission_ring_radius = Settings.SKILL_STORM_RING_MAX * 0.8
	pm.emission_ring_inner_radius = Settings.SKILL_STORM_RING_MIN
	pm.emission_ring_height = 0.4
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 14.0
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 3.5
	pm.tangential_accel_min = 16.0
	pm.tangential_accel_max = 26.0
	pm.radial_accel_min = -3.0
	pm.radial_accel_max = -1.0
	pm.gravity = Vector3(0, 2.5, 0)
	pm.scale_min = 0.22
	pm.scale_max = 0.55
	pm.color = color
	p.process_material = pm
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.14, 0.14, 0.14)
	mesh.material = _emat(color, 1.0)
	p.draw_pass_1 = mesh
	arena.add_child(p)
	p.global_position = pos + Vector3(0, 0.4, 0)
	p.emitting = true
	_free_after(p, Settings.SKILL_STORM_TIME + 1.2)
	_ring(arena, pos, color, Settings.SKILL_STORM_RING_MAX, 0.7)
	# Random pops inside the ring for the storm's whole duration (the CM "rain").
	var pops: int = int(Settings.SKILL_STORM_TIME / 0.35)
	for i in pops:
		var t: SceneTreeTimer = arena.get_tree().create_timer(0.25 + 0.35 * float(i))
		t.timeout.connect(
			func() -> void:
				if not is_instance_valid(arena):
					return
				var ang: float = randf() * TAU
				var r: float = randf_range(
					Settings.SKILL_STORM_RING_MIN, Settings.SKILL_STORM_RING_MAX
				)
				var at: Vector3 = pos + Vector3(cos(ang) * r, 0.3, sin(ang) * r)
				_flash(arena, at, color, 7.0)
				_ring(arena, at, color, 2.6, 0.3)
		)


static func _blink_fx(arena: Node, pos: Vector3, facing: Vector3, color: Color) -> void:
	var a := pos + Vector3(0, 1.0, 0)
	var b := pos + facing * 9.0 + Vector3(0, 1.0, 0)
	_flash(arena, a, color, 8.0)
	_flash(arena, b, color, 8.0)
	_beam(arena, a, b, color, 0.08, 0.25)
	_particles(arena, a, color, 16, 0.4, 4.0, 1.5, Vector3(0, 1, 0), 0.25)


static func _shield_fx(arena: Node, pos: Vector3, color: Color) -> void:
	var dome := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.7
	sm.height = 3.4
	dome.mesh = sm
	dome.material_override = _emat(color, 0.2)
	arena.add_child(dome)
	dome.global_position = pos + Vector3(0, 1.0, 0)
	dome.scale = Vector3.ONE * 0.3
	var tw := dome.create_tween()
	tw.tween_property(dome, "scale", Vector3.ONE, 0.2)
	tw.tween_interval(1.4)
	tw.tween_property(dome.material_override, "albedo_color", _fade(color), 0.5)
	tw.tween_callback(dome.queue_free)


static func _dash_fx(arena: Node, pos: Vector3, facing: Vector3, color: Color) -> void:
	_ring(arena, pos, color, 4.0, 0.3)
	_particles(arena, pos + Vector3(0, 0.2, 0), color, 18, 0.4, 7.0, -8.0, Vector3(0, 1, 0), 0.25)
	for k in 3:
		_flash(arena, pos + facing * (1.2 * float(k + 1)) + Vector3(0, 0.6, 0), color, 3.0)


static func _recon_fx(arena: Node, pos: Vector3, color: Color) -> void:
	_ring(arena, pos, color, 22.0, 0.7)
	_ring(arena, pos, color, 14.0, 0.5)
	_flash(arena, pos + Vector3(0, 1.0, 0), color, 6.0)


## BREACH: shock-cone at launch + speed-line bursts down the charge lane (the wall
## chunks the server smashes provide the debris spectacle for free).
static func _breach_fx(arena: Node, pos: Vector3, facing: Vector3, color: Color) -> void:
	_cone_flash(arena, pos + Vector3(0, 0.8, 0), facing, color)
	for i in 3:
		var lp: Vector3 = pos + facing * (2.5 * float(i + 1))
		_ring(arena, lp, color, 3.5 + float(i), 0.3 + 0.08 * float(i))
	var dp := pos + facing * 1.5 + Vector3(0, 0.3, 0)
	_particles(arena, dp, color, 30, 0.45, 12.0, -6.0, facing + Vector3(0, 0.3, 0), 0.3)
	_flash(arena, pos + facing * 6.0 + Vector3(0, 0.5, 0), color, 8.0)


static func _bite_fx(arena: Node, pos: Vector3, facing: Vector3, color: Color) -> void:
	var mouth := pos + Vector3(0, 0.8, 0)
	_cone_flash(arena, mouth, facing, color)
	_particles(arena, mouth + facing * 2.5, color, 20, 0.4, 9.0, -4.0, facing, 0.3)


## Chain shock reads as electric-blue arcs to the nearest machines (or radiating if none).
static func _chain_fx(arena: Node, pos: Vector3) -> void:
	var elec := Color(0.5, 0.9, 1.0)
	var origin := pos + Vector3(0, 1.0, 0)
	_flash(arena, origin, elec, 7.0)
	var tree := arena.get_tree()
	var hits: Array = []
	if tree != null:
		for e in tree.get_nodes_in_group(_ENEMIES):
			if e is Node3D and (e as Node3D).global_position.distance_to(pos) < 8.0:
				hits.append(e)
	hits.sort_custom(
		func(x: Node, y: Node) -> bool:
			return (
				(x as Node3D).global_position.distance_to(pos)
				< (y as Node3D).global_position.distance_to(pos)
			)
	)
	var prev := origin
	var cnt := 0
	for e in hits:
		if cnt >= 4:
			break
		var tp: Vector3 = (e as Node3D).global_position + Vector3(0, 0.8, 0)
		_beam(arena, prev, tp, elec, 0.06, 0.3)
		prev = tp
		cnt += 1
	if cnt == 0:
		for k in 4:
			var ang := float(k) / 4.0 * TAU
			_beam(
				arena,
				origin,
				origin + Vector3(cos(ang) * 4.0, 0.0, sin(ang) * 4.0),
				elec,
				0.06,
				0.3
			)


# ------------------------------------------------------------ primitive builders
## Expanding emissive torus ring on the ground (the classic shockwave/ping).
static func _ring(arena: Node, pos: Vector3, color: Color, max_r: float, life: float = 0.4) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.45
	tm.outer_radius = 0.6
	ring.mesh = tm
	ring.material_override = _emat(color, 0.85)
	arena.add_child(ring)
	ring.global_position = pos + Vector3(0, 0.25, 0)
	ring.rotation_degrees = Vector3(90, 0, 0)
	ring.scale = Vector3.ONE * 0.2
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 5.0
	light.omni_range = 6.0
	ring.add_child(light)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * max_r, life)
	tw.tween_property(ring.material_override, "albedo_color", _fade(color), life)
	tw.tween_property(light, "light_energy", 0.0, life * 0.8)
	tw.set_parallel(false)
	tw.tween_callback(ring.queue_free)


## A stretched, fading cylinder beam between two world points (mortar arc / blink line / arc).
static func _beam(
	arena: Node, from: Vector3, to: Vector3, color: Color, radius: float, life: float
) -> void:
	var seg := to - from
	var ln := seg.length()
	if ln < 0.01:
		return
	var dir := seg / ln
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.cap_top = false
	mesh.cap_bottom = false
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _emat(color, 0.85)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arena.add_child(mi)
	var up_ref := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var bx := up_ref.cross(dir).normalized()
	var bz := bx.cross(dir).normalized()
	var b := Basis(bx, dir, bz).scaled(Vector3(1, ln, 1))
	mi.global_transform = Transform3D(b, (from + to) * 0.5)
	var tw := mi.create_tween()
	tw.tween_property(mi.material_override, "albedo_color", _fade(color), life)
	tw.tween_callback(mi.queue_free)


## A forward-pointing cone flash (the bite maw).
static func _cone_flash(arena: Node, pos: Vector3, facing: Vector3, color: Color) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = 1.6
	mesh.height = 3.0
	mesh.radial_segments = 10
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _emat(color, 0.45)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arena.add_child(mi)
	# Cone axis is +Y; point it along `facing`, base at the mouth, tip forward.
	var dir := facing.normalized()
	var up_ref := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var bx := up_ref.cross(dir).normalized()
	var bz := bx.cross(dir).normalized()
	mi.global_transform = Transform3D(Basis(bx, dir, bz), pos + dir * 1.5)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(1.3, 1.0, 1.3), 0.25)
	tw.tween_property(mi.material_override, "albedo_color", _fade(color), 0.25)
	tw.set_parallel(false)
	tw.tween_callback(mi.queue_free)


## A bright omni-light + additive billboard pop (muzzle-flash style).
static func _flash(arena: Node, pos: Vector3, color: Color, energy: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = 6.0
	l.shadow_enabled = false
	arena.add_child(l)
	l.global_position = pos
	var spr := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1.4, 1.4)
	spr.mesh = qm
	var m := _emat(color, 0.9)
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	spr.material_override = m
	arena.add_child(spr)
	spr.global_position = pos
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "light_energy", 0.0, 0.25)
	tw.tween_property(spr, "scale", Vector3.ONE * 2.2, 0.25)
	tw.tween_property(m, "albedo_color", _fade(color), 0.25)
	tw.set_parallel(false)
	tw.tween_callback(l.queue_free)
	tw.tween_callback(spr.queue_free)


## A one-shot GPU particle burst (debris/sparks). Frees itself after its lifetime.
static func _particles(
	arena: Node,
	pos: Vector3,
	color: Color,
	amount: int,
	life: float,
	vmax: float,
	grav_y: float,
	dir: Vector3,
	msize: float = 0.3
) -> void:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.7
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.35
	pm.direction = dir
	pm.spread = 55.0
	pm.initial_velocity_min = vmax * 0.4
	pm.initial_velocity_max = vmax
	pm.gravity = Vector3(0, grav_y, 0)
	pm.scale_min = msize * 0.5
	pm.scale_max = msize
	pm.color = color
	p.process_material = pm
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.1, 0.1, 0.1)
	mesh.material = _emat(color, 1.0)
	p.draw_pass_1 = mesh
	arena.add_child(p)
	p.global_position = pos
	p.emitting = true
	_free_after(p, life + 0.3)


static func _dust(arena: Node, pos: Vector3) -> void:
	_particles(
		arena,
		pos + Vector3(0, 0.1, 0),
		Color(0.62, 0.62, 0.64),
		20,
		0.7,
		4.0,
		1.0,
		Vector3(0, 1, 0),
		0.5
	)


# ------------------------------------------------------------ shared material/util
static func _emat(color: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 4.0
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _fade(color: Color) -> Color:
	return Color(color.r, color.g, color.b, 0.0)


static func _free_after(node: Node, secs: float) -> void:
	var tw := node.create_tween()
	tw.tween_interval(secs)
	tw.tween_callback(node.queue_free)
