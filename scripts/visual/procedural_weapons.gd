extends RefCounted
class_name ProceduralWeapons
## Procedural weapon view-models v2 (D4.1) — pistol / smg / rifle / shotgun / dmr assembled
## from the shared ProceduralModels primitive helpers. The gun is on screen 100% of the
## match, so every class now carries the parts a player actually reads: a Picatinny rail,
## a hooded front post + a rear notch/aperture, a real stock, a SEPARATE detachable
## magazine, a textured grip, a handguard/forend and a muzzle device.
##
## Authoring convention (matches the .glb weapons + held-in-hand expectation):
##   - facing -Z (muzzle forward), grip pointing DOWN (-Y), body roughly centred
##     around the WeaponMount origin so it sits in the hand.
##   - built at FINAL hand-held size — AssetRegistry applies NO model_scale to builder
##     output for these ids (so an id must have its CATALOG "model" path CLEARED to
##     route here; a present .glb wins over a builder).
##
## NAMED NODES the rest of the game reads off the view-model (never rename):
##   "Muzzle" — Marker3D at the real barrel tip: flash / smoke / tracer origin.
##   "Eject"  — Marker3D at the ejection port: shell casings.
##   "Magazine" — the DETACHABLE mag as its own Node3D subtree (body + curved lower half +
##     floorplate). Reload choreography animates THIS node (drop / swap / seat) without
##     touching the receiver; its pivot is the mag-well mouth so a rotation reads as a rock-in.
##   "Grip" / "Rail" / "Scope" — grouped for the same reason (idle sway, ADS, attachments).
##
## MATERIALS come from the ProcPlating family only (blued receiver / polymer furniture /
## rubber grip / lacquered wood / bare steel), NEVER a hand-rolled StandardMaterial3D:
## one texture bake serves every part and the finish stays consistent with the machines.
## Emissive is limited to SIGHT MARKS and INDICATORS (tritium beads, scope lenses, the
## ammo strip) — a gun this close to the camera must not glow anywhere else.
##
## BAKE-SEED PIN (perf): ProcPlating caches its 256² bakes per (archetype, seed) where
## seed = (|sid| % 3) % 2, and a COLD pair costs a ~0.5-1 s main-thread bake. The sids
## below are pinned to pairs the enemy kits already warm at boot, so swapping a weapon
## never hitches. Change a sid only against ProcEnemyKits._SPECS.

const WEAPON_IDS := ["smg", "shotgun", "pistol", "dmr", "rifle"]

# Palette. Deliberately mid-value, not black: the world relight lifted the whole scene and
# a near-black gun sinks under the cold grade's floor (the same lesson the enemy kits took).
const _C_BLUED := Color(0.30, 0.31, 0.34)  # blued/parkerized receiver steel
const _C_POLY := Color(0.235, 0.24, 0.255)  # polymer furniture (handguard / stock / mag)
const _C_GRIP := Color(0.20, 0.205, 0.215)  # stippled rubber grip
const _C_HW := Color(0.225, 0.23, 0.245)  # small hardware (rails, sights, pins)
const _C_WOOD := Color(0.42, 0.27, 0.155)  # lacquered furniture (shotgun)
const _C_BRASS := Color(0.60, 0.46, 0.19)
const _C_GLOW := Color(0.45, 1.0, 0.60)  # tritium sight mark
const _C_LENS := Color(0.42, 0.70, 1.0)

# Triplanar repeat = 1/scale metres. A gun is ~0.5 m, so the enemy-scale default (0.55 ->
# a 1.8 m repeat) would stretch ONE panel across the whole receiver.
const _UV_BODY := Vector3(6.0, 6.0, 6.0)  # ~17 cm panel pitch on the receiver
const _UV_FINE := Vector3(11.0, 11.0, 11.0)  # small hardware
const _UV_GRIP := Vector3(8.0, 8.0, 8.0)  # rubber weave at thumb scale
const _UV_WOOD := Vector3(3.0, 3.0, 3.0)  # broad soft grain bands


## The per-gun material set. A typed holder (not a Dictionary) on purpose: Dictionary
## lookups return Variant, which is the `var x := <Variant>` parse trap this codebase bans.
class Kit:
	var blued: StandardMaterial3D
	var poly: StandardMaterial3D
	var grip: StandardMaterial3D
	var hw: StandardMaterial3D
	var steel: StandardMaterial3D
	var wood: StandardMaterial3D
	var brass: StandardMaterial3D
	var glow: StandardMaterial3D
	var lens: StandardMaterial3D


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
		"rifle":
			return _build_rifle()
	return null


