extends RefCounted
class_name ProceduralBuildings
## Procedural modular BUILDINGS — believable urban-ruins structures assembled in
## code from primitive boxes/cylinders, each part carrying BOTH a rendered mesh and
## (for solid walls/floors/roofs) a StaticBody3D + CollisionShape3D on collision
## layer 1, so the runtime navmesh bake (arena.gd `_bake_navmesh`) routes pathing
## around them and weapon raycasts are blocked.
##
## Reuses ProceduralModels' static helpers for materials/parts where convenient, but
## adds COLLISION (ProceduralModels parts are render-only). Every builder works in
## building-LOCAL coordinates with feet at local y≈0; arena.gd places the returned
## Node3D at the POI world center.
##
## Determinism: NO Math.random()/Date — all variation derives from a passed `seed`
## int via cheap arithmetic hashing (`_h`).
##
## CRITICAL parse trap (warnings-as-errors): never `var x := <Variant>` from
## Dictionary.get()/untyped ternary — every local below is explicitly typed.

# ---------------------------------------------------------------- materials
## Weathered urban palette. All StandardMaterial3D (required).
static func mat_concrete() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.40, 0.40, 0.42), 0.0, 0.92)

static func mat_concrete_dark() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.27, 0.28, 0.30), 0.0, 0.94)

static func mat_concrete_stained() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.33, 0.32, 0.30), 0.05, 0.9)

static func mat_rust() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.46, 0.26, 0.16), 0.25, 0.82)

static func mat_metal() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.34, 0.37, 0.41), 0.55, 0.45)

static func mat_metal_dark() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.18, 0.19, 0.21), 0.5, 0.5)

static func mat_glass() -> StandardMaterial3D:
	# Dark window glass with a faint cold emission so windows read at dusk.
	return ProceduralModels._mat(Color(0.07, 0.09, 0.12), 0.6, 0.15,
		Color(0.10, 0.16, 0.22), 0.5)

static func mat_container(sid: int) -> StandardMaterial3D:
	# Pick a faded shipping-container color deterministically from seed.
	var palette: Array[Color] = [
		Color(0.42, 0.20, 0.14),  # rust red
		Color(0.20, 0.34, 0.27),  # faded green
		Color(0.18, 0.28, 0.40),  # navy
		Color(0.46, 0.40, 0.20),  # ochre
		Color(0.36, 0.37, 0.40),  # gray
	]
	var idx: int = _h(sid) % palette.size()
	var c: Color = palette[idx]
	return ProceduralModels._mat(c, 0.2, 0.72)

# ---------------------------------------------------------------- seed helper
## Cheap deterministic positive hash of an int → big positive int.
static func _h(n: int) -> int:
	var x: int = (n * 2654435761) ^ 0x27d4eb2d
	x = (x ^ (x >> 15)) * 0x85ebca6b
	x = x ^ (x >> 13)
	return abs(x)

## Deterministic float in [0,1) from seed `n`.
static func _hf(n: int) -> float:
	return float(_h(n) % 100000) / 100000.0

