class_name ProceduralBuildingDetail
extends RefCounted
## Rooftop / facade / street DETAIL KITS for the procedural POI buildings — AC units,
## antennas, vent stacks, water tanks, drainpipes, barriers, benches, crates, fallen
## sandstone blocks and street lamps — batched as ONE MultiMeshInstance3D per kit type
## MAP-WIDE (unit BoxMesh/CylinderMesh primitives; each instance bakes its real size
## into the per-instance Transform3D basis).
##
## RENDER-ONLY + PER-PEER COSMETIC (the ProceduralClimateZones discipline):
##   - NO collision, NO nav impact, NO netcode. Everything lives under the ARENA ROOT
##     ("BuildingDetail"), NEVER under NavigationRegion3D — the golden determinism
##     snapshot (GoldenSnapshot) folds only NavigationRegion3D children and must not move.
##   - DETERMINISTIC: every position/yaw/kit pick hashes off the POI index via ProcHash
##     (no randf/randi/Time).
##   - SKIPPED on a headless/dedicated server.
##
## Night identity: each street lamp adds a real OmniLight3D (energy 0 by day) in
## Groups.NIGHT_LIGHTS, tagged with the SHARED emissive head material via the
## "night_glow_mat" meta — world_atmosphere._apply_sun_ambient raises light + glow as
## the sun drops.
##
## INTERIOR LIGHT (D3): the sun never reaches a building interior, so at NOON an indoor
## frame measured 99% of pixels under the readable floor. Every roofed volume therefore
## gets 1-3 warm ceiling lamps (see _interior_lamps). They are deliberately NOT in
## Groups.NIGHT_LIGHTS — that group is MULTIPLIED by (1 - sun_ratio), which would switch
## them off exactly at midday. They live in INTERIOR_LIGHTS_GROUP, burn at a constant
## energy around the clock, and are budgeted by DISTANCE instead (gate_interior_lights).
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

# Per-theme flat-roof height fallbacks — used only if a building root lost its "roof_h"
# meta (set by the build_tower/build_warehouse/build_house hooks).
const _FALLBACK_ROOF_H := {"tower": 9.0, "warehouse": 5.0, "house": 6.0, "yard": 2.6}
const _FLAT_ROOF_THEMES: Array[String] = ["tower", "warehouse", "house"]
const _URBAN_THEMES: Array[String] = ["tower", "warehouse", "house", "yard", "plaza"]
const _EVAC_CLEARANCE := 11.0  # street pieces keep this far from every extraction zone
const _LAMP_CAP := 14  # map-wide street-lamp budget (each carries a live OmniLight3D)
const _WARM := Color(1.0, 0.82, 0.55)

# --- Interior ceiling lamps (D3) -------------------------------------------------
## Own group, NOT Groups.NIGHT_LIGHTS: the night drive scales that group by (1 - sun),
## i.e. it would black out every interior at noon — the exact frame this fixes. (It is
## declared here rather than in Groups.gd because that file belongs to another lane;
## moving the string there later is a pure rename.)
const INTERIOR_LIGHTS_GROUP := "interior_lights"
## Camera distance beyond which a lamp is switched off. VISUALLY FREE: omni_range is
## 8.5 m, so a lamp 35 m away already contributes nothing — this only stops the
## renderer from clustering light volumes nobody can see.
const INTERIOR_LIGHT_DIST := 35.0
## Hard cap on simultaneously lit interior lamps (nearest-first). Forward+ pays per
## light volume touching a cluster, and a raid can have ~30 of these map-wide.
const INTERIOR_LIGHT_ACTIVE_MAX := 12
const _INTERIOR_WARM := Color(1.0, 0.74, 0.44)  # incandescent/sodium, vs the cold grade
const _INTERIOR_ENERGY := 3.6
const _INTERIOR_RANGE := 8.5
const _INTERIOR_GLOW := 3.2  # emissive energy of the plafond disc (never gated → no pop)
const _INTERIOR_PER_BUILDING_MAX := 6  # lamps per POI, spread over its floors
const _INTERIOR_GATE_PERIOD := 0.35  # seconds between distance-gate passes
const _ADOPT_BUILDER_LIGHTS := true  # also budget ProceduralBuildings' own fixtures
const _STOREY_H := 3.0  # tower/house storey height in ProceduralBuildings
const _WALL_INSET := 1.4  # lamps stay this far inside the footprint walls
const _CEIL_DROP := 0.45  # lamp hangs this far below the ceiling PLANE (slab is 0.3 thick)
## Lamp spots inside a volume: the four quarter-points, walked as a ring so consecutive
## lamps land in opposite corners (deterministic start index per building).
const _QUAD: Array[Vector2] = [Vector2(1, -1), Vector2(-1, -1), Vector2(-1, 1), Vector2(1, 1)]
const _CYL_KITS: Array[String] = [
	"ac_fan",
	"antenna",
	"water_tank",
	"drainpipe",
	"lamp_pole",
	"ceiling_lamp",
	"ceiling_bulb",
	# --- D3.4 street props ---
	"barrel",
	"barrel_band",
	"sign_post",
	"bin",
	"pipe",
	"spool_flange",
	"spool_hub",
	"wreck_wheel",
]
## Tapered kits (traffic cones) — a CylinderMesh with a near-zero top radius.
const _CONE_KITS: Array[String] = ["cone"]
const _NO_SHADOW_KITS: Array[String] = ["antenna", "ceiling_lamp", "ceiling_bulb", "barrel_band"]


## BATCHED RUBBLE for arena._rebuild_scatter: the SAME per-pile ProcHash chunk math as
## ProceduralBuildings.rubble_pile (seeds i*137+11 in `positions` order — cover geometry
## byte-identical), but render collapses from ~150 per-chunk MeshInstance3D draws into
## THREE map-wide MultiMeshes (one per material; world-triplanar keeps per-pile grime
## variety for free) while collision stays one StaticBody3D per pile with a BoxShape3D
## per chunk — identical navmesh input. Runs on headless too (collision is gameplay).
static func rubble_field(scatter: Node3D, positions: Array[Vector3]) -> void:
	var mats: Array = [
		ProceduralBuildings.mat_concrete(11),
		ProceduralBuildings.mat_concrete_dark(13),
		ProceduralBuildings.mat_rust(17),
	]
	var buckets: Array = [
		[] as Array[Transform3D], [] as Array[Transform3D], [] as Array[Transform3D]
	]
	for i in range(positions.size()):
		var sid: int = i * 137 + 11
		var base: Vector3 = positions[i]
		var body := StaticBody3D.new()
		body.name = "Rubble%d" % i
		body.collision_layer = 1
		body.collision_mask = 0
		body.position = base
		scatter.add_child(body)
		var count: int = 3 + (ProcHash.h(sid) % 3)
		for c in range(count):
			var s: int = sid * 31 + c * 7
			var sx: float = 0.5 + ProcHash.hf(s) * 1.1
			var sy: float = 0.3 + ProcHash.hf(s + 1) * 0.7
			var sz: float = 0.5 + ProcHash.hf(s + 2) * 1.1
			var px: float = (ProcHash.hf(s + 3) - 0.5) * 2.2
			var pz: float = (ProcHash.hf(s + 4) - 0.5) * 2.2
			var roty: float = ProcHash.hf(s + 5) * 90.0
			var pick: int = ProcHash.h(s + 6) % 3
			var col := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(sx, sy, sz)
			col.shape = shape
			col.position = Vector3(px, sy * 0.5, pz)
			col.rotation_degrees = Vector3(0.0, roty, 0.0)
			body.add_child(col)
			if DisplayServer.get_name() != "headless":
				var b := Basis.from_euler(Vector3(0.0, deg_to_rad(roty), 0.0)).scaled(
					Vector3(sx, sy, sz)
				)
				(buckets[pick] as Array[Transform3D]).append(
					Transform3D(b, base + Vector3(px, sy * 0.5, pz))
				)
	if DisplayServer.get_name() == "headless":
		return
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	for mi in range(3):
		var xforms: Array[Transform3D] = buckets[mi]
		if xforms.is_empty():
			continue
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "RubbleMM%d" % mi
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = false
		mm.mesh = unit
		mm.instance_count = xforms.size()
		for j in range(xforms.size()):
			mm.set_instance_transform(j, xforms[j])
		mmi.multimesh = mm
		mmi.material_override = mats[mi]
		scatter.add_child(mmi)


