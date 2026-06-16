class_name ProceduralAbsorbed
extends RefCounted
## The visual side of the Mutant-Harvest mechanic: deterministic LIMBS of harvested
## enemy parts welded onto the player's back, plus the single-part nodes the homing streak FX
## reuses. Every enemy archetype donates a recognizable signature part (Settings.SKILL_DEFS):
## spider→legs, oni→horn, scarab→shell, … capped PER TYPE (the user's "max 8 spider legs").
##
## Built from `absorbed` ({enemy_id: count}) — the owner-authoritative replicated dict — and a
## STABLE seed (the peer id), with an LCG (no randf/Time) and SORTED-key iteration, so every
## co-op peer rebuilds the byte-identical cluster (same discipline as ProceduralModels.scar_parts).
## Parts are faintly emissive in the enemy's signature colour (the "one hot accent" look). The
## body faces -Z, so the back is +Z — the cluster sits on the upper back where the centered
## behind-the-back camera frames it. Render-only.

const _MODELS := preload("res://scripts/visual/procedural_models.gd")


# --- primitive shorthands (mirror ProceduralPlayer) --------------------------
static func _p(
	root: Node3D,
	mesh: Mesh,
	mat: StandardMaterial3D,
	off := Vector3.ZERO,
	rot := Vector3.ZERO,
	scl := Vector3.ONE
) -> MeshInstance3D:
	return _MODELS._part(root, mesh, mat, off, rot, scl)


static func _box(s: Vector3) -> BoxMesh:
	return _MODELS._box(s)


static func _cyl(r: float, h: float, seg := 8) -> CylinderMesh:
	return _MODELS._cyl(r, h, seg)


static func _cone(r: float, h: float, seg := 6) -> CylinderMesh:
	return _MODELS._cone(r, h, seg)


static func _sph(r: float, hemi := false) -> SphereMesh:
	return _MODELS._sphere(r, hemi)


## A saturated, strongly-emissive material in the part's signature colour so the parts GLOW (the
## "absorbed energy" read) and bloom past the glow HDR threshold even under the cold grade.
static func _pmat(color: Color) -> StandardMaterial3D:
	return _MODELS._mat(color.lightened(0.15), 0.3, 0.35, color, 5.5)


# --- one signature part (shared by the cluster + the homing streak) ----------
## Build a single signature part (the shape extends +Y from its local origin). `token` is the
## part id from Settings.SKILL_DEFS; `color` is its signature tint.
static func build_part_node(token: String, color: Color) -> Node3D:
	var n := Node3D.new()
	n.name = "Part"
	var m := _pmat(color)
	match token:
		"horn":
			_p(n, _cone(0.055, 0.34, 6), m, Vector3(0, 0.17, 0))
		"spike":
			_p(n, _cone(0.05, 0.26, 6), m, Vector3(0, 0.13, 0))
		"fin":
			_p(
				n,
				_cone(0.07, 0.30, 5),
				m,
				Vector3(0, 0.15, 0),
				Vector3.ZERO,
				Vector3(0.5, 1.0, 1.0)
			)
		"blade":
			_p(n, _box(Vector3(0.05, 0.30, 0.15)), m, Vector3(0, 0.15, 0))
		"claw":
			_p(n, _cyl(0.035, 0.24, 6), m, Vector3(0, 0.12, 0))
			_p(n, _cone(0.04, 0.12, 5), m, Vector3(0.03, 0.27, 0), Vector3(0, 0, -35))
		"fist":
			_p(n, _box(Vector3(0.19, 0.17, 0.19)), m, Vector3(0, 0.10, 0))
			_p(n, _box(Vector3(0.20, 0.05, 0.05)), m, Vector3(0, 0.18, 0))
		"shell":
			_p(n, _sph(0.17, true), m, Vector3(0, 0.03, 0), Vector3.ZERO, Vector3(1.1, 0.7, 1.3))
		"rotor":
			_p(n, _cyl(0.17, 0.03, 12), m, Vector3(0, 0.12, 0))
			_p(n, _box(Vector3(0.34, 0.035, 0.05)), m, Vector3(0, 0.12, 0))
			_p(n, _box(Vector3(0.05, 0.035, 0.34)), m, Vector3(0, 0.12, 0))
		"antenna":
			_p(n, _cyl(0.013, 0.34, 5), m, Vector3(0, 0.17, 0))
			_p(n, _sph(0.035), _pmat(color.lightened(0.3)), Vector3(0, 0.35, 0))
		"barrel":
			_p(n, _cyl(0.07, 0.26, 8), m, Vector3(0, 0.13, 0))
		"vane":
			_p(n, _box(Vector3(0.06, 0.26, 0.17)), m, Vector3(0, 0.13, 0), Vector3(0, 0, 18))
		"maw":
			_p(n, _cyl(0.16, 0.09, 10), m, Vector3(0, 0.07, 0))
			for k in 4:
				var a: float = float(k) / 4.0 * TAU
				_p(n, _cone(0.03, 0.10, 4), m, Vector3(cos(a) * 0.13, 0.16, sin(a) * 0.13))
		_:  # "scrap" + any unmapped id
			_p(n, _box(Vector3(0.16, 0.12, 0.13)), m, Vector3(0, 0.08, 0), Vector3(12, 20, 8))
			_p(
				n,
				_box(Vector3(0.10, 0.14, 0.09)),
				m,
				Vector3(0.06, 0.18, 0.02),
				Vector3(-18, 5, 22)
			)
	return n


