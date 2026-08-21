class_name ProceduralModelsFauna
extends RefCounted
## Procedural models for the v0.3 BIOME FAUNA + biome minibosses + the recon drone.
## Split from procedural_models.gd purely for size discipline (that file sits near the
## gdlint max-file-lines ceiling); reuses ITS static mesh/material/placement helpers
## (no copy-paste — the AUDIT F1 rule). Dispatched via ProceduralModels.build()/
## has_builder (FAUNA_BUILDERS), so AssetRegistry.get_model — and therefore the
## enemy scenes AND IconRenderer — pick these up automatically.
##
## Same discipline as the enemies in procedural_models.gd: StandardMaterial3D only
## (hit-flash compatible), authored facing -Z, named parts for the per-frame idle
## animation hooks in the enemy scripts (robot_worm / robot_kamikaze / robot_strafer).
##
## Every machine that WALKS also publishes named hip pivots "GaitLeg0".."GaitLeg3"
## (see `_gait_hip` / `_quad_hips` below) — the contract EnemyGait swings from the body's
## own measured speed. Adding those pivots is what opts a machine into the walk cycle;
## the hover/burrow ones (sand-worm, dust-devil, dune warden, specter) publish none.
##
## D3 SILHOUETTE PASS. The complaint these bodies answer is "every machine has the same
## humanoid signature". Per docs/research/model-overhaul-research.md §2-3 a machine covers
## 15-31 px at 100 m, so ONLY the outline, one light/dark split and one emissive survive
## that distance — and detail must be CONCENTRATED (large calm plates, density at the
## joints) instead of spread evenly. Each family therefore owns an outline no other family
## is allowed to use:
##   hound       (frosthound, kappa)  — a LOW HORIZONTAL bar, mass carried forward on the
##                                      shoulders; legs bent so a crouch reads as a coil
##   siege walker(avalanche, oni + their minibosses) — a smooth carapace slung HIGH on
##                                      articulated legs; the GAP under the hull is the
##                                      signature and the joints are the fat, shootable bits
##   skitter     (scarab)             — tiny, six-legged, splayed: reads as a cluster
##   artillery   (cryomortar)         — a wide dug-in tripod under a steeply ELEVATED tube
##   serpent     (sandworm)           — ribbed bands + a flared MAW terminal form, no legs
##   whirl gunner(dustdevil, warden)  — an INVERTED spinning cone, no torso and no shoulders
##   stag        (raiju)              — leggy, arched, antler-crowned: the anti-hound
##
## SIZE IS PINNED BY THE SCENES. Every body here is authored against its own .tscn (which
## this file must never edit): the collision capsule sets the height/width envelope, and the
## WeakPoint sphere pins where the signature part (head / chest core / maw / back seal) has
## to sit — a signature that drifts off its sphere makes the documented kill window
## unhittable. The per-builder doc comments quote the numbers they were authored against.


static func build(id: String) -> Node3D:
	match id:
		"robot_sandworm":
			return build_robot_sandworm()
		"robot_scarab":
			return build_robot_scarab()
		"robot_dustdevil":
			return build_robot_dustdevil()
		"robot_frosthound":
			return build_robot_frosthound()
		"robot_cryomortar":
			return build_robot_cryomortar()
		"robot_avalanche":
			return build_robot_avalanche()
		"robot_oni":
			return build_robot_oni()
		"robot_kappa":
			return build_robot_kappa()
		"robot_raiju":
			return build_robot_raiju()
		"robot_snow_golem":
			return build_robot_snow_golem()
		"robot_dune_warden":
			return build_robot_dune_warden()
		"robot_oni_chief":
			return build_robot_oni_chief()
		"robot_specter":
			return build_robot_specter()
	return null


# ------------------------------------------------------------------ local shorthands
# Pure one-line DELEGATIONS to the shared helpers in procedural_models.gd — not copies
# (AUDIT F1). They exist for the line budget: the silhouette pass roughly doubles the part
# count of this file and a wrapped `ProceduralModels._part(...)` call costs 6-8 formatted
# lines each. Every material still reaches the mesh through `_part`, so the hit-flash
# `material_override` contract, the nemesis scar collector and LimbBurst are untouched.


static func _pt(
	parent: Node3D,
	mesh: Mesh,
	mat: StandardMaterial3D,
	off := Vector3.ZERO,
	rot := Vector3.ZERO,
	scl := Vector3.ONE
) -> MeshInstance3D:
	return ProceduralModels._part(parent, mesh, mat, off, rot, scl)


static func _bx(size: Vector3) -> BoxMesh:
	return ProceduralModels._box(size)


static func _cy(r: float, h: float, seg := 10) -> CylinderMesh:
	return ProceduralModels._cyl(r, h, seg)


static func _cn(r: float, h: float, seg := 8) -> CylinderMesh:
	return ProceduralModels._cone(r, h, seg)


static func _sp(r: float, hemi := false, rings := 8, radial := 12) -> SphereMesh:
	return ProceduralModels._sphere(r, hemi, rings, radial)


## A RING (torus) standing in the XY plane once rotated 90° about X — the rib bands of the
## serpent, the mouth collar and the drone's rotor ducts. Godot's TorusMesh defaults to
## 64x32 segments (~4k tris EACH); these are silhouette props, so the counts are forced
## down to a level a wave of them can afford.
static func _ring(inner: float, outer: float, seg := 14, sides := 6) -> TorusMesh:
	var m := TorusMesh.new()
	m.inner_radius = inner
	m.outer_radius = outer
	m.rings = seg
	m.ring_segments = sides
	return m


# ----------------------------------------------------------------- gait pivots (D2.4)
## One named HIP pivot at the point where a leg meets the body. Every part of that leg
## becomes a CHILD with its offset re-expressed relative to `pos`, so the rest pose is
## unchanged (pure re-parenting) while EnemyGait can swing the whole limb by rotating
## just this node — the machines used to slide with rigid legs.
##
## Deliberately NOT named "Leg%d": robot_enemy / robot_pouncer / robot_kamikaze cache
## nodes with THAT name for their own idle sway and would fight the stride. "GaitLeg*"
## is the walk-cycle contract, "Leg*" stays the idle-sway one — and because the sway
## pivot lives INSIDE the hip, the two compose (hip swings the limb, sway wiggles it).
static func _gait_hip(root: Node3D, idx: int, pos: Vector3) -> Node3D:
	var hip := Node3D.new()
	hip.name = "GaitLeg%d" % idx
	hip.position = pos
	root.add_child(hip)
	return hip


## The four hip pivots of a quadruped, created in EnemyGait's PHASE order.
##
## EnemyGait collects pivots in TREE order and puts EVEN indices half a cycle out of phase
## with ODD ones, so the hips must be added in a CIRCULAR walk (front-left → rear-left →
## rear-right → front-right) for that split to land on the two DIAGONAL pairs: a TROT.
## The builders' own left-side-then-right-side order would have paired the two front legs
## against the two rear ones — a bound (a rabbit hop), which is not how these read.
## It also matches robot_pouncer's own diagonal pairing (0,3)/(1,2), so the script sway and
## the stride reinforce instead of cancelling.
##
## `attach` holds the hip points in the BUILDERS' leg order (0 front-left, 1 rear-left,
## 2 front-right, 3 rear-right) and the returned pivots keep THAT order, so each builder's
## leg geometry below is untouched.
static func _quad_hips(root: Node3D, attach: Array[Vector3]) -> Array[Node3D]:
	var order: Array[int] = [0, 1, 3, 2]
	var hips: Array[Node3D] = []
	hips.resize(4)
	for gi in 4:
		var li: int = order[gi]
		var pos: Vector3 = attach[li]
		hips[li] = _gait_hip(root, gi, pos)
	return hips


