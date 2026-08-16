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
##
## RELOAD CHOREOGRAPHY (D4.3): `build` returns an `ArmsRig` — the same render-only arm
## pair, plus a per-frame read of the owning WeaponController's reload clock. The pose is
## a PURE FUNCTION of the NORMALIZED progress t∈[0,1], sampled off keyframe tracks built
## once per weapon class (`_reload_tracks`), so it stretches itself to any reload_time
## (perks/attachments/mastery/Adrenaline all scale it for free), can be interrupted at any
## instant (the next frame simply samples t=0 again) and needs no timer and no tween.
## t≤0 is the authored idle/ADS pose, unchanged down to the transform.

const DEFAULT_WEAPON := "rifle"
const DEFAULT_ARMS := "arms_standard"
# Wrist joint in HAND-local space (the ball `_hand` parks at +Y). The forearm is aimed at
# this point, so the idle build and the reload choreography must read it from ONE place.
const WRIST_LOCAL := Vector3(0.0, 0.085, 0.01)
# How much of the hand's reload travel the (off-frame) elbow follows. 0 = a pinned elbow
# and a badly telescoping forearm (the mag-pouch dip squashes it to ~0.67 of its length);
# 1 = the whole arm slides rigidly. 0.45 keeps the stretch inside ~0.76…1.20 — and since
# the elbow is off-frame anyway, moving it costs nothing on screen.
const RELOAD_ELBOW_FOLLOW := 0.45

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
## for `weapon_id` (a weapon .tres id). Render-only output — no signals, nothing to
## replicate; the caller parents it under the weapon's ModelHolder and toggles `visible`.
## The returned ArmsRig animates its own reload (see the class docs); a caller that wants
## to drive that itself calls `set_reload_progress` and the internal poll steps aside.
static func build(cosmetics: Dictionary = {}, weapon_id: String = DEFAULT_WEAPON) -> Node3D:
	var cos: Dictionary = ProceduralPlayer._with_defaults(cosmetics)
	var mats: Dictionary = ProceduralPlayer._mats(ProceduralPlayer._paint_of(String(cos["paint"])))
	var prof: Dictionary = PROFILES.get(String(cos["arms"]), PROFILES[DEFAULT_ARMS])
	var pose: Dictionary = POSES.get(weapon_id, POSES[DEFAULT_WEAPON])
	var root := ArmsRig.new()
	root.name = "FPArms"
	var recs: Array = []
	recs.append(_arm(root, pose, prof, mats, 1.0))  # right — trigger hand on the grip
	recs.append(_arm(root, pose, prof, mats, -1.0))  # left — support hand on the handguard
	root.setup(recs, _reload_tracks(pose, weapon_id), float(prof["hand"]))
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
## grip anchor, the left the fore anchor. Returns the JOINT RECORD the reload
## choreography re-poses each frame (see ArmsRig._pose_arm): the two drivable nodes plus
## the rest anchors every animated value is measured against.
static func _arm(
	root: Node3D, pose: Dictionary, prof: Dictionary, m: Dictionary, sx: float
) -> Dictionary:
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
	var wrist: Vector3 = hand.transform * (WRIST_LOCAL * hs)
	var limb := _forearm(root, wrist, elbow, prof, m, sx)
	# The trigger hand rides the "grip" track, the support hand does the mag/pump work.
	var track_key := "grip" if right else "sup"
	return {
		"hand": hand,
		"limb": limb,
		"at": at,
		"elbow": elbow,
		"sx": sx,
		"span": wrist.distance_to(elbow),
		"track": track_key,
	}