## Adds a "BuildingDetail" Node3D under `arena_root` with every detail kit batched into
## one MultiMeshInstance3D per kit type. `evac_points` = the arena's extraction-zone XZ
## list (street pieces keep clear of them).
##
## HEADLESS SPLIT (D3.4): the MultiMeshes / lamps are render-only and skipped on a
## dedicated server, but the STREET-PROP COLLIDERS are gameplay (they are navmesh input —
## cover the AI has to path around), so `_street_layer` runs BEFORE that early-out and
## builds the same bodies on every peer. Its visual half still lands in `kits`, which the
## headless return then simply drops on the floor — ONE code path, so a server and a
## client can never disagree about where the cover stands.
static func build(arena_root: Node3D, poi_defs: Dictionary, evac_points: Array[Vector2]) -> void:
	if arena_root == null:
		return
	var kits: Dictionary = {}  # kit name -> Array of Transform3D (one MultiMesh each)
	_street_layer(arena_root, kits, poi_defs, evac_points)
	if DisplayServer.get_name() == "headless":
		return
	var root := Node3D.new()
	root.name = "BuildingDetail"
	arena_root.add_child(root)
	# Every interior OmniLight3D hangs here (one parent = one cheap distance-gate pass).
	var lights_root := Node3D.new()
	lights_root.name = "InteriorLights"
	root.add_child(lights_root)
	# ONE shared emissive head material for every lamp (energy 0 by day; the night drive
	# animates it through each light's "night_glow_mat" meta).
	var head_mat: StandardMaterial3D = ProcMaterials.emissive(_WARM, 0.0)
	var keys: Array = poi_defs.keys()
	var lamps: int = 0
	for i in range(keys.size()):
		var poi_name: String = str(keys[i])
		var def: Dictionary = poi_defs[poi_name]
		var theme: String = str(def["theme"])
		var s: int = ProcHash.h(7919 * (i + 1))
		var center := Vector3(float(def["x"]), 0.0, float(def["z"]))
		var annex: Vector2 = _annex_point(poi_name, i, def)
		if theme in _FLAT_ROOF_THEMES:
			var roof_h: float = _roof_height(arena_root, poi_name, theme)
			_rooftop(kits, s, center, def, theme, roof_h)
			_drainpipe(kits, s, center, def, roof_h)
			# Flat-roof themes are exactly the ENTERABLE ones (temple/lodge/ruins are
			# solid landmark cores), so this is also the interior-lighting set.
			_interior_lamps(lights_root, kits, s, center, def, theme, roof_h)
		elif theme == "yard":
			_yard_stack_pieces(kits, s, center, def)
		_street_ring(kits, s, center, def, theme, evac_points, annex)
		if theme in _URBAN_THEMES and lamps < _LAMP_CAP:
			lamps += _lamps(
				root, kits, head_mat, s, center, def, theme, evac_points, annex, _LAMP_CAP - lamps
			)
	_emit(root, kits, head_mat)
	if _ADOPT_BUILDER_LIGHTS:
		_adopt_builder_lights(arena_root)
	_arm_interior_gate(lights_root)


## The building's flat-roof height: the "roof_h" meta set by the ProceduralBuildings
## builders, else a per-theme constant.
static func _roof_height(arena_root: Node3D, poi_name: String, theme: String) -> float:
	var b: Node = arena_root.get_node_or_null("NavigationRegion3D/Geometry/%s" % poi_name)
	if b != null and b.has_meta("roof_h"):
		return float(b.get_meta("roof_h"))
	return float(_FALLBACK_ROOF_H.get(theme, 5.0))


## XZ of the locked annex bolted onto a landmark POI (mirrors arena._build_locked_annex's
## ProcHash side pick + clearance) so street pieces never clip it. Vector2.INF if none.
static func _annex_point(poi_name: String, idx: int, def: Dictionary) -> Vector2:
	if not Settings.LOCKED_ROOM_POIS.has(poi_name):
		return Vector2.INF
	var seed_val: int = 7100 + idx * 131
	var sides: Array[Vector3] = [
		Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)
	]
	var dir: Vector3 = sides[int(ProcHash.hf(seed_val + 9) * 4.0) % 4]
	var clearance: float = maxf(float(def["w"]), float(def["d"])) * 0.5 + 2.9
	return Vector2(float(def["x"]) + dir.x * clearance, float(def["z"]) + dir.z * clearance)


## 2-4 rooftop pieces per flat-roof building, hash-placed inset >=1.2 m from the
## footprint edge with 1.5 m min spacing (rejects in deterministic order). Courtyard
## warehouses/houses only roof their back wing, so candidates are constrained to that
## band; the closed house keeps its stepped top cap clear, the tower its roof housing.
static func _rooftop(
	kits: Dictionary, s: int, center: Vector3, def: Dictionary, theme: String, roof_h: float
) -> void:
	var w: float = float(def["w"])
	var d: float = float(def["d"])
	var court: bool = bool(def["court"])
	var z_min: float = -d * 0.5 + 1.2
	var z_max: float = d * 0.5 - 1.2
	if court:
		z_max = -ProceduralBuildings.COURT_CLEAR - 0.5
	if z_max <= z_min or w < 3.0:
		return
	var choices: Array[String] = ["ac_unit", "antenna", "vent_stack"]
	if theme != "house":
		choices.append("water_tank")  # water tanks on tower/warehouse roofs only
	var target: int = 2 + ProcHash.h(s + 1) % 3
	var placed: Array[Vector2] = []
	for k in range(12):
		if placed.size() >= target:
			break
		var ks: int = s + 100 + k * 13
		var px: float = ProcHash.hrange(ks, -w * 0.5 + 1.2, w * 0.5 - 1.2)
		var pz: float = ProcHash.hrange(ks + 1, z_min, z_max)
		if theme == "house" and not court and absf(px) < w * 0.31 and absf(pz) < d * 0.31:
			continue  # the closed house has a stepped roof cap over its centre
		if (
			theme == "tower"
			and absf(px - w * 0.18) < w * 0.175 + 0.6
			and absf(pz + d * 0.15) < d * 0.175 + 0.6
		):
			continue  # the tower's rooftop utility housing
		if not _spaced(placed, px, pz, 1.5):
			continue
		placed.append(Vector2(px, pz))
		var kit: String = choices[ProcHash.h(ks + 3) % choices.size()]
		_piece(kits, kit, center + Vector3(px, roof_h, pz), ProcHash.hf(ks + 2) * TAU, ks)


## One drainpipe per flat-roof building, hugging a hash-picked facade corner from the
## ground to the roof. Courtyard shells only keep their back (-Z) corners' walls, so
## those pick from the two back corners (listed first).
static func _drainpipe(
	kits: Dictionary, s: int, center: Vector3, def: Dictionary, roof_h: float
) -> void:
	var hw: float = float(def["w"]) * 0.5 + 0.1
	var hd: float = float(def["d"]) * 0.5 + 0.1
	var corners: Array[Vector3] = [
		Vector3(hw, 0, -hd), Vector3(-hw, 0, -hd), Vector3(hw, 0, hd), Vector3(-hw, 0, hd)
	]
	var n: int = 2 if bool(def["court"]) else 4
	var c: Vector3 = corners[ProcHash.h(s + 200) % n]
	var t: Transform3D = _xf(Vector3(0.14, roof_h, 0.14), center + c + Vector3(0, roof_h * 0.5, 0))
	_add(kits, "drainpipe", t)


## Container-yard "rooftops": pieces sit on the 4 corner container stacks. Positions,
## stack levels and the top container's x-jitter mirror build_container_yard's
## deterministic spot table, so the pieces land exactly on the stacked containers.
static func _yard_stack_pieces(kits: Dictionary, s: int, center: Vector3, def: Dictionary) -> void:
	var ex: float = float(def["w"]) * 0.5 - 1.5
	var ez: float = float(def["d"]) * 0.5 - 1.5
	# [cx, cz, stack levels, build_container_yard spot seed]
	var corners: Array = [[-ex, -ez, 2, 1], [ex, -ez, 1, 2], [ex, ez, 2, 3], [-ex, ez, 1, 4]]
	var choices: Array[String] = ["ac_unit", "vent_stack", "antenna"]
	var target: int = 2 + ProcHash.h(s + 2) % 3
	var start: int = ProcHash.h(s + 3) % 4
	for k in range(mini(target, 4)):
		var cd: Array = corners[(start + k) % 4]
		var levels: int = int(cd[2])
		var sd: int = int(cd[3])
		var jitter: float = (ProcHash.hf(sd * 13 + levels - 1) - 0.5) * 0.4
		var pos: Vector3 = (
			center + Vector3(float(cd[0]) + jitter, float(levels) * 2.6, float(cd[1]))
		)
		var ks: int = s + 300 + k * 17
		_piece(kits, choices[ProcHash.h(ks) % choices.size()], pos, ProcHash.hf(ks + 1) * TAU, ks)


## 3-5 street pieces ringing the POI at max(w,d)/2 + 2.5..5.0 m (theme-flavoured:
## benches at temple/plaza, crates at warehouse/yard/lodge, 2-3 fallen sandstone blocks
## at the ruins, barriers elsewhere), seated on the real terrain. Rejects spots near
## extraction zones / the POI's locked annex in deterministic order.
static func _street_ring(
	kits: Dictionary,
	s: int,
	center: Vector3,
	def: Dictionary,
	theme: String,
	evac_points: Array[Vector2],
	annex: Vector2
) -> void:
	var w: float = maxf(float(def["w"]), 22.0 if theme == "plaza" else 0.0)
	var d: float = maxf(float(def["d"]), 22.0 if theme == "plaza" else 0.0)
	var base_r: float = maxf(w, d) * 0.5
	var n: int = 3 + ProcHash.h(s + 4) % 3
	if theme == "desert_ruins":
		n = 2 + ProcHash.h(s + 4) % 2  # 2-3 fallen sandstone blocks only
	var placed: int = 0
	for k in range(16):
		if placed >= n:
			break
		var ks: int = s + 400 + k * 19
		var ang: float = ProcHash.hf(ks) * TAU
		var rr: float = base_r + ProcHash.hrange(ks + 1, 2.5, 5.0)
		var px: float = center.x + cos(ang) * rr
		var pz: float = center.z + sin(ang) * rr
		if _blocked(px, pz, evac_points, annex):
			continue
		var pos := Vector3(px, ProceduralTerrain.height_at(px, pz), pz)
		_piece(kits, _ring_kit(theme, ks), pos, ProcHash.hf(ks + 2) * TAU, ks)
		placed += 1