## The six hip pivots of an INSECT, created in EnemyGait's phase order so the even/odd split
## lands on the two alternating TRIPODS (left-front + right-mid + left-rear against their
## mirror) instead of on one whole side — a hexapod that paddles one flank at a time reads
## as broken, and the tripod is the gait everybody recognises as "bug".
##
## `attach` is in the builder's own order [LF, RF, LM, RM, LR, RR]; the returned pivots keep
## that order so the leg geometry below stays readable.
static func _hex_hips(root: Node3D, attach: Array[Vector3]) -> Array[Node3D]:
	var order: Array[int] = [0, 1, 3, 2, 5, 4]
	var hips: Array[Node3D] = []
	hips.resize(6)
	for gi in 6:
		var li: int = order[gi]
		hips[li] = _gait_hip(root, gi, attach[li])
	return hips


## A chained limb: struts along `pts` (limb-local; pts[0] is the attachment point) using
## `radii` per segment, with a JOINT BALL at every interior point.
##
## The joints are deliberately the fattest thing on the limb — research §2 (Guerrilla's
## "not enough area to shoot at"): on a walker the knees are simultaneously the visual
## articulation that sells the silhouette AND the only part of a leg wide enough to aim at.
## Untyped Arrays on purpose: callers pass inline literals, and a typed parameter would
## reject them at runtime.
static func _limb(
	parent: Node3D,
	pts: Array,
	radii: Array,
	joint_r: float,
	seg_mat: StandardMaterial3D,
	joint_mat: StandardMaterial3D
) -> void:
	for i in range(pts.size() - 1):
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var r: float = radii[mini(i, radii.size() - 1)]
		ProceduralModels._strut(parent, a, b, r, seg_mat)
		if i > 0 and joint_r > 0.0:
			_pt(parent, _sp(joint_r, false, 6, 8), joint_mat, a)


## One ARTICULATED walker leg on `hip`: a fat hip ball, a femur that reaches OUT AND UP to a
## high knee, then a tibia dropping back IN to a broad ground pad. That inverted-V is what
## holds the carapace a metre off the ground — the family's whole signature is the daylight
## you can see UNDER the machine, and a straight column leg destroys it.
## `knee`/`foot` are hip-local and already side-signed by the caller.
static func _walker_leg(
	hip: Node3D,
	knee: Vector3,
	foot: Vector3,
	radii: Vector2,
	pad: Vector3,
	frame: StandardMaterial3D,
	steel: StandardMaterial3D
) -> void:
	_pt(hip, _sp(radii.x * 1.25, false, 7, 10), frame, Vector3.ZERO)
	_limb(hip, [Vector3.ZERO, knee, foot], [radii.x, radii.y], radii.x * 1.15, steel, frame)
	_pt(hip, _bx(pad), frame, foot + Vector3(0, -pad.y * 0.5, 0))


## DESERT — Sand-worm: a ribbed mechanical serpent. Terminal MAW first (a dark flared jaw
## funnel with a glowing throat ring and six rim teeth — the documented kill window is a
## HOLE, not a drill point), then 7 banded rib segments under pivots "Seg0".."Seg6" (the
## crawl undulation sways the pivots) with a saw-tooth dorsal edge, tapering to a tail spike.
## No legs, ever: the family reads by the banding, and legs would drag it back into the mob.
## Scene: capsule r0.5 h1.2 @y0.6, WeakPoint r0.3 @(0,0.5,-0.45) → maw axis pinned to y0.5.
static func build_robot_sandworm() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated sand hull; the jaw funnel + ribs' bare steel; the Maw keeps
	# its identity-amber kill-window glow (kit energy 3.5 = signage).
	var k := ProcEnemyKits.kit("robot_sandworm")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var plate: StandardMaterial3D = k["steel"]
	var maw_mat: StandardMaterial3D = k["glow"]

	# MAW: cones are authored apex-at-+Y, so rot X +90 puts the apex at the REAR and the wide
	# opening forward — an open funnel. The glow cone sits INSIDE the dark one, so from any
	# angle the head is a bright ring in a dark socket.
	# The funnel's apex is buried INSIDE the first segment (z -0.25 vs the segment cord at
	# -0.28) so the head grows out of the body instead of being a cone parked in front of it.
	_pt(root, _cn(0.45, 0.46, 12), dark, Vector3(0, 0.5, -0.48), Vector3(90, 0, 0))
	var maw := _pt(root, _cn(0.34, 0.34, 12), maw_mat, Vector3(0, 0.5, -0.46), Vector3(90, 0, 0))
	maw.name = "Maw"
	_pt(root, _ring(0.4, 0.5, 14, 6), plate, Vector3(0, 0.5, -0.68), Vector3(90, 0, 0))
	# Six rim teeth, apexes forward (rot X -90).
	for i in 6:
		var a := TAU * float(i) / 6.0 + 0.26
		var tp := Vector3(cos(a) * 0.38, 0.5 + sin(a) * 0.38, -0.74)
		_pt(root, _cn(0.06, 0.26, 5), plate, tp, Vector3(-90, 0, 0))

	# 7 banded segments: a dark inner cord with a LIGHT rib ring standing proud of it. The
	# alternating light/dark banding is the whole read at distance — one long striped bar.
	for i in 7:
		var t := float(i) / 6.0
		var r: float = lerpf(0.4, 0.17, t)
		var pivot := Node3D.new()
		pivot.name = "Seg%d" % i
		pivot.position = Vector3(0, lerpf(0.5, 0.36, t), -0.15 + float(i) * 0.27)
		root.add_child(pivot)
		_pt(pivot, _cy(r * 0.74, 0.26, 10), dark, Vector3.ZERO, Vector3(90, 0, 0))
		_pt(pivot, _ring(r * 0.74, r, 14, 6), shell, Vector3.ZERO, Vector3(90, 0, 0))
		_pt(
			pivot,
			_cn(0.09, 0.3 - t * 0.13, 4),
			plate,
			Vector3(0, r * 0.86, 0.02),
			Vector3(-14, 0, 0)
		)
	# Tail spike (+Z rear).
	_pt(root, _cn(0.15, 0.55, 8), dark, Vector3(0, 0.36, 1.82), Vector3(90, 0, 0))
	return root


