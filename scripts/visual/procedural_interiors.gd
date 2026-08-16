class_name ProceduralInteriors
extends RefCounted
## INTERIOR FURNISHING KITS for the procedural POI buildings — the missing inside of every
## shell (walk in today and you are in an empty box). `furnish()` returns ONE Node3D holding
## a themed furniture set laid out in a PERIMETER BAND along the walls of a w×d room, floor
## at local y=0, so the MIDDLE of the room stays open and walkable — enemies path through
## these buildings and must never be pinched by decoration.
##
## CONTRACT (the lead places the returned node):
##     var interior := ProceduralInteriors.furnish("warehouse", w, d, h, sid)
##     ProceduralBuildings._place(root, interior, Vector3(0.0, floor_y, 0.0))
##   * (w, d) is the FULL footprint of the enclosing shell; the band insets itself by
##     WALL_INSET (0.55 m), which clears wall thicknesses up to ~0.5 m — so pass the same
##     w/d the builder passed to its walls, NOT a pre-shrunk rect.
##   * `h` is the storey/ceiling height: anything taller than h - CEILING_CLEAR is skipped.
##   * For a COURTYARD shell (only the back wing is enclosed) pass the WING's w×d and place
##     the node at the wing centre — the open half is then never furnished by construction.
##   * `doors` is a list of building-LOCAL XZ keep-out points: door centres, stair-flight
##     lanes, locked-annex loot points, anything that must stay clear. Items keep
##     DOOR_CLEAR (1.2 m) PLUS their own half-extent away from each point.
##
## RENDER-ONLY BY DEFAULT (`collide_large` = false): the runtime navmesh bake parses ONLY
## collision shapes (`geometry_parsed_geometry_type=1`), so furniture with no collider cannot
## break a single enemy path. `collide_large = true` opts the BULKY items (rack, workbench,
## cabinet, bunk, altar, stove, bed…) into ONE StaticBody3D + BoxShape3D each — real cover,
## but it re-bakes into the navmesh, so switch it on per theme only after a live path check.
##
## PERF: every piece is a unit BoxMesh / CylinderMesh / SphereMesh instance whose real size
## is baked into its per-instance Transform3D basis, batched into ONE MultiMeshInstance3D per
## (mesh, material) kit per building — a fully furnished warehouse is ~10 draws, not ~120
## (the ProceduralBuildingDetail discipline). Materials + unit meshes are cached statically,
## so the second building of a theme allocates nothing.
##
## DETERMINISM: every pick / gap / jitter hashes off `seed_val` through ProcHash — no
## randf/randi/Time — so co-op peers furnish byte-identically. NOTE FOR THE LEAD: these nodes
## live under the building, i.e. under NavigationRegion3D, whose children GoldenSnapshot folds
## (name/class/transform + MultiMesh buffers) — the first integration is an INTENDED golden
## change and needs `check_golden.py --capture`.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>` — every local below is typed.

# ---------------------------------------------------------------- layout tuning
const WALL_INSET := 0.55  # gap from the footprint edge to an item's BACK face
const CENTER_MIN_CLEAR := 2.0  # walkable lane guaranteed down the middle of the room (m)
const BAND_MAX := 1.25  # deepest perimeter band, however big the room is
const DOOR_CLEAR := 1.2  # keep-out radius around every `doors` point (+ item half-extent)
const CORNER_MARGIN := 0.15  # slack ON TOP of the perpendicular band at each wall's ends
const CEILING_CLEAR := 0.35  # headroom kept under the ceiling
const DENSITY_PER_M := 0.18  # items per metre of wall run
const MAX_ITEMS := 20  # hard budget per room
const YAW_JITTER := 3.0  # degrees of hand-placed-looking rotation slop
const GAP_MIN := 0.35
const GAP_MAX := 1.15

# Item footprint table: id -> [foot_x (along the wall), foot_z (depth), visual height,
# collider height, blocks]. `foot_x/foot_z` drive the wall walk + the door keep-out radius;
# `visual height` is the ceiling fit test; `collider height` only matters when the caller
# asks for collision on the bulky pieces.
const _ITEMS := {
	"shelf": [2.0, 0.6, 2.0, 2.0, true],
	"crate_stack": [1.35, 0.9, 1.45, 1.45, true],
	"pallet": [1.3, 1.05, 0.9, 0.9, false],
	"barrels": [1.35, 0.75, 0.95, 0.9, false],
	"workbench": [2.0, 0.85, 1.8, 1.0, true],
	"desk": [1.65, 0.85, 1.2, 0.75, true],
	"chair": [0.55, 0.55, 0.9, 0.9, false],
	"cabinet": [0.95, 0.5, 1.85, 1.85, true],
	"partition": [1.8, 0.25, 1.55, 1.5, false],
	"table": [1.45, 0.95, 0.8, 0.76, true],
	"bed": [2.05, 1.05, 0.7, 0.6, true],
	"dresser": [1.15, 0.55, 0.9, 0.9, true],
	"altar": [2.35, 1.0, 1.95, 1.05, true],
	"offer_stand": [0.7, 0.7, 1.3, 1.0, false],
	"low_table": [1.3, 0.7, 0.45, 0.36, false],
	"floor_mat": [1.55, 1.0, 0.22, 0.0, false],
	"bunk": [2.05, 0.95, 1.95, 1.9, true],
	"stove": [1.05, 1.0, 1.95, 1.55, true],
	"woodpile": [1.75, 0.65, 0.9, 0.85, false],
	"locker": [0.85, 0.5, 1.8, 1.78, true],
	"bench": [1.6, 0.5, 0.5, 0.45, false],
	"pot": [0.9, 0.8, 0.9, 0.85, false],
	"debris": [1.35, 0.95, 0.6, 0.55, false],
	"reed_mat": [1.65, 1.05, 0.3, 0.0, false],
	"column_drum": [1.0, 0.95, 0.8, 0.6, true],
}