## Theme flavour for the street ring.
static func _ring_kit(theme: String, ks: int) -> String:
	match theme:
		"temple":
			return "bench"
		"plaza":
			return "bench" if ProcHash.h(ks + 3) % 2 == 0 else "barrier"
		"snow_lodge":
			return "crate"  # log-pile stand-ins by the lodge
		"desert_ruins":
			return "ruin_block"
		"warehouse", "yard":
			return "crate" if ProcHash.h(ks + 3) % 2 == 0 else "barrier"
	return "barrier"


## 1-2 street lamps per urban POI biased to its door side (capped map-wide): pole+head
## instances in the kits PLUS a real OmniLight3D (energy 0 by day, no shadows) in
## Groups.NIGHT_LIGHTS tagged with the shared head material. Returns lamps placed.
static func _lamps(
	root: Node3D,
	kits: Dictionary,
	head_mat: StandardMaterial3D,
	s: int,
	center: Vector3,
	def: Dictionary,
	theme: String,
	evac_points: Array[Vector2],
	annex: Vector2,
	budget: int
) -> int:
	var w: float = maxf(float(def["w"]), 22.0 if theme == "plaza" else 0.0)
	var d: float = maxf(float(def["d"]), 22.0 if theme == "plaza" else 0.0)
	var rr: float = maxf(w, d) * 0.5 + 3.0
	# Doors: the tower opens to -Z, warehouse/house to +Z; yard/plaza ring anywhere.
	var door_ang: float = -PI * 0.5 if theme == "tower" else PI * 0.5
	var want: int = mini(1 + ProcHash.h(s + 5) % 2, budget)
	var placed: int = 0
	for k in range(6):
		if placed >= want:
			break
		var ks: int = s + 500 + k * 23
		var ang: float = door_ang + ProcHash.hrange(ks, -0.9, 0.9)
		if theme == "yard" or theme == "plaza":
			ang = ProcHash.hf(ks) * TAU
		var px: float = center.x + cos(ang) * rr
		var pz: float = center.z + sin(ang) * rr
		if _blocked(px, pz, evac_points, annex):
			continue
		var gy: float = ProceduralTerrain.height_at(px, pz)
		_add(kits, "lamp_pole", _xf(Vector3(0.16, 3.4, 0.16), Vector3(px, gy + 1.7, pz)))
		_add(kits, "lamp_head", _xf(Vector3(0.35, 0.18, 0.35), Vector3(px, gy + 3.49, pz)))
		var light := OmniLight3D.new()
		light.position = Vector3(px, gy + 3.2, pz)
		light.shadow_enabled = false
		light.light_energy = 0.0
		light.light_color = _WARM
		light.omni_range = 8.0
		light.add_to_group(Groups.NIGHT_LIGHTS)
		light.set_meta("night_glow_mat", head_mat)
		root.add_child(light)
		placed += 1
	return placed


# ===================================================================== D3.4 STREET PROPS
## "Улицы живые" — a deterministic CITY PROP layer over the open ground that used to be
## bare terrain between the POIs: barricade checkpoints, burnt-out husks, barrel dumps,
## pallet/pipe depots, cable spools, dumpsters, road signs and cones, so a street reads as
## a PLACE instead of the floor between two landmarks.
##
## WHERE — two placement families, both ProcHash-deterministic (no randf/Time):
##   STREETS — the POI graph (every POI wired to its two nearest neighbours) plus spokes
##     from the map crossroads to the nearest landmark of each outer biome. Props stand on
##     the SHOULDER (_PROP_LATERAL_MIN..MAX off the centre line), never on it: the lane is
##     the combat/pathing corridor and stays open by construction.
##   APRONS — a ring band just outside each POI footprint, where scavenged material would
##     actually pile up. Starts past the existing `_street_ring` band so the two never
##     interleave.
## Density is biome-scaled (_PROP_BIOME_DENSITY: dense city, near-empty desert) and grove
## cores are skipped (FloraField.forest_w) so a dumpster never lands inside a tree.
##
## COLLISION — the one gameplay-visible half, and the reason D3.4 breaks the golden
## snapshot. Only the BIG props (road blocks, wrecks, cable spools, pipe stacks,
## dumpsters) carry a StaticBody3D; anything you could step over stays render-only,
## because the navmesh carve is shape + agent_radius 0.6 and a SOLID traffic cone would
## pinch a lane shut. Those bodies live under NavigationRegion3D/Geometry/StreetProps —
## the only subtree the runtime bake parses (Arena.tscn's NavigationMesh leaves
## geometry_source_geometry_mode at ROOT_NODE_CHILDREN and parses STATIC COLLIDERS on
## layer 1) — and are therefore built on HEADLESS too. Solid props keep _PROP_CLEAR_BIG
## clear of every building FOOTPRINT RECT, which is what guarantees no collider can stand
## in a doorway without this file having to know where each theme puts its door.
##
## Tunables are LOCAL consts (this lane owns no shared file); the lead may lift them into
## Settings verbatim.
const STREET_PROPS_ENABLED := true
const _PROP_STATION_STEP := 11.0  # metres between prop stations along a street
const _PROP_STREET_END := 12.0  # street props stop this far from a link end (aprons own it)
## Min distance between two accepted CLUSTER centres. Aprons are placed first, so where a
## street runs into the band around its own POI the street station is the one that yields —
## which is the right priority and the only reason the two families can share that ground.
const _PROP_CLUSTER_SPACING := 7.5
const _PROP_LATERAL_MIN := 3.7  # shoulder offset: the lane centre stays walkable
const _PROP_LATERAL_MAX := 7.6
const _PROP_LINK_MIN := 28.0  # shorter POI pairs are one place, not a street
const _PROP_LINK_MAX := 132.0  # longer ones are wilderness, not a street
const _PROP_APRON_IN := 6.0  # apron band, measured OUT from the footprint radius
const _PROP_APRON_OUT := 18.0
const _PROP_CLEAR_SMALL := 3.0  # render-only clutter: footprint-rect expansion
const _PROP_CLEAR_BIG := 6.0  # COLLIDING props: never nearer a building than this
const _PROP_SPAWN_CLEAR := 15.0  # deploy cluster stays clean
const _PROP_ENEMY_SPAWN_CLEAR := 5.5  # no machine wakes up inside a wreck
const _PROP_RUBBLE_CLEAR := 3.8  # arena rubble piles already own their ground
const _PROP_ANNEX_CLEAR := 6.5  # the key-locked annex keeps its approach
const _PROP_RIVER_CLEAR := 9.5  # nothing floating in / on the waterline
const _PROP_MAX_RISE := 1.15  # max height delta over a 2.6 m span (~24°) — off the berm
const _PROP_FOREST_MAX := 0.55  # grove cores belong to the trees
const _PROP_EDGE_INSET := 10.0  # stay off the perimeter berm / walls
const _PROP_COLLIDER_CAP := 150  # map-wide budget of navmesh-carving bodies
const _PLAZA_FOOTPRINT := 22.0  # the plaza POI has w=d=0; treat it as this square
const _PROP_BIOME_DENSITY := {"urban": 1.0, "rain": 0.72, "snow": 0.58, "desert": 0.34}
## Cluster archetypes per biome — the "story" a pile of junk tells. Desert keeps only the
## sun-bleached ones (no wet-city bins), snow the logistics ones.
const _CLUSTER_POOL := {
	"urban": ["checkpoint", "dump", "depot", "wreck", "works", "bins"],
	"rain": ["dump", "bins", "depot", "wreck", "works"],
	"snow": ["depot", "works", "wreck", "dump"],
	"desert": ["wreck", "works", "dump"],
}
## The props that carry a collider. Everything else is render-only clutter.
const _PROP_SOLID: Array[String] = ["road_block", "wreck", "spool", "pipe_stack", "dumpster"]
## kit -> [material family, sid] (+ paint tint for the "paint" family). ONE material per
## kit == one MultiMesh batch == one draw call, matching the rooftop/facade kit discipline.
##
## The sid is deliberately shared PER FAMILY, not per kit: ProcMaterials caches its noise
## by (sid, grime), so 16 distinct sids would bake 48 extra 512² textures during the arena
## build — the one phase that must not grow (a long main-thread stall there is what silently
## drops a co-op client on load). Sharing costs nothing visually, because the weathering is
## WORLD-triplanar: two drums metres apart already sample different grime.
const _PROP_MATS := {
	"road_block": ["concrete", 141],
	"barrel": ["paint", 143, Color(0.55, 0.40, 0.24)],
	"barrel_band": ["metal_dark", 145],
	"pallet": ["timber", 147],
	"wreck_body": ["rust", 149],
	"wreck_cabin": ["metal_dark", 145],
	"wreck_wheel": ["rubber", 153],
	"spool_flange": ["timber", 147],
	"spool_hub": ["metal_dark", 145],
	"pipe": ["metal", 159],
	"dumpster": ["paint", 143, Color(0.30, 0.42, 0.32)],
	"dumpster_lid": ["metal_dark", 145],
	"sign_post": ["metal_dark", 145],
	"sign_plate": ["paint", 143, Color(0.72, 0.62, 0.30)],
	"bin": ["paint", 143, Color(0.40, 0.42, 0.46)],
	"cone": ["paint", 143, Color(0.72, 0.34, 0.16)],
}


