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
## int via the shared ProcHash.h/hf arithmetic hash (scripts/core/proc_hash.gd).
##
## CRITICAL parse trap (warnings-as-errors): never `var x := <Variant>` from
## Dictionary.get()/untyped ternary — every local below is explicitly typed.

# ---------------------------------------------------------------- materials
## Weathered urban palette. All StandardMaterial3D (required), now procedurally
## WORN via the shared ProcMaterials toolkit (triplanar grime/streak noise) instead
## of flat solid albedo. Each helper takes an optional per-piece `sid` so adjacent
## walls/slabs don't share the exact same grime pattern; callers thread the seeds
## they already have. `world`-triplanar keeps detail continuous across a building.
##
## `streaked()` (vertical rain-stain weathering) is used for TALL wall surfaces so
## stains run down; `weathered()` (broad grime mask) for slabs/roofs/horizontals.

## Light worn concrete — broad grime, fully matte. Used for general walls/piers.
## Fine normal map + boosted relief (last arg) for crisp, detailed up-close concrete.
static func mat_concrete(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.streaked(Color(0.40, 0.40, 0.42), 0.0, 0.92, 0.5,
		sid * 7 + 3, 0.7, true)

## Darker concrete for slabs/floors/roofs — horizontal grime (not streaked) + relief.
static func mat_concrete_dark(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.27, 0.28, 0.30), 0.0, 0.94, 0.45,
		sid * 13 + 5, Vector3(0.13, 0.13, 0.13), true, 0.7, true)

## Stained warehouse concrete — heavier dirt streaks + relief.
static func mat_concrete_stained(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.streaked(Color(0.33, 0.32, 0.30), 0.05, 0.9, 0.38,
		sid * 17 + 9, 0.7, true)

## Mottled rust — broad noise so the corrosion patches read as blotchy, not striped.
## Moderate metallic + mid roughness so SDFGI reflections still catch. Strong normal
## relief for pitted, corroded depth (heightmap POM is unavailable on triplanar).
static func mat_rust(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.46, 0.26, 0.16), 0.3, 0.6, 0.4,
		sid * 23 + 1, Vector3(0.12, 0.12, 0.12), true, 0.8, true)

## Dirtier structural metal — kept semi-reflective (metallic ~0.45, roughness ~0.55)
## so it reads as worn steel and SDFGI bounces off it.
static func mat_metal(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.34, 0.37, 0.41), 0.45, 0.55, 0.5,
		sid * 29 + 4, Vector3(0.12, 0.12, 0.12), true)

## Dark grimy metal for ribs/door-ends/trim.
static func mat_metal_dark(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.18, 0.19, 0.21), 0.4, 0.55, 0.5,
		sid * 31 + 2, Vector3(0.10, 0.10, 0.10), true)

static func mat_glass() -> StandardMaterial3D:
	# Cool reflective window glass that READS as a window in daylight from outside:
	# lighter cool albedo + low roughness/moderate metallic for sky reflection, plus a
	# faint cold emission so panes still glow at dusk. Kept flat (no grime) via _mat.
	return ProceduralModels._mat(Color(0.35, 0.45, 0.55), 0.4, 0.1,
		Color(0.12, 0.18, 0.24), 0.6)

static func mat_container(sid: int) -> StandardMaterial3D:
	# Pick a faded shipping-container color deterministically from seed, then weather
	# it with vertical streaks (rust running down the corrugated panels).
	var palette: Array[Color] = [
		Color(0.42, 0.20, 0.14),  # rust red
		Color(0.20, 0.34, 0.27),  # faded green
		Color(0.18, 0.28, 0.40),  # navy
		Color(0.46, 0.40, 0.20),  # ochre
		Color(0.36, 0.37, 0.40),  # gray
	]
	var idx: int = ProcHash.h(sid) % palette.size()
	var c: Color = palette[idx]
	# Corrugated baked normal/albedo ribs (vertical, ~8 cm pitch) with rust streaks.
	return ProcMaterials.corrugated(c, sid * 37 + 6)

# --- Themed materials for the 3 new climate-zone landmarks (temple / lodge / ruins).
## Red lacquered timber — temple columns/beams/torii. Vivid + low grime/roughness so the red
## reads through the bright daylight (the weathered grime overlay otherwise greys it out).
static func mat_lacquer(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.70, 0.10, 0.08), 0.05, 0.45, 0.24,
		sid * 23 + 3, Vector3(0.06, 0.06, 0.06), true, 0.6, true)

## Dark temple/lodge roof timber — broad grime, matte.
static func mat_roofwood(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.15, 0.11, 0.09), 0.0, 0.82, 0.45,
		sid * 31 + 2, Vector3(0.10, 0.10, 0.10), true, 0.7, true)