# Theme -> the pool the wall walk draws from (repeat an id to weight it). Unknown themes
# fall back to "default"; "plaza" is deliberately EMPTY (open-air cover, nothing to furnish).
const _THEME_POOLS := {
	"warehouse": ["shelf", "crate_stack", "pallet", "barrels", "workbench", "shelf", "crate_stack"],
	"tower": ["desk", "chair", "cabinet", "partition", "shelf", "desk", "chair"],
	"office": ["desk", "chair", "cabinet", "partition", "shelf", "desk", "chair"],
	"house": ["table", "chair", "dresser", "shelf", "bed", "chair", "cabinet"],
	"temple": ["altar", "offer_stand", "low_table", "floor_mat", "offer_stand", "low_table"],
	"snow_lodge": ["bunk", "stove", "woodpile", "locker", "bench", "woodpile", "crate_stack"],
	"desert_ruins": ["pot", "debris", "reed_mat", "column_drum", "pot", "debris"],
	"yard": ["crate_stack", "pallet", "barrels", "shelf"],
	"plaza": [],
	"default": ["crate_stack", "barrels", "shelf", "pallet"],
}

# The one piece a themed room is built around — forced as the FIRST attempt, against the
# back (-Z) wall, so the room reads as a workshop / shrine / bunkroom instead of storage.
const _HERO := {
	"warehouse": "workbench",
	"tower": "cabinet",
	"office": "cabinet",
	"house": "bed",
	"temple": "altar",
	"snow_lodge": "stove",
	"desert_ruins": "column_drum",
}
# Items that must appear at most ONCE per room (a room with three altars reads as a prop bin).
const _ONCE := ["workbench", "altar", "stove", "bed"]

# Facing per wall index: 0 = -Z wall, 1 = +Z, 2 = -X, 3 = +X. Items are authored with their
# BACK at -Z and their FRONT at +Z, so this yaw turns each one to face into the room.
const _SIDE_YAW := [0.0, 180.0, 90.0, -90.0]

# Kit -> unit mesh. Everything not listed is a 1 m box; the per-instance basis scales it.
const _CYL_KITS := ["barrel", "dark_cyl", "log", "post", "candle", "clay_neck", "stone_cyl", "gold"]
const _SPHERE_KITS := ["clay_body"]
# Tiny / emissive kits are pulled out of the sun's shadow pass (they cast nothing readable).
const _NO_SHADOW := ["glow_warm", "glow_cool", "glow_fire", "candle", "gold", "dark_trim", "straw"]

# Kit -> [albedo, metallic, roughness, grime, material seed] for ProcMaterials.weathered.
# ALBEDO IS DELIBERATELY LIGHT: the world went through the D1 relight, and anything below
# ~0.35 value collapses under the cold grade's toe indoors (where there is no direct sun) —
# see ProcMaterials.FINE_DETAIL_ALPHA and the palette-lift note in procedural_buildings.gd.
const _KIT_MATS := {
	"crate": [Color(0.632, 0.487, 0.322), 0.0, 0.86, 0.52, 11],
	"wood": [Color(0.523, 0.386, 0.262), 0.0, 0.84, 0.5, 13],
	"board": [Color(0.679, 0.573, 0.428), 0.0, 0.82, 0.55, 17],
	"frame": [Color(0.472, 0.502, 0.541), 0.14, 0.58, 0.55, 19],
	"panel": [Color(0.601, 0.623, 0.641), 0.1, 0.62, 0.55, 23],
	"fabric": [Color(0.742, 0.723, 0.681), 0.0, 0.92, 0.6, 29],
	"stone": [Color(0.712, 0.692, 0.643), 0.0, 0.9, 0.5, 31],
	"cloth": [Color(0.667, 0.221, 0.191), 0.0, 0.78, 0.45, 37],
	"dark_trim": [Color(0.312, 0.325, 0.346), 0.16, 0.55, 0.5, 41],
	"straw": [Color(0.769, 0.664, 0.428), 0.0, 0.9, 0.55, 43],
	"sand_block": [Color(0.791, 0.627, 0.401), 0.0, 0.9, 0.45, 47],
	"barrel": [Color(0.432, 0.531, 0.508), 0.2, 0.6, 0.45, 53],
	"dark_cyl": [Color(0.352, 0.366, 0.383), 0.28, 0.52, 0.45, 59],
	"log": [Color(0.556, 0.418, 0.286), 0.0, 0.86, 0.5, 61],
	"post": [Color(0.596, 0.462, 0.322), 0.0, 0.84, 0.5, 67],
	"candle": [Color(0.881, 0.851, 0.762), 0.0, 0.72, 0.3, 71],
	"clay_neck": [Color(0.688, 0.428, 0.296), 0.0, 0.88, 0.5, 73],
	"clay_body": [Color(0.688, 0.428, 0.296), 0.0, 0.88, 0.5, 73],
	"stone_cyl": [Color(0.744, 0.612, 0.428), 0.0, 0.9, 0.48, 79],
	"gold": [Color(0.724, 0.581, 0.268), 0.35, 0.35, 0.3, 83],
}
# Kit -> [emission colour, energy] for ProcMaterials.emissive (candle flames, stove fire,
# monitor faces, work lamps). Deliberately few and small — these are accents, not lights.
const _KIT_GLOW := {
	"glow_warm": [Color(1.0, 0.82, 0.5), 2.2],
	"glow_cool": [Color(0.45, 0.85, 1.0), 1.6],
	"glow_fire": [Color(1.0, 0.48, 0.16), 2.6],
}

static var _mesh_cache: Dictionary = {}
static var _mat_cache: Dictionary = {}