## Build the whole street layer. Visuals go into `kits` (batched by the caller); colliders
## go straight under the nav region. See the section header for the co-op/golden contract.
static func _street_layer(
	arena_root: Node3D, kits: Dictionary, poi_defs: Dictionary, evac_points: Array[Vector2]
) -> void:
	if not STREET_PROPS_ENABLED:
		return
	var ctx: Dictionary = _street_ctx(arena_root, poi_defs, evac_points)
	var keys: Array = poi_defs.keys()
	for i in range(keys.size()):
		_apron(kits, ctx, i, poi_defs[keys[i]])
	var links: Array[Vector4] = _street_links(poi_defs, ctx)
	for li in range(links.size()):
		_street(kits, ctx, links[li], li)


## The immutable placement context + the two mutable counters (collider budget / body
## sequence). Keep-outs are derived from LIVE SCENE DATA — the POI defs the buildings were
## built from, the arena's own ExtractionZone/PlayerSpawn/EnemySpawn markers and the rubble
## piles that already exist — so nothing here can drift out of sync with a hand-copied list.
static func _street_ctx(
	arena_root: Node3D, poi_defs: Dictionary, evac_points: Array[Vector2]
) -> Dictionary:
	var rects: Array[Vector4] = []
	var circles: Array[Vector3] = []  # (x, z, radius)
	var keys: Array = poi_defs.keys()
	for i in range(keys.size()):
		var poi_name: String = str(keys[i])
		var def: Dictionary = poi_defs[poi_name]
		var plaza: float = _PLAZA_FOOTPRINT if str(def["theme"]) == "plaza" else 0.0
		var w: float = maxf(float(def["w"]), plaza)
		var d: float = maxf(float(def["d"]), plaza)
		rects.append(Vector4(float(def["x"]), float(def["z"]), w * 0.5, d * 0.5))
		var a: Vector2 = _annex_point(poi_name, i, def)
		if a.is_finite():
			circles.append(Vector3(a.x, a.y, _PROP_ANNEX_CLEAR))
	for e in evac_points:
		circles.append(Vector3(e.x, e.y, _EVAC_CLEARANCE))
	_collect_marker_circles(arena_root, "PlayerSpawnMarkers", _PROP_SPAWN_CLEAR, circles)
	_collect_marker_circles(arena_root, "EnemySpawnMarkers", _PROP_ENEMY_SPAWN_CLEAR, circles)
	_collect_marker_circles(
		arena_root, "NavigationRegion3D/Geometry/Scatter", _PROP_RUBBLE_CLEAR, circles
	)
	var used: Array[Vector2] = []
	return {
		"rects": rects,
		"circles": circles,
		"used": used,  # accepted cluster centres (min-spacing, filled as we go)
		"spawn": _marker_centroid(arena_root, "PlayerSpawnMarkers"),
		"props": _collider_root(arena_root),
		"budget": _PROP_COLLIDER_CAP,
		"seq": 0,
	}


## Append (x, z, radius) keep-out circles for every Node3D child of `path`.
##
## HEADLESS-PARITY TRAP (caught in review): the rubble Scatter node holds the per-pile
## StaticBody3Ds AND — in a WINDOWED build only — three map-wide MultiMeshInstance3Ds
## parked at the ORIGIN (`rubble_field` returns before creating them on headless). Folding
## those in would have given a client a phantom keep-out at (0,0) that a dedicated server
## never saw, i.e. a different street layout per peer. Skip them by class.
static func _collect_marker_circles(
	arena_root: Node3D, path: String, radius: float, out: Array[Vector3]
) -> void:
	var holder := arena_root.get_node_or_null(path)
	if holder == null:
		return
	for c in holder.get_children():
		var n3 := c as Node3D
		if n3 != null and not (n3 is MultiMeshInstance3D):
			out.append(Vector3(n3.position.x, n3.position.z, radius))


## XZ centroid of `path`'s Node3D children, or Vector2.INF when it has none. Same
## MultiMesh exclusion as above (identical on a server and a client).
static func _marker_centroid(arena_root: Node3D, path: String) -> Vector2:
	var pts: Array[Vector3] = []
	_collect_marker_circles(arena_root, path, 0.0, pts)
	if pts.is_empty():
		return Vector2.INF
	var acc := Vector2.ZERO
	for p in pts:
		acc += Vector2(p.x, p.y)
	return acc / float(pts.size())


## The collider parent under the nav region. NavigationRegion3D children are the ONLY
## subtree `bake_navigation_mesh()` parses, which is both why the bodies must live here
## and why D3.4 changes the golden container checksum. Null when there is no nav region
## (then the layer is render-only — a preview/tool scene, never a real arena).
static func _collider_root(arena_root: Node3D) -> Node3D:
	var geo := arena_root.get_node_or_null("NavigationRegion3D/Geometry") as Node3D
	if geo == null:
		geo = arena_root.get_node_or_null("NavigationRegion3D") as Node3D
	if geo == null:
		return null
	var stale := geo.get_node_or_null("StreetProps")
	if stale != null:
		stale.free()
	var props := Node3D.new()
	props.name = "StreetProps"
	geo.add_child(props)
	return props


## The street NETWORK: every POI (plus the map crossroads and the deploy cluster) wired to
## its two nearest neighbours, deduped by index pair, with links outside
## _PROP_LINK_MIN.._PROP_LINK_MAX dropped — a 200 m gap between two biomes is wilderness,
## not a street. Then explicit spokes from the crossroads to the nearest landmark of each
## OUTER biome, which is what turns the three far quadrants into places you walk TO.
static func _street_links(poi_defs: Dictionary, ctx: Dictionary) -> Array[Vector4]:
	var nodes: Array[Vector2] = []
	var keys: Array = poi_defs.keys()
	for i in range(keys.size()):
		var def: Dictionary = poi_defs[keys[i]]
		nodes.append(Vector2(float(def["x"]), float(def["z"])))
	var hub_i: int = nodes.size()
	nodes.append(Vector2(WorldBounds.CX, WorldBounds.CZ))
	# The deploy cluster is a street node too — the walk out of spawn is the first street
	# the player ever sees, so it must not be the one stretch of bare ground.
	var spawn: Vector2 = ctx["spawn"]
	if spawn.is_finite():
		nodes.append(spawn)
	var links: Array[Vector4] = []
	for i in range(nodes.size()):
		var first: int = -1
		var second: int = -1
		var d1: float = INF
		var d2: float = INF
		for j in range(nodes.size()):
			if j == i:
				continue
			var dist: float = nodes[i].distance_to(nodes[j])
			if dist < d1:
				d2 = d1
				second = first
				d1 = dist
				first = j
			elif dist < d2:
				d2 = dist
				second = j
		_link_add(links, nodes, i, first)
		_link_add(links, nodes, i, second)
	var biomes: Array[String] = ["snow", "desert", "rain"]
	for b in biomes:
		var pick: int = -1
		var best: float = INF
		for i in range(keys.size()):
			if WorldBounds.biome_at(nodes[i].x, nodes[i].y) != b:
				continue
			var dist: float = nodes[hub_i].distance_to(nodes[i])
			if dist < best:
				best = dist
				pick = i
		_link_add(links, nodes, hub_i, pick)
	return links


## Add the i<->j link once (ordered by index so the pair dedupes) if it is street-length.
static func _link_add(links: Array[Vector4], nodes: Array[Vector2], i: int, j: int) -> void:
	if j < 0 or i == j:
		return
	var a: Vector2 = nodes[mini(i, j)]
	var b: Vector2 = nodes[maxi(i, j)]
	var dist: float = a.distance_to(b)
	if dist < _PROP_LINK_MIN or dist > _PROP_LINK_MAX:
		return
	var v := Vector4(a.x, a.y, b.x, b.y)
	if not links.has(v):
		links.append(v)


## Prop STATIONS every ~_PROP_STATION_STEP along one street, alternating shoulders. The
## first/last _PROP_STREET_END metres are skipped — that ground belongs to the POI aprons,
## and doubling up there is what would read as a junkyard rather than a street.
static func _street(kits: Dictionary, ctx: Dictionary, link: Vector4, li: int) -> void:
	var a := Vector2(link.x, link.y)
	var b := Vector2(link.z, link.w)
	var span: Vector2 = b - a
	var len_m: float = span.length()
	if len_m < _PROP_LINK_MIN:
		return
	var dir: Vector2 = span / len_m
	var nrm := Vector2(-dir.y, dir.x)
	var steps: int = int(len_m / _PROP_STATION_STEP)
	for k in range(1, steps + 1):
		var s: int = ProcHash.h(90001 + li * 977 + k * 37)
		var t: float = (float(k) + ProcHash.hrange(s, -0.28, 0.28)) * _PROP_STATION_STEP
		if t < _PROP_STREET_END or t > len_m - _PROP_STREET_END:
			continue
		var side: float = 1.0 if ProcHash.h(s + 1) % 2 == 0 else -1.0
		var off: float = ProcHash.hrange(s + 2, _PROP_LATERAL_MIN, _PROP_LATERAL_MAX)
		var p: Vector2 = a + dir * t + nrm * (off * side)
		if not _cluster_spot_ok(ctx, p.x, p.y, s + 3):
			continue
		var yaw: float = atan2(dir.x, dir.y) + ProcHash.hrange(s + 4, -0.45, 0.45)
		_cluster(kits, ctx, _pick_cluster(p.x, p.y, s + 5), p, yaw, s + 7)