## A robot fist closed around a grip that runs along the hand's local +Y: armour plate on
## the back of the hand (outward = sx), fingers curled across the FRONT (-Z, muzzle side),
## thumb crossing the back.
static func _hand(hand: Node3D, prof: Dictionary, m: Dictionary, sx: float) -> void:
	var hs: float = float(prof["hand"])
	var tr := String(prof["trait"])
	# Wrist ball + rubber collar (the joint the forearm hangs off).
	_part(hand, _sph(0.048 * hs), m.metal, WRIST_LOCAL * hs)
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
##
## The whole forearm hangs off ONE node anchored AT THE WRIST whose basis is the limb
## frame (+Y toward the elbow) and whose children are authored along that +Y — the exact
## world layout the flat version produced, but now re-aimable as a unit: the reload only
## has to rewrite that node's transform (new direction + a stretch along local Y) for the
## arm to follow the fist instead of tearing off it. Returns that node.
static func _forearm(
	root: Node3D, wrist: Vector3, elbow: Vector3, prof: Dictionary, m: Dictionary, sx: float
) -> Node3D:
	var r: float = float(prof["r"])
	var tr := String(prof["trait"])
	var limb := Node3D.new()
	limb.name = "ForearmR" if sx > 0.0 else "ForearmL"
	limb.transform = Transform3D(_limb_basis(wrist, elbow, sx), wrist)
	root.add_child(limb)
	var span := wrist.distance_to(elbow)
	_strut(limb, Vector3.ZERO, Vector3(0.0, span, 0.0), r, m.armor)
	_part(limb, _sph(r * 1.25), m.metal, Vector3(0.0, span, 0.0))  # elbow cap (off-frame)
	# Sleeve cuff near the elbow — the "sleeve" every variant shares.
	var cuff := Node3D.new()
	cuff.position = Vector3(0.0, span * 0.76, 0.0)
	limb.add_child(cuff)
	_part(cuff, _cyl(r * 1.32, 0.06, 10), m.trim)
	# Variant feature, authored in LIMB space: +Y runs toward the elbow, +X is OUTWARD
	# (away from the gun centreline) on both sides, so nothing has to be hand-mirrored.
	var mid := Node3D.new()
	mid.position = Vector3(0.0, span * 0.42, 0.0)
	limb.add_child(mid)
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
	return limb


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


# ================================================================= RELOAD CHOREOGRAPHY
## The three keyframe tracks a reload plays, all in NORMALIZED time (t=0 the shot that
## emptied the mag, t=1 the round chambered) and all in WEAPON-VIEW-MODEL space:
##   "gun"  — the whole rig (gun + both hands) dipping out of the aim line and back;
##   "sup"  — the support hand: mag well / fresh mag / charging handle (or the pump);
##   "grip" — the trigger hand, which only flinches when the bolt or the pump slams.
## Built ONCE per weapon class off that class's POSES anchors, so a longer gun's mag well
## and charging handle move forward with it and nothing needs a second table.
static func _reload_tracks(pose: Dictionary, weapon_id: String) -> Dictionary:
	if weapon_id == "shotgun":
		return _tracks_pump(pose)
	return _tracks_mag(pose)


