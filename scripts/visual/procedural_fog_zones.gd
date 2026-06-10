class_name ProceduralFogZones
extends RefCounted
## Localized "smoke bank" fog: a handful of ELLIPSOID FogVolume nodes at chosen LANDMARKS
## (the North Tower + the south-west POIs) and low river-valley points. The GLOBAL
## volumetric fog density is now ZERO (world_atmosphere) — these volumes are the ONLY fog
## in the world, so from afar each reads as a distinct smoke bank over its landmark, and
## up close (edge_fade) you walk INTO it smoothly and it reads as fog. The player spawn
## corner is kept clear (SPAWN_EXCLUDE).
##
## RENDER-ONLY + PER-PEER COSMETIC (same discipline as reflection-probes / atmosphere):
##   - NO collision, NO nav, NO groups used by gameplay, NO netcode.
##   - DETERMINISTIC: placement derives ONLY from the POI marker positions + fixed
##     river-valley constants (no randf / randi / Time), so every co-op peer is identical.
##   - SKIPPED on a headless/dedicated server and when Settings.local_fog_enabled is off.
##
## NOTE: FogVolumes only render when the active Environment's volumetric_fog_enabled is
## true — driven by the quality setting (world_atmosphere._apply_graphics_quality), which
## also raises volumetric_fog_length so the banks are visible across the whole map.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals are explicitly typed.

const ZONE_ALBEDO := Color(0.8, 0.85, 0.9)
const ZONE_EDGE_FADE := 0.5  # high = SOFT, smooth-transition edges (walk-in feels gradual)
# Zones whose CENTRE is closer than this to the player-spawn cluster are skipped, so the
# start area is always clear (zone radius ~20 m → visible mist stays ~20 m+ further out).
const SPAWN_EXCLUDE_RADIUS := 40.0
# Fallback spawn centre (the Arena passes the real marker centroid; this matches it).
const SPAWN_FALLBACK := Vector3(58.0, 0.0, 62.0)

# Per-landmark zone profiles. POI order matches arena.gd _POI_DEFS keys():
#   0 NorthTower · 1 EastWarehouse · 2 Plaza · 3 SWHouse · 4 SouthYard · 5 EastYard
# EastYard is deliberately ABSENT (it sits ~21 m from the player spawn corner).
# The tower gets a TALL, dense plume (low height_falloff = a volumetric smoke column you
# can see across the map); the south POIs + river get wide ground-hugging mist pools.
const POI_ZONES := {
	0: {"size": Vector3(44.0, 24.0, 44.0), "height": 8.0, "density": 1.4, "falloff": 0.08},  # NorthTower plume
	3: {"size": Vector3(40.0, 14.0, 40.0), "height": 4.0, "density": 1.1, "falloff": 0.25},  # SWHouse mist
	4: {"size": Vector3(40.0, 14.0, 40.0), "height": 4.0, "density": 1.1, "falloff": 0.25},  # SouthYard mist
}
# Extra pools at river-valley centreline points (the deep channel collects mist).
const RIVER_POINTS := [Vector3(16.0, 0.0, 38.0), Vector3(10.0, 0.0, 62.0)]
const RIVER_ZONE := {
	"size": Vector3(36.0, 12.0, 36.0), "height": 3.0, "density": 0.9, "falloff": 0.35
}


## Adds a "FogZones" Node3D under `parent` holding one ELLIPSOID FogVolume per landmark.
## `spawn_center` = the player-spawn centroid (zones inside SPAWN_EXCLUDE_RADIUS are
## skipped). No-op on headless or when the toggle is off.
static func build(
	parent: Node3D, poi_markers: Node3D, spawn_center: Vector3 = SPAWN_FALLBACK
) -> void:
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
	# Banks at the chosen POI landmarks.
	if poi_markers != null:
		var markers := poi_markers.get_children()
		for i in POI_ZONES.keys():
			var mi := int(i)
			if mi < 0 or mi >= markers.size():
				continue
			var marker := markers[mi] as Node3D
			if marker == null:
				continue
			var prof: Dictionary = POI_ZONES[i]
			var pos: Vector3 = marker.global_position + Vector3(0.0, float(prof["height"]), 0.0)
			_add_zone(root, "FogZone_POI_%d" % idx, pos, prof, spawn_center)
			idx += 1
	# Pools along the river valley.
	for p in RIVER_POINTS:
		var rp: Vector3 = p + Vector3(0.0, float(RIVER_ZONE["height"]), 0.0)
		_add_zone(root, "FogZone_River_%d" % idx, rp, RIVER_ZONE, spawn_center)
		idx += 1
	# Apply the user's density multiplier to the freshly built zones.
	apply_density(parent)


static func _add_zone(
	root: Node3D, zone_name: String, world_pos: Vector3, prof: Dictionary, spawn_center: Vector3
) -> void:
	# Keep the start area clear: skip any zone whose centre is near the spawn cluster.
	var flat_zone := Vector3(world_pos.x, 0.0, world_pos.z)
	var flat_spawn := Vector3(spawn_center.x, 0.0, spawn_center.z)
	if flat_zone.distance_to(flat_spawn) < SPAWN_EXCLUDE_RADIUS:
		return
	var fog := FogVolume.new()
	fog.name = zone_name
	fog.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fog.size = prof["size"]
	var mat := FogMaterial.new()
	mat.density = float(prof["density"])
	mat.albedo = ZONE_ALBEDO
	mat.edge_fade = ZONE_EDGE_FADE
	mat.height_falloff = float(prof["falloff"])
	fog.material = mat
	# Remember the authored base density so the settings slider can rescale it live.
	fog.set_meta("base_density", float(prof["density"]))
	root.add_child(fog)
	# Position AFTER add_child so global_position is meaningful.
	fog.global_position = world_pos


## LIVE: rescale every zone's density by the user's "Local Fog Density" multiplier
## (SettingsManager "volumetric_fog_density", 0..2, default 1.0). Called by
## world_atmosphere on every graphics-settings change — no rebuild needed.
static func apply_density(scene_root: Node) -> void:
	if scene_root == null:
		return
	var zones := scene_root.find_child("FogZones", true, false)
	if zones == null:
		return
	var mult: float = clampf(float(SettingsManager.get_value("volumetric_fog_density")), 0.0, 2.0)
	for c in zones.get_children():
		if c is FogVolume and (c as FogVolume).material is FogMaterial:
			var base: float = (
				float(c.get_meta("base_density")) if c.has_meta("base_density") else 1.0
			)
			((c as FogVolume).material as FogMaterial).density = base * mult