## DESERT — Scarab: a SIX-legged skitter, deliberately the smallest and busiest outline in
## the roster so a pack of them reads as a moving cluster rather than as individuals. Low
## wide carapace, splayed insect legs (knees ABOVE the shell line), front mandibles, and the
## arming charge lifted onto a cocked abdomen — "Core", which the script blinks while ARMED.
## Hips are published in tripod order (see _hex_hips); the outer four also carry the script's
## own "Leg0".."Leg3" skitter pivots. Scene: sphere r0.32 @y0.32, no WeakPoint.
static func build_robot_scarab() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated rust hull; the arming Core keeps its bespoke RED
	# blink (gameplay signage, NOT the identity orange) at restrained energy.
	var k := ProcEnemyKits.kit("robot_scarab")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var leg_mat: StandardMaterial3D = k["steel"]
	var core_mat := ProcPlating.glow(Color(0.95, 0.2, 0.12), 3.5)
	var accent: StandardMaterial3D = k["accent"]

	# Flat wide carapace + dark underbelly + a bright dorsal seam.
	_pt(
		root,
		_sp(0.26, true, 8, 14),
		shell,
		Vector3(0, 0.3, 0),
		Vector3.ZERO,
		Vector3(1.15, 0.62, 1.3)
	)
	_pt(root, _bx(Vector3(0.3, 0.1, 0.44)), dark, Vector3(0, 0.28, 0))
	_pt(root, _bx(Vector3(0.035, 0.03, 0.5)), accent, Vector3(0, 0.455, 0))
	# Prothorax + mandible prongs (-Z).
	_pt(root, _bx(Vector3(0.18, 0.1, 0.13)), dark, Vector3(0, 0.3, -0.34))
	_pt(root, _cn(0.04, 0.2, 6), dark, Vector3(0.09, 0.28, -0.46), Vector3(-100, 0, 0))
	_pt(root, _cn(0.04, 0.2, 6), dark, Vector3(-0.09, 0.28, -0.46), Vector3(-100, 0, 0))
	# Cocked abdomen carrying the charge: the Core rides HIGH and to the rear, so the blink
	# is visible over the shell from every angle a player can approach from.
	_pt(root, _bx(Vector3(0.19, 0.14, 0.17)), shell, Vector3(0, 0.44, 0.26), Vector3(-24, 0, 0))
	var core := _pt(root, _sp(0.09, false, 8, 12), core_mat, Vector3(0, 0.52, 0.34))
	core.name = "Core"

	# 6 splayed legs. Builder order [LF, RF, LM, RM, LR, RR]; _hex_hips re-orders the pivots
	# so EnemyGait's even/odd split becomes the alternating tripod.
	var attach: Array[Vector3] = [
		Vector3(-0.19, 0.32, -0.2),
		Vector3(0.19, 0.32, -0.2),
		Vector3(-0.21, 0.32, 0.02),
		Vector3(0.21, 0.32, 0.02),
		Vector3(-0.19, 0.32, 0.2),
		Vector3(0.19, 0.32, 0.2)
	]
	var hips := _hex_hips(root, attach)
	# The four OUTER legs also get the script's skitter pivot; the mids stay stride-only.
	var swayed: Array[int] = [0, 1, 4, 5]
	for li in 6:
		var a: Vector3 = attach[li]
		var side: float = signf(a.x)
		# Front legs rake forward, rear legs rake back, the mid pair stays square — the
		# splayed star is what makes a cluster of these read as a swarm and not as a blob.
		var dz: float = (signf(a.z) * 0.1) if absf(a.z) > 0.1 else 0.0
		var host: Node3D = hips[li]
		var slot: int = swayed.find(li)
		if slot >= 0:
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % slot
			hips[li].add_child(pivot)
			host = pivot
		_limb(
			host,
			[Vector3.ZERO, Vector3(side * 0.14, 0.08, dz), Vector3(side * 0.25, -0.32, dz * 1.4)],
			[0.03, 0.023],
			0.036,
			leg_mat,
			dark
		)
	return root


## DESERT — Dust-devil: a whirl gunner. An INVERTED spinning cone (apex on the ground, wide
## rim up) under a compact sensor pod — no torso, no shoulders, no head, because those three
## are exactly what made every machine read as the same humanoid. The pivot "Skirt" is spun
## by the script; the "Eye" is a horizontal sensor SLIT, not a ball (research §2).
## Scene: capsule r0.45 h1.5 @y0.75, WeakPoint r0.22 @(0,1.42,-0.2) → Eye inside that sphere.
static func build_robot_dustdevil() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated sand hull; skirt vanes carry the identity-amber accent.
	var k := ProcEnemyKits.kit("robot_dustdevil")
	var sand: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var eye_mat: StandardMaterial3D = k["glow"]
	var plate: StandardMaterial3D = k["accent"]

	# Spinning whirl: rot X 180 flips the cone so its apex touches the ground.
	var skirt := Node3D.new()
	skirt.name = "Skirt"
	root.add_child(skirt)
	_pt(skirt, _cn(0.46, 1.04, 16), sand, Vector3(0, 0.52, 0), Vector3(180, 0, 0))
	_pt(skirt, _cy(0.12, 0.05, 10), dark, Vector3(0, 0.03, 0))
	for i in 4:
		var ang := TAU * float(i) / 4.0
		_pt(
			skirt,
			_bx(Vector3(0.05, 0.6, 0.26)),
			plate,
			Vector3(cos(ang) * 0.3, 0.72, sin(ang) * 0.3),
			Vector3(0, rad_to_deg(-ang), 20)
		)
	# Sensor pod sitting on the rim: a flat drum + a low cowl, kept under the capsule top.
	_pt(root, _cy(0.38, 0.07, 14), dark, Vector3(0, 1.03, 0))
	_pt(root, _cy(0.34, 0.22, 14), sand, Vector3(0, 1.14, 0))
	_pt(root, _sp(0.24, true, 8, 14), sand, Vector3(0, 1.24, 0))
	var eye := _pt(root, _bx(Vector3(0.28, 0.06, 0.06)), eye_mat, Vector3(0, 1.3, -0.31))
	eye.name = "Eye"
	# Twin gun tubes flanking the pod (-Z) + rear vents.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_pt(root, _bx(Vector3(0.12, 0.12, 0.16)), dark, Vector3(side * 0.26, 1.14, -0.1))
		_pt(root, _cy(0.055, 0.44, 8), dark, Vector3(side * 0.26, 1.14, -0.3), Vector3(-90, 0, 0))
		_pt(
			root,
			_bx(Vector3(0.1, 0.18, 0.05)),
			dark,
			Vector3(side * 0.16, 1.1, 0.3),
			Vector3(0, side * 15.0, 0)
		)
	return root


## SNOW — Frost-hound: the LOW HORIZONTAL of the roster. A long spine bar barely above the
## ground with the mass thrown forward onto a raised shoulder yoke, the head thrust FORWARD
## at bar height (never perched on a neck), and a rear that tapers away — the profile falls
## from front to back, which nothing else here does. Legs are digitigrade with the hind pair
## carrying an extra hock segment, so the rest pose already reads as a coiled spring and the
## pounce is legible as a compression rather than as a colour change.
## Named parts: "Core" visor slit (script pulse) + "GaitLeg0..3" hips wrapping "Leg0..3".
## Scene: capsule r0.4 h1.0 @y0.5 (top 1.0 — nothing here rises above 0.98); WeakPoint
## r0.22 @(0,0.85,-0.7) → the head box is centred inside that sphere.
static func build_robot_frosthound() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated frost-grey hull; icicle fins keep their translucent-ice
	# read (kept as-is per the sweep rules); legs are bare steel.
	var k := ProcEnemyKits.kit("robot_frosthound")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var ice := ProceduralModels._mat(Color(0.7, 0.88, 0.98), 0.1, 0.25)
	var visor: StandardMaterial3D = k["glow"]
	var leg_mat: StandardMaterial3D = k["steel"]

	# THE BAR: one long calm plate with a dark under-frame running its whole length. The
	# light-over-black pairing is what makes the horizontal survive at 100 m.
	_pt(root, _bx(Vector3(0.3, 0.16, 1.24)), shell, Vector3(0, 0.66, 0.08))
	_pt(root, _bx(Vector3(0.24, 0.13, 1.1)), dark, Vector3(0, 0.55, 0.08))
	# Mass forward: a wide shoulder yoke + cowl over the front legs, and a small rear haunch.
	_pt(root, _bx(Vector3(0.6, 0.32, 0.46)), shell, Vector3(0, 0.72, -0.32))
	_pt(root, _bx(Vector3(0.5, 0.1, 0.34)), shell, Vector3(0, 0.9, -0.28))
	_pt(root, _bx(Vector3(0.44, 0.2, 0.1)), dark, Vector3(0, 0.66, -0.55))
	_pt(root, _bx(Vector3(0.38, 0.24, 0.36)), shell, Vector3(0, 0.64, 0.5))
	# Head thrust forward on a short thick neck; jaw under it; sensor SLIT across the face.
	ProceduralModels._strut(root, Vector3(0, 0.8, -0.5), Vector3(0, 0.86, -0.64), 0.09, dark)
	_pt(root, _bx(Vector3(0.26, 0.2, 0.3)), shell, Vector3(0, 0.86, -0.76))
	_pt(root, _bx(Vector3(0.18, 0.1, 0.22)), dark, Vector3(0, 0.78, -0.88))
	var core := _pt(root, _bx(Vector3(0.22, 0.05, 0.05)), visor, Vector3(0, 0.9, -0.9))
	core.name = "Core"
	# Back-swept sensor prongs + a low icicle ridge + a level tail: all of it lengthens the
	# horizontal instead of raising the profile.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_pt(root, _cn(0.045, 0.2, 6), dark, Vector3(side * 0.11, 0.92, -0.5), Vector3(52, 0, 0))
	for i in 3:
		_pt(
			root,
			_cn(0.07, 0.22 - float(i) * 0.04, 6),
			ice,
			Vector3(0, 0.76, -0.02 + float(i) * 0.3),
			Vector3(18, 0, 0)
		)
	_pt(root, _cn(0.07, 0.34, 6), shell, Vector3(0, 0.66, 0.78), Vector3(104, 0, 0))

	# 4 legs: a "GaitLeg" HIP pivot (the distance-driven stride) wrapping the pouncer script's
	# "Leg%d" pivot (its own time-driven trot sway). Front legs are a simple bent column; the
	# HIND pair gets the extra hock so the machine is visibly loaded, ready to spring.
	var attach: Array[Vector3] = [
		Vector3(-0.2, 0.66, -0.34),
		Vector3(-0.2, 0.62, 0.44),
		Vector3(0.2, 0.66, -0.34),
		Vector3(0.2, 0.62, 0.44)
	]
	var hips := _quad_hips(root, attach)
	for li in 4:
		var side: float = signf(attach[li].x)
		var pivot := Node3D.new()
		pivot.name = "Leg%d" % li
		hips[li].add_child(pivot)
		if li == 0 or li == 2:
			var fknee := Vector3(side * 0.05, -0.3, 0.02)
			_limb(
				pivot,
				[Vector3.ZERO, fknee, Vector3(side * 0.06, -0.6, 0.0)],
				[0.07, 0.05],
				0.055,
				leg_mat,
				dark
			)
			_pt(pivot, _bx(Vector3(0.13, 0.06, 0.22)), dark, Vector3(side * 0.06, -0.63, 0.03))
		else:
			_limb(
				pivot,
				[
					Vector3.ZERO,
					Vector3(side * 0.05, -0.16, 0.13),
					Vector3(side * 0.06, -0.4, -0.05),
					Vector3(side * 0.06, -0.56, 0.02)
				],
				[0.075, 0.055, 0.045],
				0.055,
				leg_mat,
				dark
			)
			_pt(pivot, _bx(Vector3(0.13, 0.06, 0.22)), dark, Vector3(side * 0.06, -0.59, 0.05))
	return root


