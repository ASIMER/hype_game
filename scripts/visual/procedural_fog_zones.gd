class_name ProceduralFogZones
extends RefCounted
## Localized ground-hugging mist pools: a handful of ELLIPSOID FogVolume nodes placed at a
## few POI markers + low-lying river-valley spots. Each carries a FogMaterial with SOFT
## edges (high edge_fade) so the mist fades smoothly into the global volumetric fog rather
## than showing a hard boundary, and a height_falloff that keeps it hugging the ground.
##
## RENDER-ONLY + PER-PEER COSMETIC (same discipline as reflection-probes / atmosphere):
##   - NO collision, NO nav, NO groups used by gameplay, NO netcode.
##   - DETERMINISTIC: placement derives ONLY from the POI marker positions + fixed
##     river-valley constants (no randf / randi / Time), so every co-op peer is identical.
##   - SKIPPED on a headless/dedicated server (no rendering there) and when the
##     Settings.local_fog_enabled toggle is off.
##
## NOTE: FogVolumes only render when the active Environment's volumetric_fog_enabled is
## true — that's driven by the quality setting (world_atmosphere._apply_graphics_quality).
## The zones are placed regardless and simply appear once global volumetric fog is on.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals are explicitly typed.

# A wide, shallow pool — wide footprint, short height so the mist reads as ground fog.
const ZONE_SIZE := Vector3(40.0, 14.0, 40.0)
# Centre height (m) above the marker — raise so the pool's base sits near the ground.
const ZONE_HEIGHT := 4.0
const ZONE_DENSITY := 0.4
const ZONE_ALBEDO := Color(0.8, 0.85, 0.9)
const ZONE_EDGE_FADE := 0.5      # high = SOFT, smooth-transition edges (the requirement)
const ZONE_HEIGHT_FALLOFF := 0.3 # ground-hugging mist (density falls off with height)

# Which POI markers (by index) get a fog pool. A low-lying SUBSET — not every POI — so the
# mist feels placed, not blanket. POI order matches arena.gd _POI_DEFS keys().
const POI_INDICES := [3, 4, 5]   # SWHouse, SouthYard, EastYard (the low south basin)
# Extra fog pools at river-valley centreline points (the deep channel collects mist).
const RIVER_POINTS := [Vector3(16.0, 0.0, 38.0), Vector3(10.0, 0.0, 62.0)]

## Adds a "FogZones" Node3D under `parent` holding one ELLIPSOID FogVolume per chosen POI
## marker + the river-valley points. No-op on headless or when the toggle is off.
static func build(parent: Node3D, poi_markers: Node3D) -> void:
	if parent == null:
		return
	# No rendering on a dedicated/headless server — fog volumes would do nothing but cost.
	if DisplayServer.get_name() == "headless":
		return
	if not Settings.local_fog_enabled:
		return
	var root := Node3D.new()
	root.name = "FogZones"
	parent.add_child(root)

	var idx := 0
	# Pools at the chosen POI markers.
	if poi_markers != null:
		var markers := poi_markers.get_children()
		for i in POI_INDICES:
			if i < 0 or i >= markers.size():
				continue
			var marker := markers[i] as Node3D
			if marker == null:
				continue
			var pos: Vector3 = marker.global_position + Vector3(0.0, ZONE_HEIGHT, 0.0)
			_add_zone(root, "FogZone_POI_%d" % idx, pos)
			idx += 1
	# Pools along the river valley.
	for p in RIVER_POINTS:
		var rp: Vector3 = p + Vector3(0.0, ZONE_HEIGHT, 0.0)
		_add_zone(root, "FogZone_River_%d" % idx, rp)
		idx += 1

static func _add_zone(root: Node3D, zone_name: String, world_pos: Vector3) -> void:
	var fog := FogVolume.new()
	fog.name = zone_name
	fog.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fog.size = ZONE_SIZE
	var mat := FogMaterial.new()
	mat.density = ZONE_DENSITY
	mat.albedo = ZONE_ALBEDO
	mat.edge_fade = ZONE_EDGE_FADE
	mat.height_falloff = ZONE_HEIGHT_FALLOFF
	fog.material = mat
	root.add_child(fog)
	# Position AFTER add_child so global_position is meaningful.
	fog.global_position = world_pos
