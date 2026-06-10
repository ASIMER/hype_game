extends RefCounted
class_name ProceduralWeapons
## Procedural weapon view-models (smg / shotgun / pistol / dmr) assembled from the
## shared ProceduralModels primitive helpers (_part/_strut/_box/_cyl/_cone) so the
## held weapon reads as a real gun instead of a flat primitive box. AssetRegistry
## routes these ids here when their .glb path is empty.
##
## Authoring convention (matches the .glb weapons + held-in-hand expectation):
##   - facing -Z (muzzle forward), grip pointing DOWN (-Y), body roughly centred
##     around the WeaponMount origin so it sits in the hand.
##   - built at FINAL hand-held size (~0.45-0.7 m long) — AssetRegistry applies NO
##     model_scale to builder output for these ids.
##   - StandardMaterial3D only (ProcMaterials.weathered worn gunmetal + a small
##     emissive sight dot); modest part counts.

const WEAPON_IDS := ["smg", "shotgun", "pistol", "dmr"]


static func has_builder(id: String) -> bool:
	return id in WEAPON_IDS


static func build(id: String) -> Node3D:
	match id:
		"smg":
			return _build_smg()
		"shotgun":
			return _build_shotgun()
		"pistol":
			return _build_pistol()
		"dmr":
			return _build_dmr()
	return null


# --------------------------------------------------------------- materials
## Worn gunmetal receiver (world=false so the weathering doesn't swim as the gun
## moves in the hand).
static func _gunmetal() -> StandardMaterial3D:
	return ProcMaterials.weathered(
		Color(0.13, 0.14, 0.16), 0.6, 0.45, 0.55, 7, Vector3(0.4, 0.4, 0.4), false
	)


static func _dark() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.08, 0.085, 0.095), 0.45, 0.55)


## A matte polymer (grips / furniture) — slightly browner than the receiver.
static func _polymer() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.1, 0.1, 0.11), 0.15, 0.7)


static func _steel() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.34, 0.36, 0.39), 0.75, 0.3)


## A small glowing sight dot (faces the shooter).
static func _sight_dot() -> StandardMaterial3D:
	return ProceduralModels._mat(Color(0.4, 1.0, 0.55), 0.0, 0.3, Color(0.3, 1.0, 0.45), 4.0)


# Convenience aliases onto the shared primitive makers.
static func _box(size: Vector3) -> BoxMesh:
	return ProceduralModels._box(size)


static func _cyl(r: float, h: float, seg := 10) -> CylinderMesh:
	return ProceduralModels._cyl(r, h, seg)


static func _cone(r: float, h: float, seg := 10) -> CylinderMesh:
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


## A barrel cylinder running along -Z (muzzle toward -Z). `len` along Z, centred at
## z = `z`. Cylinders are authored along +Y so we tip them 90° about X.
static func _barrel(
	parent: Node3D, r: float, length: float, z: float, y: float, mat: StandardMaterial3D, seg := 12
) -> MeshInstance3D:
	return _part(parent, _cyl(r, length, seg), mat, Vector3(0, y, z), Vector3(90, 0, 0))


## A simple iron front+rear notch sight pair on the top rail, with a glowing rear dot.
static func _iron_sights(root: Node3D, top_y: float, front_z: float, rear_z: float) -> void:
	var metal := _steel()
	_part(root, _box(Vector3(0.012, 0.05, 0.012)), metal, Vector3(0, top_y + 0.03, front_z))  # front post
	_part(root, _box(Vector3(0.05, 0.04, 0.012)), metal, Vector3(0, top_y + 0.025, rear_z))  # rear leaf
	_part(root, _box(Vector3(0.012, 0.018, 0.012)), _sight_dot(), Vector3(0, top_y + 0.035, rear_z))  # glowing dot


## A short top rail block under the sights.
static func _rail(root: Node3D, length: float, z: float, top_y: float) -> void:
	_part(root, _box(Vector3(0.03, 0.018, length)), _dark(), Vector3(0, top_y + 0.005, z))


## A trigger guard loop (a thin ring under the receiver, in front of the grip).
static func _trigger_guard(root: Node3D, z: float, y: float) -> void:
	var metal := _steel()
	_part(root, _box(Vector3(0.022, 0.05, 0.012)), metal, Vector3(0, y, z + 0.045))  # front strap
	_part(root, _box(Vector3(0.022, 0.012, 0.1)), metal, Vector3(0, y - 0.022, z))  # bottom bar
	_part(root, _cone(0.012, 0.05, 6), metal, Vector3(0, y + 0.01, z), Vector3(180, 0, 0))  # trigger blade


## An angled pistol grip pointing down-and-back from (z,y).
static func _grip(root: Node3D, z: float, y: float, length: float, lean := 18.0) -> MeshInstance3D:
	return _part(
		root,
		_box(Vector3(0.05, length, 0.07)),
		_polymer(),
		Vector3(0, y - length * 0.5, z),
		Vector3(lean, 0, 0)
	)