## SNOW — Cryo-mortar: an emplacement. A WIDE dug-in tripod (thin splayed legs ending in flat
## ground pads) under a squat turntable, and one long tube ELEVATED ~52° — the barrel angle
## is the telegraph all by itself: "this thing is planted and it shells you from over there".
## Named parts: the yaw pivot "Tube" (player-tracked) + the cyan "Core" frost tank.
## Scene: capsule r0.6 h1.4 @y0.7; WeakPoint r0.22 @(0.3,0.9,0.18) → the Core tank is pinned
## exactly there, and the muzzle stays under the 1.4 capsule top.
static func build_robot_cryomortar() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated frost hull; the mortar tube + tripod legs are bare steel.
	var k := ProcEnemyKits.kit("robot_cryomortar")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var frost: StandardMaterial3D = k["glow"]

	# 3 splayed legs. All three hinge at the SAME hub point — that IS the tripod joint — so
	# each gets a hip pivot there and the emplacement shuffles its legs while it repositions
	# (EnemyGait relaxes below walking speed, so a firing mortar still stands perfectly still).
	# The flat PADS at ground level are what read as "dug in" without widening the body.
	var hub := Vector3(0, 0.46, 0)
	for i in 3:
		var ang := TAU * float(i) / 3.0 + 0.5
		var foot := Vector3(cos(ang) * 0.62, 0.06, sin(ang) * 0.62)
		var hip := _gait_hip(root, i, hub)
		ProceduralModels._strut(hip, Vector3.ZERO, foot - hub, 0.06, steel)
		_pt(hip, _sp(0.06, false, 6, 8), dark, foot - hub)
		_pt(hip, _cy(0.17, 0.05, 10), dark, foot - hub + Vector3(0, -0.03, 0))
	# Squat turntable: a low light drum over a dark collar (the two-tone base line).
	_pt(root, _cy(0.44, 0.06, 14), dark, Vector3(0, 0.44, 0))
	_pt(root, _cy(0.4, 0.16, 14), shell, Vector3(0, 0.52, 0))
	_pt(root, _cy(0.19, 0.28, 12), shell, Vector3(0, 0.68, 0.36), Vector3(90, 0, 0))
	# The tube under its yaw pivot: trunnion cheeks, a long barrel raised 52°, muzzle brake.
	var tube := Node3D.new()
	tube.name = "Tube"
	tube.position = Vector3(0, 0.62, 0)
	root.add_child(tube)
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_pt(tube, _bx(Vector3(0.07, 0.22, 0.22)), dark, Vector3(side * 0.21, 0.16, 0.02))
	_pt(tube, _cy(0.115, 1.16, 12), steel, Vector3(0, 0.36, -0.26), Vector3(-52, 0, 0))
	_pt(tube, _cy(0.145, 0.34, 12), dark, Vector3(0, 0.15, -0.0), Vector3(-52, 0, 0))
	_pt(tube, _cy(0.15, 0.13, 12), shell, Vector3(0, 0.71, -0.71), Vector3(-52, 0, 0))
	# Frost tanks: one glowing "Core" (the scene weak point) + a dark twin, both bracketed
	# to the turntable so they no longer float.
	var core := _pt(root, _cy(0.13, 0.4, 10), frost, Vector3(0.3, 0.9, 0.18))
	core.name = "Core"
	_pt(root, _cy(0.13, 0.4, 10), dark, Vector3(-0.3, 0.9, 0.18))
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		ProceduralModels._strut(
			root, Vector3(side * 0.14, 0.58, 0.16), Vector3(side * 0.3, 0.74, 0.18), 0.04, dark
		)
	return root


