class_name ProceduralArms
extends RefCounted
## FIRST-PERSON ARMS view-model: a pair of forearms + hands that hold the gun in the
## first-person zoom step (Settings.VIEW_STEP_FIRST_PERSON). Without them FP is a
## floating weapon — a camera with a rifle taped to it instead of a body.
##
## Assembled in the same key as ProceduralWeapons (shared ProceduralModels primitive
## helpers, StandardMaterial3D ONLY — the hit-flash material_override contract), but
## PAINTED FROM THE PLAYER: the paint scheme and the forearm silhouette come from the
## player's own cosmetics via ProceduralPlayer (`_paint_of`/`_mats`/`_with_defaults`,
## the same statics the body builder uses), so these read as HIS arms — a Bulky arm
## keeps its slab forearm and a Claw arm still ends in prongs.
##
## COORDINATE FRAME = weapon-view-model space. The arms are parented under the
## weapon's ModelHolder (see PlayerGear), so they inherit the recoil kick and the
## FP/TP WeaponMount pose for free and the hands never drift off the gun. In that
## space the muzzle points -Z, the grip hangs -Y and the shooter is toward +Z.
## Shoulders are deliberately OUT of frame: each arm is a forearm that leaves through
## the bottom-outer screen edge at an elbow anchor, exactly like a classic FPS
## view-model (a full arm would punch through the camera near-plane).
##
## TUNING: the only table that needs eyeballing in-game is POSES — per weapon class,
## where the trigger hand sits on the grip, where the support hand sits on the
## handguard, and the two off-screen elbow anchors. Everything else derives from those.

const DEFAULT_WEAPON := "rifle"
const DEFAULT_ARMS := "arms_standard"

# Per weapon class (the 5 ids in resources/weapons/*.tres): the two hand anchors in
# view-model space + the elbow anchors the forearms run out to. `*_rot` is the fist's
# euler in degrees; its x rotates the WRIST DIRECTION (the hand's local +Y, see _hand)
# about the gun's X axis, and the sign is what makes or breaks the pose:
#   ~-15°  stands the trigger hand on a rearward-raked pistol grip — wrist on TOP of the
#          grip, fingers on its front strap, and the forearm bends back from there;
#   ~+105° lays the support hand across a horizontal handguard — fingers over the top,
#          wrist BEHIND the fist, which is the only way the forearm can run back to an
#          elbow instead of poking out toward the muzzle.
# Longer guns push both anchors forward (-Z) and the elbows further back (+Z).
const POSES := {
	"rifle":
	{
		"grip": Vector3(0.0, -0.115, 0.14),
		"grip_rot": Vector3(-16.0, 0.0, 0.0),
		"fore": Vector3(0.0, -0.075, -0.20),
		"fore_rot": Vector3(105.0, 0.0, 0.0),
		"elbow_r": Vector3(0.22, -0.36, 0.36),
		"elbow_l": Vector3(-0.24, -0.33, 0.02),
	},
	"smg":
	{
		"grip": Vector3(0.0, -0.105, 0.10),
		"grip_rot": Vector3(-18.0, 0.0, 0.0),
		"fore": Vector3(0.0, -0.065, -0.15),
		"fore_rot": Vector3(105.0, 0.0, 0.0),
		"elbow_r": Vector3(0.21, -0.35, 0.32),
		"elbow_l": Vector3(-0.23, -0.31, -0.02),
	},
	"shotgun":
	{
		"grip": Vector3(0.0, -0.115, 0.13),
		"grip_rot": Vector3(-14.0, 0.0, 0.0),
		"fore": Vector3(0.0, -0.085, -0.24),
		"fore_rot": Vector3(100.0, 0.0, 0.0),  # pump slide is grabbed lower, from the side
		"elbow_r": Vector3(0.22, -0.36, 0.35),
		"elbow_l": Vector3(-0.24, -0.34, 0.02),
	},
	"dmr":
	{
		"grip": Vector3(0.0, -0.115, 0.17),
		"grip_rot": Vector3(-14.0, 0.0, 0.0),
		"fore": Vector3(0.0, -0.075, -0.26),
		"fore_rot": Vector3(108.0, 0.0, 0.0),  # longest reach — the wrist tips furthest back
		"elbow_r": Vector3(0.22, -0.36, 0.39),
		"elbow_l": Vector3(-0.25, -0.34, 0.0),
	},
	# The sidearm is the odd one out: the support hand CUPS the firing hand (isosceles
	# stance) instead of reaching for a handguard, so both elbows sit further back.
	"pistol":
	{
		"grip": Vector3(0.0, -0.10, 0.06),
		"grip_rot": Vector3(-12.0, 0.0, 0.0),
		"fore": Vector3(-0.055, -0.115, 0.045),
		"fore_rot": Vector3(35.0, 0.0, 0.0),
		"elbow_r": Vector3(0.20, -0.34, 0.30),
		"elbow_l": Vector3(-0.24, -0.32, 0.22),
	},
}