## Box-mag guns (rifle/smg/dmr/pistol): drop the empty, fetch a fresh one, slap it home,
## run the bolt. The support hand does all of it — that is the hand a real shooter reloads
## with, and it is the one whose rest anchor (the handguard) is free to leave.
static func _tracks_mag(pose: Dictionary) -> Dictionary:
	var grip: Vector3 = pose["grip"]
	var fore: Vector3 = pose["fore"]
	var grip_rot: Vector3 = pose["grip_rot"]
	var fore_rot: Vector3 = pose["fore_rot"]
	# The mag well sits under the receiver, roughly two thirds of the way back from the
	# handguard to the grip; the charging handle rides above and behind it.
	var well := Vector3(0.0, minf(grip.y, fore.y) - 0.11, lerpf(fore.z, grip.z, 0.62))
	var fetch := well + Vector3(-0.075, -0.17, 0.13)  # off-frame, at the mag pouch
	var charge := Vector3(0.02, maxf(grip.y, fore.y) + 0.085, grip.z + 0.03)
	# Wrist rake: rest is the ~105° "fingers over the handguard" lay; the mag grip rolls
	# the fist nearly upright (it has to come UNDER the magazine), the charging handle
	# pinch is halfway back up.
	var mag_rot := Vector3(-6.0, 0.0, -12.0)
	var chg_rot := Vector3(58.0, 0.0, -8.0)
	var release := fore.lerp(well, 0.45) + Vector3(-0.02, 0.0, 0.02)
	var pull := well + Vector3(-0.025, -0.15, 0.035)
	var sup: Array = [
		{"t": 0.0, "p": fore, "r": fore_rot},
		{"t": 0.1, "p": release, "r": fore_rot.lerp(mag_rot, 0.55)},
		{"t": 0.22, "p": well, "r": mag_rot},  # hand on the empty mag
		{"t": 0.34, "p": pull, "r": mag_rot + Vector3(-10.0, 0.0, -8.0)},  # ripped out
		{"t": 0.46, "p": fetch, "r": mag_rot + Vector3(-18.0, 0.0, -14.0)},  # fresh mag
		{"t": 0.6, "p": fetch + Vector3(0.03, 0.06, -0.03), "r": mag_rot},
		{"t": 0.72, "p": well + Vector3(0.0, -0.04, 0.0), "r": mag_rot},  # nosed in
		{"t": 0.78, "p": well + Vector3(0.0, 0.012, 0.0), "r": mag_rot},  # slapped home
		{"t": 0.86, "p": charge, "r": chg_rot},
		{"t": 0.9, "p": charge + Vector3(0.0, 0.0, 0.075), "r": chg_rot},  # YANK
		{"t": 0.94, "p": charge + Vector3(0.0, 0.0, -0.005), "r": chg_rot},  # released
		{"t": 1.0, "p": fore, "r": fore_rot},
	]
	var jolt := grip + Vector3(0.0, 0.0, 0.012)
	var grp: Array = [
		{"t": 0.0, "p": grip, "r": grip_rot},
		{"t": 0.86, "p": grip, "r": grip_rot},
		{"t": 0.9, "p": jolt, "r": grip_rot + Vector3(2.5, 0.0, 0.0)},  # bolt slams
		{"t": 0.95, "p": grip, "r": grip_rot},
	]
	var gun: Array = [
		{"t": 0.0, "p": Vector3.ZERO, "r": Vector3.ZERO},
		{"t": 0.14, "p": Vector3(0.012, -0.045, 0.03), "r": Vector3(-13.0, 9.0, 16.0)},
		{"t": 0.7, "p": Vector3(0.014, -0.05, 0.035), "r": Vector3(-15.0, 10.0, 18.0)},
		{"t": 0.86, "p": Vector3(0.008, -0.026, 0.02), "r": Vector3(-7.0, 6.0, 10.0)},
		{"t": 0.9, "p": Vector3(0.008, -0.02, 0.03), "r": Vector3(-4.0, 5.0, 8.0)},
		{"t": 1.0, "p": Vector3.ZERO, "r": Vector3.ZERO},
	]
	return {"gun": gun, "sup": sup, "grip": grp}