## SNOW — Avalanche: a SIEGE WALKER, not a brute. A smooth wide carapace slung a metre off
## the ground on four articulated legs — you can see the background straight through the gap
## under it, which is the family signature and is unique in the roster. The knees are the
## fattest parts of the machine (the shootable articulation), the two "Fist0"/"Fist1" rams
## hang INTO that gap and are hauled up against the hull during the slam windup, and the
## chest "Core" is the scene's weak point.
## Scene: capsule r0.7 h2.2 @y1.1; WeakPoint r0.25 @(0,1.55,-0.36) → Core pinned there.
static func build_robot_avalanche() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated white armour; the chest Core hosts the scene weak point,
	# so it keeps its bespoke saturated blue at signage energy; ice slabs kept as-is.
	var k := ProcEnemyKits.kit("robot_avalanche")
	var plate: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var core_mat := ProcPlating.glow(Color(0.35, 0.7, 1.0), 3.5)
	var ice := ProceduralModels._mat(Color(0.7, 0.88, 0.98), 0.1, 0.25)

	# Carapace: one big calm dome, WIDE and shallow (never a torso-shaped box), over a dark
	# chassis slab. Hull underside sits at y1.13 — everything below that is daylight.
	_pt(
		root,
		_sp(0.78, true, 9, 16),
		plate,
		Vector3(0, 1.46, 0),
		Vector3.ZERO,
		Vector3(1.0, 0.62, 0.62)
	)
	_pt(root, _bx(Vector3(1.4, 0.34, 0.86)), dark, Vector3(0, 1.3, 0))
	# The seam ring is SQUASHED in Z to follow the shallow dome — an unscaled disc would ring
	# out to z±0.82 and turn the walker into a flying saucer.
	_pt(root, _cy(0.82, 0.08, 18), dark, Vector3(0, 1.47, 0), Vector3.ZERO, Vector3(1, 1, 0.62))
	var core := _pt(root, _sp(0.16, false, 8, 12), core_mat, Vector3(0, 1.55, -0.5))
	core.name = "Core"
	# Low sensor blister + ice crown slabs breaking the dome outline (kept under the capsule).
	_pt(root, _cy(0.22, 0.16, 12), dark, Vector3(0, 1.98, -0.16))
	_pt(root, _bx(Vector3(0.24, 0.05, 0.06)), core_mat, Vector3(0, 1.99, -0.38))
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_pt(
			root,
			_bx(Vector3(0.34, 0.2, 0.4)),
			ice,
			Vector3(side * 0.44, 1.94, 0.06),
			Vector3(0, 0, side * -12.0)
		)

	# 4 articulated legs. Hips ride the chassis edge; femurs go OUT and UP so the knees are
	# the widest, highest points of the leg and the hull hangs between them.
	var attach: Array[Vector3] = [
		Vector3(-0.62, 1.3, -0.3),
		Vector3(-0.62, 1.3, 0.34),
		Vector3(0.62, 1.3, -0.3),
		Vector3(0.62, 1.3, 0.34)
	]
	var hips := _quad_hips(root, attach)
	for li in 4:
		var side: float = signf(attach[li].x)
		_walker_leg(
			hips[li],
			Vector3(side * 0.3, 0.16, 0),
			Vector3(side * 0.36, -1.2, 0.02),
			Vector2(0.12, 0.09),
			Vector3(0.24, 0.1, 0.32),
			dark,
			steel
		)
	# Pile-driver rams under pivots so the windup can HAUL them up the hull's flanks. They hang
	# FORWARD of the front legs on purpose: the hips now sit where a humanoid's arms used to,
	# and a ram parked beside a leg would be swept through by every stride.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var fist := Node3D.new()
		fist.name = "Fist%d" % i
		fist.position = Vector3(side * 0.76, 0.8, -0.62)
		root.add_child(fist)
		ProceduralModels._strut(
			root, Vector3(side * 0.62, 1.24, -0.44), Vector3(side * 0.74, 0.98, -0.6), 0.11, dark
		)
		_pt(fist, _bx(Vector3(0.34, 0.38, 0.4)), plate, Vector3.ZERO)
		_pt(fist, _bx(Vector3(0.38, 0.14, 0.2)), dark, Vector3(0, -0.16, -0.16))
	return root


## RAIN — Oni: the temple-guardian SIEGE WALKER. Same family outline as the avalanche (a
## carapace held high on four articulated legs, daylight underneath) but wearing the biome's
## language: lacquered flared sode plates, a kabuto crest, hanging kusazuri skirt plates that
## frame the gap without closing it, and a naginata sweeping down into it. NOT a samurai
## man-shape — that humanoid read is exactly what this pass removes.
## Named parts: the glowing mask "Core"; the scene's ×3 weak point is the BACK seal.
## Scene: capsule r0.6 h2.2 @y1.1; WeakPoint r0.3 @(0,1.55,0.4) → the seal is pinned there.
static func build_robot_oni() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): lacquered dark-red hull (kit arch LACQUER); skirt/sode plates
	# keep their brighter red via the ProcPlating.lacquer factory; blade = bare steel;
	# kabuto gold routed through the high-metallic decor recipe (same colour).
	var k := ProcEnemyKits.kit("robot_oni")
	var armor: StandardMaterial3D = k["hull"]
	var lacquer := ProcPlating.lacquer(Color(0.5, 0.12, 0.12), 81)
	var dark: StandardMaterial3D = k["frame"]
	var mask: StandardMaterial3D = k["glow"]
	var steel: StandardMaterial3D = k["steel"]
	var gold := ProceduralModels._mat(Color(0.85, 0.68, 0.25), 0.85, 0.25)

	# Hull: an angular lacquered carapace on a dark chassis (underside at y1.22 = the gap).
	_pt(root, _bx(Vector3(1.05, 0.62, 0.72)), armor, Vector3(0, 1.58, 0))
	_pt(root, _bx(Vector3(1.15, 0.16, 0.6)), dark, Vector3(0, 1.3, 0))
	_pt(root, _bx(Vector3(0.5, 0.06, 0.5)), gold, Vector3(0, 1.9, -0.06))
	# Flared sode plates — the outline break that says "temple", carried by the HULL.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_pt(
			root,
			_bx(Vector3(0.4, 0.46, 0.34)),
			lacquer,
			Vector3(side * 0.66, 1.66, 0),
			Vector3(0, 0, side * -12.0)
		)
		_pt(
			root,
			_cn(0.05, 0.34, 6),
			gold,
			Vector3(side * 0.13, 1.98, -0.16),
			Vector3(0, 0, side * -24.0)
		)
	_pt(root, _sp(0.2, true, 8, 12), armor, Vector3(0, 1.86, -0.14))
	var face := _pt(root, _bx(Vector3(0.26, 0.2, 0.06)), mask, Vector3(0, 1.8, -0.4))
	face.name = "Core"
	# BACK seal — the glowing plate marking the scene's ×3 weak point (+Z).
	_pt(root, _bx(Vector3(0.3, 0.3, 0.05)), mask, Vector3(0, 1.55, 0.4))
	# Kusazuri: plates hanging off the hull edge INTO the gap — they frame it, never fill it.
	# The row is kept narrower than the hip sockets so a swinging leg never saws through one.
	for i in 3:
		var a := -0.26 + float(i) * 0.26
		_pt(
			root, _bx(Vector3(0.22, 0.34, 0.05)), lacquer, Vector3(a, 1.13, -0.32), Vector3(9, 0, 0)
		)
		_pt(
			root, _bx(Vector3(0.22, 0.34, 0.05)), lacquer, Vector3(a, 1.13, 0.32), Vector3(-9, 0, 0)
		)
	# Naginata arm (right) sweeping down-forward, and a short grip claw on the left — both
	# carried FORWARD of the front legs, which now occupy the old humanoid arm space.
	ProceduralModels._strut(root, Vector3(0.52, 1.5, -0.1), Vector3(0.8, 1.16, -0.42), 0.09, dark)
	_pt(root, _bx(Vector3(0.05, 0.98, 0.15)), steel, Vector3(0.89, 0.78, -0.68), Vector3(32, 0, 0))
	ProceduralModels._strut(root, Vector3(-0.52, 1.5, -0.1), Vector3(-0.7, 1.2, -0.44), 0.09, dark)
	_pt(root, _bx(Vector3(0.22, 0.22, 0.24)), armor, Vector3(-0.72, 1.12, -0.5))

	# 4 articulated legs — slimmer and taller than the avalanche's, same inverted-V.
	var attach: Array[Vector3] = [
		Vector3(-0.52, 1.24, -0.26),
		Vector3(-0.52, 1.24, 0.3),
		Vector3(0.52, 1.24, -0.26),
		Vector3(0.52, 1.24, 0.3)
	]
	var hips := _quad_hips(root, attach)
	for li in 4:
		var side: float = signf(attach[li].x)
		_walker_leg(
			hips[li],
			Vector3(side * 0.26, 0.14, 0),
			Vector3(side * 0.3, -1.16, 0.02),
			Vector2(0.1, 0.075),
			Vector3(0.2, 0.08, 0.28),
			dark,
			steel
		)
	return root


