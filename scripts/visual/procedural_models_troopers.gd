class_name ProceduralModelsTroopers
extends RefCounted
## The three STARTER bots (grunt / heavy / elite) rebuilt as procedural mechs (v0.5-B4).
## They were the LAST .glb enemies (the three.js RobotExpressive mascot) — the machine
## reskin killed the cartoon face texture, leaving a dark toy blob with UNPAINTED EYES.
## Rebuilt on the same kit-material pipeline every other machine uses (ProcEnemyKits:
## plated hull / rubber frame / worn steel / restrained accent / EMISSIVE glow eyes).
##
## One parametric TROOPER body (bipedal infantry frame — the family resemblance) with
## per-id width/height factors, a face variant (mono VISOR / TWIN eyes / angled VEE)
## and identity details (antenna / exhaust stacks / commander crest).
##
## Shares ProceduralModels' part+mesh helpers (no copy-paste — the AUDIT F1 rule).
## Feet sit at the NEGATIVE of each scene's ModelRoot Y offset (grunt/elite -0.8,
## heavy -0.95) so the body lands on the ground without touching any .tscn.

const IDS := ["robot_grunt", "robot_heavy", "robot_elite"]


static func build(id: String) -> Node3D:
	match id:
		"robot_grunt":
			return _trooper(id, 1.0, 1.0, "visor", -0.8)
		"robot_heavy":
			return _trooper(id, 1.35, 1.14, "twin", -0.95)
		"robot_elite":
			return _trooper(id, 1.05, 1.04, "vee", -0.8)
	return null


## The shared infantry frame. `wf`/`hf` scale width/height off the grunt base (~1.6 m),
## `face` picks the emissive eye layout, `foot_y` matches the scene's ModelRoot offset.
static func _trooper(id: String, wf: float, hf: float, face: String, foot_y: float) -> Node3D:
	var root := Node3D.new()
	root.name = id + "_model"
	var rig := Node3D.new()
	rig.name = "Rig"
	rig.position = Vector3(0, foot_y, 0)
	root.add_child(rig)
	var k := ProcEnemyKits.kit(id)
	var hull: StandardMaterial3D = k["hull"]
	var frame: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var accent: StandardMaterial3D = k["accent"]
	var glow: StandardMaterial3D = k["glow"]

	# --- Legs (mirrored): steel foot, plated shin, rubber knee ball + thigh. ---
	for sx in [-1.0, 1.0]:
		var x: float = sx * 0.15 * wf
		ProceduralModels._part(
			rig,
			ProceduralModels._box(Vector3(0.22 * wf, 0.09, 0.34)),
			steel,
			Vector3(x, 0.05, -0.02)
		)
		ProceduralModels._part(
			rig,
			ProceduralModels._box(Vector3(0.13 * wf, 0.32, 0.15)),
			hull,
			Vector3(x, 0.28 * hf, 0)
		)
		ProceduralModels._part(
			rig, ProceduralModels._sphere(0.085 * wf), frame, Vector3(x, 0.47 * hf, 0)
		)
		ProceduralModels._part(
			rig,
			ProceduralModels._box(Vector3(0.15 * wf, 0.30, 0.17)),
			frame,
			Vector3(x, 0.64 * hf, 0)
		)

	# --- Pelvis + torso: plated chest over a rubber core, identity stripe + chest core. ---
	ProceduralModels._part(
		rig, ProceduralModels._box(Vector3(0.38 * wf, 0.15, 0.24)), frame, Vector3(0, 0.82 * hf, 0)
	)
	ProceduralModels._part(
		rig, ProceduralModels._box(Vector3(0.46 * wf, 0.40, 0.28)), hull, Vector3(0, 1.10 * hf, 0)
	)
	ProceduralModels._part(
		rig,
		ProceduralModels._box(Vector3(0.40 * wf, 0.24, 0.06)),
		hull,
		Vector3(0, 1.14 * hf, -0.155)
	)
	ProceduralModels._part(
		rig,
		ProceduralModels._box(Vector3(0.26 * wf, 0.05, 0.02)),
		accent,
		Vector3(0, 0.98 * hf, -0.165)
	)
	ProceduralModels._part(
		rig, ProceduralModels._box(Vector3(0.10, 0.06, 0.02)), glow, Vector3(0, 1.10 * hf, -0.185)
	)
	ProceduralModels._part(
		rig,
		ProceduralModels._box(Vector3(0.30 * wf, 0.28, 0.13)),
		frame,
		Vector3(0, 1.10 * hf, 0.185)
	)

	# --- Arms (mirrored): rubber shoulder ball, plated pauldron + upper arm, steel
	# forearm; the RIGHT forearm carries the integrated gun barrel. ---
	for sx in [-1.0, 1.0]:
		var ax: float = sx * 0.31 * wf
		ProceduralModels._part(
			rig, ProceduralModels._sphere(0.10 * wf), frame, Vector3(sx * 0.30 * wf, 1.27 * hf, 0)
		)
		ProceduralModels._part(
			rig,
			ProceduralModels._box(Vector3(0.17 * wf, 0.09, 0.23)),
			hull,
			Vector3(sx * 0.32 * wf, 1.34 * hf, 0)
		)
		ProceduralModels._part(
			rig, ProceduralModels._box(Vector3(0.11, 0.24, 0.12)), hull, Vector3(ax, 1.13 * hf, 0)
		)
		ProceduralModels._part(
			rig, ProceduralModels._sphere(0.06), frame, Vector3(ax, 0.99 * hf, 0)
		)
		ProceduralModels._part(
			rig, ProceduralModels._box(Vector3(0.10, 0.24, 0.11)), steel, Vector3(ax, 0.86 * hf, 0)
		)
		ProceduralModels._part(
			rig, ProceduralModels._box(Vector3(0.09, 0.08, 0.10)), frame, Vector3(ax, 0.72 * hf, 0)
		)
	var gx: float = 0.31 * wf
	ProceduralModels._part(
		rig,
		ProceduralModels._cyl(0.035, 0.24),
		steel,
		Vector3(gx, 0.80 * hf, -0.20),
		Vector3(90, 0, 0)
	)
	ProceduralModels._part(
		rig, ProceduralModels._sphere(0.018), glow, Vector3(gx, 0.80 * hf, -0.325)
	)

	# --- Head: plated helmet + brow, dark face plate, EMISSIVE eyes (the point). ---
	ProceduralModels._part(rig, ProceduralModels._cyl(0.05, 0.08), frame, Vector3(0, 1.36 * hf, 0))
	ProceduralModels._part(
		rig, ProceduralModels._box(Vector3(0.24, 0.19, 0.24)), hull, Vector3(0, 1.47 * hf, 0)
	)
	ProceduralModels._part(
		rig, ProceduralModels._box(Vector3(0.25, 0.045, 0.05)), hull, Vector3(0, 1.535 * hf, -0.10)
	)
	ProceduralModels._part(
		rig, ProceduralModels._box(Vector3(0.19, 0.13, 0.03)), frame, Vector3(0, 1.46 * hf, -0.125)
	)
	match face:
		"visor":
			ProceduralModels._part(
				rig,
				ProceduralModels._box(Vector3(0.19, 0.05, 0.02)),
				glow,
				Vector3(0, 1.485 * hf, -0.148)
			)
		"twin":
			for sx in [-1.0, 1.0]:
				ProceduralModels._part(
					rig,
					ProceduralModels._sphere(0.032),
					glow,
					Vector3(sx * 0.055, 1.48 * hf, -0.14)
				)
		"vee":
			for sx in [-1.0, 1.0]:
				ProceduralModels._part(
					rig,
					ProceduralModels._box(Vector3(0.085, 0.032, 0.02)),
					glow,
					Vector3(sx * 0.048, 1.48 * hf, -0.145),
					Vector3(0, 0, -sx * 18.0)
				)

	_details(rig, id, wf, hf, hull, steel, accent, glow)
	return root