## The shotgun is tube-fed: the support hand leaves the pump, thumbs shells into the port
## under the receiver three times, then racks the pump back and slams it forward. (The
## pump slide is part of the gun mesh, so the RACK is sold by the hand's travel plus the
## gun's jolt — nothing reaches into another builder's node names.)
static func _tracks_pump(pose: Dictionary) -> Dictionary:
	var grip: Vector3 = pose["grip"]
	var fore: Vector3 = pose["fore"]
	var grip_rot: Vector3 = pose["grip_rot"]
	var fore_rot: Vector3 = pose["fore_rot"]
	var port := Vector3(0.0, minf(grip.y, fore.y) - 0.075, lerpf(fore.z, grip.z, 0.78))
	var belt := port + Vector3(-0.045, -0.13, 0.06)  # off-frame, at the shell loops
	var shell_rot := Vector3(20.0, 0.0, -10.0)
	var belt_rot := shell_rot + Vector3(-14.0, 0.0, -10.0)
	var racked := fore + Vector3(0.0, 0.005, 0.095)
	var sup: Array = [
		{"t": 0.0, "p": fore, "r": fore_rot},
		{"t": 0.1, "p": fore.lerp(port, 0.6), "r": fore_rot.lerp(shell_rot, 0.6)},
		{"t": 0.2, "p": port, "r": shell_rot},  # shell 1
		{"t": 0.3, "p": belt, "r": belt_rot},
		{"t": 0.4, "p": port, "r": shell_rot},  # shell 2
		{"t": 0.5, "p": belt, "r": belt_rot},
		{"t": 0.6, "p": port, "r": shell_rot},  # shell 3
		{"t": 0.72, "p": fore, "r": fore_rot},  # back on the pump
		{"t": 0.84, "p": racked, "r": fore_rot + Vector3(-7.0, 0.0, 0.0)},  # RACK back
		{"t": 0.92, "p": fore + Vector3(0.0, 0.0, -0.014), "r": fore_rot},  # slam forward
		{"t": 1.0, "p": fore, "r": fore_rot},
	]
	var grp: Array = [
		{"t": 0.0, "p": grip, "r": grip_rot},
		{"t": 0.84, "p": grip, "r": grip_rot},
		{"t": 0.88, "p": grip + Vector3(0.0, 0.0, 0.014), "r": grip_rot + Vector3(3.0, 0.0, 0.0)},
		{"t": 0.94, "p": grip, "r": grip_rot},
	]
	var gun: Array = [
		{"t": 0.0, "p": Vector3.ZERO, "r": Vector3.ZERO},
		{"t": 0.12, "p": Vector3(0.01, -0.04, 0.026), "r": Vector3(-12.0, 8.0, 14.0)},
		{"t": 0.66, "p": Vector3(0.012, -0.044, 0.03), "r": Vector3(-13.0, 9.0, 15.0)},
		{"t": 0.8, "p": Vector3(0.004, -0.016, 0.014), "r": Vector3(-4.0, 4.0, 6.0)},
		{"t": 0.88, "p": Vector3(0.004, -0.01, 0.026), "r": Vector3(2.0, 3.0, 5.0)},
		{"t": 1.0, "p": Vector3.ZERO, "r": Vector3.ZERO},
	]
	return {"gun": gun, "sup": sup, "grip": grp}


## Samples a track at `t` — smoothstepped between the bracketing keys, clamped at both
## ends. THE pure function the whole choreography rests on: same t in, same pose out, no
## history, so an interrupt (switch/cancel/death) only has to stop feeding it a t.
static func _sample(track: Array, t: float) -> Dictionary:
	var n := track.size()
	if n == 0:
		return {"p": Vector3.ZERO, "r": Vector3.ZERO}
	var first: Dictionary = track[0]
	if n == 1 or t <= float(first["t"]):
		return {"p": first["p"], "r": first["r"]}
	for i in range(1, n):
		var b: Dictionary = track[i]
		var bt := float(b["t"])
		if t > bt:
			continue
		var a: Dictionary = track[i - 1]
		var at := float(a["t"])
		var u: float = 1.0 if bt <= at else smoothstep(0.0, 1.0, (t - at) / (bt - at))
		var ap: Vector3 = a["p"]
		var bp: Vector3 = b["p"]
		var ar: Vector3 = a["r"]
		var br: Vector3 = b["r"]
		return {"p": ap.lerp(bp, u), "r": ar.lerp(br, u)}
	var last: Dictionary = track[n - 1]
	return {"p": last["p"], "r": last["r"]}