## 2-4 clusters ringing one POI in the _PROP_APRON_IN.._PROP_APRON_OUT band outside its
## footprint radius, spread over the full circle (one sector per cluster) so the props
## never pile on a single facade. Rejections retry in deterministic order.
static func _apron(kits: Dictionary, ctx: Dictionary, idx: int, def: Dictionary) -> void:
	var plaza: float = _PLAZA_FOOTPRINT if str(def["theme"]) == "plaza" else 0.0
	var cx: float = float(def["x"])
	var cz: float = float(def["z"])
	var base_r: float = maxf(maxf(float(def["w"]), plaza), maxf(float(def["d"]), plaza)) * 0.5
	var s0: int = ProcHash.h(60013 + idx * 613)
	var want: int = 2 + ProcHash.h(s0) % 3
	var placed: int = 0
	for k in range(want * 4):
		if placed >= want:
			break
		var s: int = ProcHash.h(s0 + 17 + k * 29)
		var sector: float = float(k % want)
		var ang: float = TAU * (sector + ProcHash.hrange(s, 0.12, 0.88)) / float(want)
		var rr: float = base_r + ProcHash.hrange(s + 1, _PROP_APRON_IN, _PROP_APRON_OUT)
		var p := Vector2(cx + cos(ang) * rr, cz + sin(ang) * rr)
		if not _cluster_spot_ok(ctx, p.x, p.y, s + 2):
			continue
		# Face the cluster along the wall it leans against (tangent to the apron ring).
		var yaw: float = ang + PI * 0.5 + ProcHash.hrange(s + 3, -0.35, 0.35)
		_cluster(kits, ctx, _pick_cluster(p.x, p.y, s + 4), p, yaw, s + 6)
		placed += 1


## Cluster-centre validation: the cheap keep-outs, the min-spacing against already-accepted
## clusters, the biome density roll, then the expensive world probes (river / grove /
## slope), cheapest test first. Individual pieces only re-run the cheap keep-outs
## (`_prop_spot_ok`) — they sit within ~3 m of a centre that already passed all of this.
## ACCEPTS by recording the centre, so it must be called exactly once per cluster.
static func _cluster_spot_ok(ctx: Dictionary, x: float, z: float, s: int) -> bool:
	if not _prop_spot_ok(ctx, x, z, true):
		return false
	var used: Array[Vector2] = ctx["used"]
	for u in used:
		if Vector2(x - u.x, z - u.y).length_squared() < _PROP_CLUSTER_SPACING ** 2:
			return false
	if ProcHash.hf(s) > float(_PROP_BIOME_DENSITY.get(WorldBounds.biome_at(x, z), 0.6)):
		return false
	if ProceduralTerrain.river_distance(x, z) < _PROP_RIVER_CLEAR:
		return false
	if FloraField.forest_w(x, z) > _PROP_FOREST_MAX:
		return false
	if not _ground_flat(x, z):
		return false
	used.append(Vector2(x, z))
	return true


## True when a prop of this class may stand at (x,z). `solid` = it will carry a collider,
## so it keeps the WIDE berth from every building footprint — that single rule is what
## keeps colliders out of doorways, loading bays and courtyard mouths without this file
## having to model where each theme puts its openings.
static func _prop_spot_ok(ctx: Dictionary, x: float, z: float, solid: bool) -> bool:
	if (
		x < WorldBounds.X_MIN + _PROP_EDGE_INSET
		or x > WorldBounds.X_MAX - _PROP_EDGE_INSET
		or z < WorldBounds.Z_MIN + _PROP_EDGE_INSET
		or z > WorldBounds.Z_MAX - _PROP_EDGE_INSET
	):
		return false
	var pad: float = _PROP_CLEAR_BIG if solid else _PROP_CLEAR_SMALL
	var rects: Array[Vector4] = ctx["rects"]
	for r in rects:
		if absf(x - r.x) < r.z + pad and absf(z - r.y) < r.w + pad:
			return false
	var circles: Array[Vector3] = ctx["circles"]
	for c in circles:
		var dx: float = x - c.x
		var dz: float = z - c.y
		if dx * dx + dz * dz < c.z * c.z:
			return false
	return true


## Ground flat enough to seat a prop: props are placed on a single height sample, so a
## steep spot buries one corner and floats the opposite one. Also the cheapest way to keep
## everything off the perimeter berm and the river banks.
static func _ground_flat(x: float, z: float) -> bool:
	const P := 1.3
	var dx: float = absf(
		ProceduralTerrain.height_at(x + P, z) - ProceduralTerrain.height_at(x - P, z)
	)
	var dz: float = absf(
		ProceduralTerrain.height_at(x, z + P) - ProceduralTerrain.height_at(x, z - P)
	)
	return maxf(dx, dz) <= _PROP_MAX_RISE


## Biome-appropriate cluster archetype.
static func _pick_cluster(x: float, z: float, s: int) -> String:
	var pool: Array = _CLUSTER_POOL.get(WorldBounds.biome_at(x, z), [])
	if pool.is_empty():
		return "dump"
	return str(pool[ProcHash.h(s) % pool.size()])


## One cluster = a small story told with 3-6 props around `p`, `yaw` facing along the
## street (local +Z = down the lane, local +X = away from it). Every piece re-validates
## its own spot, so a cluster straddling a keep-out THINS OUT instead of vanishing.
static func _cluster(
	kits: Dictionary, ctx: Dictionary, kind: String, p: Vector2, yaw: float, s: int
) -> void:
	match kind:
		"checkpoint":
			# Jersey blocks laid ALONG the lane (a line across it would be a wall the
			# navmesh carve turns into a dead end), plus cones and a sign.
			var nb: int = 3 + ProcHash.h(s + 11) % 2
			for i in range(nb):
				var t: float = (float(i) - float(nb - 1) * 0.5) * 1.72
				var jy: float = ProcHash.hrange(s + 13 + i * 5, -0.2, 0.2)
				_place_prop(
					kits, ctx, "road_block", p + _rot(Vector2(0.0, t), yaw), yaw + jy, s + i
				)
			_place_prop(kits, ctx, "cone", p + _rot(Vector2(-1.5, 2.6), yaw), yaw, s + 41)
			_place_prop(kits, ctx, "cone", p + _rot(Vector2(-1.7, -2.4), yaw), yaw, s + 43)
			if ProcHash.h(s + 45) % 2 == 0:
				_place_prop(kits, ctx, "sign", p + _rot(Vector2(1.7, 3.4), yaw), yaw + PI, s + 47)
		"dump":
			var nd: int = 3 + ProcHash.h(s + 11) % 3
			for i in range(nd):
				var ang: float = TAU * (float(i) + ProcHash.hrange(s + i * 3, 0.1, 0.9)) / float(nd)
				var rr: float = ProcHash.hrange(s + i * 3 + 1, 0.55, 1.5)
				var bp: Vector2 = p + Vector2(cos(ang) * rr, sin(ang) * rr)
				_place_prop(kits, ctx, "barrel", bp, ProcHash.hf(s + i * 3 + 2) * TAU, s + i * 9)
			_place_prop(kits, ctx, "pallet", p + _rot(Vector2(2.1, -0.9), yaw), yaw, s + 51)
			if ProcHash.h(s + 53) % 3 != 0:
				_place_prop(kits, ctx, "bin", p + _rot(Vector2(-2.0, 1.1), yaw), yaw, s + 55)
		"depot":
			var ns: int = 2 + ProcHash.h(s + 11) % 2
			for i in range(ns):
				var sx: float = (float(i) - float(ns - 1) * 0.5) * 1.55
				_place_prop(
					kits, ctx, "pallet", p + _rot(Vector2(sx, -0.6), yaw), yaw, s + 60 + i * 4
				)
			_place_prop(kits, ctx, "crate", p + _rot(Vector2(-0.9, 1.3), yaw), yaw + 0.3, s + 71)
			if ProcHash.h(s + 73) % 2 == 0:
				_place_prop(
					kits, ctx, "crate", p + _rot(Vector2(0.2, 1.7), yaw), yaw - 0.25, s + 75
				)
			_place_prop(kits, ctx, "spool", p + _rot(Vector2(2.7, 0.9), yaw), yaw + 1.1, s + 77)
		"wreck":
			var wy: float = yaw + ProcHash.hrange(s + 11, -0.35, 0.35)
			_place_prop(kits, ctx, "wreck", p, wy, s + 13)
			_place_prop(kits, ctx, "barrel", p + _rot(Vector2(2.5, 1.2), yaw), yaw, s + 81)
			if ProcHash.h(s + 83) % 2 == 0:
				_place_prop(kits, ctx, "barrel", p + _rot(Vector2(3.0, 0.3), yaw), yaw, s + 85)
			_place_prop(kits, ctx, "cone", p + _rot(Vector2(-2.3, 2.4), yaw), yaw, s + 87)
		"works":
			_place_prop(kits, ctx, "pipe_stack", p, yaw, s + 91)
			_place_prop(kits, ctx, "cone", p + _rot(Vector2(1.7, 2.2), yaw), yaw, s + 93)
			_place_prop(kits, ctx, "cone", p + _rot(Vector2(-1.8, -2.2), yaw), yaw, s + 95)
			_place_prop(
				kits, ctx, "sign", p + _rot(Vector2(2.7, -1.5), yaw), yaw + PI * 0.5, s + 97
			)
			if ProcHash.h(s + 99) % 3 == 0:
				_place_prop(kits, ctx, "spool", p + _rot(Vector2(-3.1, 1.0), yaw), yaw, s + 101)
		"bins":
			_place_prop(kits, ctx, "dumpster", p, yaw, s + 103)
			_place_prop(kits, ctx, "bin", p + _rot(Vector2(2.0, 1.0), yaw), yaw, s + 105)
			if ProcHash.h(s + 107) % 2 == 0:
				_place_prop(kits, ctx, "bin", p + _rot(Vector2(2.6, 0.1), yaw), yaw, s + 109)
			_place_prop(kits, ctx, "pallet", p + _rot(Vector2(-1.9, -0.9), yaw), yaw + 0.5, s + 111)


