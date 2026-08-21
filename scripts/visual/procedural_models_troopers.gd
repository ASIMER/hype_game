class_name ProceduralModelsTroopers
extends RefCounted
## The three STARTER bots (grunt / heavy / elite) as procedural DIGITIGRADE mechs.
##
## v0.5-B4 rebuilt them off the .glb mascot; THIS pass fixes what the owner actually
## complained about — "the enemies barely differ, they are all humanoid and share one
## signature". These three were the worst offenders: straight human legs, a neck, a boxy
## head with a PAIR OF EYES. Per docs/research/model-overhaul-research.md §2-3 a machine
## is 15-31 px at 100 m, so only the OUTLINE, one light mass and one emissive survive that
## range — every fix here therefore lives in the silhouette:
##   * DIGITIGRADE legs — femur down-FORWARD, tibia down-BACK (the hock reads as a knee
##     bending the wrong way), a long metatarsus onto a toe pad. No boot, no heel.
##   * NO NECK — the skull is wedged between two shoulder blocks on a dark collar.
##   * ONE HORIZONTAL SENSOR SLIT under a brow hood. Never a pair of eyes.
##   * Inverted-trapezoid torso (flared chest, cinched pelvis) and arms ending in WEAPON
##     MOUNTS — barrel cluster right, breaching clamp left — instead of hands.
##   * TIER = MASS and SHOULDER SPAN, not height: grunt lean, heavy a squat bunker of
##     double pauldrons / hip skirts / exhaust stacks, elite the lean frame plus a swept
##     commander crest, gorget wings and gold trims.
##
## Contracts this file MUST keep (found by audit — do not "clean them up"):
##   * "Rig" + "GaitLeg0/1" — EnemyGait swings those pivots around X and bobs the
##     assembly; leg parts are children of the pivot, authored MINUS the pivot position.
##   * Feet sit at the NEGATIVE of each scene's ModelRoot Y (grunt/elite -0.8, heavy
##     -0.95) so the machine stands on the ground without touching a .tscn.
##   * Mass stays inside the scene capsule (grunt/elite r0.45 h1.6, heavy r0.65 h1.9) and
##     the head inside the scene's WeakPoint sphere (y1.5 / y1.82 / y1.55) — art outside
##     the capsule eats bullets, a head outside the sphere kills the headshot.
##   * Materials come from ProcEnemyKits (light plate over black frame) and every part
##     goes through ProceduralModels._part (the hit-flash material_override contract).
## Deliberately NOT naming any part "Eye"/"Leg%d": those switch on robot_enemy's idle
## animation, which drives the very node EnemyGait already bobs.

const IDS := ["robot_grunt", "robot_heavy", "robot_elite"]

## Per-id frame. wf = width factor; stance = leg-pivot X; span = OUTER pauldron edge
## (capsule-limited: 0.45 grunt/elite, 0.65 heavy); hip/yoke/head = the three key heights
## (hip pivot, shoulder yoke, skull centre); hw = skull width; bar = sensor-slit width;
## foot_y = -(the scene's ModelRoot.y). Heavy's legs are the SHORTEST of the three — its
## bulk is torso and shoulders, which is what makes it read as a bunker and not a giant.
const _SPECS: Dictionary = {
	"robot_grunt":
	{
		"wf": 1.0,
		"stance": 0.16,
		"span": 0.385,
		"hip": 0.88,
		"yoke": 1.36,
		"head": 1.46,
		"hw": 0.25,
		"bar": 0.17,
		"foot_y": -0.8
	},
	"robot_heavy":
	{
		"wf": 1.3,
		"stance": 0.26,
		"span": 0.6,
		"hip": 0.86,
		"yoke": 1.46,
		"head": 1.72,
		"hw": 0.3,
		"bar": 0.15,
		"foot_y": -0.95
	},
	"robot_elite":
	{
		"wf": 1.06,
		"stance": 0.17,
		"span": 0.39,
		"hip": 0.9,
		"yoke": 1.36,
		"head": 1.5,
		"hw": 0.25,
		"bar": 0.19,
		"foot_y": -0.8
	}
}


static func build(id: String) -> Node3D:
	var spec: Dictionary = _SPECS.get(id, {})
	if spec.is_empty():
		return null
	return _trooper(id, spec)


