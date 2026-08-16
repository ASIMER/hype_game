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
	"ac_fan", "antenna", "water_tank", "drainpipe", "lamp_pole", "ceiling_lamp", "ceiling_bulb"
]
const _NO_SHADOW_KITS: Array[String] = ["antenna", "ceiling_lamp", "ceiling_bulb"]


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
## list (street pieces keep clear of them). No-op on headless.
static func build(arena_root: Node3D, poi_defs: Dictionary, evac_points: Array[Vector2]) -> void:
	if arena_root == null:
		return
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
	var kits: Dictionary = {}  # kit name -> Array of Transform3D (one MultiMesh each)
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


## Unit primitive per kit: cylinder kits get r=0.5 h=1.0, box kits a 1 m cube — the
## per-instance basis scale turns these into the real sizes.
static func _kit_mesh(kit: String) -> Mesh:
	if kit in _CYL_KITS:
		var c := CylinderMesh.new()
		c.top_radius = 0.5
		c.bottom_radius = 0.5
		c.height = 1.0
		c.radial_segments = 10
		return c
	var b := BoxMesh.new()
	b.size = Vector3.ONE
	return b


## Kit materials reuse the shared weathered building palette (ONE instance per kit —
## the whole MultiMesh batch shares it).
static func _kit_material(kit: String) -> StandardMaterial3D:
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
