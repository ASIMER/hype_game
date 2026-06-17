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


# --- recognizable LIMB models (arm / leg) — the dropped + attached body parts ----
## A dull metal/flesh BASE material for the limb body (so it reads as an actual limb, not a glowing
## blob — the signature colour is only an accent/emission on the joints + end-bit).
static func _limb_base_mat() -> StandardMaterial3D:
	# Light warm grey (flesh/metal) + a faint self-emission so the limb READS clearly as a body
	# part even under the cold dark grade (the dark version was nearly invisible in-world).
	return _MODELS._mat(Color(0.62, 0.56, 0.52), 0.35, 0.55, Color(0.30, 0.26, 0.24), 0.5)


## Build a RECOGNIZABLE body-part model — an ARM (shoulder→upper→elbow→forearm→hand+fingers) or a
## LEG (thigh→knee→shin→foot), assembled like ProceduralPlayer's limbs so a dropped one reads as
## "a severed arm/leg", not an abstract bit. The themed signature bit (claw/fist/blade/…) caps the
## hand/foot in the skill colour, and the joints glow the skill colour. Extends +Y from the local
## origin (the "cut" end), ~0.95 m tall — the drop lays it flat, the body-attach scales it down.
static func build_limb_model(skill_id: String, color: Color) -> Node3D:
	var def: Dictionary = Settings.skill_def(skill_id)
	var part: String = String(def["part"])
	var limb: String = String(def.get("limb", "arm"))
	var n := Node3D.new()
	n.name = "Limb"
	var base := _limb_base_mat()
	var glow := _pmat(color)
	if limb == "leg":
		_p(n, _cyl(0.11, 0.44), base, Vector3(0, 0.22, 0))  # thigh
		_p(n, _sph(0.115), glow, Vector3(0, 0.45, 0))  # knee (glows)
		_p(n, _cyl(0.09, 0.40), base, Vector3(0, 0.67, 0))  # shin
		_p(n, _sph(0.08), base, Vector3(0, 0.88, 0))  # ankle
		_p(n, _box(Vector3(0.17, 0.11, 0.32)), base, Vector3(0, 0.93, -0.09))  # foot
		var bit := build_part_node(part, color)  # themed spur on the foot
		bit.scale = Vector3.ONE * 0.55
		bit.position = Vector3(0, 0.96, -0.22)
		n.add_child(bit)
	else:  # arm
		_p(n, _sph(0.105), base, Vector3(0, 0.05, 0))  # shoulder ball
		_p(n, _cyl(0.085, 0.38), base, Vector3(0, 0.26, 0))  # upper arm
		_p(n, _sph(0.085), glow, Vector3(0, 0.46, 0))  # elbow (glows)
		_p(n, _cyl(0.07, 0.36), base, Vector3(0, 0.67, 0))  # forearm
		_p(n, _box(Vector3(0.12, 0.13, 0.13)), base, Vector3(0, 0.88, 0))  # palm
		for f in 3:  # fingers
			_p(n, _box(Vector3(0.03, 0.11, 0.035)), base, Vector3(-0.04 + float(f) * 0.04, 0.97, 0))
		var bit := build_part_node(part, color)  # themed "weapon hand"
		bit.scale = Vector3.ONE * 0.7
		bit.position = Vector3(0, 0.9, 0.0)
		n.add_child(bit)
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
		var color: Color = def["color"]
		var limb: String = String(def.get("limb", "arm"))
		for i in lvl:
			if total >= Settings.LIMB_CLUSTER_MAX:
				return root
			s = (s * 1103515245 + 12345) & 0x7fffffff  # LCG — deterministic, no Math.random
			_place_limb(root, String(sid), color, limb, i, s)
			total += 1
	return root


## Attach the i-th recognizable LIMB (a full arm/leg from build_limb_model) at a BODY anchor:
## extra ARMS sprout from the shoulders (drooping out), extra LEGS hang off the hips — alternating
## L/R, fanning back/down by tier so the Frankenstein silhouette reads. Deterministic jitter `s`.
static func _place_limb(
	root: Node3D, sid: String, color: Color, limb: String, i: int, s: int
) -> void:
	var node := build_limb_model(sid, color)
	var jitter: float = float(s % 1000) / 1000.0 - 0.5
	var side: float = -1.0 if i % 2 == 0 else 1.0
	var tier: int = i / 2
	var pos: Vector3
	var rot: Vector3
	var scl: float
	if limb == "leg":  # hangs off the hip, splaying out + back by tier (the extra legs)
		pos = Vector3(side * (0.22 + 0.04 * float(tier)), 0.86, 0.05 + 0.12 * float(tier))
		rot = Vector3(170.0 - 8.0 * float(tier), side * 12.0, side * (14.0 + 6.0 * jitter))
		scl = 0.66
	else:  # arm sprouts from the shoulder/upper back, drooping outward (the extra arms)
		pos = Vector3(
			side * (0.34 + 0.05 * float(tier)), 1.42 - 0.16 * float(tier), 0.06 + 0.1 * float(tier)
		)
		rot = Vector3(18.0, side * 10.0, side * (112.0 + 8.0 * jitter))
		scl = 0.7
	node.position = pos
	node.scale = Vector3.ONE * scl
	node.rotation_degrees = rot
	root.add_child(node)