# --- visible LIMBS on the body (Frankenstein) --------------------------------
## Build the "LimbCluster": every held skill's level → that many signature parts attached at a
## BODY anchor (horns on the head, fists on the shoulders, legs/claws marching down the torso
## sides, blades on the forearms, the rest fanned on the back). The body frame is FROZEN
## (procedural_player.gd) so the anchors are constants. Deterministic in `seed_val` (peer id) +
## SORTED keys → every co-op peer builds byte-identical limbs. Mounts under the animated body so
## the limbs ride PlayerAnimator. `skills` = {skill_id: level}.
static func build_limbs(skills: Dictionary, seed_val: int) -> Node3D:
	var root := Node3D.new()
	root.name = "LimbCluster"
	var keys: Array = skills.keys()
	keys.sort()
	var s: int = absi(seed_val)
	var total: int = 0
	for sid in keys:
		var def: Dictionary = Settings.skill_def(String(sid))
		var lvl: int = mini(int(skills[sid]), int(def["max_level"]))
		var part: String = String(def["part"])
		var color: Color = def["color"]
		for i in lvl:
			if total >= Settings.LIMB_CLUSTER_MAX:
				return root
			s = (s * 1103515245 + 12345) & 0x7fffffff  # LCG — deterministic, no Math.random
			_place_limb(root, part, color, i, s)
			total += 1
	return root


## Attach the i-th instance of `part` at its body anchor, fanning out by index (deterministic
## jitter from `s`). Sides alternate L/R; legs/blades march down, horns ring the head.
static func _place_limb(root: Node3D, part: String, color: Color, i: int, s: int) -> void:
	var node := build_part_node(part, color)
	var jitter: float = float(s % 1000) / 1000.0 - 0.5
	var side: float = -1.0 if i % 2 == 0 else 1.0
	var tier: int = i / 2
	var pos: Vector3
	var rot: Vector3
	# Parts are scaled UP and pushed further off the body so the Frankenstein silhouette reads
	# clearly from the behind-the-back camera (the user couldn't see the old small limbs).
	var scl: float = 1.4
	match part:
		"horn", "spike":  # head-top, ringing outward
			pos = Vector3(side * (0.12 + 0.06 * float(tier)), 1.80 + 0.02 * jitter, 0.02)
			rot = Vector3(-18.0, 0.0, side * 30.0)
			scl = 1.5
		"fist":  # shoulders
			pos = Vector3(side * 0.44, 1.42 - 0.14 * float(tier), 0.0)
			rot = Vector3(0.0, 0.0, side * 92.0)
			scl = 1.55
		"claw":  # torso sides — legs marching DOWN (the spider legs)
			pos = Vector3(side * (0.36 + 0.03 * jitter), 1.20 - float(tier) * 0.18, 0.04)
			rot = Vector3(90.0, side * 18.0, side * 62.0)
			scl = 1.5
		"blade":  # forearms
			pos = Vector3(side * 0.42, 0.82 - float(tier) * 0.14, 0.06)
			rot = Vector3(20.0, 0.0, side * 40.0)
			scl = 1.45
		"maw":  # chest front
			pos = Vector3(side * 0.14 * float(tier), 1.22 + 0.06 * jitter, -0.26)
			rot = Vector3(-90.0, 0.0, 0.0)
			scl = 1.5
		_:  # shell/vane/barrel/rotor/antenna/scrap → fanned on the back
			var ang: float = side * (0.4 + 0.25 * float(tier)) + jitter * 0.1
			pos = Vector3(sin(ang) * 0.32, 1.32 + float(tier) * 0.18, 0.26 + cos(ang) * 0.06)
			rot = Vector3(-24.0, rad_to_deg(ang) * 0.5, sin(ang) * 28.0)
	node.position = pos
	node.scale = Vector3.ONE * scl
	node.rotation_degrees = rot
	root.add_child(node)