## Adds a named Marker3D child (local space, gun faces -Z). Combat FX read "Muzzle" (barrel
## tip → flash/smoke/tracer origin) and "Eject" (right-side port → shell casings) off the held
## view-model so the effects leave the actual gun, not the camera.
static func _mark(root: Node3D, mark_name: String, pos: Vector3) -> void:
	var m := Marker3D.new()
	m.name = mark_name
	m.position = pos
	root.add_child(m)


# ================================================================= BUILDERS


## SMG — compact: short receiver, short barrel, vertical-ish box mag, collapsible
## stock, top rail with a small glowing sight. ~0.5 m long.
static func _build_smg() -> Node3D:
	var root := Node3D.new()
	var metal := _gunmetal()
	var dark := _dark()
	# Receiver body (compact). Centre near origin; muzzle toward -Z.
	_part(root, _box(Vector3(0.07, 0.1, 0.3)), metal, Vector3(0, 0.0, -0.04))
	_part(root, _box(Vector3(0.075, 0.05, 0.18)), dark, Vector3(0, 0.055, -0.02))  # top cover / ejection
	# Short barrel + a stubby handguard shroud.
	_barrel(root, 0.018, 0.2, -0.26, 0.0, _steel(), 10)
	_part(root, _box(Vector3(0.05, 0.05, 0.14)), dark, Vector3(0, 0.0, -0.22))  # handguard
	# Curved-ish box magazine under the receiver (slightly forward), angled.
	_part(root, _box(Vector3(0.045, 0.2, 0.07)), dark, Vector3(0, -0.13, 0.0), Vector3(10, 0, 0))
	_part(root, _box(Vector3(0.05, 0.03, 0.08)), metal, Vector3(0, -0.04, 0.01))  # mag well
	# Pistol grip + trigger guard.
	_grip(root, 0.1, -0.03, 0.13, 22.0)
	_trigger_guard(root, 0.06, -0.04)
	# Collapsible wire stock to the rear (+Z) with a shoulder pad.
	_part(root, _box(Vector3(0.02, 0.02, 0.12)), dark, Vector3(0.03, 0.0, 0.16))
	_part(root, _box(Vector3(0.02, 0.02, 0.12)), dark, Vector3(-0.03, 0.0, 0.16))
	_part(root, _box(Vector3(0.05, 0.08, 0.025)), _polymer(), Vector3(0, 0.0, 0.22))  # butt pad
	# Top rail + iron sights with glowing rear dot.
	_rail(root, 0.16, -0.02, 0.085)
	_iron_sights(root, 0.085, -0.16, 0.07)
	_mark(root, "Muzzle", Vector3(0, 0.0, -0.37))
	_mark(root, "Eject", Vector3(0.05, 0.05, -0.02))
	return root


## SHOTGUN — wide pump: thick barrel with a tube magazine slung UNDER the barrel,
## a sliding pump grip on it, wooden-ish stock. ~0.62 m long, beefy silhouette.
static func _build_shotgun() -> Node3D:
	var root := Node3D.new()
	var metal := _gunmetal()
	var dark := _dark()
	var wood := ProceduralModels._mat(Color(0.16, 0.1, 0.07), 0.1, 0.65)  # dark furniture
	# Receiver block (thick).
	_part(root, _box(Vector3(0.08, 0.11, 0.2)), metal, Vector3(0, 0.0, 0.02))
	_part(root, _box(Vector3(0.085, 0.04, 0.14)), dark, Vector3(0, 0.06, 0.0))  # top of receiver
	# Thick barrel forward (-Z), long.
	_barrel(root, 0.032, 0.36, -0.26, 0.025, metal, 14)
	# Under-barrel tube magazine + a sliding pump fore-grip on it.
	_barrel(root, 0.026, 0.32, -0.24, -0.04, dark, 12)
	_part(root, _box(Vector3(0.075, 0.07, 0.1)), wood, Vector3(0, -0.04, -0.18))  # pump slide
	_part(root, _box(Vector3(0.085, 0.018, 0.1)), dark, Vector3(0, -0.075, -0.18))  # ribbed underside
	# Pistol-wrist grip + trigger guard.
	_grip(root, 0.1, -0.04, 0.14, 16.0)
	_trigger_guard(root, 0.07, -0.05)
	# Full wooden buttstock to the rear (+Z).
	_part(root, _box(Vector3(0.06, 0.09, 0.18)), wood, Vector3(0, -0.02, 0.21), Vector3(-6, 0, 0))
	_part(root, _box(Vector3(0.065, 0.11, 0.03)), dark, Vector3(0, -0.04, 0.3))  # butt pad
	# A simple bead front sight (no glow needed — keep it gritty) + tiny glow dot.
	_part(root, _cyl(0.01, 0.03, 6), _steel(), Vector3(0, 0.062, -0.42))
	_part(root, _box(Vector3(0.012, 0.016, 0.012)), _sight_dot(), Vector3(0, 0.07, -0.42))
	_mark(root, "Muzzle", Vector3(0, 0.025, -0.45))
	_mark(root, "Eject", Vector3(0.055, 0.06, 0.02))
	return root