# ================================================================ PUBLIC API
## Furnishes a w×d room `h` tall with `theme`'s set and returns the assembly (floor at local
## y=0, centred on the room's centre). `doors` = building-LOCAL XZ keep-out points (door
## centres / stair lanes / loot spots). `collide_large` gives the BULKY items a StaticBody3D
## (default OFF — render-only furniture cannot affect the navmesh bake). Returns an EMPTY
## node when the theme has nothing to place or the room is too small to keep a walkable lane.
static func furnish(
	theme: String,
	w: float,
	d: float,
	h: float,
	seed_val: int,
	doors: Array[Vector2] = [],
	collide_large: bool = false
) -> Node3D:
	var root := Node3D.new()
	root.name = "Interior"
	var pool: Array = _pool_for(theme)
	if pool.is_empty() or w < 2.0 or d < 2.0 or h < 1.4:
		return root
	# Band depth is PER AXIS: what is left of a half-width after the wall inset and half the
	# guaranteed central lane. Items on the ±Z walls eat depth out of d, items on the ±X walls
	# out of w — so a long shallow room (a courtyard wing) still gets deep pieces on its short
	# walls while its long walls take only slim ones. The walkable middle is a GUARANTEE.
	var bands := Vector2(
		clampf(w * 0.5 - WALL_INSET - CENTER_MIN_CLEAR * 0.5, 0.0, BAND_MAX),
		clampf(d * 0.5 - WALL_INSET - CENTER_MIN_CLEAR * 0.5, 0.0, BAND_MAX)
	)
	if maxf(bands.x, bands.y) < 0.45:
		return root
	var headless: bool = DisplayServer.get_name() == "headless"
	if headless and not collide_large:
		return root  # pure decoration: a dedicated server never builds it
	var kits: Dictionary = {}
	var solids: Array = []
	_run_walls(kits, solids, pool, theme, Vector3(w, h, d), bands, seed_val, doors)
	if not headless:
		_emit(root, kits)
	if collide_large:
		_emit_solids(root, solids)
	return root


## The item pool for `theme` (unknown themes get the generic storage set).
static func _pool_for(theme: String) -> Array:
	if _THEME_POOLS.has(theme):
		return _THEME_POOLS[theme]
	return _THEME_POOLS["default"]


# ================================================================ PLACEMENT
## Walks the 4 walls in order, placing items back-to-wall until the budget runs out. Every
## pick, gap and yaw jitter hashes off `sid` → identical on every peer. `kits` collects the
## per-kit instance transforms; `solids` collects [place transform, box size] for the bulky
## pieces (only consumed when the caller asked for collision).
static func _run_walls(
	kits: Dictionary,
	solids: Array,
	pool: Array,
	theme: String,
	dims: Vector3,
	bands: Vector2,
	sid: int,
	doors: Array[Vector2]
) -> void:
	var w: float = dims.x
	var h: float = dims.y
	var d: float = dims.z
	var live: Array = pool.duplicate()
	var hero: String = str(_HERO.get(theme, ""))
	var hero_pending: bool = _ITEMS.has(hero)
	var budget: int = clampi(int((w + d) * 2.0 * DENSITY_PER_M), 3, MAX_ITEMS)
	var placed: int = 0
	var k: int = 0
	for side in range(4):
		var along_x: bool = side < 2
		var run: float = w if along_x else d
		# This side's usable DEPTH is the band of the axis it eats into; its run stops a full
		# PERPENDICULAR band short of both corners, so an item here can never occupy the same
		# corner square as one on the wall it meets (sides are placed independently — there is
		# no global overlap test).
		var band: float = bands.y if along_x else bands.x
		var margin: float = WALL_INSET + (bands.x if along_x else bands.y) + CORNER_MARGIN
		var yaw: float = float(_SIDE_YAW[side])
		var cursor: float = -run * 0.5 + margin
		var stop: float = run * 0.5 - margin
		for _step in range(10):
			if placed >= budget or live.is_empty():
				break
			k += 1
			var s: int = sid * 131 + side * 37 + k * 7
			var id: String = ""
			if hero_pending:
				hero_pending = false  # one attempt only — a hero that cannot fit is dropped
				id = hero
			else:
				id = str(live[ProcHash.h(s) % live.size()])
			var spec: Array = _ITEMS[id]
			var fx: float = float(spec[0])
			var fz: float = float(spec[1])
			if fz > band or float(spec[2]) > h - CEILING_CLEAR:
				continue  # too deep for the band / too tall for the ceiling — re-pick
			if cursor + fx > stop:
				break
			var pos: Vector3 = _slot_pos(side, cursor + fx * 0.5, fz, w, d)
			if _near_door(pos, doors, DOOR_CLEAR + maxf(fx, fz) * 0.5):
				cursor += 0.9  # step past the doorway and try again further along the wall
				continue
			var jit: float = ProcHash.hrange(s + 3, -YAW_JITTER, YAW_JITTER)
			var xf := Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(yaw + jit), 0.0)), pos)
			_item(kits, id, xf, s)
			if bool(spec[4]):
				solids.append([xf, Vector3(fx, float(spec[3]), fz)])
			if id in _ONCE:
				while live.has(id):
					live.erase(id)
			cursor += fx + ProcHash.hrange(s + 5, GAP_MIN, GAP_MAX)
			placed += 1


## Room-local floor position of a slot: `mid` along the wall, the item's back face parked
## WALL_INSET in from the footprint edge.
static func _slot_pos(side: int, mid: float, fz: float, w: float, d: float) -> Vector3:
	var inset: float = WALL_INSET + fz * 0.5
	if side == 0:
		return Vector3(mid, 0.0, -d * 0.5 + inset)
	if side == 1:
		return Vector3(mid, 0.0, d * 0.5 - inset)
	if side == 2:
		return Vector3(-w * 0.5 + inset, 0.0, mid)
	return Vector3(w * 0.5 - inset, 0.0, mid)


## True when the slot centre is inside `r` of any caller-supplied keep-out point.
static func _near_door(pos: Vector3, doors: Array[Vector2], r: float) -> bool:
	for dp in doors:
		if Vector2(pos.x - dp.x, pos.z - dp.y).length_squared() < r * r:
			return true
	return false


# ================================================================ ITEM BUILDERS
# Each builder authors its pieces in ITEM-LOCAL space: origin on the floor at the footprint
# centre, +Z pointing INTO the room (the wall is behind, at -Z). `xf` carries the room-local
# position + facing, so a piece's final instance transform is xf * (local scale/rot/offset).