## Off-white temple/lodge plaster wall — light grime.
static func mat_plaster(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.84, 0.81, 0.74), 0.0, 0.9, 0.38,
		sid * 41 + 9, Vector3(0.07, 0.07, 0.07), true, 0.6, true)

## Warm timber logs — alpine lodge walls. Vertical streaks read as plank/log grain.
static func mat_timber(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.streaked(Color(0.34, 0.22, 0.13), 0.0, 0.85, 0.5,
		sid * 29 + 5, 0.7, true)

## Bright snow — roof caps / lodge accents. Slightly glossy so it catches light.
static func mat_snow(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.90, 0.93, 0.98), 0.0, 0.62, 0.25,
		sid * 37 + 1, Vector3(0.05, 0.05, 0.05), true, 0.5, false)

## Warm sandstone — desert ruins walls/columns/obelisk. Saturated tan with lighter grime so
## it reads sandy (not blown-out white) under the strong sun.
static func mat_sandstone(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.74, 0.55, 0.31), 0.0, 0.9, 0.4,
		sid * 19 + 7, Vector3(0.11, 0.11, 0.11), true, 0.75, true)

## Darker weathered sandstone for caps / shadowed blocks.
static func mat_sandstone_dark(sid: int = 0) -> StandardMaterial3D:
	return ProcMaterials.weathered(Color(0.56, 0.41, 0.23), 0.0, 0.92, 0.42,
		sid * 17 + 4, Vector3(0.12, 0.12, 0.12), true, 0.75, true)

# Seed hashing: ProcHash.h/hf (scripts/core/proc_hash.gd) — ONE copy shared with
# terrain/flora so every procedural system stays determinism-synchronized.

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

## A vertical collidable CYLINDER (round column / obelisk shaft) — both renders and collides
## (StaticBody3D + CylinderShape3D on layer 1) so the navmesh routes around it. Base at the
## given `offset` centre (offset.y is the cylinder CENTRE, like _solid). `seg` controls how
## round it looks (4 = a square pillar/obelisk, 12 = a smooth column).
static func _solid_cyl(parent: Node3D, radius: float, height: float, mat: StandardMaterial3D,
		offset: Vector3, seg: int = 12, rot_y_deg: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.transform = Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(rot_y_deg), 0.0)), offset)
	var mi := MeshInstance3D.new()
	mi.mesh = ProceduralModels._cyl(radius, height, seg)
	mi.material_override = mat
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	col.shape = shape
	body.add_child(col)
	parent.add_child(body)
	return body

## A warm interior ceiling lamp at `pos`: a render-only fixture (dark housing disc +
## an emissive warm-glowing disc) PLUS a real OmniLight3D so robots indoors are clearly
## lit/readable. No collision (pure render + light node). `sid` only varies the housing
## grime seed; placement is fully deterministic from the caller.
static func _light_fixture(parent: Node3D, pos: Vector3, sid: int) -> void:
	# Dark housing (thin flat cylinder) hanging at the ceiling.
	var housing := mat_metal_dark(sid * 3 + 1)
	ProceduralModels._part(parent, ProceduralModels._cyl(0.32, 0.12), housing, pos)
	# Emissive warm disc just below the housing (the visible "bulb").
	var glow := ProcMaterials.emissive(Color(1.0, 0.85, 0.55), 2.6)
	ProceduralModels._part(parent, ProceduralModels._cyl(0.24, 0.06), glow,
		pos + Vector3(0.0, -0.08, 0.0))
	# The actual light source.
	var light := OmniLight3D.new()
	light.position = pos + Vector3(0.0, -0.1, 0.0)
	light.shadow_enabled = false
	light.light_color = Color(1.0, 0.86, 0.6)
	light.light_energy = Settings.INTERIOR_LIGHT_ENERGY
	light.omni_range = Settings.INTERIOR_LIGHT_RANGE
	parent.add_child(light)

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
		# Small emissive door lamp beside the door (render-only, no OmniLight) so the
		# entrance reads at night/storm. Sits just outside the wall face, +X side.
		var lamp_mat := ProcMaterials.emissive(Color(1.0, 0.82, 0.5), 2.4)
		_decor(root, Vector3(0.18, 0.3, 0.12), lamp_mat,
			Vector3(dw * 0.5 + 0.35, dh * 0.85, thickness * 0.5 + 0.06))
	elif with_window:
		# Window band: low sill, a TALL opening, slim header. Lowered sill + raised max
		# opening height so windows read clearly from outside and let far more sky/sun
		# light in (every opening is a genuine hole → more SDFGI/sun bounce indoors).
		var sill_h: float = min(0.9, height * 0.3)
		var win_h: float = min(1.4, max(0.4, height - sill_h - 0.5))
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
		# Protruding sill ledge under the window (cheap silhouette detail; render-only).
		var ledge := mat_concrete_dark(int(length * 17.0))
		_decor(root, Vector3(ww + 0.4, 0.12, thickness + 0.18), ledge,
			Vector3(0.0, sill_h - 0.02, 0.0))
		# A thin lintel lip above the opening so the header casts a shadow line.
		_decor(root, Vector3(ww + 0.3, 0.1, thickness + 0.12), ledge,
			Vector3(0.0, head_y + 0.04, 0.0))
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
	# Darker coping cap along the parapet top (cheap render-only silhouette trim).
	var cap := mat_metal_dark(int(w * 53.0 + d))
	_decor(root, Vector3(w + 0.1, 0.08, 0.34), cap, Vector3(0.0, ph + 0.02, d * 0.5 - 0.12))
	_decor(root, Vector3(w + 0.1, 0.08, 0.34), cap, Vector3(0.0, ph + 0.02, -d * 0.5 + 0.12))
	_decor(root, Vector3(0.34, 0.08, d + 0.1), cap, Vector3(w * 0.5 - 0.12, ph + 0.02, 0.0))
	_decor(root, Vector3(0.34, 0.08, d + 0.1), cap, Vector3(-w * 0.5 + 0.12, ph + 0.02, 0.0))
	# A vent/pipe stub on the roof for rooftop interest (render-only).
	var vent := mat_metal(int(w * 71.0))
	_decor(root, Vector3(0.5, 0.9, 0.5), vent, Vector3(w * 0.25, 0.45, -d * 0.2))
	_decor(root, Vector3(0.3, 0.6, 0.3), vent, Vector3(-w * 0.28, 0.3, d * 0.22))
	return root