# --------------------------------------------------------------- materials
## One fresh material set per built gun (shared by that gun's parts). Instances are never
## cached across builds — ProcPlating's contract is "textures cached, materials fresh", and
## a shared instance would let one weapon's future tint bleed into every other.
static func _kit() -> Kit:
	var k := Kit.new()
	k.blued = ProcPlating.plated(_C_BLUED, ProcPlating.Arch.MECH_HULL, 71, 0.35, 0.34, _UV_BODY)
	k.poly = ProcPlating.plated(_C_POLY, ProcPlating.Arch.ARMOR_PLATE, 47, 0.03, 0.62, _UV_BODY)
	k.grip = ProcPlating.plated(_C_GRIP, ProcPlating.Arch.RUBBER, 24, 0.02, 0.88, _UV_GRIP)
	k.hw = ProcPlating.plated(_C_HW, ProcPlating.Arch.MECH_HULL, 127, 0.30, 0.48, _UV_FINE)
	k.wood = ProcPlating.plated(_C_WOOD, ProcPlating.Arch.LACQUER, 79, 0.02, 0.34, _UV_WOOD)
	k.brass = ProcPlating.plated(_C_BRASS, ProcPlating.Arch.MECH_HULL, 71, 0.72, 0.30, _UV_FINE)
	k.steel = ProcPlating.steel(0.95)
	k.glow = ProcPlating.glow(_C_GLOW, 3.0)
	k.lens = ProcPlating.glow(_C_LENS, 2.0)
	return k


# Convenience aliases onto the shared primitive makers.
static func _box(size: Vector3) -> BoxMesh:
	return ProceduralModels._box(size)


static func _cyl(r: float, h: float, seg := 10) -> CylinderMesh:
	return ProceduralModels._cyl(r, h, seg)


static func _torus(inner: float, outer: float, rings := 10, seg := 6) -> TorusMesh:
	return ProceduralModels._torus(inner, outer, rings, seg)


static func _part(
	parent: Node3D,
	mesh: Mesh,
	mat: StandardMaterial3D,
	offset := Vector3.ZERO,
	rot_deg := Vector3.ZERO,
	scale := Vector3.ONE
) -> MeshInstance3D:
	return ProceduralModels._part(parent, mesh, mat, offset, rot_deg, scale)


## A cylinder running along -Z/+Z (barrels, tubes, scope bodies). Cylinders are authored
## along +Y so we tip them 90 degrees about X.
static func _zcyl(
	parent: Node3D, r: float, length: float, pos: Vector3, mat: StandardMaterial3D, seg := 12
) -> MeshInstance3D:
	return _part(parent, _cyl(r, length, seg), mat, pos, Vector3(90, 0, 0))


## `count` copies of ONE box mesh stepping from `first` — the whole vocabulary of repeated
## detail (rail slots, slide serrations, vent louvres, grip grooves, M-LOK cuts, witness
## holes). The mesh is built once and shared by the row, so a 8-slot rail costs 1 Mesh.
static func _row(
	parent: Node3D,
	mat: StandardMaterial3D,
	size: Vector3,
	first: Vector3,
	step: Vector3,
	count: int,
	rot_deg := Vector3.ZERO
) -> void:
	if count <= 0:
		return
	var mesh := _box(size)
	for i in count:
		_part(parent, mesh, mat, first + step * float(i), rot_deg)


# ---------------------------------------------------------------- components


## Picatinny top rail spanning z_front..z_back: base + top strip + proud cross-ribs (the
## ribs ARE the read — a flat bar at this size just looks like a seam).
static func _rail(
	parent: Node3D, kit: Kit, z_front: float, z_back: float, y: float, slots: int
) -> Node3D:
	var rail := Node3D.new()
	rail.name = "Rail"
	parent.add_child(rail)
	var length: float = z_back - z_front
	var mid: float = (z_front + z_back) * 0.5
	_part(rail, _box(Vector3(0.030, 0.009, length)), kit.hw, Vector3(0, y, mid))
	_part(rail, _box(Vector3(0.019, 0.008, length)), kit.hw, Vector3(0, y + 0.008, mid))
	if slots > 1:
		var step: float = (length - 0.024) / float(slots - 1)
		_row(
			rail,
			kit.blued,
			Vector3(0.032, 0.011, 0.007),
			Vector3(0, y + 0.004, z_front + 0.012),
			Vector3(0, 0, step),
			slots
		)
	return rail