## Per-id identity details on top of the shared frame.
static func _details(
	rig: Node3D,
	id: String,
	wf: float,
	hf: float,
	hull: StandardMaterial3D,
	steel: StandardMaterial3D,
	accent: StandardMaterial3D,
	glow: StandardMaterial3D
) -> void:
	match id:
		"robot_grunt":
			# Comms antenna with a lit tip — the rank-and-file radio soldier.
			ProceduralModels._part(
				rig, ProceduralModels._cyl(0.012, 0.16), steel, Vector3(0.09, 1.63 * hf, 0.05)
			)
			ProceduralModels._part(
				rig, ProceduralModels._sphere(0.018), glow, Vector3(0.09, 1.72 * hf, 0.05)
			)
		"robot_heavy":
			# Twin exhaust stacks + knee guards — the walking bunker.
			for sx in [-1.0, 1.0]:
				ProceduralModels._part(
					rig,
					ProceduralModels._cyl(0.045, 0.26),
					steel,
					Vector3(sx * 0.14 * wf, 1.34 * hf, 0.24),
					Vector3(-12, 0, 0)
				)
				ProceduralModels._part(
					rig,
					ProceduralModels._box(Vector3(0.15 * wf, 0.09, 0.06)),
					accent,
					Vector3(sx * 0.15 * wf, 0.50 * hf, -0.09)
				)
			ProceduralModels._part(
				rig,
				ProceduralModels._box(Vector3(0.30 * wf, 0.05, 0.28)),
				hull,
				Vector3(0, 1.40 * hf, 0.02)
			)
		"robot_elite":
			# Commander CREST fin + gold pauldron trims — the one you focus first.
			ProceduralModels._part(
				rig,
				ProceduralModels._box(Vector3(0.035, 0.14, 0.26)),
				accent,
				Vector3(0, 1.63 * hf, 0.02),
				Vector3(-12, 0, 0)
			)
			for sx in [-1.0, 1.0]:
				ProceduralModels._part(
					rig,
					ProceduralModels._box(Vector3(0.18 * wf, 0.03, 0.24)),
					accent,
					Vector3(sx * 0.32 * wf, 1.395 * hf, 0)
				)
			ProceduralModels._part(
				rig,
				ProceduralModels._box(Vector3(0.05, 0.20, 0.02)),
				glow,
				Vector3(0, 1.12 * hf, 0.255)
			)