## Dispatch: append one item's pieces into the per-kit instance buckets.
static func _item(kits: Dictionary, id: String, xf: Transform3D, sid: int) -> void:
	match id:
		"shelf":
			_it_shelf(kits, xf, sid)
		"crate_stack":
			_it_crate_stack(kits, xf, sid)
		"pallet":
			_it_pallet(kits, xf, sid)
		"barrels":
			_it_barrels(kits, xf, sid)
		"workbench":
			_it_workbench(kits, xf, sid)
		"desk":
			_it_desk(kits, xf, sid)
		"chair":
			_it_chair(kits, xf, sid)
		"cabinet":
			_it_cabinet(kits, xf, sid)
		"partition":
			_it_partition(kits, xf, sid)
		"table":
			_it_table(kits, xf, sid)
		"bed":
			_it_bed(kits, xf, sid)
		"dresser":
			_it_dresser(kits, xf, sid)
		"altar":
			_it_altar(kits, xf, sid)
		"offer_stand":
			_it_offer_stand(kits, xf, sid)
		"low_table":
			_it_low_table(kits, xf, sid)
		"floor_mat":
			_it_floor_mat(kits, xf, sid)
		"bunk":
			_it_bunk(kits, xf, sid)
		"stove":
			_it_stove(kits, xf, sid)
		"woodpile":
			_it_woodpile(kits, xf, sid)
		"locker":
			_it_locker(kits, xf, sid)
		"bench":
			_it_bench(kits, xf, sid)
		"pot":
			_it_pot(kits, xf, sid)
		"debris":
			_it_debris(kits, xf, sid)
		"reed_mat":
			_it_reed_mat(kits, xf, sid)
		"column_drum":
			_it_column_drum(kits, xf, sid)