## Hooded front post with a tritium bead. `s` scales the whole assembly (pistols get 0.8).
static func _front_sight(parent: Node3D, kit: Kit, z: float, y: float, s: float) -> void:
	_part(parent, _box(Vector3(0.028, 0.010, 0.014) * s), kit.hw, Vector3(0, y, z))
	_part(parent, _box(Vector3(0.007, 0.026, 0.008) * s), kit.hw, Vector3(0, y + 0.018 * s, z))
	var wing := _box(Vector3(0.006, 0.024, 0.009) * s)
	_part(parent, wing, kit.hw, Vector3(-0.011 * s, y + 0.017 * s, z), Vector3(0, 0, 9))
	_part(parent, wing, kit.hw, Vector3(0.011 * s, y + 0.017 * s, z), Vector3(0, 0, -9))
	_part(parent, _box(Vector3(0.005, 0.005, 0.006) * s), kit.glow, Vector3(0, y + 0.029 * s, z))


## Rear sight: a ghost-ring APERTURE (rifles/dmr/shotgun) or a two-dot NOTCH (pistol/smg).
static func _rear_sight(
	parent: Node3D, kit: Kit, z: float, y: float, aperture: bool, s: float
) -> void:
	_part(parent, _box(Vector3(0.034, 0.010, 0.016) * s), kit.hw, Vector3(0, y, z))
	if aperture:
		_part(
			parent,
			_torus(0.007 * s, 0.014 * s, 10, 6),
			kit.hw,
			Vector3(0, y + 0.022 * s, z),
			Vector3(90, 0, 0)
		)
		_part(
			parent, _box(Vector3(0.005, 0.005, 0.005) * s), kit.glow, Vector3(0, y + 0.034 * s, z)
		)
		return
	var post := _box(Vector3(0.010, 0.022, 0.008) * s)
	var dot := _box(Vector3(0.005, 0.005, 0.006) * s)
	_part(parent, post, kit.hw, Vector3(-0.012 * s, y + 0.015 * s, z))
	_part(parent, post, kit.hw, Vector3(0.012 * s, y + 0.015 * s, z))
	_part(parent, dot, kit.glow, Vector3(-0.012 * s, y + 0.025 * s, z))
	_part(parent, dot, kit.glow, Vector3(0.012 * s, y + 0.025 * s, z))


## Trigger guard bow + the blade inside it. `z` is the guard centre, `y` the receiver underside.
static func _trigger_group(parent: Node3D, kit: Kit, z: float, y: float) -> void:
	_part(parent, _box(Vector3(0.020, 0.044, 0.010)), kit.hw, Vector3(0, y - 0.006, z - 0.042))
	_part(parent, _box(Vector3(0.020, 0.010, 0.094)), kit.hw, Vector3(0, y - 0.026, z))
	_part(parent, _box(Vector3(0.020, 0.022, 0.012)), kit.hw, Vector3(0, y - 0.012, z + 0.046))
	_part(
		parent,
		_box(Vector3(0.008, 0.028, 0.009)),
		kit.steel,
		Vector3(0, y - 0.013, z + 0.010),
		Vector3(-12, 0, 0)
	)


## Pistol grip as its own leaning subtree: stippled body + polymer backstrap + base cap +
## finger grooves down the front strap.
static func _grip(
	parent: Node3D, kit: Kit, z: float, y: float, length: float, lean: float
) -> Node3D:
	var g := Node3D.new()
	g.name = "Grip"
	g.position = Vector3(0, y, z)
	g.rotation_degrees = Vector3(lean, 0, 0)
	parent.add_child(g)
	var half: float = length * 0.5
	_part(g, _box(Vector3(0.042, length, 0.060)), kit.grip, Vector3(0, -half, 0))
	_part(g, _box(Vector3(0.046, length * 0.6, 0.012)), kit.poly, Vector3(0, -half * 0.85, 0.034))
	_part(g, _box(Vector3(0.048, 0.014, 0.066)), kit.hw, Vector3(0, -length - 0.005, 0))
	_row(
		g,
		kit.hw,
		Vector3(0.044, 0.006, 0.010),
		Vector3(0, -half * 0.55, -0.029),
		Vector3(0, -half * 0.5, 0),
		3
	)
	return g