## RAIN — Kappa: the hound family's second read — same LOW HORIZONTAL, but sprawled instead
## of digitigrade: a wide flat carapace with a dark rim line, legs that go OUT to knees at
## belly height before dropping (a crocodilian sprawl, so it is never mistaken for the
## frost-hound at distance), and a head craned up on a short neck under its dish crown.
## Named parts: the "Core" eye slit + "GaitLeg0..3" hips wrapping "Leg0..3" (pouncer sway).
## Scene: capsule r0.45 h1.2 @y0.6; WeakPoint r0.2 @(0,1.06,-0.45) → the head sits in it.
static func build_robot_kappa() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated swamp-green hull; claws are bare steel.
	var k := ProcEnemyKits.kit("robot_kappa")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var eye_mat: StandardMaterial3D = k["glow"]
	var claw: StandardMaterial3D = k["steel"]

	# Carapace: wide, flat and LONG, with a dark rim disc under it — that light-plate-over-
	# black-lip pairing is the whole horizontal read.
	_pt(
		root,
		_sp(0.46, true, 8, 16),
		shell,
		Vector3(0, 0.72, 0.08),
		Vector3.ZERO,
		Vector3(1.0, 0.42, 1.25)
	)
	_pt(root, _cy(0.47, 0.07, 18), dark, Vector3(0, 0.71, 0.08))
	_pt(root, _bx(Vector3(0.4, 0.14, 0.66)), dark, Vector3(0, 0.6, 0.08))
	for i in 3:
		_pt(
			root,
			_cn(0.06, 0.15, 6),
			shell,
			Vector3(0, 0.9, -0.12 + float(i) * 0.22),
			Vector3(-20, 0, 0)
		)
	# Craned head: short neck, beaked skull, dish crown (the kappa's identity) + eye slit.
	ProceduralModels._strut(root, Vector3(0, 0.82, -0.38), Vector3(0, 1.0, -0.44), 0.085, dark)
	_pt(root, _bx(Vector3(0.24, 0.18, 0.26)), shell, Vector3(0, 1.04, -0.48))
	_pt(root, _cy(0.17, 0.05, 12), shell, Vector3(0, 1.14, -0.48))
	_pt(root, _cn(0.07, 0.2, 6), claw, Vector3(0, 1.0, -0.64), Vector3(-100, 0, 0))
	var eyes := _pt(root, _bx(Vector3(0.2, 0.05, 0.05)), eye_mat, Vector3(0, 1.06, -0.6))
	eyes.name = "Core"
	# Claw arms reaching forward past the shell.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		ProceduralModels._strut(
			root, Vector3(side * 0.26, 0.78, -0.26), Vector3(side * 0.42, 0.46, -0.42), 0.06, dark
		)
		_pt(root, _cn(0.07, 0.22, 6), claw, Vector3(side * 0.44, 0.38, -0.5), Vector3(-115, 0, 0))

	# 4 SPRAWLED legs: the femur runs almost horizontally out to a knee at belly height, then
	# the shin drops straight down — a wide low stance the frost-hound never makes.
	var attach: Array[Vector3] = [
		Vector3(-0.2, 0.66, -0.18),
		Vector3(-0.2, 0.66, 0.3),
		Vector3(0.2, 0.66, -0.18),
		Vector3(0.2, 0.66, 0.3)
	]
	var hips := _quad_hips(root, attach)
	for li in 4:
		var side: float = signf(attach[li].x)
		var pivot := Node3D.new()
		pivot.name = "Leg%d" % li
		hips[li].add_child(pivot)
		_limb(
			pivot,
			[Vector3.ZERO, Vector3(side * 0.18, -0.05, 0.0), Vector3(side * 0.2, -0.6, 0.04)],
			[0.06, 0.05],
			0.062,
			dark,
			claw
		)
		_pt(pivot, _bx(Vector3(0.16, 0.06, 0.2)), claw, Vector3(side * 0.2, -0.63, 0.05))
	return root


## RAIN — Raiju: the ANTI-hound. Where the hound family hugs the ground, this one is all
## clearance and height: long thin legs, an arched slim spine, a high head and a forked
## antler crown — a stag outline nothing else in the roster competes with, which is what
## keeps two rain quadrupeds (kappa and raiju) from reading as the same machine.
## Named parts: "Antler0"/"Antler1" quiver pivots (the script OVERWRITES their rotation.z,
## so the pivots stay unrotated and the tilt lives on their children) + the chest "Core".
## Scene: capsule r0.4 h1.0 @y0.5; WeakPoint r0.2 @(0,0.92,-0.7) → the head sits in it.
static func build_robot_raiju() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated storm-blue hull; core/fins/antlers share the identity
	# electric glow (kit energy, down from the old neon 7.0); legs are bare steel.
	var k := ProcEnemyKits.kit("robot_raiju")
	var body: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var bolt: StandardMaterial3D = k["glow"]
	var leg_mat: StandardMaterial3D = k["steel"]

	# Arched spine: three short plates stepping up toward the haunches, deep chest at the
	# front. High belly line = the daylight under it is part of the read.
	_pt(root, _bx(Vector3(0.26, 0.22, 0.3)), body, Vector3(0, 0.72, -0.38))
	_pt(root, _bx(Vector3(0.24, 0.18, 0.42)), body, Vector3(0, 0.76, -0.1), Vector3(-6, 0, 0))
	_pt(root, _bx(Vector3(0.22, 0.16, 0.42)), body, Vector3(0, 0.74, 0.28), Vector3(8, 0, 0))
	_pt(root, _bx(Vector3(0.18, 0.1, 0.9)), dark, Vector3(0, 0.62, 0.0))
	# Neck + head high and forward, muzzle down.
	ProceduralModels._strut(root, Vector3(0, 0.8, -0.44), Vector3(0, 0.94, -0.62), 0.06, dark)
	_pt(root, _bx(Vector3(0.18, 0.16, 0.26)), body, Vector3(0, 0.94, -0.72))
	_pt(root, _cn(0.05, 0.16, 6), dark, Vector3(0, 0.9, -0.88), Vector3(-100, 0, 0))
	var core := _pt(root, _sp(0.09, false, 8, 12), bolt, Vector3(0, 0.72, -0.56))
	core.name = "Core"
	for i in 2:
		_pt(
			root,
			_bx(Vector3(0.04, 0.16, 0.2)),
			bolt,
			Vector3(0, 0.88, -0.06 + float(i) * 0.34),
			Vector3(-16, 0, 0)
		)
	# Forked antler racks under quiver pivots (pivot rotation stays ZERO — script contract).
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var ant := Node3D.new()
		ant.name = "Antler%d" % i
		ant.position = Vector3(side * 0.09, 1.02, -0.66)
		root.add_child(ant)
		_pt(
			ant,
			_cn(0.03, 0.3, 5),
			bolt,
			Vector3(side * 0.05, 0.13, 0.02),
			Vector3(0, 0, -side * 20.0)
		)
		_pt(
			ant,
			_cn(0.022, 0.18, 5),
			bolt,
			Vector3(side * 0.12, 0.2, -0.04),
			Vector3(-14, 0, -side * 44.0)
		)
	_pt(root, _cn(0.09, 0.46, 6), body, Vector3(0, 0.76, 0.6), Vector3(122, 0, 0))

	# 4 long thin legs — the hips sit HIGH and the shins are nearly straight, so the machine
	# stands tall on stilts instead of crouching like the hound.
	var attach: Array[Vector3] = [
		Vector3(-0.14, 0.66, -0.3),
		Vector3(-0.15, 0.68, 0.36),
		Vector3(0.14, 0.66, -0.3),
		Vector3(0.15, 0.68, 0.36)
	]
	var hips := _quad_hips(root, attach)
	for li in 4:
		var a: Vector3 = attach[li]
		var side: float = signf(a.x)
		var back: float = 0.1 if (li == 1 or li == 3) else -0.06
		_limb(
			hips[li],
			[
				Vector3.ZERO,
				Vector3(side * 0.03, -0.3, back),
				Vector3(side * 0.05, -a.y + 0.05, 0.02)
			],
			[0.045, 0.035],
			0.042,
			leg_mat,
			dark
		)
		_pt(
			hips[li], _bx(Vector3(0.09, 0.05, 0.14)), dark, Vector3(side * 0.05, -a.y + 0.025, 0.03)
		)
	return root