## The node `build` returns: the assembled arms PLUS the reload animator.
##
## It drives itself. PlayerGear owns the arms' lifecycle by POLLING (there is no signal
## for the FP view step) and frees them on every weapon switch, so wiring a per-frame
## update call through it would have meant editing that file for a purely cosmetic effect;
## instead the rig reads the reload clock off the owning WeaponController the way the HUD
## reads ammo. It prefers a public `reload_progress()` if the controller ever grows one and
## otherwise falls back to the controller's own `_reloading`/`_reload_timer` pair,
## normalized by the reload length reconstructed from PUBLIC api (`current_weapon()`
## .reload_time × the player's `buff_reload_mult()` — exactly what _begin_reload uses).
##
## The gun itself dips too, which means moving the weapon model: it is our SIBLING under
## ModelHolder (never a parent — the controller's recoil kick owns ModelHolder's own
## transform and would overwrite us every frame). We cache each sibling's rest transform,
## write `dip * rest` while t>0 and put them back on the way out, including _exit_tree,
## so a rig freed mid-reload can never leave the gun tilted.
class ArmsRig:
	extends Node3D

	const CONTROLLER_PATH := "CameraPivot/SpringArm3D/Camera3D/WeaponController"

	## False once someone calls set_reload_progress(): whoever drives it, owns it.
	var auto_poll := true

	var _joints: Array = []  # per-arm records from ProceduralArms._arm
	var _tracks: Dictionary = {}  # "gun"/"sup"/"grip" → keyframe arrays
	var _hs := 1.0  # hand scale (WRIST_LOCAL is authored at 1.0)
	var _rest := Transform3D.IDENTITY  # our own untouched transform
	var _t := -1.0  # last applied progress (-1 = nothing applied yet)
	var _gun: Array = []  # [{node, rest}] sibling weapon nodes we dip with us
	var _wc: Node = null
	var _player: Node = null
	var _probe := 0  # 0 unresolved, 1 controller readable, -1 give up (stay at rest)
	var _total := 1.0  # length of the reload currently running, seconds
	var _tracking := false
	var _armed := false  # seen a rest frame, so the cached gun rest pose is trustworthy

	func _ready() -> void:
		_rest = transform

	## Restores the gun if we are freed (weapon switch / cosmetics rebuild / leaving FP)
	## while the dip is applied — otherwise the tilt would outlive its animator.
	func _exit_tree() -> void:
		_restore_gun()

	func _process(_delta: float) -> void:
		if not auto_poll:
			return
		# Third person: PlayerGear hides us, and a dipped gun IS visible there.
		if not visible:
			if _t > 0.0:
				_apply(0.0)
			return
		_apply(_poll_progress())

	## Handed the joint records + tracks by ProceduralArms.build.
	func setup(joints: Array, tracks: Dictionary, hand_scale: float) -> void:
		_joints = joints
		_tracks = tracks
		_hs = hand_scale

	## Drive the choreography EXTERNALLY (0 = idle pose … 1 = round chambered). The first
	## call switches the internal poll off for good, so the caller must feed it every
	## frame — and can stop at any t simply by feeding 0.
	func set_reload_progress(t: float) -> void:
		auto_poll = false
		_apply(t)

	## Applies the pose for `t`. Pure: nothing here reads its own previous output (the _t
	## check is a redundant-work guard, not state), so any t can follow any other t.
	func _apply(t: float) -> void:
		if _tracks.is_empty():
			return
		var tt := clampf(t, 0.0, 1.0)
		if tt <= 0.0:
			_armed = true
		elif not _armed:
			# Built mid-reload (a cosmetics rebuild): we have never seen the gun at rest,
			# so caching "rest" now would bake in someone else's dip. Sit this one out.
			return
		if is_equal_approx(tt, _t):
			return
		_t = tt
		var gun_track: Array = _tracks["gun"]
		var g: Dictionary = ProceduralArms._sample(gun_track, tt)
		var gp: Vector3 = g["p"]
		var gr: Vector3 = g["r"]
		var dip := Transform3D(ProceduralArms._euler(gr), gp)
		transform = dip * _rest
		if tt <= 0.0:
			_restore_gun()
		else:
			_capture_gun()
			for e in _gun:
				var rec: Dictionary = e
				if not is_instance_valid(rec["node"]):
					continue
				var n: Node3D = rec["node"]
				var rest: Transform3D = rec["rest"]
				n.transform = dip * rest
		for j in _joints:
			var jr: Dictionary = j
			_pose_arm(jr, tt)

	## One arm at `t`: the fist goes where its track says, then the forearm is re-aimed
	## from the new wrist at the (slightly following) elbow and stretched along its own
	## axis to span the gap — a plain 1-bone solve, and the identity at t=0.
	func _pose_arm(joint: Dictionary, t: float) -> void:
		if not is_instance_valid(joint["hand"]) or not is_instance_valid(joint["limb"]):
			return
		var hand: Node3D = joint["hand"]
		var limb: Node3D = joint["limb"]
		var track: Array = _tracks[String(joint["track"])]
		var s: Dictionary = ProceduralArms._sample(track, t)
		var hp: Vector3 = s["p"]
		var hr: Vector3 = s["r"]
		hand.transform = Transform3D(ProceduralArms._euler(hr), hp)
		var at: Vector3 = joint["at"]
		var elbow: Vector3 = joint["elbow"]
		elbow += (hp - at) * ProceduralArms.RELOAD_ELBOW_FOLLOW
		var wrist: Vector3 = hand.transform * (ProceduralArms.WRIST_LOCAL * _hs)
		var span: float = joint["span"]
		var k := clampf(wrist.distance_to(elbow) / maxf(0.001, span), 0.55, 1.7)
		var lb := ProceduralArms._limb_basis(wrist, elbow, float(joint["sx"]))
		limb.transform = Transform3D(lb * Basis.from_scale(Vector3(1.0, k, 1.0)), wrist)

	## Normalized progress of the reload the owning controller is running, 0 if none.
	func _poll_progress() -> float:
		var wc := _controller()
		if wc == null:
			return 0.0
		if wc.has_method("reload_progress"):
			var pv: Variant = wc.call("reload_progress")
			return clampf(float(pv), 0.0, 1.0) if pv is float else 0.0
		var rv: Variant = wc.get("_reloading")
		var tv: Variant = wc.get("_reload_timer")
		if not (rv is bool) or not (tv is float):
			_probe = -1  # controller renamed its clock — stay in the idle pose
			return 0.0
		if not bool(rv):
			_tracking = false
			return 0.0
		var left := float(tv)
		if not _tracking:
			# Rising edge: the controller counts DOWN, so the length has to be
			# reconstructed once, and never below what is already on the clock.
			_tracking = true
			_total = maxf(_reload_seconds(wc), left)
		return clampf(1.0 - left / maxf(0.05, _total), 0.0, 1.0)

	## The length _begin_reload would have set, from public api only: the EQUIPPED
	## weapon's already-modified reload_time (perks/attachments/mastery are folded into
	## the controller's duplicate) × the player's active reload buff.
	func _reload_seconds(wc: Node) -> float:
		var secs := 1.6
		if wc.has_method("current_weapon"):
			var d: Variant = wc.call("current_weapon")
			if d is Resource:
				var rt: Variant = (d as Resource).get("reload_time")
				if rt is float:
					secs = float(rt)
		if is_instance_valid(_player) and _player.has_method("buff_reload_mult"):
			var bm: Variant = _player.call("buff_reload_mult")
			if bm is float:
				secs *= float(bm)
		return maxf(0.1, secs)

	## The WeaponController of the player we are mounted on. ModelHolder was reparented to
	## WeaponMount, so the controller is NOT an ancestor — walk up to the body, then down.
	func _controller() -> Node:
		if _probe < 0:
			return null
		if is_instance_valid(_wc):
			return _wc
		var n: Node = get_parent()
		while n != null and not (n is CharacterBody3D):
			n = n.get_parent()
		if n == null:
			return null
		_player = n
		var wc := n.get_node_or_null(CONTROLLER_PATH)
		if wc == null:
			wc = n.find_child("WeaponController", true, false)
		if wc == null:
			_probe = -1
			return null
		_wc = wc
		_probe = 1
		return wc

	## Caches the rest transform of every sibling under ModelHolder (the weapon model and
	## its fallback Muzzle/Eject markers) so the dip can be written and undone as a delta.
	func _capture_gun() -> void:
		if not _gun.is_empty():
			return
		var holder := get_parent() as Node3D
		if holder == null:
			return
		for c in holder.get_children():
			if c == self:
				continue
			var n := c as Node3D
			if n != null:
				_gun.append({"node": n, "rest": n.transform})

	func _restore_gun() -> void:
		for e in _gun:
			var rec: Dictionary = e
			if is_instance_valid(rec["node"]):
				var n: Node3D = rec["node"]
				n.transform = rec["rest"]
		_gun.clear()