## Rotate a cluster-local offset (x = across the lane, y = along it) into world XZ.
static func _rot(v: Vector2, yaw: float) -> Vector2:
	var c: float = cos(yaw)
	var s: float = sin(yaw)
	return Vector2(c * v.x + s * v.y, -s * v.x + c * v.y)


## Seat one prop: validate, sample the ground, emit its instances, and give it a collider
## when it is one of the solid few (budget-capped — over budget the prop is SKIPPED, not
## silently ghosted, so what you see is always what you bump into).
static func _place_prop(
	kits: Dictionary, ctx: Dictionary, kind: String, p: Vector2, yaw: float, s: int
) -> void:
	var solid: bool = kind in _PROP_SOLID
	if solid and int(ctx["budget"]) <= 0:
		return
	if not _prop_spot_ok(ctx, p.x, p.y, solid):
		return
	var pos := Vector3(p.x, ProceduralTerrain.height_at(p.x, p.y), p.y)
	var box: Vector3 = _prop_build(kits, kind, pos, yaw, s)
	if box == Vector3.ZERO:
		return
	_prop_body(ctx, box, pos, yaw)


## Emit ONE prop's instances into the kit batches at `pos` (its BASE — the ground). Returns
## the collider box size for a solid prop, Vector3.ZERO for render-only clutter. Sizes are
## hash-jittered so a barricade never reads as a copy-paste row.
static func _prop_build(
	kits: Dictionary, kind: String, pos: Vector3, yaw: float, s: int
) -> Vector3:
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
	var fwd: Vector3 = basis * Vector3(0.0, 0.0, 1.0)
	var rgt: Vector3 = basis * Vector3(1.0, 0.0, 0.0)
	match kind:
		"road_block":
			var bh: float = ProcHash.hrange(s + 1, 0.9, 1.06)
			var sz := Vector3(0.78, bh, 1.6)
			_add(kits, "road_block", _xf(sz, pos + Vector3(0.0, bh * 0.5, 0.0), yaw))
			return sz
		"wreck":
			var wl: float = ProcHash.hrange(s + 2, 3.4, 4.3)
			_add(kits, "wreck_body", _xf(Vector3(1.7, 0.8, wl), pos + Vector3(0.0, 0.72, 0.0), yaw))
			var cab: Vector3 = pos - fwd * (wl * 0.07) + Vector3(0.0, 1.44, 0.0)
			_add(kits, "wreck_cabin", _xf(Vector3(1.5, 0.74, wl * 0.42), cab, yaw))
			for i in range(4):
				var sf: float = 1.0 if i < 2 else -1.0
				var sr: float = 1.0 if i % 2 == 0 else -1.0
				var wp: Vector3 = pos + fwd * (wl * 0.31 * sf) + rgt * (0.88 * sr)
				var we := Vector3(0.0, yaw, PI * 0.5)
				var wu := Vector3(0.0, 0.36, 0.0)
				_add(kits, "wreck_wheel", _xf_rot(Vector3(0.72, 0.26, 0.72), wp + wu, we))
			return Vector3(1.9, 1.8, wl)
		"spool":
			var sr2: float = ProcHash.hrange(s + 3, 0.72, 0.92)
			var half: float = ProcHash.hrange(s + 4, 0.42, 0.55)
			var ctr: Vector3 = pos + Vector3(0.0, sr2, 0.0)
			var se := Vector3(0.0, yaw, PI * 0.5)
			var flange := Vector3(sr2 * 2.0, 0.13, sr2 * 2.0)
			_add(kits, "spool_flange", _xf_rot(flange, ctr + rgt * half, se))
			_add(kits, "spool_flange", _xf_rot(flange, ctr - rgt * half, se))
			_add(kits, "spool_hub", _xf_rot(Vector3(sr2 * 0.9, half * 1.7, sr2 * 0.9), ctr, se))
			return Vector3(half * 2.3, sr2 * 2.0, sr2 * 2.0)
		"pipe_stack":
			var pl: float = ProcHash.hrange(s + 5, 2.6, 3.4)
			const PR := 0.27
			var pe := Vector3(PI * 0.5, yaw, 0.0)
			var pipe := Vector3(PR * 2.0, pl, PR * 2.0)
			for i in range(3):
				var ox: float = (float(i) - 1.0) * (PR * 2.05)
				_add(kits, "pipe", _xf_rot(pipe, pos + rgt * ox + Vector3(0.0, PR, 0.0), pe))
			for i in range(2):
				var ox2: float = (float(i) - 0.5) * (PR * 2.05)
				_add(
					kits, "pipe", _xf_rot(pipe, pos + rgt * ox2 + Vector3(0.0, PR * 2.76, 0.0), pe)
				)
			return Vector3(PR * 6.4, PR * 3.9, pl)
		"dumpster":
			var dl: float = ProcHash.hrange(s + 6, 1.9, 2.2)
			_add(kits, "dumpster", _xf(Vector3(dl, 1.16, 1.12), pos + Vector3(0, 0.58, 0), yaw))
			var lid := Vector3(dl * 1.03, 0.11, 1.2)
			_add(kits, "dumpster_lid", _xf(lid, pos + Vector3(0.0, 1.2, 0.0), yaw))
			return Vector3(dl, 1.3, 1.15)
		"barrel":
			var bt: float = ProcHash.hrange(s + 7, 0.84, 0.98)
			_add(kits, "barrel", _xf(Vector3(0.58, bt, 0.58), pos + Vector3(0, bt * 0.5, 0), yaw))
			var band := Vector3(0.62, 0.07, 0.62)
			_add(kits, "barrel_band", _xf(band, pos + Vector3(0.0, bt * 0.3, 0.0), yaw))
			_add(kits, "barrel_band", _xf(band, pos + Vector3(0.0, bt * 0.7, 0.0), yaw))
			return Vector3.ZERO
		"pallet":
			var lv: int = 1 + ProcHash.h(s + 8) % 3
			for i in range(lv):
				var jy: float = ProcHash.hrange(s + 8 + i * 3, -0.16, 0.16)
				var py: float = 0.07 + float(i) * 0.155
				_add(
					kits, "pallet", _xf(Vector3(1.22, 0.14, 1.0), pos + Vector3(0, py, 0), yaw + jy)
				)
			return Vector3.ZERO
		"sign":
			var sh: float = ProcHash.hrange(s + 9, 2.2, 2.7)
			_add(
				kits, "sign_post", _xf(Vector3(0.11, sh, 0.11), pos + Vector3(0, sh * 0.5, 0), yaw)
			)
			var plate: Vector3 = pos + fwd * 0.06 + Vector3(0.0, sh - 0.44, 0.0)
			_add(kits, "sign_plate", _xf(Vector3(0.92, 0.68, 0.06), plate, yaw))
			return Vector3.ZERO
		"bin":
			var bh2: float = ProcHash.hrange(s + 10, 0.88, 1.04)
			_add(kits, "bin", _xf(Vector3(0.62, bh2, 0.62), pos + Vector3(0, bh2 * 0.5, 0), yaw))
			return Vector3.ZERO
		"cone":
			var ch: float = ProcHash.hrange(s + 11, 0.56, 0.68)
			_add(kits, "cone", _xf(Vector3(0.44, ch, 0.44), pos + Vector3(0, ch * 0.5, 0), yaw))
			return Vector3.ZERO
		"crate":
			_piece(kits, "crate", pos, yaw, s + 12)
			return Vector3.ZERO
	return Vector3.ZERO


## One prop collider: a single BoxShape3D seated on the ground (bottom face at pos.y),
## layer 1 / mask 0 exactly like the rubble piles, so the navmesh bake parses it and
## nothing else pays for it.
static func _prop_body(ctx: Dictionary, size: Vector3, pos: Vector3, yaw: float) -> void:
	var parent := ctx["props"] as Node3D
	if parent == null or not is_instance_valid(parent):
		return
	var seq: int = int(ctx["seq"])
	ctx["seq"] = seq + 1
	ctx["budget"] = int(ctx["budget"]) - 1
	var body := StaticBody3D.new()
	body.name = "Prop%d" % seq
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos + Vector3(0.0, size.y * 0.5, 0.0)
	body.rotation.y = yaw
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	parent.add_child(body)


