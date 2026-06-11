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
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

# Per-theme flat-roof height fallbacks — used only if a building root lost its "roof_h"
# meta (set by the build_tower/build_warehouse/build_house hooks).
const _FALLBACK_ROOF_H := {"tower": 9.0, "warehouse": 5.0, "house": 6.0, "yard": 2.6}
const _FLAT_ROOF_THEMES: Array[String] = ["tower", "warehouse", "house"]
const _URBAN_THEMES: Array[String] = ["tower", "warehouse", "house", "yard", "plaza"]
const _EVAC_CLEARANCE := 11.0  # street pieces keep this far from every extraction zone
const _LAMP_CAP := 14  # map-wide street-lamp budget (each carries a live OmniLight3D)
const _WARM := Color(1.0, 0.82, 0.55)


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
		elif theme == "yard":
			_yard_stack_pieces(kits, s, center, def)
		_street_ring(kits, s, center, def, theme, evac_points, annex)
		if theme in _URBAN_THEMES and lamps < _LAMP_CAP:
			lamps += _lamps(
				root, kits, head_mat, s, center, def, theme, evac_points, annex, _LAMP_CAP - lamps
			)
	_emit(root, kits, head_mat)


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
		if kit == "antenna":
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)


## Unit primitive per kit: cylinder kits get r=0.5 h=1.0, box kits a 1 m cube — the
## per-instance basis scale turns these into the real sizes.
static func _kit_mesh(kit: String) -> Mesh:
	if kit in ["ac_fan", "antenna", "water_tank", "drainpipe", "lamp_pole"]:
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
	return ProceduralBuildings.mat_metal_dark(103)  # ac_fan / antenna / drainpipe / lamp_pole
