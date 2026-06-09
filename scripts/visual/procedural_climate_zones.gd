class_name ProceduralClimateZones
extends RefCounted
## Localized CLIMATE zones at the 3 far-quadrant landmarks (paired with their themed buildings):
##   RAIN over the Temple (SE) · SNOW over the Alpine Lodge (NE) · DESERT sand-haze over the
##   Ruins (SW).
## Each zone = a GPUParticles3D (precipitation / blowing haze) + a ground Decal (wet / snow /
## sand tint that conforms to the terrain) + a FogVolume (local atmosphere tint). The climate is
## LOCALIZED — pointwise around each landmark, exactly like ProceduralFogZones — so you stand AT
## the landmark and it rains/snows/blows sand, and walking away (beyond the zone radius) fades it
## out and the base climate returns. NOT whole-map.
##
## RENDER-ONLY + PER-PEER COSMETIC (same discipline as ProceduralFogZones / reflection-probes /
## atmosphere):
##   - NO collision, NO nav, NO groups used by gameplay, NO netcode.
##   - DETERMINISTIC placement: zone centres come ONLY from the POI marker positions (no
##     randf/randi/Time). Particle SIMULATION is GPU-side + cosmetic, so it need not match across
##     peers — only gameplay is authoritative.
##   - SKIPPED on a headless/dedicated server and when Settings.climate_zones_enabled is off.
##
## The FogVolume part only renders when the active Environment's volumetric fog is on (driven by
## the quality preset, like ProceduralFogZones); the PARTICLES + DECAL always render, so the
## climate reads regardless of the fog setting.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals are explicitly typed.

# Climate profiles keyed by POI index — arena.gd _POI_DEFS keys() order:
#   0..5 = original NW POIs · 6 SnowLodge · 7 SnowDepot · 8 DesertRuins · 9 RuinColumns ·
#   10 Temple · 11 ShrineHouse.  The 3 landmarks (6/8/10) get the climate zones.
const ZONES := {
	10: { "kind": "rain",   "radius": 33.0, "top": 26.0 },  # Temple (SE)
	6:  { "kind": "snow",   "radius": 35.0, "top": 24.0 },  # Alpine Lodge (NE)
	8:  { "kind": "desert", "radius": 38.0, "top": 16.0 },  # Desert Ruins (SW)
}

# Per-kind base particle counts (scaled by particle_density at build + climate_density live).
const BASE_AMOUNT := { "rain": 950, "snow": 460, "desert": 320 }

# Cached soft-radial decal texture (white RGB, radial alpha) — one shared instance.
static var _radial: ImageTexture = null

## Adds a "ClimateZones" Node3D under `parent` with one climate zone per far landmark.
## No-op on headless or when the toggle is off.
static func build(parent: Node3D, poi_markers: Node3D) -> void:
	if parent == null:
		return
	if DisplayServer.get_name() == "headless":
		return
	if not Settings.climate_zones_enabled:
		return
	if poi_markers == null:
		return
	var root := Node3D.new()
	root.name = "ClimateZones"
	parent.add_child(root)
	var markers := poi_markers.get_children()
	for i in ZONES.keys():
		var mi: int = int(i)
		if mi < 0 or mi >= markers.size():
			continue
		var marker := markers[mi] as Node3D
		if marker == null:
			continue
		_add_zone(root, marker.global_position, ZONES[i])
	# Apply the live density multiplier to the freshly built zones.
	apply_density(parent)

static func _add_zone(root: Node3D, center: Vector3, prof: Dictionary) -> void:
	var kind: String = String(prof["kind"])
	var radius: float = float(prof["radius"])
	var top: float = float(prof["top"])
	# Particle count scales with the ambient particle-density quality lever (like dust/embers).
	var pd: float = clampf(float(SettingsManager.get_value("particle_density")), 0.0, 1.5)
	var zone := Node3D.new()
	zone.name = "Climate_%s" % kind
	root.add_child(zone)
	zone.global_position = Vector3(center.x, 0.0, center.z)
	# Precipitation / haze.
	var p := _build_particles(kind, radius, top, pd)
	zone.add_child(p)
	# Ground tint (conforms to terrain relief).
	var dec := _build_decal(kind, radius)
	zone.add_child(dec)
	# Local atmosphere FogVolume (renders only when volumetric fog is enabled).
	var fog := _build_fog(kind, radius, top)
	zone.add_child(fog)