# Per ProceduralPlayer arm variant: forearm radius, hand size scale, and the one
# feature that variant is RECOGNISED by (the shoulder/pauldron half of the body
# builders is off-frame here, so the identity has to live on the forearm/fist).
const PROFILES := {
	"arms_standard": {"r": 0.055, "hand": 1.0, "trait": ""},
	"arms_light": {"r": 0.040, "hand": 0.86, "trait": ""},
	"arms_bulky": {"r": 0.075, "hand": 1.15, "trait": "slab"},
	"arms_servo": {"r": 0.042, "hand": 0.95, "trait": "servo"},
	"arms_pauldron": {"r": 0.058, "hand": 1.0, "trait": "cuff"},
	"arms_blade": {"r": 0.055, "hand": 1.0, "trait": "blade"},
	"arms_gauntlet": {"r": 0.070, "hand": 1.12, "trait": "knuckle"},
	"arms_piston": {"r": 0.050, "hand": 1.0, "trait": "piston"},
	"arms_shield": {"r": 0.055, "hand": 1.0, "trait": "bracer"},
	"arms_claw": {"r": 0.070, "hand": 1.1, "trait": "claw"},
}


## Build the FP arm pair for `cosmetics` (the player's replicated cosmetics dict) posed
## for `weapon_id` (a weapon .tres id). Pure render output — no state, no signals; the
## caller parents it under the weapon's ModelHolder and toggles `visible`.
static func build(cosmetics: Dictionary = {}, weapon_id: String = DEFAULT_WEAPON) -> Node3D:
	var cos: Dictionary = ProceduralPlayer._with_defaults(cosmetics)
	var mats: Dictionary = ProceduralPlayer._mats(ProceduralPlayer._paint_of(String(cos["paint"])))
	var prof: Dictionary = PROFILES.get(String(cos["arms"]), PROFILES[DEFAULT_ARMS])
	var pose: Dictionary = POSES.get(weapon_id, POSES[DEFAULT_WEAPON])
	var root := Node3D.new()
	root.name = "FPArms"
	_arm(root, pose, prof, mats, 1.0)  # right — trigger hand on the grip
	_arm(root, pose, prof, mats, -1.0)  # left — support hand on the handguard
	# A view-model must not cast shadows: in FP the body mesh is hidden, so shadowed
	# arms would drop a pair of severed limbs onto the ground next to the gun's shadow.
	_kill_shadows(root)
	return root


# --------------------------------------------------------------- primitive aliases
static func _box(size: Vector3) -> BoxMesh:
	return ProceduralModels._box(size)


static func _sph(r: float, hemi := false, ri := 6, ra := 8) -> SphereMesh:
	return ProceduralModels._sphere(r, hemi, ri, ra)


static func _cyl(r: float, h: float, seg := 8) -> CylinderMesh:
	return ProceduralModels._cyl(r, h, seg)


static func _cone(r: float, h: float, seg := 6) -> CylinderMesh:
	return ProceduralModels._cone(r, h, seg)


static func _part(
	parent: Node3D,
	mesh: Mesh,
	mat: StandardMaterial3D,
	offset := Vector3.ZERO,
	rot_deg := Vector3.ZERO,
	scale := Vector3.ONE
) -> MeshInstance3D:
	return ProceduralModels._part(parent, mesh, mat, offset, rot_deg, scale)