## FADED PAINTED STEEL for the street props (drums / dumpsters / bins / signs / cones):
## the same ProcMaterials.weathered stack the buildings use, but with PAINT's PBR —
## metallic 0.0, because metallic is effectively BINARY (D2) and a dielectric coat is what
## lets the tint survive at all; at 0.4 every one of these would read as the same grey tin.
## World triplanar at a coarse scale means each prop samples the grime mask at ITS OWN
## world position, so a row of identical drums weathers differently for free.
static func _mat_painted(base: Color, sid: int, rough: float = 0.62) -> StandardMaterial3D:
	return ProcMaterials.weathered(
		base, 0.0, rough, 0.42, sid, Vector3(0.25, 0.25, 0.25), true, 0.55, false
	)


## Street-prop material, or null when `kit` is not one (the rooftop/facade kits fall
## through to _kit_material's own table).
static func _prop_material(kit: String) -> StandardMaterial3D:
	var spec: Array = _PROP_MATS.get(kit, [])
	if spec.is_empty():
		return null
	var family: String = str(spec[0])
	var sid: int = int(spec[1])
	match family:
		"concrete":
			return ProceduralBuildings.mat_concrete(sid)
		"metal":
			return ProceduralBuildings.mat_metal(sid)
		"metal_dark":
			return ProceduralBuildings.mat_metal_dark(sid)
		"rust":
			return ProceduralBuildings.mat_rust(sid)
		"timber":
			return ProceduralBuildings.mat_timber(sid)
		"rubber":
			return _mat_painted(Color(0.15, 0.15, 0.16), sid, 0.95)
	var tint: Color = spec[2]
	return _mat_painted(tint, sid)


# =============================================================== INTERIOR CEILING LAMPS


## 1-3 warm ceiling lamps per ROOFED volume of one building (see _interior_volumes),
## capped at _INTERIOR_PER_BUILDING_MAX per POI. Two passes so the budget spreads over
## FLOORS first: pass 0 gives every volume its one mandatory lamp (a pitch-black storey
## is the bug being fixed), pass 1 tops the big rooms up to their area-driven count.
## Deterministic: the only hash is the quarter-point start index for this building.
static func _interior_lamps(
	lights_root: Node3D,
	kits: Dictionary,
	s: int,
	center: Vector3,
	def: Dictionary,
	theme: String,
	roof_h: float
) -> void:
	var vols: Array[Dictionary] = _interior_volumes(theme, def, roof_h)
	if vols.is_empty():
		return
	var start: int = ProcHash.h(s + 600) % _QUAD.size()
	var budget: int = _INTERIOR_PER_BUILDING_MAX
	for pass_i in range(2):
		for vi in range(vols.size()):
			var v: Dictionary = vols[vi]
			var hw: float = float(v["hw"])
			var hd: float = float(v["hd"])
			var lo: int = 0 if pass_i == 0 else 1
			var hi: int = 1 if pass_i == 0 else _lamp_count(hw, hd)
			for k in range(lo, hi):
				if budget <= 0:
					return
				budget -= 1
				var q: Vector2 = _QUAD[(start + vi + k) % _QUAD.size()]
				_interior_lamp(
					lights_root,
					kits,
					Vector3(
						center.x + float(v["cx"]) + q.x * hw * 0.5,
						float(v["y"]),
						center.z + float(v["cz"]) + q.y * hd * 0.5
					)
				)


