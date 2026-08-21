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
## A flesh/metal BASE material for the limb body (so it reads as an actual limb, not a glowing
## blob). Mostly a warm grey with a HINT of the skill colour + a faint matching emission, so the
## limb READS under the cold dark grade AND each skill's limb has a subtle colour identity.
static func _limb_base_mat(tint: Color) -> StandardMaterial3D:
	var g: Color = Color(0.62, 0.56, 0.52).lerp(tint, 0.22)
	return _MODELS._mat(g, 0.35, 0.55, tint.darkened(0.35), 0.6)


## Build a RECOGNIZABLE body-part model — a BENT ARM (shoulder→upper→elbow→forearm→hand+fingers)
## or a BENT LEG (thigh→knee→shin→foot). The kink at the elbow/knee + the hand/foot at the end are
## the silhouette cues that make a dropped one read as "a severed arm/leg", not an abstract rod; the
## themed signature bit (claw/fist/blade/…) caps the hand/foot in the skill colour and the joints
## glow it. Extends roughly +Y from the local origin (the "cut" end) — the drop lays it flat.
static func build_limb_model(skill_id: String, color: Color) -> Node3D:
	var def: Dictionary = Settings.skill_def(skill_id)
	var part: String = String(def["part"])
	var n := Node3D.new()
	n.name = "Limb"
	var base := _limb_base_mat(color)
	var glow := _pmat(color)
	if String(def.get("limb", "arm")) == "leg":
		_build_leg(n, part, color, base, glow)
	else:
		_build_arm(n, part, color, base, glow)
	return n


## A bent leg: thigh (origin→knee), a SOLID grey knee that BRIDGES the joint (kills the gap) wearing
## a thin glowing seam, a shin kinked ~22° (dipping below the pivot to overlap), and an L-shaped foot
## pointing +Z with a toe + a themed spur.
static func _build_leg(
	n: Node3D, part: String, color: Color, base: StandardMaterial3D, glow: StandardMaterial3D
) -> void:
	_p(n, _cyl(0.12, 0.50), base, Vector3(0, 0.25, 0))  # thigh
	_p(n, _sph(0.16), base, Vector3(0, 0.48, 0))  # knee — solid, bridges thigh↔shin (no gap)
	_p(n, _cyl(0.175, 0.05), glow, Vector3(0, 0.48, 0))  # glowing knee seam (skill colour)
	var shin := Node3D.new()
	shin.position = Vector3(0, 0.48, 0)
	shin.rotation_degrees = Vector3(22, 0, 0)  # kink forward at the knee
	n.add_child(shin)
	_p(shin, _cyl(0.105, 0.48), base, Vector3(0, 0.18, 0))  # shin (dips below pivot → overlaps knee)
	_p(shin, _sph(0.1), base, Vector3(0, 0.42, 0))  # ankle
	var foot := Node3D.new()
	foot.position = Vector3(0, 0.42, 0)
	foot.rotation_degrees = Vector3(-22, 0, 0)  # cancel the kink so the foot sits flat
	shin.add_child(foot)
	_p(foot, _box(Vector3(0.18, 0.1, 0.36)), base, Vector3(0, -0.02, 0.13))  # foot
	_p(foot, _box(Vector3(0.16, 0.07, 0.1)), base, Vector3(0, -0.03, 0.32))  # toe
	var bit := build_part_node(part, color)
	bit.scale = Vector3.ONE * 0.55
	bit.position = Vector3(0, 0.06, 0.18)
	foot.add_child(bit)


## A bent arm: shoulder ball, upper arm (origin→elbow), a SOLID grey elbow that BRIDGES the joint
## wearing a thin glowing seam, a forearm kinked ~22° (dipping below the pivot to overlap), then a
## HAND (palm + spread fingers + thumb) with the themed bit as the per-skill silhouette (a fist vs
## an antenna now read differently).
static func _build_arm(
	n: Node3D, part: String, color: Color, base: StandardMaterial3D, glow: StandardMaterial3D
) -> void:
	_p(n, _sph(0.12), base, Vector3(0, 0.06, 0))  # shoulder ball
	_p(n, _cyl(0.09, 0.42), base, Vector3(0, 0.27, 0))  # upper arm
	_p(n, _sph(0.12), base, Vector3(0, 0.49, 0))  # elbow — solid, bridges (no gap)
	_p(n, _cyl(0.135, 0.05), glow, Vector3(0, 0.49, 0))  # glowing elbow seam (skill colour)
	var fore := Node3D.new()
	fore.position = Vector3(0, 0.49, 0)
	fore.rotation_degrees = Vector3(22, 0, 0)  # kink forward at the elbow
	n.add_child(fore)
	_p(fore, _cyl(0.078, 0.42), base, Vector3(0, 0.16, 0))  # forearm (dips below pivot → overlaps)
	var hand := Node3D.new()
	hand.position = Vector3(0, 0.37, 0)
	hand.rotation_degrees = Vector3(-22, 0, 0)
	fore.add_child(hand)
	_build_hand(hand, base)
	var bit := build_part_node(part, color)  # themed "weapon hand"
	bit.scale = Vector3.ONE * 0.7
	bit.position = Vector3(0, 0.06, 0.06)
	hand.add_child(bit)


## Palm + four spread fingers + an angled thumb, pointing +Z — the recognizable hand silhouette.
static func _build_hand(hand: Node3D, base: StandardMaterial3D) -> void:
	_p(hand, _box(Vector3(0.14, 0.06, 0.13)), base, Vector3(0, 0, 0.05))  # palm
	for f in 4:
		var fx: float = -0.045 + float(f) * 0.03
		_p(hand, _box(Vector3(0.025, 0.03, 0.12)), base, Vector3(fx, 0, 0.16))  # finger
	_p(hand, _box(Vector3(0.03, 0.03, 0.08)), base, Vector3(0.085, 0, 0.05), Vector3(0, 0, 28))


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