## The DETACHABLE magazine — its own subtree named "Magazine" so reload choreography can
## drop/swap it. Pivot sits at the mag-well mouth (rotating the node rocks the mag out the
## way a real one leaves). `curve` kicks the lower half FORWARD, which is what makes a box
## mag read as a magazine instead of a brick.
static func _mag(
	parent: Node3D, kit: Kit, pos: Vector3, size: Vector3, lean: float, curve: float
) -> Node3D:
	var mag := Node3D.new()
	mag.name = "Magazine"
	mag.position = pos
	mag.rotation_degrees = Vector3(lean, 0, 0)
	parent.add_child(mag)
	var seg: float = size.y * 0.5
	_part(mag, _box(Vector3(size.x, seg, size.z)), kit.poly, Vector3(0, -seg * 0.5, 0))
	# Feed-lip collar at the well mouth.
	_part(mag, _box(Vector3(size.x + 0.007, 0.011, size.z + 0.006)), kit.hw, Vector3(0, -0.005, 0))
	var low := Node3D.new()
	low.name = "MagLower"
	low.position = Vector3(0, -seg, 0)
	low.rotation_degrees = Vector3(curve, 0, 0)
	mag.add_child(low)
	_part(low, _box(Vector3(size.x, seg, size.z)), kit.poly, Vector3(0, -seg * 0.5, 0))
	_row(
		low,
		kit.hw,
		Vector3(size.x + 0.002, 0.005, 0.011),
		Vector3(0, -seg * 0.28, -size.z * 0.5),
		Vector3(0, -seg * 0.3, 0),
		3
	)
	_part(
		low,
		_box(Vector3(size.x + 0.009, 0.013, size.z + 0.008)),
		kit.hw,
		Vector3(0, -seg - 0.006, 0)  # floorplate
	)
	return mag


## Muzzle device (brake / flash hider / choke): body + crown + collar + top ports.
static func _muzzle_device(
	parent: Node3D, kit: Kit, z: float, y: float, r: float, ports: int
) -> void:
	var length: float = r * 2.6
	_zcyl(parent, r, length, Vector3(0, y, z), kit.hw, 12)
	_zcyl(parent, r * 1.14, 0.007, Vector3(0, y, z - length * 0.5 + 0.004), kit.steel, 12)
	_zcyl(parent, r * 1.06, 0.007, Vector3(0, y, z + length * 0.5 - 0.004), kit.steel, 12)
	if ports > 0:
		var step: float = (length - 0.016) / float(maxi(ports, 1))
		_row(
			parent,
			kit.blued,
			Vector3(r * 2.3, 0.006, 0.006),
			Vector3(0, y + r * 0.6, z - length * 0.5 + 0.010),
			Vector3(0, 0, step),
			ports
		)


## Ejection port recess + the brass deflector behind it. `pos` is the port centre (right side).
static func _eject_port(parent: Node3D, kit: Kit, pos: Vector3) -> void:
	_part(parent, _box(Vector3(0.006, 0.026, 0.056)), kit.hw, pos)
	_part(parent, _box(Vector3(0.012, 0.020, 0.020)), kit.blued, pos + Vector3(0.004, 0.019, 0.030))


## Adds a named Marker3D child (local space, gun faces -Z). Combat FX read "Muzzle" (barrel
## tip -> flash/smoke/tracer origin) and "Eject" (right-side port -> shell casings) off the held
## view-model so the effects leave the actual gun, not the camera.
static func _mark(root: Node3D, mark_name: String, pos: Vector3) -> void:
	var m := Marker3D.new()
	m.name = mark_name
	m.position = pos
	root.add_child(m)


# ================================================================= BUILDERS