## The ROOFED volumes of one building in building-local XZ ({cx,cz,hw,hd} rect) with the
## lamp height `y` already dropped below that volume's ceiling PLANE (slabs/roofs are
## built top-face-down: a slab placed at Y occupies [Y-0.3, Y], so the underside is
## Y-0.3 and _CEIL_DROP 0.45 leaves ~0.1 m of clearance).
##   tower     — one volume per storey, ceiling at (s+1)*_STOREY_H.
##   warehouse — one volume, ceiling at roof_h.
##   house     — two volumes (ground + upper), ceilings at _STOREY_H and roof_h.
## COURTYARD shells are open to the sky around the origin, so their only roofed room is
## the closed BACK wing (-Z beyond COURT_CLEAR) — the rect is clamped to that band.
static func _interior_volumes(theme: String, def: Dictionary, roof_h: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var w: float = float(def["w"])
	var d: float = float(def["d"])
	var hw: float = w * 0.5 - _WALL_INSET
	var hd: float = d * 0.5 - _WALL_INSET
	if hw < 1.0 or hd < 0.5:
		return out
	if theme == "tower":
		var storeys: int = maxi(1, int(round(roof_h / _STOREY_H)))
		for s in range(storeys):
			var ceil_y: float = float(s + 1) * _STOREY_H
			out.append({"cx": 0.0, "cz": 0.0, "hw": hw, "hd": hd, "y": ceil_y - _CEIL_DROP})
		return out
	var cz: float = 0.0
	if bool(def["court"]):
		# 0.9 (not _WALL_INSET) off the back wall — the wing band is only ~2.5 m deep.
		var z_far: float = -d * 0.5 + 0.9
		var z_near: float = -ProceduralBuildings.COURT_CLEAR - 0.4
		if z_near - z_far < 0.6:
			return out
		cz = (z_far + z_near) * 0.5
		hd = (z_near - z_far) * 0.5
	if theme == "warehouse":
		out.append({"cx": 0.0, "cz": cz, "hw": hw, "hd": hd, "y": roof_h - _CEIL_DROP})
		return out
	out.append({"cx": 0.0, "cz": cz, "hw": hw, "hd": hd, "y": _STOREY_H - _CEIL_DROP})
	out.append({"cx": 0.0, "cz": cz, "hw": hw, "hd": hd, "y": roof_h - _CEIL_DROP})
	return out


## Lamps a volume of this floor area deserves (1-3). One lamp only reaches _INTERIOR_RANGE,
## so a big shed needs several before its middle stops reading as a black box.
static func _lamp_count(hw: float, hd: float) -> int:
	var area: float = (hw * 2.0) * (hd * 2.0)
	if area >= 210.0:
		return 3
	if area >= 120.0:
		return 2
	return 1


## One ceiling lamp at `pos` (world XZ, ceiling-relative Y): the housing + plafond discs
## join the batched kit MultiMeshes (free), and the light itself is a real shadowless
## OmniLight3D in INTERIOR_LIGHTS_GROUP. Born ON deliberately — if the gate ever stops
## running, the failure mode is "unbudgeted but LIT", never "every interior black".
## The emissive plafond is never gated either, so gating cannot pop visibly.
static func _interior_lamp(lights_root: Node3D, kits: Dictionary, pos: Vector3) -> void:
	_add(kits, "ceiling_lamp", _xf(Vector3(0.62, 0.12, 0.62), pos))
	_add(kits, "ceiling_bulb", _xf(Vector3(0.44, 0.07, 0.44), pos - Vector3(0.0, 0.1, 0.0)))
	var light := OmniLight3D.new()
	light.position = pos - Vector3(0.0, 0.18, 0.0)
	light.shadow_enabled = false  # PERF: shadow maps are the expensive half of a light
	light.light_color = _INTERIOR_WARM
	light.light_energy = _INTERIOR_ENERGY
	light.light_specular = 0.35  # keeps wet/metal interiors from turning into hotspots
	light.omni_range = _INTERIOR_RANGE
	light.omni_attenuation = 0.85  # <1 = flatter falloff: fill, not a spotlight pool
	light.add_to_group(INTERIOR_LIGHTS_GROUP)
	lights_root.add_child(light)


## PERF GATE — keeps at most INTERIOR_LIGHT_ACTIVE_MAX interior lamps in the render list,
## nearest to the camera first, and only within INTERIOR_LIGHT_DIST. `visible = false`
## drops a light from the renderer entirely (unlike energy 0, which still clusters).
## Public + camera-driven so ANY per-frame owner can call it (see _arm_interior_gate);
## a camera-less frame (hub/menu/headless) switches every lamp off.
static func gate_interior_lights(cam: Camera3D) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var lights: Array = tree.get_nodes_in_group(INTERIOR_LIGHTS_GROUP)
	if lights.is_empty():
		return
	var live: bool = cam != null and cam.is_inside_tree()
	var cam_pos: Vector3 = cam.global_position if live else Vector3.ZERO
	var cut: float = INTERIOR_LIGHT_DIST * INTERIOR_LIGHT_DIST
	if live and lights.size() > INTERIOR_LIGHT_ACTIVE_MAX:
		# Cheap nearest-N: sort the distances (not the nodes) and take the Nth as the cut.
		var d2s: Array[float] = []
		for n in lights:
			var probe := n as Node3D
			if probe != null and probe.is_inside_tree():
				d2s.append(probe.global_position.distance_squared_to(cam_pos))
		if d2s.size() > INTERIOR_LIGHT_ACTIVE_MAX:
			d2s.sort()
			cut = minf(cut, d2s[INTERIOR_LIGHT_ACTIVE_MAX - 1])
	var on: int = 0
	for n in lights:
		var light := n as Light3D
		if light == null or not light.is_inside_tree():
			continue
		var want: bool = (
			live
			and on < INTERIOR_LIGHT_ACTIVE_MAX
			and light.global_position.distance_squared_to(cam_pos) <= cut
		)
		if want:
			on += 1
		if light.visible != want:
			light.visible = want


## Self-driving gate tick (~3 Hz) so the budget holds with no wiring elsewhere. The gate
## is idempotent state assignment, so a second owner (e.g. world_atmosphere's 1 Hz
## _gate_climate_zones tick) may call gate_interior_lights too — then delete this Timer.
static func _arm_interior_gate(lights_root: Node3D) -> void:
	var timer := Timer.new()
	timer.name = "InteriorGate"
	timer.wait_time = _INTERIOR_GATE_PERIOD
	timer.autostart = true
	timer.timeout.connect(func() -> void: _gate_tick(lights_root))
	lights_root.add_child(timer)


## Resolve THIS peer's camera off the lights root and run one gate pass.
static func _gate_tick(node: Node3D) -> void:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return
	var vp: Viewport = node.get_viewport()
	if vp == null:
		gate_interior_lights(null)
		return
	gate_interior_lights(vp.get_camera_3d())


## Fold the BUILDERS' own fixtures (ProceduralBuildings._light_fixture: tower storeys,
## warehouse wing, house floors, yard pole, locked annex + the temple lanterns) into the
## SAME budget — otherwise ~16 permanently-lit omnis sit outside the cap and the "12
## active" number is a fiction. Runtime-only: it adds a GROUP and later toggles
## `visible`; the golden container checksum folds name/class/transform/multimesh only,
## so this cannot move it. Flip _ADOPT_BUILDER_LIGHTS to leave them untouched.
static func _adopt_builder_lights(arena_root: Node3D) -> void:
	var geo := arena_root.get_node_or_null("NavigationRegion3D/Geometry") as Node3D
	if geo == null:
		return
	for n in geo.find_children("*", "OmniLight3D", true, false):
		var light := n as OmniLight3D
		if light == null:
			continue
		if light.is_in_group(INTERIOR_LIGHTS_GROUP) or light.is_in_group(Groups.NIGHT_LIGHTS):
			continue
		light.add_to_group(INTERIOR_LIGHTS_GROUP)


## Append the kit's transform(s) at `pos` (the kit's BASE — roof surface / ground).
static func _piece(kits: Dictionary, kit: String, pos: Vector3, yaw: float, ks: int) -> void:
	match kit:
		"ac_unit":
			_add(kits, "ac_unit", _xf(Vector3(0.9, 0.8, 0.5), pos + Vector3(0, 0.4, 0), yaw))
			_add(kits, "ac_fan", _xf(Vector3(0.5, 0.06, 0.5), pos + Vector3(0, 0.83, 0), yaw))
		"antenna":
			_add(kits, "antenna", _xf(Vector3(0.1, 3.0, 0.1), pos + Vector3(0, 1.5, 0), yaw))
		"vent_stack":
			_add(kits, "vent_stack", _xf(Vector3(0.4, 0.9, 0.4), pos + Vector3(0, 0.45, 0), yaw))
		"water_tank":
			_add(kits, "water_tank", _xf(Vector3(1.8, 1.6, 1.8), pos + Vector3(0, 0.8, 0), yaw))
		"barrier":
			_add(kits, "barrier", _xf(Vector3(1.8, 0.9, 0.4), pos + Vector3(0, 0.45, 0), yaw))
		"crate":
			_add(kits, "crate", _xf(Vector3(0.7, 0.7, 0.7), pos + Vector3(0, 0.35, 0), yaw))
		"bench":
			var back: Vector3 = Basis.from_euler(Vector3(0, yaw, 0)) * Vector3(0, 0, -0.215)
			_add(kits, "bench", _xf(Vector3(1.8, 0.08, 0.5), pos + Vector3(0, 0.42, 0), yaw))
			_add(
				kits, "bench", _xf(Vector3(1.8, 0.42, 0.07), pos + back + Vector3(0, 0.62, 0), yaw)
			)
		"ruin_block":
			var sc := Vector3(
				ProcHash.hrange(ks + 5, 1.4, 2.0),
				ProcHash.hrange(ks + 6, 0.5, 0.9),
				ProcHash.hrange(ks + 7, 0.4, 0.7)
			)
			var tilt: float = ProcHash.hrange(ks + 8, -0.09, 0.09)
			var b: Basis = Basis.from_euler(Vector3(tilt, yaw, tilt * 0.7)) * Basis.from_scale(sc)
			_add(kits, "ruin_block", Transform3D(b, pos + Vector3(0, sc.y * 0.5 - 0.08, 0)))


## Street-piece keep-outs: >=11 m from every extraction zone, >=4 m from the annex.
static func _blocked(px: float, pz: float, evac_points: Array[Vector2], annex: Vector2) -> bool:
	for e in evac_points:
		if Vector2(px - e.x, pz - e.y).length_squared() < _EVAC_CLEARANCE * _EVAC_CLEARANCE:
			return true
	return annex.is_finite() and Vector2(px - annex.x, pz - annex.y).length_squared() < 16.0


## Min-spacing check against already-accepted local rooftop points.
static func _spaced(placed: Array[Vector2], px: float, pz: float, min_d: float) -> bool:
	for p in placed:
		if Vector2(px - p.x, pz - p.y).length_squared() < min_d * min_d:
			return false
	return true


## Transform3D with the kit's real size baked into the basis (unit meshes).
static func _xf(scale: Vector3, pos: Vector3, yaw: float = 0.0) -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0, yaw, 0)) * Basis.from_scale(scale), pos)


## Same, for kits that must be TIPPED OVER (wheels, cable-spool flanges, laid pipes): the
## unit cylinder's axis is +Y, so the euler carries the tip and `scale` stays in the MESH's
## own frame (x/z = diameter, y = length along the axis). Default euler order is YXZ, so
## (PI/2, yaw, 0) lays the axis along the yaw-forward direction and (0, yaw, PI/2) lays it
## across it — the axle of a wheel.
static func _xf_rot(scale: Vector3, pos: Vector3, euler: Vector3) -> Transform3D:
	return Transform3D(Basis.from_euler(euler) * Basis.from_scale(scale), pos)


static func _add(kits: Dictionary, kit: String, t: Transform3D) -> void:
	if not kits.has(kit):
		kits[kit] = []
	(kits[kit] as Array).append(t)


## ONE MultiMeshInstance3D per kit type map-wide. Shadows ON except the thin antennas.
static func _emit(root: Node3D, kits: Dictionary, head_mat: StandardMaterial3D) -> void:
	for kit_name in kits.keys():
		var kit: String = str(kit_name)
		var arr: Array = kits[kit_name]
		if arr.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _kit_mesh(kit)
		mm.instance_count = arr.size()
		for j in range(arr.size()):
			var t: Transform3D = arr[j]
			mm.set_instance_transform(j, t)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Kit_%s" % kit
		mmi.multimesh = mm
		mmi.material_override = head_mat if kit == "lamp_head" else _kit_material(kit)
		if kit in _NO_SHADOW_KITS:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)


## Unit primitive per kit: cylinder kits get r=0.5 h=1.0, cone kits the same with a
## near-zero top radius, box kits a 1 m cube — the per-instance basis scale turns these
## into the real sizes.
static func _kit_mesh(kit: String) -> Mesh:
	if kit in _CYL_KITS or kit in _CONE_KITS:
		var c := CylinderMesh.new()
		c.top_radius = 0.06 if kit in _CONE_KITS else 0.5
		c.bottom_radius = 0.5
		c.height = 1.0
		c.radial_segments = 10
		return c
	var b := BoxMesh.new()
	b.size = Vector3.ONE
	return b


## Kit materials reuse the shared weathered building palette (ONE instance per kit —
## the whole MultiMesh batch shares it). Street-prop kits resolve through their own table
## first (_PROP_MATS) so this match stays inside the gdlint max-returns budget.
static func _kit_material(kit: String) -> StandardMaterial3D:
	var prop: StandardMaterial3D = _prop_material(kit)
	if prop != null:
		return prop
	match kit:
		"ac_unit":
			return ProceduralBuildings.mat_metal(101)
		"vent_stack":
			return ProceduralBuildings.mat_rust(105)
		"water_tank":
			return ProceduralBuildings.mat_rust(115)
		"barrier":
			return ProceduralBuildings.mat_concrete(107)
		"bench":
			return ProceduralBuildings.mat_timber(109)
		"crate":
			return ProceduralBuildings.mat_timber(119)
		"ruin_block":
			return ProceduralBuildings.mat_sandstone(111)
		"ceiling_lamp":
			# LIGHT metal (not mat_metal_dark): post-relight, a dark housing on a dark
			# ceiling falls under the grade's readable floor and the lamp disappears.
			return ProceduralBuildings.mat_metal(127)
		"ceiling_bulb":
			return ProcMaterials.emissive(_INTERIOR_WARM, _INTERIOR_GLOW)
	return ProceduralBuildings.mat_metal_dark(103)  # ac_fan / antenna / drainpipe / lamp_pole