# ---------------------------------------------------------------- particles
static func _build_particles(kind: String, radius: float, top: float, pd: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Precip"
	p.amount = maxi(1, int(float(int(BASE_AMOUNT.get(kind, 300))) * clampf(pd, 0.05, 1.5)))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.fixed_fps = 24
	p.randomness = 1.0
	# Live density lever (climate_density) rides on amount_ratio (0..1); base stays in amount.
	p.amount_ratio = clampf(Settings.climate_density, 0.0, 1.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	match kind:
		"rain":
			# Fast straight downpour from the top of the column.
			p.position = Vector3(0.0, top, 0.0)
			p.lifetime = 1.3
			p.preprocess = 1.3
			pm.emission_box_extents = Vector3(radius, 0.5, radius)
			pm.direction = Vector3(0.05, -1.0, 0.03)
			pm.spread = 3.0
			pm.gravity = Vector3(0.0, -34.0, 0.0)
			pm.initial_velocity_min = 14.0
			pm.initial_velocity_max = 20.0
			pm.scale_min = 0.9
			pm.scale_max = 1.5
			# Brighter, wider, longer streaks at higher alpha so the downpour clearly reads
			# against the bright sky/grass (the thin faint version barely registered).
			pm.color = Color(0.74, 0.82, 0.94, 0.60)
			p.draw_pass_1 = _precip_mesh(0.05, 1.5, Color(0.78, 0.85, 0.96, 0.60), false)
		"snow":
			# Slow drifting flakes with turbulence sway.
			p.position = Vector3(0.0, top, 0.0)
			p.lifetime = 8.0
			p.preprocess = 8.0
			pm.emission_box_extents = Vector3(radius, 0.5, radius)
			pm.direction = Vector3(0.1, -1.0, 0.1)
			pm.spread = 12.0
			pm.gravity = Vector3(0.0, -1.6, 0.0)
			pm.initial_velocity_min = 0.6
			pm.initial_velocity_max = 1.6
			pm.scale_min = 0.6
			pm.scale_max = 1.4
			pm.turbulence_enabled = true
			pm.turbulence_noise_strength = 0.9
			pm.turbulence_noise_scale = 1.2
			pm.turbulence_influence_min = 0.1
			pm.turbulence_influence_max = 0.4
			pm.color = Color(0.95, 0.97, 1.0, 0.92)
			p.draw_pass_1 = _precip_mesh(0.075, 0.075, Color(0.96, 0.98, 1.0, 0.92), false)
		_:  # desert sand-haze — warm dust blowing horizontally, fills the whole volume.
			p.position = Vector3(0.0, top * 0.45, 0.0)
			p.lifetime = 6.0
			p.preprocess = 6.0
			pm.emission_box_extents = Vector3(radius, top * 0.45, radius)
			pm.direction = Vector3(1.0, 0.12, 0.35)
			pm.spread = 30.0
			pm.gravity = Vector3(0.2, -0.15, 0.1)
			pm.initial_velocity_min = 2.0
			pm.initial_velocity_max = 5.5
			pm.scale_min = 1.0
			pm.scale_max = 2.6
			pm.turbulence_enabled = true
			pm.turbulence_noise_strength = 0.6
			pm.turbulence_noise_scale = 0.8
			pm.turbulence_influence_min = 0.1
			pm.turbulence_influence_max = 0.5
			pm.color = Color(0.80, 0.66, 0.40, 0.14)
			p.draw_pass_1 = _precip_mesh(0.55, 0.55, Color(0.82, 0.68, 0.42, 0.14), true)
	p.process_material = pm
	# Bound the draw to the zone column so it culls when off-screen / far away.
	p.visibility_aabb = AABB(Vector3(-radius, -2.0, -radius), Vector3(radius * 2.0, top + 6.0, radius * 2.0))
	p.emitting = true
	return p

## A camera-facing particle quad (streak for rain, dot for snow, soft puff for sand). `additive`
## uses ADD blend (faint haze) else ALPHA blend (visible precipitation).
static func _precip_mesh(w: float, h: float, col: Color, additive: bool) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(w, h)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_color = col
	m.disable_receive_shadows = true
	q.material = m
	return q

# ---------------------------------------------------------------- ground decal
static func _build_decal(kind: String, radius: float) -> Decal:
	var dec := Decal.new()
	dec.name = "GroundTint"
	# y is the vertical projection depth — generous so it conforms over terrain relief.
	dec.size = Vector3(radius * 2.0, 12.0, radius * 2.0)
	dec.position = Vector3(0.0, 1.0, 0.0)
	dec.texture_albedo = _radial_texture()
	dec.upper_fade = 0.3
	dec.lower_fade = 0.3
	match kind:
		"rain":
			dec.modulate = Color(0.16, 0.18, 0.22)   # dark wet sheen
			dec.albedo_mix = 0.55
		"snow":
			dec.modulate = Color(0.93, 0.96, 1.0)    # white snow blanket
			dec.albedo_mix = 0.88
		_:  # desert
			dec.modulate = Color(0.80, 0.66, 0.38)   # warm sand
			dec.albedo_mix = 0.6
	return dec

## A soft white radial-alpha texture (1 at centre → 0 at the rim) — the decal's circular mask.
## Cached + shared across zones.
static func _radial_texture() -> ImageTexture:
	if _radial != null:
		return _radial
	var n: int = 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var dx: float = (float(x) / float(n - 1) - 0.5) * 2.0
			var dy: float = (float(y) / float(n - 1) - 0.5) * 2.0
			var r: float = sqrt(dx * dx + dy * dy)
			var a: float = clampf(1.0 - smoothstep(0.55, 1.0, r), 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_radial = ImageTexture.create_from_image(img)
	return _radial

# ---------------------------------------------------------------- local fog
static func _build_fog(kind: String, radius: float, top: float) -> FogVolume:
	var fog := FogVolume.new()
	fog.name = "ClimateFog"
	fog.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fog.size = Vector3(radius * 2.0, top * 0.9, radius * 2.0)
	fog.position = Vector3(0.0, top * 0.35, 0.0)
	var mat := FogMaterial.new()
	mat.edge_fade = 0.5
	var base: float = 0.5
	match kind:
		"rain":
			mat.albedo = Color(0.55, 0.60, 0.68)
			base = 0.7
			mat.height_falloff = 0.2
		"snow":
			mat.albedo = Color(0.90, 0.93, 0.98)
			base = 0.5
			mat.height_falloff = 0.25
		_:  # desert
			mat.albedo = Color(0.84, 0.71, 0.45)
			base = 0.55
			mat.height_falloff = 0.18
	mat.density = base * clampf(Settings.climate_density, 0.0, 2.0)
	fog.material = mat
	fog.set_meta("climate_base_density", base)
	return fog

# ---------------------------------------------------------------- live density
## LIVE: rescale every climate zone by the user's "Climate Density" multiplier
## (Settings.climate_density, 0..2). Particle amount rides amount_ratio (0..1); fog density
## scales the full 0..2 range. Called by world_atmosphere on every graphics-settings change.
static func apply_density(scene_root: Node) -> void:
	if scene_root == null:
		return
	var zones := scene_root.find_child("ClimateZones", true, false)
	if zones == null:
		return
	var mult: float = clampf(Settings.climate_density, 0.0, 2.0)
	for zone in zones.get_children():
		for c in (zone as Node).get_children():
			if c is GPUParticles3D:
				(c as GPUParticles3D).amount_ratio = clampf(mult, 0.0, 1.0)
			elif c is FogVolume and (c as FogVolume).material is FogMaterial:
				var fm := (c as FogVolume).material as FogMaterial
				var b: float = float(c.get_meta("climate_base_density")) if c.has_meta("climate_base_density") else 0.5
				fm.density = b * mult