## PISTOL — compact slide+frame sidearm: serrated slide, accessory rail under the dust
## cover, flush magazine inside the grip, two-dot night sights. ~0.26 m.
static func _build_pistol() -> Node3D:
	var root := Node3D.new()
	var kit := _kit()
	_part(root, _box(Vector3(0.044, 0.056, 0.200)), kit.blued, Vector3(0, 0.030, -0.030))  # slide
	_part(root, _box(Vector3(0.016, 0.008, 0.190)), kit.hw, Vector3(0, 0.060, -0.030))  # sight rib
	_row(  # rear cocking serrations
		root,
		kit.hw,
		Vector3(0.046, 0.048, 0.005),
		Vector3(0, 0.030, 0.040),
		Vector3(0, 0, 0.011),
		4
	)
	_part(root, _box(Vector3(0.038, 0.034, 0.150)), kit.poly, Vector3(0, -0.004, -0.020))  # frame
	_part(root, _box(Vector3(0.026, 0.008, 0.070)), kit.hw, Vector3(0, -0.023, -0.062))  # rail base
	_row(
		root,
		kit.blued,
		Vector3(0.028, 0.009, 0.006),
		Vector3(0, -0.023, -0.086),
		Vector3(0, 0, 0.020),
		3
	)
	_zcyl(root, 0.011, 0.045, Vector3(0, 0.030, -0.140), kit.steel, 10)  # barrel
	_zcyl(root, 0.014, 0.007, Vector3(0, 0.030, -0.159), kit.steel, 10)  # crown
	_part(root, _box(Vector3(0.005, 0.022, 0.050)), kit.hw, Vector3(0.023, 0.042, -0.015))  # port
	_part(root, _box(Vector3(0.020, 0.018, 0.026)), kit.blued, Vector3(0, 0.038, 0.076))  # beavertail
	_part(root, _box(Vector3(0.008, 0.010, 0.030)), kit.hw, Vector3(-0.024, 0.012, 0.010))  # slide stop
	_part(root, _box(Vector3(0.008, 0.012, 0.012)), kit.hw, Vector3(-0.022, -0.004, 0.040))  # mag catch
	_grip(root, kit, 0.055, -0.012, 0.125, 12.0)
	# Sits low enough that the FLOORPLATE clears the grip cap — a flush mag whose baseplate
	# is also hidden reads as "no magazine at all" until the reload animation yanks it out.
	_mag(root, kit, Vector3(0, -0.022, 0.058), Vector3(0.026, 0.125, 0.044), 12.0, 0.0)
	_trigger_group(root, kit, 0.012, -0.014)
	_front_sight(root, kit, -0.105, 0.062, 0.8)
	_rear_sight(root, kit, 0.048, 0.062, false, 0.8)
	_mark(root, "Muzzle", Vector3(0, 0.030, -0.168))
	_mark(root, "Eject", Vector3(0.030, 0.052, -0.015))
	return root


## SMG — compact PDW: short railed receiver, vented polymer handguard, curved 30-round
## mag, side-folding wire stock, hooded post + ghost aperture. ~0.60 m.
static func _build_smg() -> Node3D:
	var root := Node3D.new()
	var kit := _kit()
	_part(root, _box(Vector3(0.060, 0.086, 0.260)), kit.blued, Vector3(0, 0.006, -0.040))
	_part(root, _box(Vector3(0.064, 0.026, 0.220)), kit.hw, Vector3(0, 0.058, -0.040))  # upper cover
	_rail(root, kit, -0.160, 0.060, 0.072, 6)
	_zcyl(root, 0.013, 0.160, Vector3(0, 0.010, -0.240), kit.steel, 12)  # barrel
	_part(root, _box(Vector3(0.050, 0.048, 0.150)), kit.poly, Vector3(0, 0.008, -0.215))  # handguard
	_row(  # handguard louvres
		root,
		kit.hw,
		Vector3(0.052, 0.006, 0.028),
		Vector3(0, 0.026, -0.262),
		Vector3(0, 0, 0.042),
		3
	)
	_row(  # bottom M-LOK slots
		root,
		kit.hw,
		Vector3(0.020, 0.008, 0.024),
		Vector3(0, -0.017, -0.256),
		Vector3(0, 0, 0.042),
		2
	)
	_muzzle_device(root, kit, -0.335, 0.010, 0.019, 3)
	_part(root, _box(Vector3(0.046, 0.048, 0.072)), kit.blued, Vector3(0, -0.040, -0.010))  # mag well
	_mag(root, kit, Vector3(0, -0.056, -0.008), Vector3(0.034, 0.185, 0.056), 6.0, 8.0)
	_grip(root, kit, 0.085, -0.030, 0.115, 20.0)
	_trigger_group(root, kit, 0.045, -0.032)
	_part(root, _box(Vector3(0.030, 0.012, 0.012)), kit.hw, Vector3(-0.040, 0.050, -0.020))
	_part(root, _box(Vector3(0.014, 0.014, 0.024)), kit.hw, Vector3(-0.052, 0.050, -0.020))  # handle
	_eject_port(root, kit, Vector3(0.032, 0.040, -0.020))
	_zcyl(root, 0.008, 0.130, Vector3(-0.026, 0.020, 0.155), kit.hw, 8)  # stock rails
	_zcyl(root, 0.008, 0.130, Vector3(0.026, 0.020, 0.155), kit.hw, 8)
	_part(root, _box(Vector3(0.030, 0.018, 0.040)), kit.poly, Vector3(0, 0.044, 0.178))  # latch
	_part(root, _box(Vector3(0.052, 0.076, 0.020)), kit.grip, Vector3(0, 0.016, 0.225))  # butt pad
	_front_sight(root, kit, -0.150, 0.078, 0.9)
	_rear_sight(root, kit, 0.040, 0.078, true, 0.9)
	_part(root, _box(Vector3(0.004, 0.018, 0.006)), kit.glow, Vector3(-0.031, -0.032, 0.008))
	_mark(root, "Muzzle", Vector3(0, 0.010, -0.365))
	_mark(root, "Eject", Vector3(0.038, 0.048, -0.020))
	return root


