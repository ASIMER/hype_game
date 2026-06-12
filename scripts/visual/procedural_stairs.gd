class_name ProceduralStairs
extends RefCounted
## Interior/exterior STAIR FLIGHTS, slab HOLES and container STEP-CRATES for the
## vertical-access overhaul — every multi-storey building gets a walkable path to its
## upper floors and roof, and container stacks get mantle chains / ramps.
##
## KEY MECHANIC — RAMP UNDER THE TREADS: CharacterBody3D has no stair-stepping (a
## 0.3 m riser is a wall to move_and_slide), so the COLLISION of every flight is one
## smooth solid ramp box at ≤36° (under the body's 45° floor_max_angle and the
## navmesh's 50° agent_max_slope) with RENDER-ONLY tread boxes on top for the look.
## Players walk it, enemies path it (the runtime navmesh bakes the slope), and the
## golden snapshot hashes it deterministically (no randf — constants + ProcHash only).
##
## The slab HOLE math: a body ascending the ramp needs 1.8 m of headroom under the
## slab it pierces, so the opening starts where ramp height reaches rise − 2.1
## (slab bottom 0.3 below its walking surface) and ends at the ramp top.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

const RAMP_THICKNESS := 0.3
const TREAD_RISE := 0.28  # render-only tread spacing (visual step height)


## One solid collidable ramp whose WALKING SURFACE runs from `base_pos` (lower floor)
## up `rise` metres over `run` metres along local +Z of `node` (the caller yaws the
## returned node). Surface sits 0.02 proud at the top so the slab seam never z-fights.
static func _solid_ramp(
	node: Node3D, width: float, run: float, rise: float, mat: StandardMaterial3D
) -> void:
	var dir := Vector3(0.0, rise, run).normalized()
	var right := Vector3(1.0, 0.0, 0.0)
	var up := dir.cross(right)  # (0, run, -rise)/len — perpendicular, points up-back
	if up.y < 0.0:
		up = -up
	up = up.normalized()
	var slope_len: float = sqrt(run * run + rise * rise) + 0.4
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	# Centre the box so its TOP face contains the (0,0,0)→(0,rise,run) surface line.
	var mid := Vector3(0.0, rise * 0.5, run * 0.5)
	body.position = mid - up * (RAMP_THICKNESS * 0.5 - 0.02)
	body.basis = Basis(right, up, dir)
	node.add_child(body)
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, RAMP_THICKNESS, slope_len)
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var mi := MeshInstance3D.new()
	mi.mesh = ProceduralModels._box(Vector3(width, RAMP_THICKNESS, slope_len))
	mi.material_override = mat
	body.add_child(mi)


## A full stair flight: the solid ramp + render-only horizontal treads + a thin side
## stringer. Runs along local +Z from y=0 to y=rise; the returned node is placed and
## yawed by the caller (cardinal directions only — the hole math is axis-aligned).
static func flight(
	parent: Node3D,
	base_pos: Vector3,
	run: float,
	rise: float,
	width: float,
	yaw_deg: float,
	mat: StandardMaterial3D,
	tread_mat: StandardMaterial3D
) -> void:
	var node := Node3D.new()
	node.position = base_pos
	node.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	parent.add_child(node)
	_solid_ramp(node, width, run, rise, mat)
	# Render-only treads: flat horizontal steps poking through the slope.
	var n: int = int(ceil(rise / TREAD_RISE))
	var step_run: float = run / float(n)
	var step_rise: float = rise / float(n)
	for i in range(n):
		var tread := MeshInstance3D.new()
		tread.mesh = ProceduralModels._box(Vector3(width, 0.06, step_run + 0.06))
		tread.material_override = tread_mat
		tread.position = Vector3(0.0, float(i + 1) * step_rise - 0.02, (float(i) + 0.5) * step_run)
		tread.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(tread)
	# Thin render-only stringer along one side so the flight reads as built, not extruded.
	var stringer := MeshInstance3D.new()
	var slope_len: float = sqrt(run * run + rise * rise)
	stringer.mesh = ProceduralModels._box(Vector3(0.08, 0.5, slope_len))
	stringer.material_override = mat
	stringer.position = Vector3(width * 0.5 + 0.04, rise * 0.5, run * 0.5)
	stringer.rotation = Vector3(-atan2(rise, run), 0.0, 0.0)
	stringer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(stringer)