# ================================================================= BIOME MINIBOSSES (v0.3)
# Oversized landmark threats — each is its biome grunt's FAMILY outline scaled up with extra
# plating (the point of a miniboss is "that one, but wrong-sized", so the family read has to
# survive). They reuse the SAME named animation parts as their base archetype (slammer
# Fist0/Fist1 + Core, strafer Skirt + Eye, oni back-seal, flyer RotorHub + Body + Core) so
# the inherited _animate_visual binds with no script change. ModelRoot at y=0.


## SNOW miniboss — Snow Golem: the avalanche's siege-walker outline at ~1.6×. A colossal
## carapace held nearly two metres off the ground on four articulated legs — the gap is big
## enough to walk a player through, which is the whole joke of the silhouette. Oversized
## "Fist0"/"Fist1" rams hang into it; the pale-cyan chest "Core" is the scene's weak point.
## Scene: WeakPoint r0.4 @(0,2.48,-0.576) → Core pinned there (capsule r0.7 h2.2 as authored).
static func build_robot_snow_golem() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated glacial armour; the boss core keeps its bespoke pale
	# cyan at signage energy; ice slabs kept as-is.
	var glow_col := Color(0.55, 0.85, 1.0)  # pale cyan
	var k := ProcEnemyKits.kit("robot_snow_golem")
	var plate: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var core_mat := ProcPlating.glow(glow_col, 3.5)
	var ice := ProceduralModels._mat(Color(0.72, 0.9, 1.0), 0.1, 0.22)

	# Carapace + chassis slab: underside at y1.84, so there is ~1.8 m of daylight under it.
	_pt(
		root,
		_sp(1.1, true, 10, 18),
		plate,
		Vector3(0, 2.3, 0),
		Vector3.ZERO,
		Vector3(1.0, 0.56, 0.6)
	)
	_pt(root, _bx(Vector3(2.0, 0.44, 1.2)), dark, Vector3(0, 2.06, 0))
	# Seam ring squashed in Z to follow the dome (an unscaled disc would ring out to z±1.16).
	_pt(root, _cy(1.16, 0.1, 20), dark, Vector3(0, 2.32, 0), Vector3.ZERO, Vector3(1, 1, 0.6))
	var core := _pt(root, _sp(0.22, false, 8, 12), core_mat, Vector3(0, 2.48, -0.68))
	core.name = "Core"
	# Sensor blister + jagged ice crown on the dome.
	_pt(root, _cy(0.3, 0.22, 12), dark, Vector3(0, 2.9, -0.2))
	_pt(root, _bx(Vector3(0.3, 0.06, 0.06)), core_mat, Vector3(0, 2.93, -0.42))
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_pt(
			root,
			_bx(Vector3(0.5, 0.28, 0.56)),
			ice,
			Vector3(side * 0.66, 2.86, 0.06),
			Vector3(0, 0, side * -12.0)
		)
		_pt(
			root,
			_cn(0.12, 0.4, 6),
			ice,
			Vector3(side * 0.66, 2.94, 0.06),
			Vector3(0, 0, side * -10.0)
		)

	var attach: Array[Vector3] = [
		Vector3(-0.95, 2.02, -0.45),
		Vector3(-0.95, 2.02, 0.52),
		Vector3(0.95, 2.02, -0.45),
		Vector3(0.95, 2.02, 0.52)
	]
	var hips := _quad_hips(root, attach)
	for li in 4:
		var side: float = signf(attach[li].x)
		_walker_leg(
			hips[li],
			Vector3(side * 0.42, 0.26, 0),
			Vector3(side * 0.46, -1.88, 0.02),
			Vector2(0.18, 0.13),
			Vector3(0.36, 0.14, 0.48),
			dark,
			steel
		)
	# OVERSIZED rams under pivots so the slam windup can RAISE them up the hull.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var fist := Node3D.new()
		fist.name = "Fist%d" % i
		fist.position = Vector3(side * 1.1, 1.12, -0.95)
		root.add_child(fist)
		ProceduralModels._strut(
			root, Vector3(side * 0.95, 1.9, -0.62), Vector3(side * 1.06, 1.4, -0.88), 0.15, dark
		)
		_pt(fist, _bx(Vector3(0.52, 0.58, 0.62)), plate, Vector3.ZERO)
		_pt(fist, _bx(Vector3(0.56, 0.2, 0.26)), dark, Vector3(0, -0.26, -0.24))
		for ki in 3:
			_pt(
				fist,
				_cn(0.06, 0.2, 5),
				ice,
				Vector3(-0.16 + float(ki) * 0.16, 0.0, -0.36),
				Vector3(-90, 0, 0)
			)
	return root


## DESERT miniboss — Dune Warden: the dust-devil's whirl-gunner outline at ~1.45×. A wide
## inverted sand cone under a heavy sensor pod and a triple barrel cluster ("Barrel"); the
## strafer animator only spins the "Skirt" and pulses the "Eye", but the cluster carries the
## heavy-gunner read. Scene: WeakPoint r0.319 @(0,2.059,-0.29) → the Eye sits inside it.
static func build_robot_dune_warden() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated sand armour; the boss Eye keeps its bespoke amber at
	# signage energy; skirt vanes carry the accent paint; gun cluster is bare steel.
	var glow_col := Color(0.95, 0.62, 0.22)  # desert amber
	var k := ProcEnemyKits.kit("robot_dune_warden")
	var sand: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var eye_mat := ProcPlating.glow(glow_col, 3.5)
	var plate: StandardMaterial3D = k["accent"]
	var gun: StandardMaterial3D = k["steel"]

	var skirt := Node3D.new()
	skirt.name = "Skirt"
	root.add_child(skirt)
	_pt(skirt, _cn(0.66, 1.5, 18), sand, Vector3(0, 0.75, 0), Vector3(180, 0, 0))
	_pt(skirt, _cy(0.16, 0.06, 10), dark, Vector3(0, 0.04, 0))
	for i in 5:
		var ang := TAU * float(i) / 5.0
		_pt(
			skirt,
			_bx(Vector3(0.07, 0.86, 0.36)),
			plate,
			Vector3(cos(ang) * 0.42, 1.02, sin(ang) * 0.42),
			Vector3(0, rad_to_deg(-ang), 18)
		)
	# Heavy pod on the rim.
	_pt(root, _cy(0.54, 0.1, 16), dark, Vector3(0, 1.48, 0))
	_pt(root, _cy(0.48, 0.32, 16), sand, Vector3(0, 1.65, 0))
	_pt(root, _sp(0.36, true, 8, 16), sand, Vector3(0, 1.8, 0))
	var eye := _pt(root, _bx(Vector3(0.4, 0.09, 0.08)), eye_mat, Vector3(0, 1.94, -0.42))
	eye.name = "Eye"
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_pt(
			root,
			_bx(Vector3(0.14, 0.26, 0.06)),
			dark,
			Vector3(side * 0.24, 1.62, 0.44),
			Vector3(0, side * 15.0, 0)
		)
	# Triple barrel cluster on a side arm (-Z), under "Barrel".
	var barrel := Node3D.new()
	barrel.name = "Barrel"
	barrel.position = Vector3(0.62, 1.62, -0.2)
	root.add_child(barrel)
	_pt(barrel, _bx(Vector3(0.24, 0.24, 0.34)), gun, Vector3.ZERO)
	for i in 3:
		_pt(
			barrel,
			_cy(0.05, 0.6, 8),
			gun,
			Vector3(-0.1 + float(i) * 0.1, 0.02, -0.42),
			Vector3(-90, 0, 0)
		)
	return root