## Storage rack: 4 steel uprights + 3 plank decks + a couple of crates on the low deck.
static func _it_shelf(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	for i in range(4):
		var px: float = 0.94 if i % 2 == 0 else -0.94
		var pz: float = 0.24 if i < 2 else -0.24
		_put(kits, "frame", xf, Vector3(0.08, 2.0, 0.08), Vector3(px, 1.0, pz))
	var decks: Array[float] = [0.45, 1.1, 1.75]
	for j in range(decks.size()):
		_put(kits, "board", xf, Vector3(1.92, 0.055, 0.54), Vector3(0.0, decks[j], 0.0))
	_put(kits, "frame", xf, Vector3(1.92, 0.05, 0.04), Vector3(0.0, 1.96, -0.24))
	var lift: float = ProcHash.hrange(sid + 11, 0.0, 1.0)
	_put(
		kits,
		"crate",
		xf,
		Vector3(0.52, 0.42, 0.44),
		Vector3(-0.5, 0.69, 0.0),
		Vector3(0.0, lift * 12.0 - 6.0, 0.0)
	)
	_put(
		kits,
		"crate",
		xf,
		Vector3(0.42, 0.34, 0.4),
		Vector3(0.52, 1.3, 0.02),
		Vector3(0.0, 8.0 - lift * 16.0, 0.0)
	)


## Three stacked crates with hash-jittered yaw so a row of stacks never repeats.
static func _it_crate_stack(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	var a: float = ProcHash.hrange(sid + 3, -9.0, 9.0)
	var b: float = ProcHash.hrange(sid + 5, -11.0, 11.0)
	var c: float = ProcHash.hrange(sid + 7, -13.0, 13.0)
	_put(kits, "crate", xf, Vector3(0.82, 0.78, 0.78), Vector3(-0.2, 0.39, 0.0), Vector3(0, a, 0))
	_put(kits, "crate", xf, Vector3(0.66, 0.6, 0.62), Vector3(-0.16, 1.08, 0.04), Vector3(0, b, 0))
	_put(kits, "crate", xf, Vector3(0.6, 0.56, 0.58), Vector3(0.42, 0.28, 0.06), Vector3(0, c, 0))


## Loaded pallet: plank deck on three runners + a strapped cargo block.
static func _it_pallet(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "wood", xf, Vector3(1.2, 0.08, 1.0), Vector3(0.0, 0.14, 0.0))
	for i in range(3):
		var pz: float = (float(i) - 1.0) * 0.42
		_put(kits, "wood", xf, Vector3(1.2, 0.1, 0.12), Vector3(0.0, 0.05, pz))
	var yaw: float = ProcHash.hrange(sid + 9, -7.0, 7.0)
	_put(kits, "fabric", xf, Vector3(1.0, 0.62, 0.85), Vector3(0.0, 0.49, 0.0), Vector3(0, yaw, 0))
	_put(
		kits,
		"dark_trim",
		xf,
		Vector3(1.03, 0.05, 0.88),
		Vector3(0.0, 0.66, 0.0),
		Vector3(0, yaw, 0)
	)


## Three oil drums with rolled rims.
static func _it_barrels(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	for i in range(3):
		var px: float = (float(i) - 1.0) * 0.44
		var pz: float = ProcHash.hrange(sid + i * 5, -0.1, 0.1)
		var hh: float = 0.86 + ProcHash.hrange(sid + i * 7, -0.04, 0.04)
		_put_cyl(kits, "barrel", xf, 0.27, hh, Vector3(px, hh * 0.5, pz))
		_put_cyl(kits, "dark_cyl", xf, 0.285, 0.05, Vector3(px, hh - 0.14, pz))
		_put_cyl(kits, "dark_cyl", xf, 0.285, 0.05, Vector3(px, 0.16, pz))


## Workbench: plank top on steel legs, a low shelf, a pegboard with tools and a work lamp.
static func _it_workbench(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "board", xf, Vector3(2.0, 0.09, 0.8), Vector3(0.0, 0.92, 0.02))
	_put(kits, "frame", xf, Vector3(0.08, 0.88, 0.7), Vector3(-0.9, 0.44, 0.02))
	_put(kits, "frame", xf, Vector3(0.08, 0.88, 0.7), Vector3(0.9, 0.44, 0.02))
	_put(kits, "board", xf, Vector3(1.7, 0.05, 0.6), Vector3(0.0, 0.28, 0.02))
	_put(kits, "panel", xf, Vector3(1.9, 0.75, 0.05), Vector3(0.0, 1.35, -0.38))
	_put(kits, "dark_trim", xf, Vector3(0.26, 0.22, 0.3), Vector3(0.7, 1.07, 0.06))
	for i in range(3):
		var px: float = (float(i) - 1.0) * 0.42 - 0.2
		var hh: float = 0.2 + ProcHash.hrange(sid + i * 11, 0.0, 0.16)
		_put(kits, "dark_trim", xf, Vector3(0.06, hh, 0.04), Vector3(px, 1.45, -0.34))
	_put(kits, "dark_trim", xf, Vector3(0.24, 0.1, 0.18), Vector3(-0.72, 1.66, -0.28))
	_put(kits, "glow_warm", xf, Vector3(0.18, 0.04, 0.14), Vector3(-0.72, 1.6, -0.26))


## Office desk: laminate top, side panels, drawer block, monitor with a lit face.
static func _it_desk(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "board", xf, Vector3(1.6, 0.06, 0.8), Vector3(0.0, 0.73, 0.0))
	_put(kits, "panel", xf, Vector3(0.05, 0.7, 0.75), Vector3(-0.77, 0.35, 0.0))
	_put(kits, "panel", xf, Vector3(0.05, 0.7, 0.75), Vector3(0.77, 0.35, 0.0))
	_put(kits, "panel", xf, Vector3(1.5, 0.4, 0.04), Vector3(0.0, 0.48, -0.36))
	_put(kits, "panel", xf, Vector3(0.42, 0.55, 0.6), Vector3(0.5, 0.3, 0.0))
	for i in range(2):
		_put(
			kits,
			"dark_trim",
			xf,
			Vector3(0.2, 0.03, 0.03),
			Vector3(0.5, 0.24 + float(i) * 0.24, 0.31)
		)
	var tilt: float = -6.0
	_put(kits, "dark_trim", xf, Vector3(0.16, 0.12, 0.16), Vector3(-0.35, 0.79, -0.14))
	_put(
		kits,
		"dark_trim",
		xf,
		Vector3(0.52, 0.34, 0.04),
		Vector3(-0.35, 1.02, -0.17),
		Vector3(tilt, 0, 0)
	)
	_put(
		kits,
		"glow_cool",
		xf,
		Vector3(0.46, 0.28, 0.012),
		Vector3(-0.35, 1.02, -0.14),
		Vector3(tilt, 0, 0)
	)
	var yaw: float = ProcHash.hrange(sid + 13, -14.0, 14.0)
	_put(kits, "fabric", xf, Vector3(0.3, 0.02, 0.22), Vector3(0.3, 0.77, 0.1), Vector3(0, yaw, 0))


## Simple task chair: seat, back, four legs.
static func _it_chair(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "panel", xf, Vector3(0.44, 0.07, 0.44), Vector3(0.0, 0.44, 0.0))
	_put(kits, "panel", xf, Vector3(0.44, 0.45, 0.06), Vector3(0.0, 0.68, -0.19))
	for i in range(4):
		var px: float = 0.18 if i % 2 == 0 else -0.18
		var pz: float = 0.18 if i < 2 else -0.18
		_put(kits, "frame", xf, Vector3(0.05, 0.42, 0.05), Vector3(px, 0.21, pz))
	if ProcHash.h(sid + 17) % 3 == 0:
		_put(kits, "fabric", xf, Vector3(0.4, 0.06, 0.4), Vector3(0.0, 0.5, 0.0))


## Tall storage cabinet with a seam, handles and a capping lip.
static func _it_cabinet(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "panel", xf, Vector3(0.9, 1.8, 0.45), Vector3(0.0, 0.9, 0.0))
	_put(kits, "dark_trim", xf, Vector3(0.03, 1.7, 0.02), Vector3(0.0, 0.9, 0.23))
	_put(kits, "dark_trim", xf, Vector3(0.04, 0.16, 0.04), Vector3(-0.12, 1.0, 0.24))
	_put(kits, "dark_trim", xf, Vector3(0.04, 0.16, 0.04), Vector3(0.12, 1.0, 0.24))
	_put(kits, "dark_trim", xf, Vector3(0.94, 0.05, 0.49), Vector3(0.0, 1.82, 0.0))
	if ProcHash.h(sid + 19) % 2 == 0:
		_put(kits, "dark_trim", xf, Vector3(0.5, 0.03, 0.02), Vector3(0.0, 1.55, 0.23))


## Free-standing office partition on two feet.
static func _it_partition(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "fabric", xf, Vector3(1.75, 1.35, 0.06), Vector3(0.0, 0.78, 0.0))
	for i in range(2):
		var px: float = 0.87 if i == 0 else -0.87
		_put(kits, "frame", xf, Vector3(0.05, 1.5, 0.05), Vector3(px, 0.75, 0.0))
		_put(kits, "frame", xf, Vector3(0.1, 0.06, 0.4), Vector3(px, 0.03, 0.0))
	if ProcHash.h(sid + 23) % 2 == 0:
		_put(kits, "dark_trim", xf, Vector3(1.7, 0.04, 0.08), Vector3(0.0, 1.44, 0.0))


## Dining table: plank top on four legs, with a bowl.
static func _it_table(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "board", xf, Vector3(1.4, 0.07, 0.9), Vector3(0.0, 0.74, 0.0))
	for i in range(4):
		var px: float = 0.6 if i % 2 == 0 else -0.6
		var pz: float = 0.36 if i < 2 else -0.36
		_put(kits, "wood", xf, Vector3(0.08, 0.72, 0.08), Vector3(px, 0.36, pz))
	var off: float = ProcHash.hrange(sid + 29, -0.2, 0.2)
	_put_cyl(kits, "gold", xf, 0.14, 0.09, Vector3(off, 0.82, 0.0))


## Bed: timber frame with posts, mattress, blanket and pillow.
static func _it_bed(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "wood", xf, Vector3(2.0, 0.3, 1.0), Vector3(0.0, 0.2, 0.0))
	for i in range(4):
		var px: float = 0.96 if i % 2 == 0 else -0.96
		var pz: float = 0.46 if i < 2 else -0.46
		_put(kits, "wood", xf, Vector3(0.09, 0.5, 0.09), Vector3(px, 0.25, pz))
	_put(kits, "fabric", xf, Vector3(1.9, 0.2, 0.92), Vector3(0.0, 0.45, 0.0))
	var side: float = 1.0 if ProcHash.h(sid + 31) % 2 == 0 else -1.0
	_put(kits, "cloth", xf, Vector3(1.3, 0.08, 0.94), Vector3(0.3 * side, 0.58, 0.0))
	_put(kits, "fabric", xf, Vector3(0.5, 0.12, 0.36), Vector3(-0.65 * side, 0.61, 0.0))


## Chest of drawers with faces + handles.
static func _it_dresser(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "wood", xf, Vector3(1.05, 0.85, 0.5), Vector3(0.0, 0.43, 0.0))
	for i in range(3):
		var y: float = 0.2 + float(i) * 0.25
		_put(kits, "board", xf, Vector3(0.95, 0.22, 0.03), Vector3(0.0, y, 0.26))
		_put(kits, "dark_trim", xf, Vector3(0.2, 0.03, 0.03), Vector3(0.0, y, 0.29))
	_put(kits, "board", xf, Vector3(1.1, 0.05, 0.55), Vector3(0.0, 0.87, 0.0))
	if ProcHash.h(sid + 37) % 2 == 0:
		_put_cyl(kits, "candle", xf, 0.05, 0.24, Vector3(0.35, 1.02, 0.0))
		_put(kits, "glow_warm", xf, Vector3(0.07, 0.1, 0.07), Vector3(0.35, 1.19, 0.0))


## Temple altar: stone block, cloth-draped top, twin candles, an offering bowl and a banner.
static func _it_altar(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "stone", xf, Vector3(2.2, 0.85, 0.9), Vector3(0.0, 0.42, 0.0))
	_put(kits, "stone", xf, Vector3(2.3, 0.12, 1.0), Vector3(0.0, 0.91, 0.0))
	_put(kits, "cloth", xf, Vector3(2.0, 0.05, 0.86), Vector3(0.0, 0.99, 0.02))
	for i in range(2):
		var px: float = 0.7 if i == 0 else -0.7
		_put_cyl(kits, "candle", xf, 0.05, 0.3, Vector3(px, 1.16, 0.04))
		_put(kits, "glow_warm", xf, Vector3(0.07, 0.1, 0.07), Vector3(px, 1.36, 0.04))
	_put_cyl(kits, "gold", xf, 0.2, 0.12, Vector3(0.0, 1.07, 0.02))
	var sway: float = ProcHash.hrange(sid + 41, -3.0, 3.0)
	_put(kits, "cloth", xf, Vector3(1.0, 0.9, 0.05), Vector3(0.0, 1.42, -0.44), Vector3(0, sway, 0))
	_put(kits, "wood", xf, Vector3(1.2, 0.06, 0.06), Vector3(0.0, 1.9, -0.44))


## Offering stand: a turned post carrying a tray and a lit candle.
static func _it_offer_stand(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "wood", xf, Vector3(0.4, 0.1, 0.4), Vector3(0.0, 0.05, 0.0))
	_put_cyl(kits, "post", xf, 0.08, 0.85, Vector3(0.0, 0.47, 0.0))
	_put_cyl(kits, "post", xf, 0.26, 0.09, Vector3(0.0, 0.93, 0.0))
	_put_cyl(kits, "candle", xf, 0.045, 0.22, Vector3(0.0, 1.08, 0.0))
	_put(kits, "glow_warm", xf, Vector3(0.06, 0.09, 0.06), Vector3(0.0, 1.23, 0.0))
	if ProcHash.h(sid + 43) % 2 == 0:
		_put_cyl(kits, "gold", xf, 0.1, 0.06, Vector3(0.12, 1.0, 0.05))


## Low lacquer table with a bowl and a scroll.
static func _it_low_table(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "board", xf, Vector3(1.2, 0.07, 0.6), Vector3(0.0, 0.33, 0.0))
	_put(kits, "wood", xf, Vector3(0.07, 0.3, 0.5), Vector3(-0.5, 0.15, 0.0))
	_put(kits, "wood", xf, Vector3(0.07, 0.3, 0.5), Vector3(0.5, 0.15, 0.0))
	_put_cyl(kits, "gold", xf, 0.13, 0.09, Vector3(0.25, 0.41, 0.0))
	var yaw: float = ProcHash.hrange(sid + 47, -20.0, 20.0)
	_put(kits, "fabric", xf, Vector3(0.3, 0.06, 0.1), Vector3(-0.26, 0.4, 0.04), Vector3(0, yaw, 0))


## Straw floor mat with a bordered edge and a cushion.
static func _it_floor_mat(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "straw", xf, Vector3(1.45, 0.05, 0.95), Vector3(0.0, 0.025, 0.0))
	_put(kits, "cloth", xf, Vector3(1.5, 0.035, 0.1), Vector3(0.0, 0.03, 0.46))
	_put(kits, "cloth", xf, Vector3(1.5, 0.035, 0.1), Vector3(0.0, 0.03, -0.46))
	var px: float = ProcHash.hrange(sid + 53, -0.3, 0.3)
	_put(kits, "cloth", xf, Vector3(0.5, 0.12, 0.5), Vector3(px, 0.09, 0.0))


## Two-tier bunk: posts, decks, mattresses, blankets and a short ladder.
static func _it_bunk(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	for i in range(4):
		var px: float = 0.97 if i % 2 == 0 else -0.97
		var pz: float = 0.42 if i < 2 else -0.42
		_put(kits, "wood", xf, Vector3(0.09, 1.9, 0.09), Vector3(px, 0.95, pz))
	var decks: Array[float] = [0.45, 1.3]
	for j in range(decks.size()):
		var y: float = decks[j]
		_put(kits, "wood", xf, Vector3(1.94, 0.1, 0.85), Vector3(0.0, y, 0.0))
		_put(kits, "fabric", xf, Vector3(1.85, 0.16, 0.8), Vector3(0.0, y + 0.13, 0.0))
		var off: float = ProcHash.hrange(sid + 59 + j * 3, -0.35, 0.35)
		_put(kits, "cloth", xf, Vector3(1.1, 0.07, 0.82), Vector3(off, y + 0.23, 0.0))
	for r in range(2):
		_put(kits, "wood", xf, Vector3(0.05, 0.04, 0.4), Vector3(0.9, 0.75 + float(r) * 0.3, 0.44))


## Cast-iron stove: hearth pad, drum body, hot plate, flue and a glowing firebox door.
static func _it_stove(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "stone", xf, Vector3(0.95, 0.12, 0.9), Vector3(0.0, 0.06, 0.0))
	_put_cyl(kits, "dark_cyl", xf, 0.36, 0.95, Vector3(0.0, 0.6, -0.05))
	_put_cyl(kits, "dark_cyl", xf, 0.42, 0.08, Vector3(0.0, 1.11, -0.05))
	_put_cyl(kits, "dark_cyl", xf, 0.09, 0.8, Vector3(0.0, 1.5, -0.2))
	_put(kits, "dark_trim", xf, Vector3(0.3, 0.28, 0.06), Vector3(0.0, 0.55, 0.29))
	_put(kits, "glow_fire", xf, Vector3(0.24, 0.2, 0.02), Vector3(0.0, 0.55, 0.33))
	for i in range(2):
		var y: float = 0.1 + float(i) * 0.19
		var l: float = 0.42 + ProcHash.hrange(sid + 61 + i * 5, 0.0, 0.1)
		_put_cyl(kits, "log", xf, 0.09, l, Vector3(0.4, y, 0.14), Vector3(90.0, 0, 0))


## Stacked firewood between two end posts.
static func _it_woodpile(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "wood", xf, Vector3(0.08, 0.8, 0.08), Vector3(-0.8, 0.4, 0.0))
	_put(kits, "wood", xf, Vector3(0.08, 0.8, 0.08), Vector3(0.8, 0.4, 0.0))
	var rows: Array[int] = [4, 3, 2]
	for r in range(rows.size()):
		var n: int = rows[r]
		for c in range(n):
			var pz: float = (float(c) - float(n - 1) * 0.5) * 0.17
			var y: float = 0.13 + float(r) * 0.21
			var l: float = 1.4 + ProcHash.hrange(sid + r * 13 + c * 3, -0.12, 0.12)
			_put_cyl(kits, "log", xf, 0.1, l, Vector3(0.0, y, pz), Vector3(0, 0, 90.0))


## Metal locker with vent slots and a handle.
static func _it_locker(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "panel", xf, Vector3(0.8, 1.75, 0.45), Vector3(0.0, 0.88, 0.0))
	for i in range(3):
		_put(
			kits,
			"dark_trim",
			xf,
			Vector3(0.5, 0.03, 0.02),
			Vector3(0.0, 1.5 + float(i) * 0.06, 0.23)
		)
	_put(kits, "dark_trim", xf, Vector3(0.05, 0.2, 0.04), Vector3(0.3, 1.0, 0.24))
	if ProcHash.h(sid + 67) % 3 == 0:
		_put(kits, "crate", xf, Vector3(0.4, 0.3, 0.35), Vector3(0.0, 1.9, 0.0))


## Plank bench on two solid legs.
static func _it_bench(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "board", xf, Vector3(1.55, 0.09, 0.42), Vector3(0.0, 0.42, 0.0))
	_put(kits, "wood", xf, Vector3(0.1, 0.38, 0.36), Vector3(-0.6, 0.19, 0.0))
	_put(kits, "wood", xf, Vector3(0.1, 0.38, 0.36), Vector3(0.6, 0.19, 0.0))
	if ProcHash.h(sid + 71) % 2 == 0:
		_put(kits, "fabric", xf, Vector3(0.6, 0.07, 0.4), Vector3(0.35, 0.5, 0.0))


## Clay storage jars — a big bellied amphora plus a small companion.
static func _it_pot(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "clay_body", xf, Vector3(0.62, 0.66, 0.62), Vector3(-0.1, 0.33, 0.0))
	_put_cyl(kits, "clay_neck", xf, 0.15, 0.22, Vector3(-0.1, 0.68, 0.0))
	_put_cyl(kits, "clay_neck", xf, 0.19, 0.06, Vector3(-0.1, 0.79, 0.0))
	if ProcHash.h(sid + 73) % 4 != 0:
		_put(kits, "clay_body", xf, Vector3(0.36, 0.38, 0.36), Vector3(0.26, 0.19, 0.14))
		_put_cyl(kits, "clay_neck", xf, 0.09, 0.12, Vector3(0.26, 0.4, 0.14))
	else:
		_put(kits, "clay_body", xf, Vector3(0.34, 0.2, 0.34), Vector3(0.26, 0.1, 0.14))


## Collapsed masonry — three tilted sandstone blocks.
static func _it_debris(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	for i in range(3):
		var s: int = sid * 17 + i * 7
		var sx: float = ProcHash.hrange(s, 0.4, 0.7)
		var sy: float = ProcHash.hrange(s + 1, 0.22, 0.42)
		var sz: float = ProcHash.hrange(s + 2, 0.35, 0.6)
		var px: float = ProcHash.hrange(s + 3, -0.5, 0.5)
		var pz: float = ProcHash.hrange(s + 4, -0.3, 0.3)
		var tilt: float = ProcHash.hrange(s + 5, -12.0, 12.0)
		_put(
			kits,
			"sand_block",
			xf,
			Vector3(sx, sy, sz),
			Vector3(px, sy * 0.5, pz),
			Vector3(tilt * 0.4, ProcHash.hrange(s + 6, 0.0, 90.0), tilt)
		)


## Reed mat with batten edges and a basket.
static func _it_reed_mat(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put(kits, "straw", xf, Vector3(1.5, 0.04, 1.0), Vector3(0.0, 0.02, 0.0))
	_put(kits, "wood", xf, Vector3(1.5, 0.03, 0.08), Vector3(0.0, 0.035, 0.48))
	_put(kits, "wood", xf, Vector3(1.5, 0.03, 0.08), Vector3(0.0, 0.035, -0.48))
	var px: float = ProcHash.hrange(sid + 79, -0.5, 0.5)
	_put_cyl(kits, "clay_neck", xf, 0.18, 0.24, Vector3(px, 0.14, 0.18))


## A toppled column drum with a chipped second drum and a fallen block.
static func _it_column_drum(kits: Dictionary, xf: Transform3D, sid: int) -> void:
	_put_cyl(kits, "stone_cyl", xf, 0.42, 0.5, Vector3(0.0, 0.25, 0.0))
	var tilt: float = ProcHash.hrange(sid + 83, -8.0, 8.0)
	_put_cyl(kits, "stone_cyl", xf, 0.34, 0.18, Vector3(0.08, 0.6, -0.05), Vector3(0, 0, tilt))
	_put(
		kits,
		"sand_block",
		xf,
		Vector3(0.5, 0.22, 0.35),
		Vector3(-0.3, 0.11, 0.3),
		Vector3(0, ProcHash.hrange(sid + 89, 0.0, 90.0), 6.0)
	)


# ================================================================ EMIT
## Appends one BOX piece: `size` is the real metre size (baked into the unit mesh's basis),
## `lpos`/`lrot_deg` are item-local. Final transform = xf * (rot * scale, lpos).
static func _put(
	kits: Dictionary,
	kit: String,
	xf: Transform3D,
	size: Vector3,
	lpos: Vector3,
	lrot_deg: Vector3 = Vector3.ZERO
) -> void:
	var b: Basis = Basis.from_scale(size)
	if lrot_deg != Vector3.ZERO:
		var e := Vector3(deg_to_rad(lrot_deg.x), deg_to_rad(lrot_deg.y), deg_to_rad(lrot_deg.z))
		b = Basis.from_euler(e) * b
	_add(kits, kit, xf * Transform3D(b, lpos))


## Appends one CYLINDER piece (unit cylinder is r=0.5, h=1 → scale by diameter/height).
static func _put_cyl(
	kits: Dictionary,
	kit: String,
	xf: Transform3D,
	r: float,
	hgt: float,
	lpos: Vector3,
	lrot_deg: Vector3 = Vector3.ZERO
) -> void:
	_put(kits, kit, xf, Vector3(r * 2.0, hgt, r * 2.0), lpos, lrot_deg)


static func _add(kits: Dictionary, kit: String, t: Transform3D) -> void:
	if not kits.has(kit):
		kits[kit] = []
	(kits[kit] as Array).append(t)


## ONE MultiMeshInstance3D per kit (insertion order = placement order → identical on every
## peer). Tiny/emissive kits skip the shadow pass.
static func _emit(root: Node3D, kits: Dictionary) -> void:
	for kit_name in kits.keys():
		var kit: String = str(kit_name)
		var arr: Array = kits[kit_name]
		if arr.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = false
		mm.mesh = _kit_mesh(kit)
		mm.instance_count = arr.size()
		for j in range(arr.size()):
			var t: Transform3D = arr[j]
			mm.set_instance_transform(j, t)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Kit_%s" % kit
		mmi.multimesh = mm
		mmi.material_override = _kit_material(kit)
		if kit in _NO_SHADOW:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)


## One StaticBody3D + BoxShape3D per BULKY item (layer 1, mask 0 — same contract as
## ProceduralBuildings._solid) so the navmesh bake routes around it and it stops bullets.
static func _emit_solids(root: Node3D, solids: Array) -> void:
	for i in range(solids.size()):
		var rec: Array = solids[i]
		var xf: Transform3D = rec[0]
		var size: Vector3 = rec[1]
		if size.y <= 0.05:
			continue
		var body := StaticBody3D.new()
		body.name = "Solid_%d" % i
		body.collision_layer = 1
		body.collision_mask = 0
		body.transform = Transform3D(
			xf.basis.orthonormalized(), xf.origin + Vector3(0.0, size.y * 0.5, 0.0)
		)
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		col.shape = shape
		body.add_child(col)
		root.add_child(body)


# ================================================================ MESHES + MATERIALS
## The 3 shared unit meshes (box / cylinder / sphere), built once per process.
static func _kit_mesh(kit: String) -> Mesh:
	var kind: String = "box"
	if kit in _CYL_KITS:
		kind = "cyl"
	elif kit in _SPHERE_KITS:
		kind = "sphere"
	if _mesh_cache.has(kind):
		return _mesh_cache[kind]
	var m: Mesh = ProceduralModels._box(Vector3.ONE)
	if kind == "cyl":
		m = ProceduralModels._cyl(0.5, 1.0, 10)
	elif kind == "sphere":
		m = ProceduralModels._sphere(0.5, false, 6, 10)
	_mesh_cache[kind] = m
	return m


## ONE material per kit for the whole process (the MultiMesh batch shares it; world-triplanar
## grime keeps neighbouring pieces from repeating even though the material is shared).
static func _kit_material(kit: String) -> StandardMaterial3D:
	if _mat_cache.has(kit):
		return _mat_cache[kit]
	var m: StandardMaterial3D = _build_material(kit)
	_mat_cache[kit] = m
	return m


## Builds a kit material from the palette tables. StandardMaterial3D only (never
## ShaderMaterial — the hit-flash contract), everything through ProcMaterials.
static func _build_material(kit: String) -> StandardMaterial3D:
	if _KIT_GLOW.has(kit):
		var glow: Array = _KIT_GLOW[kit]
		var gcol: Color = glow[0]
		return ProcMaterials.emissive(gcol, float(glow[1]))
	var spec: Array = _KIT_MATS[kit] if _KIT_MATS.has(kit) else _KIT_MATS["board"]
	var col: Color = spec[0]
	return ProcMaterials.weathered(
		col,
		float(spec[1]),
		float(spec[2]),
		float(spec[3]),
		int(spec[4]),
		Vector3(0.45, 0.45, 0.45),
		true,
		0.55
	)


## Drops the cached materials/meshes (mirrors ProcMaterials.clear_cache; not needed in normal
## play — kept so a tooling pass that rebuilds the palette can force a refresh).
static func clear_cache() -> void:
	_mat_cache.clear()
	_mesh_cache.clear()