## The slab/roof OPENING (building-local XZ Rect2) a flight needs to pierce the level
## above. `base_xz` = the flight's base, `dir` = its cardinal run direction (unit).
## Opens where ascending headroom (1.8 + the 0.3 slab) runs out; ends at the ramp top.
static func hole_rect(
	base_xz: Vector2, dir: Vector2, run: float, rise: float, width: float
) -> Rect2:
	# Clearance 2.6 (capsule 1.8 + its 0.4 radius sweeping the slope + margin): with
	# the theoretical 2.1 the capsule's top corner ground against the slab edge and
	# the player jammed at the opening (found by the live climb QA).
	var start_frac: float = clampf((rise - 2.6) / rise, 0.05, 0.9)
	var a: Vector2 = base_xz + dir * (start_frac * run - 0.2)
	var b: Vector2 = base_xz + dir * run
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	# Expand perpendicular to the run by the half-width (+ margin).
	var half_w: float = width * 0.5 + 0.05
	if absf(dir.x) > 0.5:
		lo.y -= half_w
		hi.y += half_w
	else:
		lo.x -= half_w
		hi.x += half_w
	return Rect2(lo, hi - lo)


## Mantle step-crates beside a 2.6 m container: THREE timber crate columns in a row
## toward the face. MANTLE-LEGAL RISES ONLY — the engine's mantle needs the ledge in
## (0.9, 1.2] (its chest probe at feet+0.9 must still HIT the wall; lower rises miss
## and can't be air-jumped either, found by live QA). Ground → A (1.15) → B (2.30) →
## C (3.30, ABOVE the container) → walk off and DROP 0.7 onto the 2.6 top. The node's
## local -Z points at the container face; C hugs it.
static func crate_steps(parent: Node3D, base_pos: Vector3, yaw_deg: float, sid: int) -> void:
	var node := Node3D.new()
	node.position = base_pos
	node.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	parent.add_child(node)
	var timber: StandardMaterial3D = ProceduralBuildings.mat_timber(sid)
	var dark: StandardMaterial3D = ProceduralBuildings.mat_metal_dark(sid + 3)
	# C hugs the container face (local -Z = origin); B and A step back (+Z).
	ProceduralBuildings._solid(node, Vector3(1.1, 3.30, 1.1), timber, Vector3(0.0, 1.65, 0.0))
	ProceduralBuildings._solid(node, Vector3(1.1, 2.30, 1.1), timber, Vector3(0.0, 1.15, 1.2))
	ProceduralBuildings._solid(node, Vector3(1.1, 1.15, 1.1), timber, Vector3(0.0, 0.575, 2.4))
	# Render seams so the tall columns read as stacked crates, not extruded boxes.
	for seam_def in [[1.65, 0.0], [2.2, 0.0], [1.15, 1.2], [0.0, 0.0]]:
		var sy: float = seam_def[0]
		var sz: float = seam_def[1]
		if sy <= 0.0:
			continue
		var seam := MeshInstance3D.new()
		seam.mesh = ProceduralModels._box(Vector3(1.14, 0.06, 1.14))
		seam.material_override = dark
		seam.position = Vector3(0.0, sy, sz)
		seam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(seam)


## Industrial welded ramp up a 5.2 m double container stack (the 4-crate alternative
## is bulky): one solid 35.5° run alongside the stack's outer long face, ending on a
## flat LANDING DECK at stack height (walking straight past the top never drops the
## player — live QA walked off the bare ramp end; step sideways onto the containers
## anywhere along the deck). The caller places/yaws so local +Z ascends parallel to
## the stack with the top edge-adjacent to it.
static func yard_ramp(
	parent: Node3D, base_pos: Vector3, yaw_deg: float, rise: float, sid: int
) -> void:
	var run: float = rise / 0.715  # ≈35.6° (tan 0.715), e.g. 5.2 → 7.27 m
	var metal: StandardMaterial3D = ProceduralBuildings.mat_metal(sid)
	flight(
		parent,
		base_pos,
		run,
		rise,
		2.0,
		yaw_deg,
		metal,
		ProceduralBuildings.mat_metal_dark(sid + 7)
	)
	var node := Node3D.new()
	node.position = base_pos
	node.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	parent.add_child(node)
	# Deck top sits 0.02 proud of `rise` (same seam rule as the ramp top). Its front
	# edge starts at run+0.1 where the ramp surface is already ABOVE deck height, so
	# the junction is a small step DOWN — a front edge under the slope's surface line
	# presents a >45° lip-wall the capsule cannot climb (live QA jammed on it).
	ProceduralBuildings._solid(
		node, Vector3(2.0, 0.3, 2.6), metal, Vector3(0.0, rise - 0.13, run + 1.4)
	)
	# Render-only support legs so the deck reads as a welded platform, not a floater.
	var dark: StandardMaterial3D = ProceduralBuildings.mat_metal_dark(sid + 11)
	for leg_x in [-0.8, 0.8]:
		ProceduralBuildings._decor(
			node,
			Vector3(0.14, rise - 0.3, 0.14),
			dark,
			Vector3(leg_x, (rise - 0.3) * 0.5, run + 2.3)
		)