## RIFLE — the assault workhorse: split upper/lower receiver, full-length flat-top rail over
## a vented free-float handguard, gas block, curved 30-round mag, buffer-tube collapsible
## stock, A2-style flash hider. ~0.81 m.
static func _build_rifle() -> Node3D:
	var root := Node3D.new()
	var kit := _kit()
	_part(root, _box(Vector3(0.056, 0.060, 0.230)), kit.blued, Vector3(0, 0.030, -0.020))  # upper
	_part(root, _box(Vector3(0.050, 0.052, 0.190)), kit.poly, Vector3(0, -0.014, 0.010))  # lower
	_part(root, _box(Vector3(0.052, 0.052, 0.076)), kit.poly, Vector3(0, -0.030, -0.030))  # mag well
	_part(root, _box(Vector3(0.048, 0.056, 0.220)), kit.poly, Vector3(0, 0.032, -0.210))  # handguard
	_rail(root, kit, -0.300, 0.090, 0.066, 8)
	_row(  # handguard louvres
		root,
		kit.hw,
		Vector3(0.050, 0.007, 0.026),
		Vector3(0, 0.036, -0.294),
		Vector3(0, 0, 0.046),
		4
	)
	_row(  # bottom M-LOK slots
		root,
		kit.hw,
		Vector3(0.020, 0.008, 0.024),
		Vector3(0, 0.006, -0.288),
		Vector3(0, 0, 0.046),
		3
	)
	_zcyl(root, 0.0125, 0.200, Vector3(0, 0.020, -0.400), kit.steel, 12)  # barrel
	_part(root, _box(Vector3(0.030, 0.032, 0.030)), kit.hw, Vector3(0, 0.026, -0.334))  # gas block
	_muzzle_device(root, kit, -0.500, 0.020, 0.017, 3)
	_mag(root, kit, Vector3(0, -0.048, -0.028), Vector3(0.036, 0.175, 0.060), 4.0, 11.0)
	_grip(root, kit, 0.078, -0.026, 0.118, 22.0)
	_trigger_group(root, kit, 0.038, -0.028)
	_eject_port(root, kit, Vector3(0.030, 0.038, -0.030))
	_part(root, _box(Vector3(0.044, 0.014, 0.014)), kit.hw, Vector3(0, 0.054, 0.108))  # charging handle
	_part(root, _box(Vector3(0.028, 0.016, 0.012)), kit.hw, Vector3(-0.026, 0.054, 0.112))  # latch
	_zcyl(root, 0.017, 0.150, Vector3(0, 0.026, 0.185), kit.hw, 10)  # buffer tube
	_part(root, _box(Vector3(0.046, 0.070, 0.120)), kit.poly, Vector3(0, 0.010, 0.200))  # stock body
	_part(root, _box(Vector3(0.040, 0.024, 0.090)), kit.poly, Vector3(0, 0.052, 0.195))  # cheek weld
	_part(root, _box(Vector3(0.050, 0.086, 0.020)), kit.grip, Vector3(0, 0.008, 0.268))  # butt pad
	_front_sight(root, kit, -0.272, 0.074, 0.9)
	_rear_sight(root, kit, 0.058, 0.074, true, 0.9)
	_part(root, _box(Vector3(0.004, 0.016, 0.006)), kit.glow, Vector3(-0.027, -0.030, -0.030))
	_mark(root, "Muzzle", Vector3(0, 0.020, -0.532))
	_mark(root, "Eject", Vector3(0.036, 0.046, -0.030))
	return root