## Assemble one trooper: the ground-level rig pivot, then legs → torso → arms → head →
## the per-id identity details, all on the shared kit materials.
static func _trooper(id: String, spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = id + "_model"
	var rig := Node3D.new()
	rig.name = "Rig"
	rig.position = Vector3(0.0, float(spec["foot_y"]), 0.0)
	root.add_child(rig)
	var k: Dictionary = ProcEnemyKits.kit(id)
	var d: Dictionary = _dims(spec)
	_leg(rig, 0, d, k)
	_leg(rig, 1, d, k)
	_torso(rig, d, k)
	_arms(rig, d, k)
	_head(rig, d, k)
	_details(rig, id, d, k)
	return root


## Derived body dimensions, computed ONCE and handed to every sub-builder so the plates,
## the yoke and the identity details can never drift out of register with each other.
## td = torso depth, bot/th/mid = the torso box (bottom, height, centre).
static func _dims(spec: Dictionary) -> Dictionary:
	var wf: float = spec["wf"]
	var hip: float = spec["hip"]
	var yoke: float = spec["yoke"]
	var bot: float = hip + 0.14
	var top: float = yoke - 0.055
	return {
		"wf": wf,
		"hip": hip,
		"yoke": yoke,
		"span": float(spec["span"]),
		"stance": float(spec["stance"]),
		"head": float(spec["head"]),
		"hw": float(spec["hw"]),
		"bar": float(spec["bar"]),
		"td": 0.26 * wf,
		"bot": bot,
		"th": top - bot,
		"mid": (bot + top) * 0.5
	}


## One DIGITIGRADE leg under its named gait pivot. The chain is authored in the PIVOT's
## own frame (hip at the origin) so EnemyGait's X swing carries the whole limb: femur down
## and FORWARD to the knee, tibia down and BACK to the hock (the backwards joint that
## kills the "person in armour" read), then a long metatarsus forward onto a toe pad.
## Joints are near-black balls between light plates — the research's "density at the
## joints, calm plates in between", and the thing that makes the zig-zag legible.
static func _leg(rig: Node3D, i: int, d: Dictionary, k: Dictionary) -> void:
	var wf: float = d["wf"]
	var hip: float = d["hip"]
	var sx: float = -1.0 if i == 0 else 1.0
	var pivot := Node3D.new()
	pivot.name = "GaitLeg%d" % i
	pivot.position = Vector3(sx * float(d["stance"]), hip, 0.0)
	rig.add_child(pivot)
	var hull: StandardMaterial3D = k["hull"]
	var frame: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var knee := Vector3(0.0, hip * 0.62 - hip, -0.15 * wf)
	var hock := Vector3(0.0, hip * 0.29 - hip, 0.16 * wf)
	var toe := Vector3(0.0, 0.05 * wf - hip, -0.08 * wf)
	ProceduralModels._part(pivot, ProceduralModels._sphere(0.115 * wf), frame)
	_seg(pivot, hull, Vector3.ZERO, knee, 0.19 * wf, 0.21 * wf)
	ProceduralModels._part(pivot, ProceduralModels._sphere(0.095 * wf), frame, knee)
	_seg(pivot, hull, knee, hock, 0.165 * wf, 0.155 * wf)
	ProceduralModels._part(pivot, ProceduralModels._sphere(0.085 * wf), frame, hock)
	# Heel spur: a plate kicking BACK off the hock. Cheapest possible way to shout
	# "this joint bends the other way" at silhouette range.
	_plate(
		pivot,
		hull,
		hock + Vector3(0.0, 0.035, 0.08 * wf),
		Vector3(0.13 * wf, 0.17, 0.09),
		Vector3(20, 0, 0)
	)
	_seg(pivot, frame, hock, toe, 0.12 * wf, 0.12 * wf)
	# Toe pad. The Y term cancels the tilt's corner drop (which scales with the pad depth,
	# i.e. with wf) so all three tiers plant their feet ON the floor, never sunk into it.
	_plate(
		pivot,
		steel,
		toe + Vector3(0.0, 0.011 * wf - 0.028, -0.035 * wf),
		Vector3(0.17 * wf, 0.05, 0.24 * wf),
		Vector3(-5, 0, 0)
	)


## Torso: an INVERTED TRAPEZOID. A cinched near-black pelvis, a dark inner frame, light
## plates that flare outward as they rise, a wide shoulder yoke, and the two blocks the
## skull sinks between — that notch between two humps is the family's read at 100 m.
static func _torso(rig: Node3D, d: Dictionary, k: Dictionary) -> void:
	var wf: float = d["wf"]
	var hip: float = d["hip"]
	var yoke: float = d["yoke"]
	var td: float = d["td"]
	var th: float = d["th"]
	var mid: float = d["mid"]
	var hull: StandardMaterial3D = k["hull"]
	var frame: StandardMaterial3D = k["frame"]
	_plate(rig, frame, Vector3(0, hip + 0.04, 0), Vector3(0.3 * wf, 0.22, td * 0.82))
	_plate(rig, frame, Vector3(0, mid, 0), Vector3(0.32 * wf, th, td * 0.86))
	_plate(
		rig,
		hull,
		Vector3(0, mid + 0.015, -(td * 0.5 + 0.03)),
		Vector3(0.36 * wf, th * 0.88, 0.08),
		Vector3(-5, 0, 0)
	)
	for i in 2:
		var sx: float = -1.0 if i == 0 else 1.0
		_plate(
			rig,
			hull,
			Vector3(sx * 0.2 * wf, mid, 0),
			Vector3(0.13 * wf, th * 0.96, td * 0.9),
			Vector3(0, 0, -16.0 * sx)
		)
	_plate(rig, hull, Vector3(0, mid + 0.05, td * 0.5 + 0.03), Vector3(0.3 * wf, th * 0.72, 0.11))
	_plate(
		rig, hull, Vector3(0, yoke, -0.02 * wf), Vector3(float(d["span"]) * 1.72, 0.12, td * 0.95)
	)
	# Shoulder blocks: they rise from the yoke to the skull, so there is no neck to see.
	var t_bot: float = yoke + 0.05
	var t_top: float = maxf(float(d["head"]) - 0.06, t_bot + 0.1)
	for j in 2:
		var sj: float = -1.0 if j == 0 else 1.0
		_plate(
			rig,
			hull,
			Vector3(sj * 0.19 * wf, (t_bot + t_top) * 0.5, 0.01),
			Vector3(0.14 * wf, t_top - t_bot, 0.2 * wf),
			Vector3(0, 0, -7.0 * sj)
		)
	# The 10% channel + the two SECONDARY emissives (slit stays the primary signal).
	_plate(
		rig,
		k["accent"],
		Vector3(0, mid - th * 0.3, -(td * 0.5 + 0.075)),
		Vector3(0.16 * wf, 0.035, 0.02)
	)
	_plate(
		rig, k["glow"], Vector3(0, mid + th * 0.32, -(td * 0.5 + 0.078)), Vector3(0.05, 0.035, 0.02)
	)


## Arms are MOUNTS, not limbs: a big plated pauldron over a dark stub arm ending in a
## weapon block — barrel cluster on the right, breaching clamp on the left. The asymmetry
## is deliberate: it tells you which side the gun is on from across the map, and no part
## of it reads as a hand.
static func _arms(rig: Node3D, d: Dictionary, k: Dictionary) -> void:
	var wf: float = d["wf"]
	var yoke: float = d["yoke"]
	var span: float = d["span"]
	var hull: StandardMaterial3D = k["hull"]
	var frame: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var ax: float = span - 0.115 * wf
	for i in 2:
		var sx: float = -1.0 if i == 0 else 1.0
		_plate(
			rig,
			hull,
			Vector3(sx * (span - 0.105 * wf), yoke + 0.005, -0.01),
			Vector3(0.19 * wf, 0.15, 0.26 * wf),
			Vector3(0, 0, -14.0 * sx)
		)
		ProceduralModels._part(
			rig, ProceduralModels._sphere(0.1 * wf), frame, Vector3(sx * ax, yoke - 0.02, 0)
		)
		_plate(rig, frame, Vector3(sx * ax, yoke - 0.2, 0), Vector3(0.13 * wf, 0.26, 0.14 * wf))
		_plate(
			rig, hull, Vector3(sx * ax, yoke - 0.43, -0.015), Vector3(0.17 * wf, 0.26, 0.23 * wf)
		)
	# RIGHT: integrated barrel + the muzzle's tertiary emissive dot.
	ProceduralModels._part(
		rig,
		ProceduralModels._cyl(0.038 * wf, 0.28),
		steel,
		Vector3(ax, yoke - 0.47, -0.22 * wf),
		Vector3(90, 0, 0)
	)
	ProceduralModels._part(
		rig, ProceduralModels._sphere(0.022), k["glow"], Vector3(ax, yoke - 0.47, -0.22 * wf - 0.16)
	)
	# LEFT: an open breaching clamp — two steel jaws, no fingers.
	_plate(
		rig,
		steel,
		Vector3(-ax, yoke - 0.56, -0.06 * wf),
		Vector3(0.19 * wf, 0.09, 0.26 * wf),
		Vector3(12, 0, 0)
	)
	_plate(
		rig,
		steel,
		Vector3(-ax, yoke - 0.63, -0.06 * wf),
		Vector3(0.19 * wf, 0.09, 0.26 * wf),
		Vector3(-12, 0, 0)
	)


## Head: a low wide skull sunk on a dark collar between the shoulder blocks (no neck), a
## brow hood throwing a shadow line, and ONE horizontal sensor slit — the primary
## emissive of the whole machine. The slit width is the only per-tier face difference:
## a pair of eyes is what made the heavy read as a face, and it is gone for good.
static func _head(rig: Node3D, d: Dictionary, k: Dictionary) -> void:
	var wf: float = d["wf"]
	var head: float = d["head"]
	var hw: float = d["hw"]
	var hd: float = hw * 0.88
	var hull: StandardMaterial3D = k["hull"]
	var frame: StandardMaterial3D = k["frame"]
	_plate(rig, frame, Vector3(0, head - 0.085, 0.005), Vector3(0.21 * wf, 0.14, 0.18 * wf))
	_plate(rig, hull, Vector3(0, head, -0.01), Vector3(hw, 0.15, hd))
	_plate(
		rig,
		hull,
		Vector3(0, head + 0.075, -(hd * 0.5 - 0.005)),
		Vector3(hw + 0.03, 0.05, 0.11),
		Vector3(24, 0, 0)
	)
	_plate(rig, frame, Vector3(0, head, -(hd * 0.5 - 0.01)), Vector3(hw + 0.015, 0.095, 0.05))
	_plate(
		rig, k["glow"], Vector3(0, head, -(hd * 0.5 + 0.028)), Vector3(float(d["bar"]), 0.034, 0.02)
	)
	_plate(
		rig,
		hull,
		Vector3(0, head - 0.088, -(hd * 0.5 - 0.02)),
		Vector3(hw * 0.8, 0.06, 0.1),
		Vector3(-16, 0, 0)
	)


## Per-id identity on top of the shared frame — the three must read as THREE MACHINES,
## not one machine at three sizes, so each gets a different upper-body outline.
static func _details(rig: Node3D, id: String, d: Dictionary, k: Dictionary) -> void:
	match id:
		"robot_grunt":
			_grunt_kit(rig, d, k)
		"robot_heavy":
			_heavy_kit(rig, d, k)
		"robot_elite":
			_elite_kit(rig, d, k)


## Grunt — the lean line trooper: a swept-back comms whip and one off-centre radio box on
## the back, so its outline is asymmetric and uncluttered next to the other two.
static func _grunt_kit(rig: Node3D, d: Dictionary, k: Dictionary) -> void:
	var wf: float = d["wf"]
	var yoke: float = d["yoke"]
	var td: float = d["td"]
	ProceduralModels._part(
		rig,
		ProceduralModels._cyl(0.011, 0.24),
		k["steel"],
		Vector3(0.1 * wf, yoke + 0.1, 0.1),
		Vector3(38, 0, 0)
	)
	ProceduralModels._part(
		rig, ProceduralModels._sphere(0.018), k["accent"], Vector3(0.1 * wf, yoke + 0.2, 0.175)
	)
	_plate(
		rig,
		k["frame"],
		Vector3(-0.13 * wf, yoke - 0.12, td * 0.5 + 0.07),
		Vector3(0.17 * wf, 0.15, 0.1)
	)


## Heavy — the walking bunker: a second pauldron deck stacked on the first, hip skirts
## flanking the thighs, a chest ram plate and two exhaust stacks over the shoulders. All
## of it widens or thickens the silhouette; NONE of it makes the machine taller.
static func _heavy_kit(rig: Node3D, d: Dictionary, k: Dictionary) -> void:
	var wf: float = d["wf"]
	var hip: float = d["hip"]
	var yoke: float = d["yoke"]
	var td: float = d["td"]
	var th: float = d["th"]
	var mid: float = d["mid"]
	var stance: float = d["stance"]
	for i in 2:
		var sx: float = -1.0 if i == 0 else 1.0
		_plate(
			rig,
			k["hull"],
			Vector3(sx * 0.38, yoke + 0.115, -0.01),
			Vector3(0.24, 0.13, 0.3),
			Vector3(0, 0, -16.0 * sx)
		)
		_plate(
			rig,
			k["hull"],
			Vector3(sx * (stance + 0.1), hip - 0.02, 0),
			Vector3(0.11 * wf, 0.3, 0.3 * wf),
			Vector3(0, 0, -6.0 * sx)
		)
		ProceduralModels._part(
			rig,
			ProceduralModels._cyl(0.05 * wf, 0.26),
			k["steel"],
			Vector3(sx * 0.24 * wf, yoke + 0.09, 0.21 * wf),
			Vector3(12, 0, 0)
		)
	_plate(
		rig,
		k["hull"],
		Vector3(0, mid + th * 0.42, -(td * 0.5 + 0.075)),
		Vector3(0.46 * wf, 0.16, 0.1),
		Vector3(-10, 0, 0)
	)
	_plate(
		rig,
		k["accent"],
		Vector3(0, mid + th * 0.42 - 0.11, -(td * 0.5 + 0.085)),
		Vector3(0.3 * wf, 0.04, 0.02)
	)


## Elite — the commander. This kit exists to solve a MEASURED failure: after the silhouette
## rework, elite and grunt still overlapped at 0.92 IoU — the same shape wearing different
## paint, which is exactly the complaint the whole batch was meant to answer. Gold trims and
## small fins cannot fix that, because they live INSIDE the outline.
##
## So everything here BREAKS the outline instead of decorating it, while staying inside the
## shared r0.45 capsule (elite and grunt use the same one, so it cannot simply be bigger):
##   * a tall swept CREST that clears the skull,
##   * GORGET WINGS that flare up and outward to the capsule edge — the "winged shoulders"
##     read you can pick out of a squad at range,
##   * an ASYMMETRIC banner hanging off one shoulder down the back, which is the cheapest
##     way to make a bipedal outline unmistakable from any angle.
static func _elite_kit(rig: Node3D, d: Dictionary, k: Dictionary) -> void:
	var wf: float = d["wf"]
	var yoke: float = d["yoke"]
	var span: float = d["span"]
	var td: float = d["td"]
	var accent: StandardMaterial3D = k["accent"]
	# Crest: tall and swept back, well clear of the skull so it reads at silhouette range.
	_plate(
		rig,
		accent,
		Vector3(0, float(d["head"]) + 0.17, 0.02),
		Vector3(0.05, 0.30, 0.20),
		Vector3(24, 0, 0)
	)
	for i in 2:
		var sx: float = -1.0 if i == 0 else 1.0
		# Gorget wing — a big plate rising up and OUT behind the shoulder.
		_plate(
			rig,
			accent,
			Vector3(sx * (span - 0.02), yoke + 0.20, 0.06),
			Vector3(0.05, 0.34, 0.22),
			Vector3(12, 0, -34.0 * sx)
		)
		# Pauldron trim, kept from the previous pass — the gold that says "officer".
		_plate(
			rig,
			accent,
			Vector3(sx * (span - 0.105 * wf), yoke + 0.085, -0.01),
			Vector3(0.2 * wf, 0.028, 0.26 * wf),
			Vector3(0, 0, -14.0 * sx)
		)
	# Command banner: long, one-sided, hanging down the back to the waist.
	_plate(
		rig,
		accent,
		Vector3(-0.12 * wf, float(d["mid"]) - 0.06, -(td * 0.5 + 0.055)),
		Vector3(0.17 * wf, 0.52, 0.03),
		Vector3(-6, 0, 4)
	)
	_plate(
		rig,
		accent,
		Vector3(0, float(d["bot"]) + 0.02, -(td * 0.5 + 0.03)),
		Vector3(0.26 * wf, 0.06, 0.03)
	)
	# Sensor mast — a thin vertical the other two never have.
	ProceduralModels._part(
		rig,
		ProceduralModels._cyl(0.014, 0.30),
		k["steel"],
		Vector3(-(span - 0.115 * wf), yoke + 0.17, 0.06)
	)
	ProceduralModels._part(
		rig,
		ProceduralModels._sphere(0.026),
		k["glow"],
		Vector3(-(span - 0.115 * wf), yoke + 0.33, 0.06)
	)


## A box part — every plate in this file goes through here (and therefore through
## ProceduralModels._part, which owns the hit-flash material contract).
static func _plate(
	p: Node3D, m: StandardMaterial3D, at: Vector3, sz: Vector3, rot := Vector3.ZERO
) -> void:
	ProceduralModels._part(p, ProceduralModels._box(sz), m, at, rot)


## A limb segment spanning a→b as a plated box of cross-section w×dep. Legs are planar in
## YZ inside their pivot, so the span needs one X rotation — which is exactly what draws
## the digitigrade zig-zag from three straight boxes.
static func _seg(
	p: Node3D, m: StandardMaterial3D, a: Vector3, b: Vector3, w: float, dep: float
) -> void:
	var v: Vector3 = b - a
	var span: float = v.length()
	if span < 0.001:
		return
	var ang: float = rad_to_deg(atan2(v.z, v.y))
	_plate(p, m, (a + b) * 0.5, Vector3(w, span, dep), Vector3(ang, 0, 0))
