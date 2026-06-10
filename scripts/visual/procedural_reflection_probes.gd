class_name ProceduralReflectionProbes
extends RefCounted
## "Ultra+RT" tier extra: spawns a handful of baked ReflectionProbe nodes at the map's
## POIs so reflective/metallic surfaces show OFF-SCREEN reflections (SSR can only reflect
## what's currently on screen; probes fill in the rest). These blend with the SDFGI the
## active WorldEnvironment already has on.
##
## RENDER-ONLY + PER-PEER COSMETIC (same discipline as flora/atmosphere):
##   - NO collision, NO nav, NO groups used by gameplay, NO netcode.
##   - DETERMINISTIC: placement derives ONLY from the POI marker positions (no randf /
##     randi / Time), so every co-op peer builds identical probes — but since they touch
##     nothing authoritative this only matters for visual parity.
##   - SKIPPED on a headless/dedicated server (no rendering there).
##
## UPDATE_ONCE = the probe captures the environment a single time then re-uses it (cheap);
## UPDATE_ALWAYS would re-capture every frame and is far too expensive for a static map.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; the Dictionary/Variant
## locals below are explicitly typed.

# How many probes to place at most (bounds GPU cost — each probe is a captured cubemap).
const MAX_PROBES := 8
# Box the probe covers, in metres (roughly a POI footprint + some headroom). Box
# projection re-projects the captured reflection onto this box for plausible parallax.
const PROBE_SIZE := Vector3(34.0, 22.0, 34.0)
# Height (m) above the marker to centre the box so it spans ground→roof of the POI.
const PROBE_HEIGHT := 8.0
const PROBE_INTENSITY := 1.0


## Adds a "ReflectionProbes" Node3D under `parent` holding one ReflectionProbe per POI
## marker (capped at MAX_PROBES). No-op on headless or when the tier toggle is off.
static func build(parent: Node3D, poi_markers: Node3D) -> void:
	if parent == null or poi_markers == null:
		return
	# No rendering on a dedicated/headless server — probes would do nothing but cost RAM.
	if DisplayServer.get_name() == "headless":
		return
	if not Settings.reflection_probes_enabled:
		return
	var root := Node3D.new()
	root.name = "ReflectionProbes"
	parent.add_child(root)
	var markers := poi_markers.get_children()
	var count: int = mini(markers.size(), MAX_PROBES)
	for i in range(count):
		var marker := markers[i] as Node3D
		if marker == null:
			continue
		var probe := ReflectionProbe.new()
		probe.name = "Probe_%d" % i
		# Baked ONCE (cheap), box-projected for parallax-correct reflections within the box.
		probe.update_mode = ReflectionProbe.UPDATE_ONCE
		probe.box_projection = true
		probe.size = PROBE_SIZE
		probe.intensity = PROBE_INTENSITY
		probe.interior = false
		probe.enable_shadows = false  # cheaper capture; SDFGI/sun already shade the world
		probe.max_distance = 0.0  # 0 = unlimited capture distance
		root.add_child(probe)
		# Position AFTER add_child so global_position is meaningful; raise to roof height
		# so the box spans the whole POI structure rather than sitting on the floor.
		probe.global_position = marker.global_position + Vector3(0.0, PROBE_HEIGHT, 0.0)


## EXPERIMENTAL: a single runtime-baked VoxelGI over the playable bounds. This is VERY
## heavy on a 160 m map (a full-extent voxel grid + a runtime bake stalls the frame), so
## it is OFF by default and gated behind Settings.voxelgi_enabled. We create + size the
## node and do a LOW-subdiv bake best-effort; callers should treat it as opt-in eye-candy.
## `bounds` is the half-extent (metres) of the playable area to cover.
static func build_voxelgi(parent: Node3D, bounds: Vector3) -> void:
	if parent == null:
		return
	if DisplayServer.get_name() == "headless":
		return
	if not Settings.voxelgi_enabled:
		return
	push_warning(
		(
			"ProceduralReflectionProbes.build_voxelgi: EXPERIMENTAL runtime VoxelGI bake on a"
			+ " large map — this can stall the frame; intended as opt-in eye-candy only."
		)
	)
	var gi := VoxelGI.new()
	gi.name = "ExperimentalVoxelGI"
	# Lowest subdivision keeps the runtime bake from being catastrophic on the 160 m map.
	gi.subdiv = VoxelGI.SUBDIV_64
	var data := VoxelGIData.new()
	gi.data = data
	gi.size = bounds * 2.0
	parent.add_child(gi)
	gi.global_position = Vector3.ZERO
	# Best-effort bake. If this proves too heavy in practice, the node still exists and a
	# later authored/baked data resource can be assigned without re-touching this code.
	gi.bake()