## SHOTGUN — box-fed combat 12ga: heavy vented barrel shroud, LACQUERED WOOD forend and
## buttstock (the one class that carries the wood material), fat 8-round box mag, brass
## side-saddle shells, ghost-ring rear + bead front. ~0.78 m.
static func _build_shotgun() -> Node3D:
	var root := Node3D.new()
	var kit := _kit()
	_part(root, _box(Vector3(0.070, 0.098, 0.215)), kit.blued, Vector3(0, 0.004, 0.010))
	_part(root, _box(Vector3(0.074, 0.024, 0.180)), kit.hw, Vector3(0, 0.062, 0.010))  # top cover
	_rail(root, kit, -0.070, 0.095, 0.076, 5)
	_zcyl(root, 0.024, 0.320, Vector3(0, 0.022, -0.255), kit.steel, 14)  # barrel
	_zcyl(root, 0.032, 0.200, Vector3(0, 0.022, -0.230), kit.hw, 12)  # heat shroud
	_row(  # shroud vents
		root,
		kit.blued,
		Vector3(0.070, 0.008, 0.026),
		Vector3(0, 0.048, -0.306),
		Vector3(0, 0, 0.042),
		4
	)
	_muzzle_device(root, kit, -0.430, 0.022, 0.028, 2)
	_part(root, _box(Vector3(0.062, 0.056, 0.150)), kit.wood, Vector3(0, -0.030, -0.210))  # forend
	_row(
		root,
		kit.hw,
		Vector3(0.064, 0.006, 0.012),
		Vector3(0, -0.055, -0.258),
		Vector3(0, 0, 0.030),
		4
	)
	_part(root, _box(Vector3(0.064, 0.044, 0.094)), kit.blued, Vector3(0, -0.036, -0.030))  # mag well
	_mag(root, kit, Vector3(0, -0.048, -0.030), Vector3(0.056, 0.155, 0.078), 8.0, 7.0)
	_grip(root, kit, 0.086, -0.040, 0.120, 16.0)
	_trigger_group(root, kit, 0.046, -0.042)
	_eject_port(root, kit, Vector3(0.038, 0.038, 0.010))
	var shell := _cyl(0.009, 0.016, 8)
	for i in 4:
		var z: float = -0.012 + float(i) * 0.026
		_part(root, shell, kit.brass, Vector3(-0.040, 0.026, z), Vector3(0, 0, 90))
	_part(root, _box(Vector3(0.050, 0.058, 0.030)), kit.hw, Vector3(0, 0.010, 0.124))  # wrist collar
	_part(
		root,
		_box(Vector3(0.052, 0.092, 0.185)),
		kit.wood,
		Vector3(0, -0.006, 0.210),
		Vector3(-5, 0, 0)
	)
	_part(root, _box(Vector3(0.044, 0.030, 0.110)), kit.wood, Vector3(0, 0.046, 0.190))  # comb
	_part(root, _box(Vector3(0.058, 0.104, 0.022)), kit.grip, Vector3(0, -0.014, 0.300))  # recoil pad
	_front_sight(root, kit, -0.392, 0.050, 0.9)
	_rear_sight(root, kit, 0.070, 0.082, true, 1.0)
	_mark(root, "Muzzle", Vector3(0, 0.022, -0.472))
	_mark(root, "Eject", Vector3(0.044, 0.046, 0.010))
	return root


## DMR — the marksman rifle: fluted heavy barrel, big multi-turret SCOPE on rings, folded
## bipod, thumbhole stock with an adjustable cheek riser, 10-round mag. ~0.95 m.
static func _build_dmr() -> Node3D:
	var root := Node3D.new()
	var kit := _kit()
	_part(root, _box(Vector3(0.054, 0.078, 0.300)), kit.blued, Vector3(0, 0.006, 0.0))
	_rail(root, kit, -0.130, 0.130, 0.052, 6)
	_part(root, _box(Vector3(0.046, 0.052, 0.210)), kit.poly, Vector3(0, 0.010, -0.250))  # handguard
	_row(
		root,
		kit.hw,
		Vector3(0.048, 0.007, 0.026),
		Vector3(0, 0.026, -0.320),
		Vector3(0, 0, 0.050),
		3
	)
	_zcyl(root, 0.015, 0.260, Vector3(0, 0.010, -0.400), kit.steel, 14)  # barrel
	_row(  # barrel flutes
		root,
		kit.hw,
		Vector3(0.005, 0.010, 0.220),
		Vector3(-0.013, 0.020, -0.410),
		Vector3(0.026, 0, 0),
		2
	)
	_muzzle_device(root, kit, -0.560, 0.010, 0.024, 4)
	_part(root, _box(Vector3(0.028, 0.024, 0.030)), kit.hw, Vector3(0, -0.028, -0.320))  # bipod hinge
	_zcyl(root, 0.006, 0.140, Vector3(-0.020, -0.032, -0.250), kit.hw, 6)  # folded legs
	_zcyl(root, 0.006, 0.140, Vector3(0.020, -0.032, -0.250), kit.hw, 6)
	_part(root, _box(Vector3(0.050, 0.044, 0.086)), kit.blued, Vector3(0, -0.030, 0.030))  # mag well
	_mag(root, kit, Vector3(0, -0.042, 0.030), Vector3(0.038, 0.150, 0.070), 10.0, 7.0)
	_grip(root, kit, 0.120, -0.026, 0.120, 20.0)
	_trigger_group(root, kit, 0.082, -0.028)
	_eject_port(root, kit, Vector3(0.029, 0.036, -0.020))
	_dmr_stock(root, kit)
	_dmr_scope(root, kit)
	_part(root, _box(Vector3(0.004, 0.016, 0.006)), kit.glow, Vector3(-0.028, -0.030, 0.030))
	_mark(root, "Muzzle", Vector3(0, 0.010, -0.596))
	_mark(root, "Eject", Vector3(0.035, 0.044, -0.020))
	return root