static func _euler(rot_deg: Vector3) -> Basis:
	return Basis.from_euler(
		Vector3(deg_to_rad(rot_deg.x), deg_to_rad(rot_deg.y), deg_to_rad(rot_deg.z))
	)


# ================================================================= ASSEMBLY
## One arm. `sx` mirrors the whole side (+1 right / -1 left) — the right hand takes the
## grip anchor, the left the fore anchor.
static func _arm(
	root: Node3D, pose: Dictionary, prof: Dictionary, m: Dictionary, sx: float
) -> void:
	var right := sx > 0.0
	var at: Vector3 = pose["grip"] if right else pose["fore"]
	var rot: Vector3 = pose["grip_rot"] if right else pose["fore_rot"]
	var elbow: Vector3 = pose["elbow_r"] if right else pose["elbow_l"]
	var hs: float = float(prof["hand"])
	# The fist is its own node so the whole hand can be posed (and re-posed by the lead)
	# as one rigid unit; its parts are authored around a grip running up its local +Y.
	var hand := Node3D.new()
	hand.name = "HandR" if right else "HandL"
	hand.transform = Transform3D(_euler(rot), at)
	root.add_child(hand)
	_hand(hand, prof, m, sx)
	# The forearm is built in WEAPON space (not hand space): the elbow is a frame-edge
	# concept, so it must not inherit the hand's rake.
	var wrist: Vector3 = hand.transform * (Vector3(0.0, 0.085, 0.01) * hs)
	_forearm(root, wrist, elbow, prof, m, sx)


## A robot fist closed around a grip that runs along the hand's local +Y: armour plate on
## the back of the hand (outward = sx), fingers curled across the FRONT (-Z, muzzle side),
## thumb crossing the back.
static func _hand(hand: Node3D, prof: Dictionary, m: Dictionary, sx: float) -> void:
	var hs: float = float(prof["hand"])
	var tr := String(prof["trait"])
	# Wrist ball + rubber collar (the joint the forearm hangs off).
	_part(hand, _sph(0.048 * hs), m.metal, Vector3(0.0, 0.085 * hs, 0.01 * hs))
	_part(hand, _cyl(0.042 * hs, 0.05 * hs), m.dark, Vector3(0.0, 0.05 * hs, 0.005 * hs))
	# Back-of-hand armour + the softer palm block inside it.
	_part(
		hand, _box(Vector3(0.040, 0.125, 0.105) * hs), m.armor, Vector3(sx * 0.050 * hs, 0.0, 0.0)
	)
	_part(
		hand, _box(Vector3(0.055, 0.105, 0.085) * hs), m.dark, Vector3(sx * 0.012 * hs, 0.0, 0.005)
	)
	if tr == "claw":
		# Claw arm: three tapered prongs clamp the grip instead of fingers.
		for i in 3:
			var cy: float = (0.036 - float(i) * 0.038) * hs
			_part(
				hand,
				_cone(0.021 * hs, 0.10 * hs),
				m.trim,
				Vector3(sx * 0.012 * hs, cy, -0.048 * hs),
				Vector3(-100.0, 0.0, 0.0)
			)
		_part(hand, _sph(0.028 * hs), m.accent, Vector3(sx * 0.012 * hs, 0.0, -0.02 * hs))
	else:
		for i in 3:
			var fy: float = (0.036 - float(i) * 0.037) * hs
			_part(
				hand, _box(Vector3(0.080, 0.028, 0.040) * hs), m.dark, Vector3(0.0, fy, -0.046 * hs)
			)
			_part(
				hand,
				_box(Vector3(0.084, 0.012, 0.014) * hs),
				m.metal,
				Vector3(0.0, fy, -0.064 * hs)
			)
	# Thumb crossing the back of the grip.
	_part(
		hand,
		_box(Vector3(0.032, 0.070, 0.034) * hs),
		m.dark,
		Vector3(sx * 0.030 * hs, 0.030 * hs, 0.040 * hs),
		Vector3(18.0, 0.0, sx * -18.0)
	)
	if tr == "knuckle":
		# Gauntlet: ridge bars across the back of the fist.
		for i in 3:
			var ky: float = (0.040 - float(i) * 0.040) * hs
			_part(
				hand,
				_box(Vector3(0.020, 0.026, 0.115) * hs),
				m.trim,
				Vector3(sx * 0.066 * hs, ky, 0.0)
			)