## RAIN miniboss — Oni Chief: the oni's siege-walker outline at ~1.4×. Broad lacquered
## carapace on four heavy articulated legs, a horned kabuto crest, the glowing mask "Core",
## a spiked tetsubo swinging into the gap, and the bright BACK seal (+Z) marking the scene's
## ×3 weak point. Scene: WeakPoint r0.42 @(0,2.17,0.56) → the seal is pinned there.
static func build_robot_oni_chief() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): lacquered crimson hull (kit arch LACQUER); skirt/sode plates
	# via the ProcPlating.lacquer factory; boss mask keeps its bespoke crimson at
	# signage energy; kabuto gold routed through the high-metallic decor recipe.
	var glow_col := Color(0.75, 0.18, 0.15)  # crimson
	var k := ProcEnemyKits.kit("robot_oni_chief")
	var armor: StandardMaterial3D = k["hull"]
	var lacquer := ProcPlating.lacquer(Color(0.62, 0.14, 0.13), 105)
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var mask := ProcPlating.glow(glow_col, 3.5)
	var gold := ProceduralModels._mat(Color(0.85, 0.68, 0.25), 0.85, 0.25)

	_pt(root, _bx(Vector3(1.35, 0.8, 0.92)), armor, Vector3(0, 2.16, 0))
	_pt(root, _bx(Vector3(1.46, 0.2, 0.78)), dark, Vector3(0, 1.78, 0))
	_pt(root, _bx(Vector3(0.66, 0.07, 0.62)), gold, Vector3(0, 2.58, -0.08))
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_pt(
			root,
			_bx(Vector3(0.52, 0.6, 0.44)),
			lacquer,
			Vector3(side * 0.86, 2.28, 0),
			Vector3(0, 0, side * -12.0)
		)
		_pt(
			root,
			_cn(0.06, 0.44, 6),
			gold,
			Vector3(side * 0.17, 2.72, -0.2),
			Vector3(0, 0, side * -24.0)
		)
	_pt(root, _sp(0.28, true, 8, 12), armor, Vector3(0, 2.54, -0.18))
	var face := _pt(root, _bx(Vector3(0.32, 0.26, 0.07)), mask, Vector3(0, 2.46, -0.5))
	face.name = "Core"
	# BACK seal — the bright glowing plate on its gold backing (+Z).
	_pt(root, _bx(Vector3(0.5, 0.5, 0.04)), gold, Vector3(0, 2.17, 0.5))
	_pt(root, _bx(Vector3(0.4, 0.4, 0.06)), mask, Vector3(0, 2.17, 0.54))
	# Kusazuri plates hanging off the hull edge into the gap, kept inside the hip sockets.
	for i in 3:
		var a := -0.36 + float(i) * 0.36
		_pt(root, _bx(Vector3(0.3, 0.42, 0.06)), lacquer, Vector3(a, 1.56, -0.42), Vector3(9, 0, 0))
		_pt(root, _bx(Vector3(0.3, 0.42, 0.06)), lacquer, Vector3(a, 1.56, 0.42), Vector3(-9, 0, 0))
	# Tetsubo club arm (right) + a grip claw (left), both carried forward of the front legs.
	ProceduralModels._strut(root, Vector3(0.7, 2.06, -0.14), Vector3(1.04, 1.6, -0.48), 0.11, dark)
	_pt(root, _bx(Vector3(0.2, 0.95, 0.2)), steel, Vector3(1.12, 1.16, -0.78), Vector3(30, 0, 0))
	for ki in 4:
		_pt(
			root,
			_cn(0.06, 0.16, 5),
			gold,
			Vector3(1.12, 0.94 + float(ki) * 0.18, -0.9),
			Vector3(-60, 0, 0)
		)
	ProceduralModels._strut(root, Vector3(-0.7, 2.06, -0.14), Vector3(-1.0, 1.66, -0.5), 0.11, dark)
	_pt(root, _bx(Vector3(0.3, 0.3, 0.32)), armor, Vector3(-1.02, 1.56, -0.62))

	var attach: Array[Vector3] = [
		Vector3(-0.72, 1.7, -0.36),
		Vector3(-0.72, 1.7, 0.42),
		Vector3(0.72, 1.7, -0.36),
		Vector3(0.72, 1.7, 0.42)
	]
	var hips := _quad_hips(root, attach)
	for li in 4:
		var side: float = signf(attach[li].x)
		_walker_leg(
			hips[li],
			Vector3(side * 0.36, 0.2, 0),
			Vector3(side * 0.42, -1.59, 0.02),
			Vector2(0.14, 0.105),
			Vector3(0.28, 0.11, 0.38),
			dark,
			steel
		)
	return root


## RECON drone — Specter: a slim hovering scout that reads by NEGATIVE SPACE (research §2):
## four DUCTED rotor rings around a thin chassis, so at distance it is a row of holes rather
## than a body. Chassis "Body" (bobbed), 4-rotor ring under "RotorHub" (Rotor0..Rotor3 spin),
## one cyan lens "Core", a tall antenna. ~0.9 m span; hovers.
static func build_robot_specter() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): mech-hull chassis, bare-steel rotor blades, identity-cyan lens.
	var k := ProcEnemyKits.kit("robot_specter")
	var body: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var rotor: StandardMaterial3D = k["steel"]
	var lens: StandardMaterial3D = k["glow"]

	# A body pivot wrapping the slim chassis + lens + antenna so the script bobs just the
	# body (named "Body") without moving the rotors' spin hub.
	var bodyp := Node3D.new()
	bodyp.name = "Body"
	root.add_child(bodyp)
	_pt(bodyp, _bx(Vector3(0.34, 0.12, 0.5)), body, Vector3.ZERO)
	_pt(bodyp, _sp(0.13, true, 8, 12), dark, Vector3(0, 0.05, 0))
	var core := _pt(bodyp, _sp(0.1, false, 10, 14), lens, Vector3(0, 0.0, -0.26))
	core.name = "Core"
	# Tall sensor antenna with a glowing tip.
	ProceduralModels._strut(bodyp, Vector3(0, 0.04, 0.14), Vector3(0, 0.34, 0.18), 0.012, dark)
	_pt(bodyp, _sp(0.03, false, 6, 8), lens, Vector3(0, 0.36, 0.18))
	# Four rotor arms to the diagonals: each disc under its own pivot in "RotorHub", ringed
	# by a DUCT — the holes are the silhouette.
	var hub := Node3D.new()
	hub.name = "RotorHub"
	root.add_child(hub)
	var arms := [
		Vector3(0.26, 0.06, 0.26),
		Vector3(-0.26, 0.06, 0.26),
		Vector3(0.26, 0.06, -0.26),
		Vector3(-0.26, 0.06, -0.26)
	]
	var ri := 0
	for tip in arms:
		var tv: Vector3 = tip
		ProceduralModels._strut(root, Vector3(tv.x * 0.4, 0.02, tv.z * 0.4), tv, 0.02, dark)
		var pivot := Node3D.new()
		pivot.name = "Rotor%d" % ri
		pivot.position = tv + Vector3(0, 0.015, 0)
		hub.add_child(pivot)
		_pt(pivot, _cy(0.09, 0.02, 12), rotor)
		_pt(pivot, _bx(Vector3(0.2, 0.028, 0.03)), dark, Vector3(0, 0.015, 0))
		_pt(pivot, _bx(Vector3(0.03, 0.028, 0.2)), dark, Vector3(0, 0.015, 0))
		_pt(root, _ring(0.13, 0.17, 14, 5), body, tv + Vector3(0, 0.01, 0))
		ri += 1
	return root