# ---------------------------------------------------------------- solid part
## Adds a box that BOTH renders (MeshInstance3D) and collides (StaticBody3D +
## BoxShape3D on layer 1) under `parent`, centered at `offset` with optional Y-rot.
## This is the building block every wall/floor/roof uses so the navmesh bakes around
## it. `rot_y_deg` rotates about Y only (keeps the box axis-aligned for collision via
## the StaticBody transform).
static func _solid(parent: Node3D, size: Vector3, mat: StandardMaterial3D,
		offset: Vector3, rot_y_deg: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var basis := Basis.from_euler(Vector3(0.0, deg_to_rad(rot_y_deg), 0.0))
	body.transform = Transform3D(basis, offset)
	var mi := MeshInstance3D.new()
	mi.mesh = ProceduralModels._box(size)
	mi.material_override = mat
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	parent.add_child(body)
	return body

## Render-only decorative box (no collision) — for window glass, trim, signage that
## should not block navigation/raycasts.
static func _decor(parent: Node3D, size: Vector3, mat: StandardMaterial3D,
		offset: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	return ProceduralModels._part(parent, ProceduralModels._box(size), mat, offset, rot_deg)

# ================================================================ LOW-LEVEL PIECES

## A wall PANEL of given length (X) × height (Y) × thickness (Z), built feet-up so
## its base sits at local y=0 of the returned node. Optional rectangular window/door
## openings are produced by building the wall as solid SEGMENTS around the gap (so
## the opening is genuinely walkable / see-through, not a painted-on hole).
## The returned Node3D is positioned/rotated by the caller.
static func wall(length: float, height: float, thickness: float, mat: StandardMaterial3D,
		with_window: bool = false, with_door: bool = false) -> Node3D:
	var root := Node3D.new()
	var glass := mat_glass()
	if with_door:
		# Door gap centered, 1.6 wide × 2.2 tall. Left pier, right pier, lintel above.
		var dw: float = 1.6
		var dh: float = min(2.2, height - 0.2)
		var side: float = (length - dw) * 0.5
		if side > 0.05:
			_solid(root, Vector3(side, height, thickness), mat,
				Vector3(-(length - side) * 0.5, height * 0.5, 0.0))
			_solid(root, Vector3(side, height, thickness), mat,
				Vector3((length - side) * 0.5, height * 0.5, 0.0))
		var lintel_h: float = height - dh
		if lintel_h > 0.05:
			_solid(root, Vector3(dw, lintel_h, thickness), mat,
				Vector3(0.0, dh + lintel_h * 0.5, 0.0))
	elif with_window:
		# Window band: sill (0.0..1.0), opening (1.0..2.0), header (2.0..height).
		var sill_h: float = min(1.0, height * 0.35)
		var win_h: float = min(1.1, max(0.4, height - sill_h - 0.6))
		var head_y: float = sill_h + win_h
		var ww: float = min(length * 0.5, 1.6)
		var pier: float = (length - ww) * 0.5
		# Sill strip across the full length.
		_solid(root, Vector3(length, sill_h, thickness), mat,
			Vector3(0.0, sill_h * 0.5, 0.0))
		# Header strip across the full length.
		var header_h: float = height - head_y
		if header_h > 0.05:
			_solid(root, Vector3(length, header_h, thickness), mat,
				Vector3(0.0, head_y + header_h * 0.5, 0.0))
		# Side piers flanking the opening.
		if pier > 0.05:
			_solid(root, Vector3(pier, win_h, thickness), mat,
				Vector3(-(length - pier) * 0.5, sill_h + win_h * 0.5, 0.0))
			_solid(root, Vector3(pier, win_h, thickness), mat,
				Vector3((length - pier) * 0.5, sill_h + win_h * 0.5, 0.0))
		# Glass pane filling the opening (decorative, thin, no collision).
		_decor(root, Vector3(ww, win_h, thickness * 0.4), glass,
			Vector3(0.0, sill_h + win_h * 0.5, 0.0))
	else:
		_solid(root, Vector3(length, height, thickness), mat,
			Vector3(0.0, height * 0.5, 0.0))
	return root

## A horizontal floor/ceiling slab w(X) × d(Z), 0.3 thick, top face at local y=0
## (so place its node at the storey height you want the walking surface).
static func floor_slab(w: float, d: float, mat: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	_solid(root, Vector3(w, 0.3, d), mat, Vector3(0.0, -0.15, 0.0))
	return root

## A flat roof slab (same as a floor but tinted, with a small parapet lip).
static func roof(w: float, d: float, mat: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	_solid(root, Vector3(w, 0.3, d), mat, Vector3(0.0, -0.15, 0.0))
	# Low parapet around the edges (knee height) so a roof reads as a roof.
	var ph: float = 0.5
	_solid(root, Vector3(w, ph, 0.25), mat, Vector3(0.0, ph * 0.5, d * 0.5 - 0.12))
	_solid(root, Vector3(w, ph, 0.25), mat, Vector3(0.0, ph * 0.5, -d * 0.5 + 0.12))
	_solid(root, Vector3(0.25, ph, d), mat, Vector3(w * 0.5 - 0.12, ph * 0.5, 0.0))
	_solid(root, Vector3(0.25, ph, d), mat, Vector3(-w * 0.5 + 0.12, ph * 0.5, 0.0))
	return root

## A square pillar of height h, radius r (box-section), base at local y=0.
static func pillar(h: float, r: float, mat: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	_solid(root, Vector3(r * 2.0, h, r * 2.0), mat, Vector3(0.0, h * 0.5, 0.0))
	return root

## A pile of a few tilted broken blocks (collidable cover), deterministic by seed.
static func rubble_pile(sid: int) -> Node3D:
	var root := Node3D.new()
	var m_a := mat_concrete()
	var m_b := mat_concrete_dark()
	var m_c := mat_rust()
	var count: int = 3 + (_h(sid) % 3)  # 3..5 chunks
	for i in range(count):
		var s: int = sid * 31 + i * 7
		var sx: float = 0.5 + _hf(s) * 1.1
		var sy: float = 0.3 + _hf(s + 1) * 0.7
		var sz: float = 0.5 + _hf(s + 2) * 1.1
		var px: float = (_hf(s + 3) - 0.5) * 2.2
		var pz: float = (_hf(s + 4) - 0.5) * 2.2
		var roty: float = _hf(s + 5) * 90.0
		var mm: StandardMaterial3D = m_a
		var pick: int = _h(s + 6) % 3
		if pick == 1:
			mm = m_b
		elif pick == 2:
			mm = m_c
		_solid(root, Vector3(sx, sy, sz), mm, Vector3(px, sy * 0.5, pz), roty)
	return root

## A shipping container w×h×d (hollow-looking via a contrasting door end), base at
## local y=0. Solid (blocks pathing) — read as crates/cargo.
static func container(w: float, h: float, d: float, mat: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	_solid(root, Vector3(w, h, d), mat, Vector3(0.0, h * 0.5, 0.0))
	# Corrugation ribs + a darker door end (decorative only).
	var ribs := mat_metal_dark()
	var n: int = int(d / 0.8)
	for i in range(n):
		var z: float = -d * 0.5 + 0.4 + i * 0.8
		_decor(root, Vector3(w + 0.04, h * 0.9, 0.06), ribs, Vector3(0.0, h * 0.5, z))
	_decor(root, Vector3(w * 0.9, h * 0.8, 0.04), ribs, Vector3(0.0, h * 0.5, d * 0.5 + 0.02))
	return root

# ================================================================ COMPOSITE BUILDINGS
# Each composite fits within `footprint` (X×Z meters), feet at local y≈0. When
# `courtyard` is true the structure is built OPEN (3-sided) leaving a ~10×10 m clear,
# roofless, collision-free area around the local origin for the extraction zone.

const COURT_CLEAR := 5.0  # half-extent (m) of the keep-clear square around origin

## Returns true if a wall segment centered at (cx,cz) spanning the given half-sizes
## would intrude into the central keep-clear square — used to skip courtyard pieces.
static func _intrudes(cx: float, cz: float, hx: float, hz: float) -> bool:
	return absf(cx) - hx < COURT_CLEAR and absf(cz) - hz < COURT_CLEAR

## Multi-storey TOWER: a tall blocky high-rise with banded window walls, an interior
## floor, a roof + a rooftop housing. Authored to roughly fill `footprint`.
static func build_tower(footprint: Vector2) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	var conc := mat_concrete()
	var conc_d := mat_concrete_dark()
	var th: float = 0.35
	var storeys: int = 3 + (_h(1) % 2)  # 3..4
	var sh: float = 3.0                  # storey height
	# Ground slab.
	_place(root, floor_slab(w, d, conc_d), Vector3(0, 0.0, 0))
	for s in range(storeys):
		var y: float = s * sh
		var win: bool = s > 0
		# Four perimeter walls per storey (front has a door on storey 0).
		_place_wall(root, w, sh, th, conc, Vector3(0, y, -d * 0.5 + th * 0.5), 0.0,
			win, s == 0)
		_place_wall(root, w, sh, th, conc, Vector3(0, y, d * 0.5 - th * 0.5), 0.0, win, false)
		_place_wall(root, d, sh, th, conc, Vector3(-w * 0.5 + th * 0.5, y, 0), 90.0, win, false)
		_place_wall(root, d, sh, th, conc, Vector3(w * 0.5 - th * 0.5, y, 0), 90.0, win, false)
		# Floor slab above each storey (the next storey's floor / final roof handled after).
		if s < storeys - 1:
			_place(root, floor_slab(w - 0.4, d - 0.4, conc_d), Vector3(0, (s + 1) * sh, 0))
	var top: float = storeys * sh
	# Roof + small rooftop utility housing.
	_place(root, roof(w, d, conc_d), Vector3(0, top, 0))
	_place(root, container(w * 0.35, 2.0, d * 0.35, mat_metal()), Vector3(w * 0.18, top, -d * 0.15))
	# A couple of corner pilasters for silhouette.
	_place(root, pillar(top, 0.4, conc_d), Vector3(-w * 0.5 + 0.4, 0, -d * 0.5 + 0.4))
	_place(root, pillar(top, 0.4, conc_d), Vector3(w * 0.5 - 0.4, 0, d * 0.5 - 0.4))
	return root

## WAREHOUSE: a big single-storey shed with tall walls, roller-door front, clerestory
## windows, a partial roof. With courtyard=true it is open-centered (3 walls + flanking
## roof wings) leaving the middle clear for an extraction zone.
static func build_warehouse(footprint: Vector2, courtyard: bool = true) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	var conc := mat_concrete_stained()
	var metal := mat_metal()
	var th: float = 0.4
	var h: float = 5.0
	# Back wall (north, -Z) + two side walls always; front wall only if NOT courtyard.
	_place_wall(root, w, h, th, conc, Vector3(0, 0, -d * 0.5 + th * 0.5), 0.0, true, false)
	# Side walls — if courtyard, only the OUTER halves (skip the inner span near origin).
	if courtyard:
		var seg: float = (d * 0.5 - COURT_CLEAR)
		if seg > 0.5:
			var cz: float = -COURT_CLEAR - seg * 0.5
			_place_wall(root, seg, h, th, conc, Vector3(-w * 0.5 + th * 0.5, 0, cz), 90.0, true, false)
			_place_wall(root, seg, h, th, conc, Vector3(w * 0.5 - th * 0.5, 0, cz), 90.0, true, false)
			# Roof wing only over the closed (north) portion, leaving center open.
			_place(root, roof(w, d * 0.5 - COURT_CLEAR + 0.5, mat_metal_dark()),
				Vector3(0, h, -COURT_CLEAR - (d * 0.5 - COURT_CLEAR) * 0.5 + 0.25))
		# Stacked containers along the back as cover (clear of center).
		_place(root, container(3.0, 2.6, 6.0, mat_container(7)),
			Vector3(-w * 0.5 + 2.0, 0, -d * 0.5 + 4.0))
		_place(root, container(3.0, 2.6, 6.0, mat_container(11)),
			Vector3(w * 0.5 - 2.0, 0, -d * 0.5 + 4.0))
	else:
		_place_wall(root, d, h, th, conc, Vector3(-w * 0.5 + th * 0.5, 0, 0), 90.0, true, false)
		_place_wall(root, d, h, th, conc, Vector3(w * 0.5 - th * 0.5, 0, 0), 90.0, true, false)
		_place_wall(root, w, h, th, conc, Vector3(0, 0, d * 0.5 - th * 0.5), 0.0, false, true)
		_place(root, roof(w, d, mat_metal_dark()), Vector3(0, h, 0))
		_place(root, container(3.0, 2.6, 6.0, mat_container(7)), Vector3(-w * 0.5 + 2.5, 0, 0))
	return root

## HOUSE: a 2-storey dwelling with a pitched-look (stepped) roof, door, windows. With
## courtyard=true the ground floor is an open 3-sided shell around the center, with an
## upper floor wing only on the closed side so the extraction zone stays clear & open.
static func build_house(footprint: Vector2, courtyard: bool = true) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	var brick := ProceduralModels._mat(Color(0.40, 0.30, 0.26), 0.0, 0.85)
	var conc_d := mat_concrete_dark()
	var th: float = 0.3
	var sh: float = 3.0
	# Ground slab.
	_place(root, floor_slab(w, d, conc_d), Vector3(0, 0.0, 0))
	# Back + sides (ground). Front wall (with door) only if not courtyard.
	_place_wall(root, w, sh, th, brick, Vector3(0, 0, -d * 0.5 + th * 0.5), 0.0, true, false)
	if courtyard:
		var seg: float = (d * 0.5 - COURT_CLEAR)
		if seg > 0.5:
			var cz: float = -COURT_CLEAR - seg * 0.5
			_place_wall(root, seg, sh, th, brick, Vector3(-w * 0.5 + th * 0.5, 0, cz), 90.0, true, false)
			_place_wall(root, seg, sh, th, brick, Vector3(w * 0.5 - th * 0.5, 0, cz), 90.0, true, false)
			# Upper floor + walls only over the closed (back) wing.
			var wing_d: float = d * 0.5 - COURT_CLEAR + 0.5
			var wing_cz: float = -COURT_CLEAR - (d * 0.5 - COURT_CLEAR) * 0.5 + 0.25
			_place(root, floor_slab(w - 0.2, wing_d, conc_d), Vector3(0, sh, wing_cz))
			_place_wall(root, w, sh, th, brick, Vector3(0, sh, -d * 0.5 + th * 0.5), 0.0, true, false)
			_place(root, roof(w, wing_d, conc_d), Vector3(0, sh * 2.0, wing_cz))
	else:
		_place_wall(root, d, sh, th, brick, Vector3(-w * 0.5 + th * 0.5, 0, 0), 90.0, true, false)
		_place_wall(root, d, sh, th, brick, Vector3(w * 0.5 - th * 0.5, 0, 0), 90.0, true, false)
		_place_wall(root, w, sh, th, brick, Vector3(0, 0, d * 0.5 - th * 0.5), 0.0, false, true)
		# Upper storey.
		_place(root, floor_slab(w - 0.2, d - 0.2, conc_d), Vector3(0, sh, 0))
		_place_wall(root, w, sh, th, brick, Vector3(0, sh, -d * 0.5 + th * 0.5), 0.0, true, false)
		_place_wall(root, w, sh, th, brick, Vector3(0, sh, d * 0.5 - th * 0.5), 0.0, true, false)
		_place_wall(root, d, sh, th, brick, Vector3(-w * 0.5 + th * 0.5, sh, 0), 90.0, true, false)
		_place_wall(root, d, sh, th, brick, Vector3(w * 0.5 - th * 0.5, sh, 0), 90.0, true, false)
		# Stepped roof (pitched look).
		_place(root, roof(w, d, conc_d), Vector3(0, sh * 2.0, 0))
		_place(root, roof(w * 0.6, d * 0.6, conc_d), Vector3(0, sh * 2.0 + 0.4, 0))
	return root

## PLAZA cover: a low open-air structure for the central plaza — a cluster of waist/
## chest-high cover blocks + a few tall pillars supporting a partial canopy. Center
## stays open & walkable (plaza is an enemy-spawn crossroads, no extraction zone).
static func build_plaza_cover() -> Node3D:
	var root := Node3D.new()
	var conc := mat_concrete()
	var conc_d := mat_concrete_dark()
	# Four chest-high cover blocks at the quadrants.
	var quad: Array[Vector2] = [Vector2(-7, -7), Vector2(7, -7), Vector2(7, 7), Vector2(-7, 7)]
	for i in range(quad.size()):
		var q: Vector2 = quad[i]
		_solid(root, Vector3(2.4, 1.2, 2.4), conc, Vector3(q.x, 0.6, q.y), float(_h(i) % 30))
	# Two edge barriers (N/S).
	_solid(root, Vector3(6.0, 1.2, 0.6), conc_d, Vector3(0, 0.6, -10))
	_solid(root, Vector3(6.0, 1.2, 0.6), conc_d, Vector3(0, 0.6, 10))
	# Four tall pillars + a thin canopy ring (open center, ~4m clearance).
	var pp: Array[Vector2] = [Vector2(-5, -5), Vector2(5, -5), Vector2(5, 5), Vector2(-5, 5)]
	for j in range(pp.size()):
		var p: Vector2 = pp[j]
		_place(root, pillar(5.0, 0.35, conc_d), Vector3(p.x, 0, p.y))
	# Canopy beams (decorative, high up — render-only so they don't block pathing).
	_decor(root, Vector3(11.0, 0.4, 0.5), conc_d, Vector3(0, 5.2, -5))
	_decor(root, Vector3(11.0, 0.4, 0.5), conc_d, Vector3(0, 5.2, 5))
	_decor(root, Vector3(0.5, 0.4, 11.0), conc_d, Vector3(-5, 5.2, 0))
	_decor(root, Vector3(0.5, 0.4, 11.0), conc_d, Vector3(5, 5.2, 0))
	return root

## CONTAINER YARD: stacks of shipping containers forming partial walls/cover. With
## courtyard=true the stacks ring the OUTSIDE of the footprint leaving the center
## clear for an extraction zone.
static func build_container_yard(footprint: Vector2, courtyard: bool = true) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	# Candidate container placements (cx, cz, sizeX, sizeZ, stackY-levels, seed).
	# Ring layout around the footprint edges.
	var ed_x: float = w * 0.5 - 1.5
	var ed_z: float = d * 0.5 - 1.5
	var spots: Array = [
		[-ed_x, -ed_z, 2.6, 6.0, 2, 1],
		[ed_x, -ed_z, 2.6, 6.0, 1, 2],
		[ed_x, ed_z, 6.0, 2.6, 2, 3],
		[-ed_x, ed_z, 6.0, 2.6, 1, 4],
		[0.0, -ed_z, 6.0, 2.6, 1, 5],
		[ed_x, 0.0, 2.6, 6.0, 2, 6],
		[-ed_x, 0.0, 2.6, 6.0, 1, 7],
		[0.0, ed_z, 6.0, 2.6, 2, 8],
	]
	var ch: float = 2.6  # container height per level
	for s in spots:
		var cx: float = s[0]
		var cz: float = s[1]
		var sx: float = s[2]
		var sz: float = s[3]
		var levels: int = s[4]
		var sd: int = s[5]
		# Skip any spot that would intrude on the keep-clear center (courtyard mode).
		if courtyard and _intrudes(cx, cz, sx * 0.5, sz * 0.5):
			continue
		for lv in range(levels):
			# Slight stagger so stacks don't look perfectly aligned.
			var jitter: float = (_hf(sd * 13 + lv) - 0.5) * 0.4
			_place(root, container(sx, ch, sz, mat_container(sd + lv)),
				Vector3(cx + jitter, lv * ch, cz))
	# A couple of rubble piles in open corners for ground detail (clear of center).
	_place(root, rubble_pile(sd_seed(1)), Vector3(-ed_x * 0.4, 0, ed_z * 0.6))
	return root

## Tiny deterministic seed source so rubble varies per call site.
static func sd_seed(n: int) -> int:
	return 9173 + n * 577

# ---------------------------------------------------------------- placement helpers
## Adds a prebuilt sub-assembly `child` under `parent` at `offset`.
static func _place(parent: Node3D, child: Node3D, offset: Vector3) -> void:
	child.position = offset
	parent.add_child(child)

## Builds a wall() and places it at offset with a Y-rotation (degrees).
static func _place_wall(parent: Node3D, length: float, height: float, thickness: float,
		mat: StandardMaterial3D, offset: Vector3, rot_y_deg: float,
		with_window: bool, with_door: bool) -> void:
	var wnode := wall(length, height, thickness, mat, with_window, with_door)
	wnode.position = offset
	wnode.rotation = Vector3(0.0, deg_to_rad(rot_y_deg), 0.0)
	parent.add_child(wnode)