## Wrist → elbow. The elbow anchor is parked below/outside the frame, so on screen this
## reads as an arm entering from the corner rather than a cylinder that stops in mid-air.
static func _forearm(
	root: Node3D, wrist: Vector3, elbow: Vector3, prof: Dictionary, m: Dictionary, sx: float
) -> void:
	var r: float = float(prof["r"])
	var tr := String(prof["trait"])
	_strut(root, wrist, elbow, r, m.armor)
	_part(root, _sph(r * 1.25), m.metal, elbow)  # elbow cap (usually off-frame)
	var basis := _limb_basis(wrist, elbow, sx)
	# Sleeve cuff near the elbow — the "sleeve" every variant shares.
	var cuff := Node3D.new()
	cuff.transform = Transform3D(basis, wrist.lerp(elbow, 0.76))
	root.add_child(cuff)
	_part(cuff, _cyl(r * 1.32, 0.06, 10), m.trim)
	# Variant feature, authored in LIMB space: +Y runs toward the elbow, +X is OUTWARD
	# (away from the gun centreline) on both sides, so nothing has to be hand-mirrored.
	var mid := Node3D.new()
	mid.transform = Transform3D(basis, wrist.lerp(elbow, 0.42))
	root.add_child(mid)
	match tr:
		"slab":
			_part(mid, _box(Vector3(0.10, 0.22, 0.11)), m.armor)
			_part(mid, _box(Vector3(0.03, 0.20, 0.11)), m.trim, Vector3(0.055, 0.0, 0.0))
		"bracer":
			_part(mid, _box(Vector3(0.03, 0.21, 0.10)), m.trim, Vector3(r + 0.015, 0.0, 0.0))
			_part(mid, _box(Vector3(0.035, 0.03, 0.09)), m.accent, Vector3(r + 0.018, 0.085, 0.0))
		"blade":
			_part(mid, _box(Vector3(0.018, 0.26, 0.055)), m.trim, Vector3(r + 0.012, 0.0, 0.0))
			_part(
				mid,
				_cone(0.026, 0.10),
				m.accent,
				Vector3(r + 0.012, -0.17, 0.0),
				Vector3(180.0, 0.0, 0.0)
			)
		"piston":
			for sz: float in [-1.0, 1.0]:
				_part(mid, _cyl(0.017, 0.17), m.metal, Vector3(r * 0.7, 0.0, sz * 0.035))
				_part(mid, _cyl(0.013, 0.09), m.accent, Vector3(r * 0.7, -0.02, sz * 0.035))
		"servo":
			_part(mid, _cyl(0.020, 0.21), m.metal)
			_part(mid, _cyl(0.028, 0.07), m.accent, Vector3(r * 0.6, 0.02, 0.0))
		"cuff":
			_part(mid, _cyl(r * 1.5, 0.05, 10), m.trim, Vector3(0.0, -0.10, 0.0))
			_part(mid, _box(Vector3(0.02, 0.05, 0.09)), m.accent, Vector3(r + 0.01, -0.10, 0.0))


static func _strut(
	root: Node3D, a: Vector3, b: Vector3, radius: float, mat: StandardMaterial3D
) -> MeshInstance3D:
	return ProceduralModels._strut(root, a, b, radius, mat)


## A basis for a limb spanning a→b: +Y along the limb, +X the OUTWARD side (`sx`),
## Gram-Schmidt'd against the limb so decorations sit flat on the forearm.
static func _limb_basis(a: Vector3, b: Vector3, sx: float) -> Basis:
	var y := b - a
	if y.length_squared() < 0.000001:
		return Basis.IDENTITY
	y = y.normalized()
	var outward := Vector3(sx, 0.0, 0.0)
	var x := outward - y * outward.dot(y)
	if x.length_squared() < 0.0001:
		# Degenerate (limb running straight out sideways) — fall back to a forward ref.
		x = Vector3(0.0, 0.0, -1.0)
		x = x - y * x.dot(y)
	x = x.normalized()
	return Basis(x, y, x.cross(y))


static func _kill_shadows(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in node.get_children():
		_kill_shadows(c)