## A square pillar of height h, radius r (box-section), base at local y=0.
static func pillar(h: float, r: float, mat: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	_solid(root, Vector3(r * 2.0, h, r * 2.0), mat, Vector3(0.0, h * 0.5, 0.0))
	return root

## A pile of a few tilted broken blocks (collidable cover), deterministic by seed.
static func rubble_pile(sid: int) -> Node3D:
	var root := Node3D.new()
	var m_a := mat_concrete(sid * 3 + 1)
	var m_b := mat_concrete_dark(sid * 3 + 2)
	var m_c := mat_rust(sid * 3 + 3)
	var count: int = 3 + (ProcHash.h(sid) % 3)  # 3..5 chunks
	for i in range(count):
		var s: int = sid * 31 + i * 7
		var sx: float = 0.5 + ProcHash.hf(s) * 1.1
		var sy: float = 0.3 + ProcHash.hf(s + 1) * 0.7
		var sz: float = 0.5 + ProcHash.hf(s + 2) * 1.1
		var px: float = (ProcHash.hf(s + 3) - 0.5) * 2.2
		var pz: float = (ProcHash.hf(s + 4) - 0.5) * 2.2
		var roty: float = ProcHash.hf(s + 5) * 90.0
		var mm: StandardMaterial3D = m_a
		var pick: int = ProcHash.h(s + 6) % 3
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
	var ribs := mat_metal_dark(int(w * 41.0 + d))
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
	var conc_d := mat_concrete_dark(int(w + d))
	var th: float = 0.35
	var storeys: int = 3 + (ProcHash.h(1) % 2)  # 3..4
	var sh: float = 3.0                  # storey height
	# Ground slab.
	_place(root, floor_slab(w, d, conc_d), Vector3(0, 0.0, 0))
	for s in range(storeys):
		var y: float = s * sh
		# Every storey (incl. the ground floor) gets windows now → daylight reaches the
		# interior and the ground floor no longer reads as a dark box.
		var win := true
		# Per-storey concrete so the grime streaks differ band-to-band.
		var conc := mat_concrete(s * 5 + 1)
		# Four perimeter walls per storey (front has a door on storey 0).
		_place_wall(root, w, sh, th, conc, Vector3(0, y, -d * 0.5 + th * 0.5), 0.0,
			win, s == 0)
		_place_wall(root, w, sh, th, conc, Vector3(0, y, d * 0.5 - th * 0.5), 0.0, win, false)
		_place_wall(root, d, sh, th, conc, Vector3(-w * 0.5 + th * 0.5, y, 0), 90.0, win, false)
		_place_wall(root, d, sh, th, conc, Vector3(w * 0.5 - th * 0.5, y, 0), 90.0, win, false)
		# Warm ceiling lamp per storey, centered just under this storey's ceiling slab.
		_light_fixture(root, Vector3(0.0, y + sh - 0.35, 0.0), 100 + s)
		# Floor slab above each storey (the next storey's floor / final roof handled after).
		if s < storeys - 1:
			_place(root, floor_slab(w - 0.4, d - 0.4, conc_d), Vector3(0, (s + 1) * sh, 0))
	var top: float = storeys * sh
	# Roof + small rooftop utility housing.
	_place(root, roof(w, d, conc_d), Vector3(0, top, 0))
	_place(root, container(w * 0.35, 2.0, d * 0.35, mat_metal(2)), Vector3(w * 0.18, top, -d * 0.15))
	# A couple of corner pilasters for silhouette.
	_place(root, pillar(top, 0.4, conc_d), Vector3(-w * 0.5 + 0.4, 0, -d * 0.5 + 0.4))
	_place(root, pillar(top, 0.4, conc_d), Vector3(w * 0.5 - 0.4, 0, d * 0.5 - 0.4))
	# A vertical drainpipe strip down one facade corner (render-only silhouette).
	var pipe := mat_metal_dark(3)
	_decor(root, Vector3(0.22, top - 0.4, 0.22), pipe,
		Vector3(w * 0.5 - 0.5, top * 0.5, -d * 0.5 + 0.25))
	return root

## WAREHOUSE: a big single-storey shed with tall walls, roller-door front, clerestory
## windows, a partial roof. With courtyard=true it is open-centered (3 walls + flanking
## roof wings) leaving the middle clear for an extraction zone.
static func build_warehouse(footprint: Vector2, courtyard: bool = true) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	var conc := mat_concrete_stained(int(w + d * 3.0))
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
			var wing_cz: float = -COURT_CLEAR - (d * 0.5 - COURT_CLEAR) * 0.5 + 0.25
			_place(root, roof(w, d * 0.5 - COURT_CLEAR + 0.5, mat_metal_dark(int(w))),
				Vector3(0, h, wing_cz))
			# Two hanging warm lamps under the roof wing (thin rod + fixture) so the
			# covered back of the shed is readable. Rod drops ~0.6 m from the roof.
			var rod := mat_metal_dark(int(w) + 71)
			var lz: Array[float] = [wing_cz - 2.0, wing_cz + 2.0]
			for i in range(lz.size()):
				var lx: float = (float(i) - 0.5) * w * 0.3
				_decor(root, Vector3(0.08, 0.6, 0.08), rod, Vector3(lx, h - 0.5, lz[i]))
				_light_fixture(root, Vector3(lx, h - 0.85, lz[i]), 300 + i)
		# Stacked containers along the back as cover (clear of center).
		_place(root, container(3.0, 2.6, 6.0, mat_container(7)),
			Vector3(-w * 0.5 + 2.0, 0, -d * 0.5 + 4.0))
		_place(root, container(3.0, 2.6, 6.0, mat_container(11)),
			Vector3(w * 0.5 - 2.0, 0, -d * 0.5 + 4.0))
	else:
		_place_wall(root, d, h, th, conc, Vector3(-w * 0.5 + th * 0.5, 0, 0), 90.0, true, false)
		_place_wall(root, d, h, th, conc, Vector3(w * 0.5 - th * 0.5, 0, 0), 90.0, true, false)
		_place_wall(root, w, h, th, conc, Vector3(0, 0, d * 0.5 - th * 0.5), 0.0, false, true)
		_place(root, roof(w, d, mat_metal_dark(int(w + d))), Vector3(0, h, 0))
		_place(root, container(3.0, 2.6, 6.0, mat_container(7)), Vector3(-w * 0.5 + 2.5, 0, 0))
	return root

## HOUSE: a 2-storey dwelling with a pitched-look (stepped) roof, door, windows. With
## courtyard=true the ground floor is an open 3-sided shell around the center, with an
## upper floor wing only on the closed side so the extraction zone stays clear & open.
static func build_house(footprint: Vector2, courtyard: bool = true) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	# Weathered brick — vertical streaks (rain stains down the brickwork).
	var brick := ProcMaterials.streaked(Color(0.40, 0.30, 0.26), 0.0, 0.85, 0.45,
		int(w * 19.0 + d))
	var conc_d := mat_concrete_dark(int(w + d * 2.0))
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
			# Lamp under the upper-wing ceiling (lights the closed back room).
			_light_fixture(root, Vector3(0.0, sh * 2.0 - 0.35, wing_cz), 220)
		# Ground-floor lamp toward the closed (back) side so the open shell is lit.
		_light_fixture(root, Vector3(0.0, sh - 0.35, -COURT_CLEAR * 0.6), 221)
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
		# One warm lamp per floor (ground + upper).
		_light_fixture(root, Vector3(0.0, sh - 0.35, 0.0), 222)
		_light_fixture(root, Vector3(0.0, sh * 2.0 - 0.35, 0.0), 223)
	return root

## PLAZA cover: a low open-air structure for the central plaza — a cluster of waist/
## chest-high cover blocks + a few tall pillars supporting a partial canopy. Center
## stays open & walkable (plaza is an enemy-spawn crossroads, no extraction zone).
static func build_plaza_cover() -> Node3D:
	var root := Node3D.new()
	var conc := mat_concrete(91)
	var conc_d := mat_concrete_dark(92)
	# Four chest-high cover blocks at the quadrants.
	var quad: Array[Vector2] = [Vector2(-7, -7), Vector2(7, -7), Vector2(7, 7), Vector2(-7, 7)]
	for i in range(quad.size()):
		var q: Vector2 = quad[i]
		_solid(root, Vector3(2.4, 1.2, 2.4), conc, Vector3(q.x, 0.6, q.y), float(ProcHash.h(i) % 30))
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
			var jitter: float = (ProcHash.hf(sd * 13 + lv) - 0.5) * 0.4
			_place(root, container(sx, ch, sz, mat_container(sd + lv)),
				Vector3(cx + jitter, lv * ch, cz))
	# A couple of rubble piles in open corners for ground detail (clear of center).
	_place(root, rubble_pile(sd_seed(1)), Vector3(-ed_x * 0.4, 0, ed_z * 0.6))
	# A pole lamp lighting the container area (3 m pole + fixture), placed just OUTSIDE
	# the keep-clear square so the evac zone stays open. Render-only pole + OmniLight.
	var pole_x: float = COURT_CLEAR + 1.5
	var pole_z: float = COURT_CLEAR + 1.5
	var pole_mat := mat_metal_dark(int(w + d) + 41)
	_decor(root, Vector3(0.16, 3.0, 0.16), pole_mat, Vector3(pole_x, 1.5, pole_z))
	_light_fixture(root, Vector3(pole_x, 3.0, pole_z), 400)
	return root

# ================================================================ CLIMATE-ZONE LANDMARKS
# Three themed landmarks for the new quadrants (paired with the localized climate zones in
# Phase 3): RAIN→Japanese Temple, SNOW→Alpine Lodge, DESERT→Sandstone Ruins. All deterministic
# from the footprint; collidable cores so the navmesh routes around them.

## JAPANESE TEMPLE (rain zone): a tiered pagoda on a stone podium + a red torii gate + two
## stone lanterns. Plaster cores (collidable) with red lacquer corner posts and wide dark
## overhanging eave roofs; a 4-sided pyramid + gold finial on top.
static func build_temple(footprint: Vector2) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	var sid: int = int(w * 23.0 + d * 7.0)
	var lacquer := mat_lacquer(sid)
	var roofw := mat_roofwood(sid)
	var plaster := mat_plaster(sid)
	var stone := mat_concrete(sid + 11)
	# Stone podium + front steps (toward +Z).
	var pod_w: float = w * 0.78
	var pod_d: float = d * 0.78
	_solid(root, Vector3(pod_w, 0.7, pod_d), stone, Vector3(0, 0.35, 0))
	_solid(root, Vector3(pod_w * 0.5, 0.5, 0.8), stone, Vector3(0, 0.25, pod_d * 0.5 + 0.2))
	_solid(root, Vector3(pod_w * 0.6, 0.25, 1.0), stone, Vector3(0, 0.12, pod_d * 0.5 + 0.9))
	# Pagoda: 3 shrinking tiers.
	var tiers: int = 3
	var base_tw: float = w * 0.46
	var base_td: float = d * 0.46
	var sh: float = 2.6
	var y: float = 0.7
	for t in range(tiers):
		var shrink: float = 1.0 - 0.18 * float(t)
		var tw: float = base_tw * shrink
		var td: float = base_td * shrink
		var cy: float = y + sh * 0.5
		# Plaster tier core.
		_solid(root, Vector3(tw, sh, td), plaster, Vector3(0, cy, 0))
		# Four red lacquer corner posts.
		var px: float = tw * 0.5 - 0.18
		var pz: float = td * 0.5 - 0.18
		_solid(root, Vector3(0.3, sh, 0.3), lacquer, Vector3(-px, cy, -pz))
		_solid(root, Vector3(0.3, sh, 0.3), lacquer, Vector3(px, cy, -pz))
		_solid(root, Vector3(0.3, sh, 0.3), lacquer, Vector3(-px, cy, pz))
		_solid(root, Vector3(0.3, sh, 0.3), lacquer, Vector3(px, cy, pz))
		# Wide overhanging eave roof (dark slab) + a red underside band.
		var eave_w: float = tw + 1.8
		var eave_d: float = td + 1.8
		_decor(root, Vector3(eave_w, 0.28, eave_d), roofw, Vector3(0, y + sh + 0.14, 0))
		_decor(root, Vector3(eave_w * 0.96, 0.12, eave_d * 0.96), lacquer, Vector3(0, y + sh - 0.04, 0))
		# Upturned eave corner accents (a slight pagoda lilt).
		var ex: float = eave_w * 0.5
		var ez: float = eave_d * 0.5
		var ay: float = y + sh + 0.34
		_decor(root, Vector3(0.6, 0.18, 0.6), roofw, Vector3(-ex, ay, -ez), Vector3(-16.0, 0, 16.0))
		_decor(root, Vector3(0.6, 0.18, 0.6), roofw, Vector3(ex, ay, -ez), Vector3(-16.0, 0, -16.0))
		_decor(root, Vector3(0.6, 0.18, 0.6), roofw, Vector3(-ex, ay, ez), Vector3(16.0, 0, 16.0))
		_decor(root, Vector3(0.6, 0.18, 0.6), roofw, Vector3(ex, ay, ez), Vector3(16.0, 0, -16.0))
		y += sh + 0.4
	# Top 4-sided pyramid roof + gold finial spire.
	var cap_r: float = base_td * 0.5 * pow(0.82, float(tiers)) + 0.9
	ProceduralModels._part(root, ProceduralModels._cone(cap_r, 1.6, 4), roofw,
		Vector3(0, y + 0.8, 0), Vector3(0, 45.0, 0))
	var gold := ProcMaterials.emissive(Color(0.95, 0.8, 0.35), 0.6, Color(0.5, 0.42, 0.18))
	_decor(root, Vector3(0.14, 1.6, 0.14), gold, Vector3(0, y + 2.4, 0))
	ProceduralModels._part(root, ProceduralModels._sphere(0.28), gold, Vector3(0, y + 3.2, 0))
	# Torii gate in front (+Z) + two flanking stone lanterns.
	_build_torii(root, lacquer, roofw, w * 0.34, Vector3(0, 0, pod_d * 0.5 + 3.4))
	_build_lantern(root, stone, Vector3(-pod_w * 0.34, 0, pod_d * 0.5 + 1.6))
	_build_lantern(root, stone, Vector3(pod_w * 0.34, 0, pod_d * 0.5 + 1.6))
	return root

## A torii gate: two red posts + a lower tie-beam (nuki) + a wide upturned top lintel (kasagi).
static func _build_torii(parent: Node3D, post_mat: StandardMaterial3D,
		beam_mat: StandardMaterial3D, span: float, base: Vector3) -> void:
	var h: float = 4.6
	var post_r: float = 0.22
	_solid(parent, Vector3(post_r * 2.0, h, post_r * 2.0), post_mat, base + Vector3(-span, h * 0.5, 0))
	_solid(parent, Vector3(post_r * 2.0, h, post_r * 2.0), post_mat, base + Vector3(span, h * 0.5, 0))
	_decor(parent, Vector3(span * 2.0 + 0.8, 0.32, 0.5), post_mat, base + Vector3(0, h * 0.78, 0))
	_decor(parent, Vector3(span * 2.0 + 2.2, 0.42, 0.7), beam_mat, base + Vector3(0, h + 0.2, 0))
	_decor(parent, Vector3(1.0, 0.3, 0.7), beam_mat, base + Vector3(-(span + 1.0), h + 0.4, 0), Vector3(0, 0, 11.0))
	_decor(parent, Vector3(1.0, 0.3, 0.7), beam_mat, base + Vector3(span + 1.0, h + 0.4, 0), Vector3(0, 0, -11.0))
	_decor(parent, Vector3(span * 2.0 + 1.0, 0.16, 0.36), beam_mat, base + Vector3(0, h + 0.46, 0))

## A stone lantern: stacked base/post/platform/light-box/cap + a warm emissive panel & light.
static func _build_lantern(parent: Node3D, stone_mat: StandardMaterial3D, base: Vector3) -> void:
	_solid(parent, Vector3(0.7, 0.3, 0.7), stone_mat, base + Vector3(0, 0.15, 0))
	_solid(parent, Vector3(0.24, 1.2, 0.24), stone_mat, base + Vector3(0, 0.9, 0))
	_solid(parent, Vector3(0.62, 0.18, 0.62), stone_mat, base + Vector3(0, 1.6, 0))
	var glow := ProcMaterials.emissive(Color(1.0, 0.72, 0.36), 2.4)
	_decor(parent, Vector3(0.5, 0.5, 0.5), glow, base + Vector3(0, 1.95, 0))
	ProceduralModels._part(parent, ProceduralModels._cone(0.5, 0.42, 4), stone_mat,
		base + Vector3(0, 2.45, 0), Vector3(0, 45.0, 0))
	var light := OmniLight3D.new()
	light.position = base + Vector3(0, 2.0, 0)
	light.shadow_enabled = false
	light.light_color = Color(1.0, 0.78, 0.5)
	light.light_energy = 1.6
	light.omni_range = 7.0
	parent.add_child(light)

## ALPINE LODGE (snow zone): two timber A-frame cabins with steep snow-laden roofs, a stone
## chimney, and a small woodpile. Collidable timber cores + render-only tilted roof panels
## (tilted-box collision isn't supported by _solid; these are landmarks, not enterable).
static func build_snow_lodge(footprint: Vector2) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	var sid: int = int(w * 29.0 + d * 11.0)
	var timber := mat_timber(sid)
	var roofw := mat_roofwood(sid + 3)
	var snow := mat_snow(sid)
	var stone := mat_concrete(sid + 5)
	# Main cabin + a smaller second cabin set back (+X/+Z).
	_build_aframe(root, timber, roofw, snow, Vector3(-w * 0.16, 0, 0), w * 0.5, d * 0.6, 5.0, sid)
	_build_aframe(root, timber, roofw, snow, Vector3(w * 0.28, 0, d * 0.18), w * 0.34, d * 0.4, 3.8, sid + 17)
	# Stone chimney on the main cabin (above the ridge) with a snow cap + a faint hearth ember.
	var ch_base := Vector3(-w * 0.16 - w * 0.2, 0, -d * 0.16)
	_solid(root, Vector3(0.9, 6.2, 0.9), stone, ch_base + Vector3(0, 3.1, 0))
	_decor(root, Vector3(1.06, 0.3, 1.06), snow, ch_base + Vector3(0, 6.32, 0))
	var ember := ProcMaterials.emissive(Color(1.0, 0.5, 0.2), 2.0)
	_decor(root, Vector3(0.5, 0.2, 0.5), ember, ch_base + Vector3(0, 6.5, 0))
	# Woodpile (stacked logs) near the main cabin entrance (+Z) as cover.
	var logmat := mat_timber(sid + 9)
	var wpx: float = -w * 0.16 + 1.9
	var wpz: float = d * 0.32
	_solid(root, Vector3(2.0, 0.32, 0.32), logmat, Vector3(wpx, 0.16, wpz))
	_solid(root, Vector3(2.0, 0.32, 0.32), logmat, Vector3(wpx, 0.16, wpz + 0.34))
	_solid(root, Vector3(2.0, 0.32, 0.32), logmat, Vector3(wpx, 0.48, wpz + 0.17))
	return root

## One A-frame cabin centred at `base`: a solid timber core (collision) + two steep tilted roof
## panels meeting at a ridge (render-only) capped with snow + front/back gables and a dark door.
static func _build_aframe(parent: Node3D, timber: StandardMaterial3D, roofw: StandardMaterial3D,
		snow: StandardMaterial3D, base: Vector3, fw: float, dd: float, hgt: float, sid: int) -> void:
	var hw: float = fw * 0.5
	# Solid lower core (navmesh routes around it).
	var core_h: float = hgt * 0.42
	_solid(parent, Vector3(fw * 0.86, core_h, dd * 0.9), timber, base + Vector3(0, core_h * 0.5, 0))
	# Two roof panels from ground (±hw) up to the ridge (0,hgt). Render-only tilted boxes.
	var slant: float = sqrt(hw * hw + hgt * hgt)
	var ang: float = rad_to_deg(atan2(hgt, hw))
	_decor(parent, Vector3(slant, 0.34, dd), roofw,
		base + Vector3(-hw * 0.5, hgt * 0.5, 0), Vector3(0, 0, ang))
	_decor(parent, Vector3(slant, 0.34, dd), roofw,
		base + Vector3(hw * 0.5, hgt * 0.5, 0), Vector3(0, 0, -ang))
	# Snow caps on the outer face of each panel.
	_decor(parent, Vector3(slant * 0.98, 0.16, dd * 0.98), snow,
		base + Vector3(-hw * 0.5 - 0.12, hgt * 0.5 + 0.14, 0), Vector3(0, 0, ang))
	_decor(parent, Vector3(slant * 0.98, 0.16, dd * 0.98), snow,
		base + Vector3(hw * 0.5 + 0.12, hgt * 0.5 + 0.14, 0), Vector3(0, 0, -ang))
	# Front + back gable panels under the ridge.
	var gable := ProcMaterials.weathered(Color(0.30, 0.20, 0.12), 0.0, 0.85, 0.45,
		sid * 7 + 1, Vector3(0.08, 0.08, 0.08), true, 0.7, true)
	_decor(parent, Vector3(fw * 0.5, hgt * 0.7, 0.2), gable, base + Vector3(0, hgt * 0.4, dd * 0.5))
	_decor(parent, Vector3(fw * 0.5, hgt * 0.7, 0.2), gable, base + Vector3(0, hgt * 0.4, -dd * 0.5))
	# Dark doorway + a warm window glow on the front gable (+Z).
	var dark := mat_concrete_dark(sid + 2)
	_decor(parent, Vector3(1.1, 1.9, 0.12), dark, base + Vector3(0, 0.95, dd * 0.5 + 0.06))
	var winglow := ProcMaterials.emissive(Color(1.0, 0.8, 0.45), 1.8)
	_decor(parent, Vector3(0.7, 0.7, 0.1), winglow, base + Vector3(fw * 0.22, 1.3, dd * 0.5 + 0.06))

## DESERT RUINS (desert zone): broken sandstone perimeter walls with toppled gaps, a colonnade
## of standing + broken round columns, and a central obelisk. All sandstone, collidable.
static func build_desert_ruins(footprint: Vector2) -> Node3D:
	var root := Node3D.new()
	var w: float = footprint.x
	var d: float = footprint.y
	var sid: int = int(w * 19.0 + d * 13.0)
	var sand := mat_sandstone(sid)
	var sand_d := mat_sandstone_dark(sid)
	# Low sandstone platform.
	_solid(root, Vector3(w * 0.8, 0.5, d * 0.8), sand_d, Vector3(0, 0.25, 0))
	# Broken perimeter walls along the 4 edges.
	var ex: float = w * 0.5 * 0.72
	var ez: float = d * 0.5 * 0.72
	_ruin_wall(root, sand, sid + 1, Vector3(0, 0, -ez), w * 0.7, false)
	_ruin_wall(root, sand, sid + 2, Vector3(0, 0, ez), w * 0.7, false)
	_ruin_wall(root, sand, sid + 3, Vector3(-ex, 0, 0), d * 0.7, true)
	_ruin_wall(root, sand, sid + 4, Vector3(ex, 0, 0), d * 0.7, true)
	# Colonnade of round columns (some broken) on an inner ring.
	var cols: int = 6
	for i in range(cols):
		var hk: int = ProcHash.h(sid * 31 + i * 7)
		var a: float = TAU * float(i) / float(cols)
		var rr: float = min(ex, ez) * 0.58
		var cxp: float = cos(a) * rr
		var czp: float = sin(a) * rr
		var broken: bool = (hk % 100) < 40
		var col_h: float = 4.2 if not broken else (1.2 + ProcHash.hf(hk + 1) * 1.6)
		_solid_cyl(root, 0.42, col_h, sand, Vector3(cxp, 0.5 + col_h * 0.5, czp), 10)
		if not broken:
			_solid(root, Vector3(1.1, 0.4, 1.1), sand_d, Vector3(cxp, 0.5 + col_h + 0.2, czp))
		else:
			var fx: float = cxp + (ProcHash.hf(hk + 2) - 0.5) * 2.4
			var fz: float = czp + (ProcHash.hf(hk + 3) - 0.5) * 2.4
			_solid_cyl(root, 0.42, 0.7, sand_d, Vector3(fx, 0.85, fz), 10, 90.0)
	# Central obelisk: a 4-sided shaft + a pyramidion cap.
	var ob_h: float = 8.5
	_solid_cyl(root, 0.66, ob_h, sand, Vector3(0, 0.5 + ob_h * 0.5, 0), 4, 45.0)
	ProceduralModels._part(root, ProceduralModels._cone(0.95, 1.3, 4), sand,
		Vector3(0, 0.5 + ob_h + 0.65, 0), Vector3(0, 45.0, 0))
	# A couple of half-buried blocks for ground detail.
	_solid(root, Vector3(1.6, 0.7, 1.2), sand_d, Vector3(ex * 0.4, 0.35, -ez * 0.5), 24.0)
	_solid(root, Vector3(1.2, 0.6, 1.8), sand, Vector3(-ex * 0.5, 0.3, ez * 0.45), 58.0)
	return root

## A broken sandstone wall running along X (or along Z if `along_z`), centred at `base`, total
## `length`, built from a few segments of varying height with toppled GAPS + fallen blocks.
static func _ruin_wall(parent: Node3D, mat: StandardMaterial3D, sid: int, base: Vector3,
		length: float, along_z: bool) -> void:
	var segs: int = 5
	var seg_len: float = length / float(segs)
	for i in range(segs):
		var hk: int = ProcHash.h(sid * 13 + i * 5)
		var toppled: bool = (hk % 100) < 30
		var hgt: float = 0.6 if toppled else (1.6 + ProcHash.hf(hk + 1) * 1.8)
		var off: float = -length * 0.5 + (float(i) + 0.5) * seg_len
		var pos: Vector3 = base + (Vector3(0, hgt * 0.5, off) if along_z else Vector3(off, hgt * 0.5, 0))
		var sz: Vector3 = Vector3(0.55, hgt, seg_len * 0.92) if along_z else Vector3(seg_len * 0.92, hgt, 0.55)
		_solid(parent, sz, mat, pos)
		if toppled:
			var jitter: float = (ProcHash.hf(hk + 2) - 0.5) * 1.4
			var bpos: Vector3 = base + (Vector3(1.1, 0.2, off + jitter) if along_z else Vector3(off + jitter, 0.2, 1.1))
			_solid(parent, Vector3(1.0, 0.4, 0.7), mat, bpos, float(ProcHash.h(hk + 3) % 40))

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