## PISTOL — small/short: slide + frame, short barrel, single grip with a flush mag,
## tiny iron sights. ~0.24 m long — clearly the compact one.
static func _build_pistol() -> Node3D:
	var root := Node3D.new()
	var metal := _gunmetal()
	var dark := _dark()
	# Slide (top) + frame (bottom). Muzzle toward -Z.
	_part(root, _box(Vector3(0.045, 0.06, 0.22)), metal, Vector3(0, 0.03, -0.02))  # slide
	_part(root, _box(Vector3(0.04, 0.04, 0.16)), dark, Vector3(0, -0.01, 0.0))  # frame/dust cover
	# Muzzle hint at the front of the slide.
	_barrel(root, 0.012, 0.04, -0.14, 0.03, _steel(), 8)
	# Grip (steeper, with the mag flush inside it) + trigger guard.
	var grip := _grip(root, 0.06, -0.02, 0.14, 12.0)
	grip.material_override = _polymer()
	_part(
		root, _box(Vector3(0.04, 0.03, 0.05)), metal, Vector3(0, -0.135, 0.085), Vector3(12, 0, 0)
	)  # mag base
	_trigger_guard(root, 0.03, -0.03)
	# Tiny iron sights with a glowing rear dot.
	_part(root, _box(Vector3(0.01, 0.018, 0.01)), _steel(), Vector3(0, 0.065, -0.1))  # front post
	_part(root, _box(Vector3(0.035, 0.016, 0.01)), _steel(), Vector3(0, 0.062, 0.07))  # rear
	_part(root, _box(Vector3(0.009, 0.012, 0.009)), _sight_dot(), Vector3(0, 0.07, 0.07))  # glow dot
	_mark(root, "Muzzle", Vector3(0, 0.03, -0.17))
	_mark(root, "Eject", Vector3(0.035, 0.05, -0.02))
	return root


## DMR — long precision rifle: long receiver, long barrel with a muzzle brake, a
## REAL scope tube up top, angled mag, full stock with a cheek riser. ~0.7 m long.
static func _build_dmr() -> Node3D:
	var root := Node3D.new()
	var metal := _gunmetal()
	var dark := _dark()
	var lens := ProceduralModels._mat(Color(0.4, 0.7, 1.0), 0.0, 0.2, Color(0.35, 0.6, 1.0), 2.5)
	# Long receiver.
	_part(root, _box(Vector3(0.06, 0.09, 0.34)), metal, Vector3(0, 0.0, 0.0))
	_part(root, _box(Vector3(0.05, 0.05, 0.22)), dark, Vector3(0, 0.0, -0.18))  # handguard
	# Long barrel forward (-Z) + a muzzle brake.
	_barrel(root, 0.016, 0.34, -0.36, 0.0, _steel(), 12)
	_part(root, _cyl(0.026, 0.06, 10), dark, Vector3(0, 0.0, -0.52), Vector3(90, 0, 0))  # muzzle brake
	_part(root, _box(Vector3(0.05, 0.012, 0.04)), dark, Vector3(0, 0.026, -0.52))  # top port
	# Angled box magazine.
	_part(root, _box(Vector3(0.045, 0.18, 0.08)), dark, Vector3(0, -0.12, 0.04), Vector3(14, 0, 0))
	_part(root, _box(Vector3(0.05, 0.03, 0.09)), metal, Vector3(0, -0.03, 0.05))  # mag well
	# Pistol grip + trigger guard.
	_grip(root, 0.13, -0.02, 0.14, 20.0)
	_trigger_guard(root, 0.09, -0.03)
	# Full stock to the rear (+Z) with a cheek riser.
	_part(root, _box(Vector3(0.05, 0.06, 0.16)), _polymer(), Vector3(0, -0.01, 0.26))
	_part(root, _box(Vector3(0.045, 0.04, 0.1)), _polymer(), Vector3(0, 0.04, 0.24))  # cheek riser
	_part(root, _box(Vector3(0.055, 0.1, 0.03)), dark, Vector3(0, -0.02, 0.35))  # butt pad
	# REAL scope: tube up top on tall rings, with glowing objective/ocular lenses.
	var ring := _steel()
	_part(root, _cyl(0.018, 0.06, 8), ring, Vector3(0, 0.075, -0.06))  # front ring
	_part(root, _cyl(0.018, 0.06, 8), ring, Vector3(0, 0.075, 0.06))  # rear ring
	_part(root, _cyl(0.026, 0.24, 14), dark, Vector3(0, 0.11, 0.0), Vector3(90, 0, 0))  # scope tube
	_part(root, _cyl(0.034, 0.05, 14), dark, Vector3(0, 0.11, -0.12), Vector3(90, 0, 0))  # objective bell
	_part(root, _cyl(0.03, 0.02, 14), lens, Vector3(0, 0.11, -0.145), Vector3(90, 0, 0))  # objective lens
	_part(root, _cyl(0.026, 0.02, 14), lens, Vector3(0, 0.11, 0.12), Vector3(90, 0, 0))  # ocular lens (glow)
	_mark(root, "Muzzle", Vector3(0, 0.0, -0.56))
	_mark(root, "Eject", Vector3(0.045, 0.05, 0.0))
	return root