## DMR thumbhole stock: wrist + top/bottom straps (the gap between them IS the thumbhole),
## butt, recoil pad and a post-adjustable cheek riser. Split out so _build_dmr stays readable.
static func _dmr_stock(root: Node3D, kit: Kit) -> void:
	_part(root, _box(Vector3(0.046, 0.046, 0.090)), kit.poly, Vector3(0, 0.000, 0.190))  # wrist
	_part(root, _box(Vector3(0.042, 0.030, 0.150)), kit.poly, Vector3(0, 0.040, 0.230))  # top strap
	_part(root, _box(Vector3(0.042, 0.026, 0.110)), kit.poly, Vector3(0, -0.038, 0.250))  # under strap
	_part(root, _box(Vector3(0.046, 0.100, 0.040)), kit.poly, Vector3(0, 0.006, 0.320))  # butt
	_part(root, _box(Vector3(0.052, 0.104, 0.020)), kit.grip, Vector3(0, 0.004, 0.348))  # recoil pad
	_part(root, _box(Vector3(0.038, 0.026, 0.110)), kit.poly, Vector3(0, 0.072, 0.235))  # cheek riser
	_row(
		root,
		kit.hw,
		Vector3(0.008, 0.030, 0.010),
		Vector3(-0.014, 0.055, 0.205),
		Vector3(0.028, 0, 0),
		2
	)


## DMR optic as its own "Scope" subtree (grouped so ADS/attachment code can find it):
## rings, tube, objective and ocular bells with glowing lenses, elevation/windage/parallax
## turrets. The OCULAR glow is deliberately dimmer than the objective — in ADS that lens
## fills the screen, and a hot emissive there would bloom the whole sight picture out.
static func _dmr_scope(root: Node3D, kit: Kit) -> void:
	var scope := Node3D.new()
	scope.name = "Scope"
	root.add_child(scope)
	var mount := _box(Vector3(0.030, 0.036, 0.026))
	_part(scope, mount, kit.hw, Vector3(0, 0.075, -0.070))
	_part(scope, mount, kit.hw, Vector3(0, 0.075, 0.070))
	_zcyl(scope, 0.023, 0.230, Vector3(0, 0.104, 0.000), kit.hw, 14)  # tube
	_zcyl(scope, 0.031, 0.055, Vector3(0, 0.104, -0.135), kit.hw, 14)  # objective bell
	_zcyl(scope, 0.028, 0.010, Vector3(0, 0.104, -0.163), kit.lens, 14)
	_zcyl(scope, 0.028, 0.040, Vector3(0, 0.104, 0.130), kit.hw, 12)  # ocular bell
	var ocular: StandardMaterial3D = kit.lens.duplicate()
	ocular.emission_energy_multiplier = 1.0
	_zcyl(scope, 0.024, 0.008, Vector3(0, 0.104, 0.151), ocular, 12)
	_part(scope, _cyl(0.017, 0.030, 10), kit.hw, Vector3(0, 0.130, 0.010))  # elevation turret
	_part(scope, _cyl(0.015, 0.026, 10), kit.hw, Vector3(0.028, 0.104, 0.010), Vector3(0, 0, 90))
	_part(scope, _cyl(0.014, 0.022, 10), kit.hw, Vector3(-0.026, 0.104, 0.010), Vector3(0, 0, 90))
