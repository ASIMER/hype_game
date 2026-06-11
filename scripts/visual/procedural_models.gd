extends RefCounted
class_name ProceduralModels
## Procedural composite models — assembled from primitive MeshInstance3D parts in
## code, with rich StandardMaterial3D (metallic / roughness / emission). Used by
## AssetRegistry.get_model() when an id has no real .glb, to give enemies distinct
## silhouettes and items real shapes (instead of one flat primitive).
##
## CRITICAL: every part uses StandardMaterial3D on `material_override` (never a
## ShaderMaterial) — robot_enemy._collect_flash_materials() only collects
## StandardMaterial3D for the hit-flash, and it base-captures/restores emission, so
## glowing parts flash and return to glow with NO change to robot_enemy.gd.
##
## All builders work in ModelRoot-LOCAL coordinates and keep the base/feet at local
## y≈0 (the ModelRoot node is already Y-offset in the scene to match collision).
## Authored facing -Z (Godot forward), matching the .glb enemies.

# Builders registered here are chosen by AssetRegistry over the single-primitive
# fallback. Attachment ids dispatch to family builders (optic/mag/barrel/grip).
const ENEMY_BUILDERS := [
	"robot_tick",
	"robot_wasp",
	"robot_bastion",
	"robot_boss",
	"robot_caller",
	"robot_sandworm",
	"robot_scarab",
	"robot_dustdevil",
	"robot_frosthound",
	"robot_cryomortar",
	"robot_avalanche",
	"robot_oni",
	"robot_kappa",
	"robot_raiju",
	"robot_snow_golem",
	"robot_dune_warden",
	"robot_oni_chief",
	"robot_specter",
]
const ITEM_BUILDERS := [
	"loot_medkit",
	"loot_cell",
	"loot_chemicals",
	"loot_stim",
	"loot_circuit",
	"loot_circuit_pack",
	"loot_artifact",
	"loot_grenade",
	"loot_grenade_mk2",
	"loot_ammo",
	"loot_scrap",
	"loot_plastic",
	"loot_data_chip"
]
const ATT_OPTIC := ["att_scope_4x", "att_holo_sight", "att_red_dot"]
const ATT_MAG := ["att_ext_mag", "att_drum_mag", "att_light_mag"]
const ATT_BARREL := ["att_long_barrel", "att_suppressor", "att_compensator"]
const ATT_GRIP := ["att_heavy_grip", "att_quickdraw_grip"]
# Deployable gadgets — each has a named tracking part the gadget script rotates
# ("Barrel" on the turret, "Head" on the sensor).
const GADGET_BUILDERS := ["gadget_turret", "gadget_dome", "gadget_sensor"]
# Batch B/C gear + consumables — built in ProceduralModelsGear (split out for the
# max-file-lines ceiling; this file only dispatches).
const GEAR_BUILDERS := [
	"key_tower",
	"key_lodge",
	"key_temple",
	"loot_flare",
	"loot_bandage",
	"loot_splint",
	"loot_painkiller",
	"armor_helmet_t1",
	"armor_helmet_t2",
	"armor_vest_t1",
	"armor_vest_t2",
	"armor_pack_med",
	"armor_pack_large",
]


static func has_builder(id: String) -> bool:
	if id in ENEMY_BUILDERS or id in ITEM_BUILDERS or id in GADGET_BUILDERS:
		return true
	if id in ATT_OPTIC or id in ATT_MAG or id in ATT_BARREL or id in ATT_GRIP:
		return true
	if id in GEAR_BUILDERS:
		return true
	return id.begins_with("schematic_")


## Returns a fresh Node3D assembly for `id`, or null if there is no builder.
static func build(id: String) -> Node3D:
	if id in GEAR_BUILDERS:
		return ProceduralModelsGear.build(id)
	match id:
		"robot_tick":
			return build_robot_tick()
		"robot_wasp":
			return build_robot_wasp()
		"robot_bastion":
			return build_robot_bastion()
		"robot_boss":
			return build_robot_boss()
		"robot_caller":
			return build_robot_caller()
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
		"loot_medkit":
			return build_medkit()
		"loot_cell":
			return build_battery(AssetRegistry.get_color(id))
		"loot_chemicals":
			return build_canister(AssetRegistry.get_color(id))
		"loot_stim":
			return build_stim()
		"loot_circuit":
			return build_circuit(AssetRegistry.get_color(id), 1)
		"loot_circuit_pack":
			return build_circuit(AssetRegistry.get_color(id), 3)
		"loot_artifact":
			return build_artifact()
		"loot_grenade":
			return build_grenade(AssetRegistry.get_color(id), false)
		"loot_grenade_mk2":
			return build_grenade(AssetRegistry.get_color(id), true)
		"loot_ammo":
			return build_ammo()
		"loot_scrap":
			return build_scrap()
		"loot_plastic":
			return build_plastic()
		"loot_data_chip":
			return build_data_chip()
		"gadget_turret":
			return build_gadget_turret()
		"gadget_dome":
			return build_gadget_dome_emitter()
		"gadget_sensor":
			return build_gadget_sensor()
	if id in ATT_OPTIC:
		return build_att_optic(id)
	if id in ATT_MAG:
		return build_att_mag(id)
	if id in ATT_BARREL:
		return build_att_barrel(id)
	if id in ATT_GRIP:
		return build_att_grip(id)
	if id.begins_with("schematic_"):
		return build_schematic(AssetRegistry.get_color(id))
	return null


# ----------------------------------------------------------------- mesh makers
static func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


static func _sphere(r: float, hemi := false, rings := 8, radial := 12) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.is_hemisphere = hemi
	m.rings = rings
	m.radial_segments = radial
	return m


static func _cyl(r: float, h: float, seg := 10) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	m.radial_segments = seg
	return m


static func _cone(r: float, h: float, seg := 10) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = r
	m.height = h
	m.radial_segments = seg
	return m


static func _capsule(r: float, h: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	return m


# ----------------------------------------------------------------- material
static func _mat(
	color: Color, metallic := 0.0, roughness := 0.7, emission := Color.BLACK, emission_energy := 0.0
) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy
	return m


# ----------------------------------------------------------------- placement
## Adds `mesh` as a MeshInstance3D under `parent` at offset/rot/scale.
static func _part(
	parent: Node3D,
	mesh: Mesh,
	mat: StandardMaterial3D,
	offset := Vector3.ZERO,
	rot_deg := Vector3.ZERO,
	scale := Vector3.ONE
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	var basis := Basis.from_scale(scale)
	if rot_deg != Vector3.ZERO:
		basis = (
			Basis.from_euler(
				Vector3(deg_to_rad(rot_deg.x), deg_to_rad(rot_deg.y), deg_to_rad(rot_deg.z))
			)
			* basis
		)
	mi.transform = Transform3D(basis, offset)
	parent.add_child(mi)
	return mi


## A cylinder strut spanning points a→b (its local +Y aligned to the span). The
## backbone for legs, limbs and frames — define a mech by its endpoints.
static func _strut(
	parent: Node3D, a: Vector3, b: Vector3, radius: float, mat: StandardMaterial3D, seg := 8
) -> MeshInstance3D:
	var diff := b - a
	var length := diff.length()
	if length < 0.0001:
		return null
	var mi := MeshInstance3D.new()
	mi.mesh = _cyl(radius, length, seg)
	mi.material_override = mat
	# Cylinder mesh runs along local +Y; rotate UP→span so it spans a→b.
	var basis := Basis(Quaternion(Vector3.UP, diff / length))
	mi.transform = Transform3D(basis, (a + b) * 0.5)
	parent.add_child(mi)
	return mi


# ================================================================= ENEMIES
## Tick — small, fast skittering hexapod. Domed carapace + glowing sensor eye +
## six bent legs. Collision: capsule r0.3 h0.7 @ world y0.35; ModelRoot @ y0.35,
## so local y0 = world 0.35, feet at local y≈-0.35.
static func build_robot_tick() -> Node3D:
	var root := Node3D.new()
	# Weathered shell so the carapace reads as worn metal (world=false so it doesn't
	# swim as the tick skitters); metal bits get a touch more metallic for SDFGI.
	var shell := ProcMaterials.weathered(
		Color(0.27, 0.33, 0.36), 0.55, 0.5, 0.55, 11, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.15, 0.17, 0.19), 0.45, 0.55)
	var accent_col := AssetRegistry.get_color("robot_tick")  # orange
	var accent := _mat(accent_col, 0.3, 0.45)
	var eye_mat := _mat(accent_col, 0.0, 0.3, accent_col, 6.0)
	var leg_mat := _mat(Color(0.32, 0.35, 0.38), 0.55, 0.45)

	# Flat, wide beetle carapace + a slightly smaller underbelly.
	_part(
		root,
		_sphere(0.32, false, 9, 16),
		shell,
		Vector3(0, 0.06, 0.0),
		Vector3.ZERO,
		Vector3(1.25, 0.5, 1.4)
	)
	_part(root, _box(Vector3(0.42, 0.12, 0.5)), dark, Vector3(0, -0.05, 0))
	# Orange accent rim along each flank + a brow over the eye.
	_part(root, _box(Vector3(0.05, 0.05, 0.46)), accent, Vector3(0.2, 0.08, 0.02))
	_part(root, _box(Vector3(0.05, 0.05, 0.46)), accent, Vector3(-0.2, 0.08, 0.02))
	_part(root, _box(Vector3(0.3, 0.05, 0.08)), accent, Vector3(0, 0.12, -0.32), Vector3(20, 0, 0))
	# Forward glowing sensor eye (faces -Z) + two mandible prongs.
	var eye := _part(root, _sphere(0.1, false, 8, 12), eye_mat, Vector3(0, 0.04, -0.42))
	eye.name = "Eye"
	_part(root, _cone(0.04, 0.18), dark, Vector3(0.1, -0.04, -0.46), Vector3(-100, 0, 0))
	_part(root, _cone(0.04, 0.18), dark, Vector3(-0.1, -0.04, -0.46), Vector3(-100, 0, 0))

	# Six wide-splayed bent legs (3 per side): knee up-and-out, foot planted on ground.
	# Each leg lives under its own pivot Node3D at the body attach point so the enemy
	# script can micro-sway the whole leg by rotating the pivot (named "Leg0".."Leg5").
	var zs := [-0.22, 0.02, 0.26]
	var li := 0
	for side in [-1.0, 1.0]:
		for z in zs:
			var zf := float(z)
			var attach := Vector3(side * 0.2, 0.02, zf)
			var knee := Vector3(side * 0.5, 0.16, zf + side * 0.03)
			var foot := Vector3(side * 0.6, -0.35, zf + side * 0.02)
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % li
			pivot.position = attach
			root.add_child(pivot)
			# Build the leg in pivot-local space (subtract the attach point).
			_strut(pivot, Vector3.ZERO, knee - attach, 0.05, leg_mat)
			_strut(pivot, knee - attach, foot - attach, 0.038, leg_mat)
			_part(pivot, _sphere(0.05, false, 6, 8), dark, foot - attach)
			li += 1
	return root


## Wasp — flying drone. Glowing core + ringed body + 4 rotor arms + a stinger.
## Collision sphere r0.4, ModelRoot @ y0 (hovers), so build symmetric about local y0.
static func build_robot_wasp() -> Node3D:
	var root := Node3D.new()
	var glow_col := AssetRegistry.get_color("robot_wasp")  # cyan
	var body := ProcMaterials.weathered(
		Color(0.18, 0.2, 0.24), 0.6, 0.4, 0.6, 23, Vector3(0.7, 0.7, 0.7), false
	)
	var dark := _mat(Color(0.1, 0.11, 0.13), 0.5, 0.5)
	var rotor := _mat(Color(0.22, 0.24, 0.27), 0.4, 0.3)
	var core_mat := _mat(glow_col, 0.0, 0.3, glow_col, 6.0)

	# A body pivot wrapping the pod + core + stinger so the script can bob just the
	# body (named "Body") without moving the rotors' spin hub.
	var bodyp := Node3D.new()
	bodyp.name = "Body"
	root.add_child(bodyp)
	# Central body pod (flattened) with a glowing sensor core at the front.
	_part(
		bodyp,
		_sphere(0.24, false, 10, 14),
		body,
		Vector3(0, 0, 0),
		Vector3.ZERO,
		Vector3(1.0, 0.6, 1.1)
	)
	var core := _part(bodyp, _sphere(0.12, false, 10, 14), core_mat, Vector3(0, 0.0, -0.2))
	core.name = "Core"
	# Top + bottom caps.
	_part(
		bodyp,
		_sphere(0.16, true, 8, 14),
		dark,
		Vector3(0, 0.06, 0),
		Vector3.ZERO,
		Vector3(1.0, 0.7, 1.0)
	)
	# Downward stinger (faces -Z, angled down) — its ranged "gun".
	_part(bodyp, _cone(0.06, 0.32), dark, Vector3(0, -0.08, -0.28), Vector3(-115, 0, 0))

	# Four rotor arms out to the diagonals, each ending in a flat spinning rotor disc.
	# Each disc sits under its OWN pivot Node3D centred on the disc (so a Y rotation
	# spins the blade in place, not orbiting the body); all pivots are grouped under
	# a "RotorHub" so the script can find + spin them in one cheap loop. Arms (struts)
	# stay fixed on the root. The disc mesh is given a 2-bladed look via a thin crossbar
	# so the spin actually reads.
	var hub := Node3D.new()
	hub.name = "RotorHub"
	root.add_child(hub)
	var arms := [
		Vector3(0.34, 0.12, 0.34),
		Vector3(-0.34, 0.12, 0.34),
		Vector3(0.34, 0.12, -0.34),
		Vector3(-0.34, 0.12, -0.34)
	]
	var ri := 0
	for tip in arms:
		var tv: Vector3 = tip
		_strut(root, Vector3(tv.x * 0.4, 0.04, tv.z * 0.4), tv, 0.03, dark)
		var pivot := Node3D.new()
		pivot.name = "Rotor%d" % ri
		pivot.position = tv + Vector3(0, 0.02, 0)
		hub.add_child(pivot)
		_part(pivot, _cyl(0.16, 0.025, 12), rotor)
		# Two crossed blades so the spin is visible against the disc.
		_part(pivot, _box(Vector3(0.32, 0.035, 0.04)), dark, Vector3(0, 0.02, 0))
		_part(pivot, _box(Vector3(0.04, 0.035, 0.32)), dark, Vector3(0, 0.02, 0))
		_part(root, _sphere(0.05, false, 6, 8), dark, tv)
		ri += 1
	return root


## Bastion — heavy stationary turret with a glowing WEAK POINT on top. Collision box
## 1.8×2.4 @ world y1.2; ModelRoot @ y1.3; WeakPoint hurtbox 1.0×0.7 @ world y2.6
## → base at local y≈-1.3, weak-point dome at local y≈+1.3.
static func build_robot_bastion() -> Node3D:
	var root := Node3D.new()
	var red := AssetRegistry.get_color("robot_bastion")  # dark red
	var armor := ProcMaterials.weathered(
		Color(0.28, 0.1, 0.1), 0.55, 0.5, 0.5, 31, Vector3(0.4, 0.4, 0.4), false
	)
	var dark := _mat(Color(0.13, 0.12, 0.13), 0.5, 0.55)
	var trim := _mat(red, 0.4, 0.45)
	var weak := _mat(Color(1.0, 0.55, 0.15), 0.0, 0.3, Color(1.0, 0.45, 0.1), 6.0)

	# Wide armored base — STATIC (does not track the player).
	_part(root, _box(Vector3(1.7, 0.9, 1.7)), dark, Vector3(0, -0.85, 0))
	_part(root, _box(Vector3(1.85, 0.2, 1.85)), armor, Vector3(0, -1.25, 0))

	# The whole upper turret rotates on Y to face the player: body + barrels + weak
	# point + shoulders all live under "TurretHead" (pivoted at the base top so it
	# spins about the centre column). The script yaws this node toward the nearest player.
	var head := Node3D.new()
	head.name = "TurretHead"
	root.add_child(head)
	# Main turret body (mid).
	_part(head, _box(Vector3(1.5, 1.0, 1.4)), armor, Vector3(0, 0.05, 0))
	_part(head, _box(Vector3(1.55, 0.18, 1.45)), trim, Vector3(0, 0.5, 0))
	# Twin forward cannon barrels (face -Z), named so the script can find the gun.
	var bi := 0
	for sx in [-0.35, 0.35]:
		var barrel := _part(
			head, _cyl(0.13, 1.0, 12), dark, Vector3(float(sx), 0.1, -0.85), Vector3(90, 0, 0)
		)
		barrel.name = "Barrel%d" % bi
		_part(head, _cyl(0.16, 0.2, 12), trim, Vector3(float(sx), 0.1, -0.5), Vector3(90, 0, 0))
		bi += 1
	# Shoulder armor plates.
	for sx2 in [-0.85, 0.85]:
		_part(
			head,
			_box(Vector3(0.25, 0.7, 1.1)),
			dark,
			Vector3(float(sx2), 0.2, 0),
			Vector3(0, 0, 12) * signf(float(sx2))
		)
	# Glowing weak point dome on top (over the WeakPoint hurtbox at world y2.6).
	_part(head, _cyl(0.45, 0.25, 8), dark, Vector3(0, 0.95, 0))
	var dome := _part(
		head,
		_sphere(0.4, true, 10, 16),
		weak,
		Vector3(0, 1.05, 0),
		Vector3.ZERO,
		Vector3(1.0, 1.1, 1.0)
	)
	dome.name = "WeakDome"
	return root


## Boss — large multi-part mech. Collision box 3.0×4.2 @ world y2.1; ModelRoot @ y2.2
## → legs/feet base at local y≈-2.2, chest core near local y0, head on top.
static func build_robot_boss() -> Node3D:
	var root := Node3D.new()
	var violet := AssetRegistry.get_color("robot_boss")  # dark purple
	var armor := ProcMaterials.weathered(
		Color(0.26, 0.12, 0.32), 0.55, 0.45, 0.5, 47, Vector3(0.3, 0.3, 0.3), false
	)
	var dark := _mat(Color(0.12, 0.1, 0.14), 0.5, 0.5)
	var trim := _mat(Color(0.55, 0.3, 0.85), 0.5, 0.4)
	var core_mat := _mat(Color(0.8, 0.4, 1.0), 0.0, 0.3, Color(0.7, 0.3, 1.0), 6.0)
	var eye_mat := _mat(Color(1.0, 0.4, 0.6), 0.0, 0.3, Color(1.0, 0.2, 0.4), 6.0)

	# Two heavy legs from the ground (local y-2.2) up to the hips — STATIC base.
	for sx in [-0.6, 0.6]:
		var fx := float(sx)
		_part(root, _box(Vector3(0.55, 0.3, 0.95)), dark, Vector3(fx, -2.05, 0.05))  # foot
		_strut(root, Vector3(fx, -2.0, 0), Vector3(fx, -1.1, 0.15), 0.22, armor)  # shin
		_strut(root, Vector3(fx, -1.1, 0.15), Vector3(fx * 0.7, -0.4, 0), 0.26, armor)  # thigh
		_part(root, _sphere(0.28, false, 8, 10), dark, Vector3(fx, -1.1, 0.15))  # knee joint
	# Hips — STATIC.
	_part(root, _box(Vector3(1.5, 0.5, 0.9)), dark, Vector3(0, -0.45, 0))

	# Upper body (torso + chest core + arms + head) rotates on Y to face the player.
	# Pivoted near the hips ("Torso") so the whole mech upper turns toward the target.
	var torso := Node3D.new()
	torso.name = "Torso"
	torso.position = Vector3(0, -0.2, 0)
	root.add_child(torso)
	# Torso shell (built in torso-local space: subtract the pivot y-offset).
	_part(torso, _box(Vector3(1.7, 1.5, 1.0)), armor, Vector3(0, 0.7, 0))
	_part(torso, _box(Vector3(1.75, 0.25, 1.05)), trim, Vector3(0, 1.45, 0))
	# Glowing chest core.
	var core := _part(torso, _sphere(0.32, false, 12, 16), core_mat, Vector3(0, 0.65, -0.45))
	core.name = "ChestCore"
	_part(torso, _cyl(0.4, 0.2, 8), dark, Vector3(0, 0.65, -0.42), Vector3(90, 0, 0))
	# Shoulder pods + arm cannons.
	for sx3 in [-1.0, 1.0]:
		var ax := float(sx3)
		_part(torso, _box(Vector3(0.6, 0.7, 0.8)), dark, Vector3(ax, 1.2, 0))
		_strut(torso, Vector3(ax, 1.0, 0), Vector3(ax * 1.05, -0.1, -0.2), 0.16, armor)  # upper arm
		_part(torso, _cyl(0.18, 1.1, 12), dark, Vector3(ax * 1.1, -0.3, -0.5), Vector3(80, 0, 0))  # cannon
		_part(torso, _cyl(0.22, 0.25, 12), trim, Vector3(ax * 1.12, -0.3, -0.95), Vector3(80, 0, 0))
	# Head with twin glowing eyes.
	var head := _part(torso, _box(Vector3(0.7, 0.55, 0.7)), dark, Vector3(0, 1.75, 0))
	head.name = "Head"
	var eyes := _part(torso, _box(Vector3(0.5, 0.12, 0.1)), eye_mat, Vector3(0, 1.8, -0.36))
	eyes.name = "Eyes"
	return root


## Caller / "Snitch" — a fragile signal bot that keeps its distance and screams for
## reinforcements. Reads as an antenna/siren, NOT a fighter: a small pod body on a spindly
## tripod, a tall mast topped with a dish ring + a glowing alarm beacon, and whip antennae.
## Collision capsule r0.4 h1.5 @ world y0.75; ModelRoot @ y0.75 → local y0 = world 0.75,
## feet at local y≈-0.72. The script pulses nodes named "Core"/"Eye" and sways "Leg%d".
static func build_robot_caller() -> Node3D:
	var root := Node3D.new()
	var beacon_col := AssetRegistry.get_color("robot_caller")  # alarm red-orange
	var shell := ProcMaterials.weathered(
		Color(0.5, 0.54, 0.58), 0.45, 0.5, 0.5, 17, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.14, 0.16, 0.18), 0.5, 0.5)
	var leg_mat := _mat(Color(0.3, 0.33, 0.36), 0.55, 0.45)
	var beacon_mat := _mat(beacon_col, 0.0, 0.3, beacon_col, 7.0)
	var eye_mat := _mat(beacon_col, 0.0, 0.3, beacon_col, 5.0)

	# Compact egg-shaped pod body centred at y0, with a collar ring.
	_part(
		root,
		_sphere(0.26, false, 10, 14),
		shell,
		Vector3(0, 0.0, 0),
		Vector3.ZERO,
		Vector3(1.0, 1.1, 1.0)
	)
	_part(root, _cyl(0.2, 0.08, 12), dark, Vector3(0, 0.18, 0))
	# Forward glowing sensor eye.
	var eye := _part(root, _sphere(0.07, false, 8, 10), eye_mat, Vector3(0, 0.02, -0.24))
	eye.name = "Eye"

	# Tall antenna mast up from the head → dish ring → glowing alarm beacon on top.
	_part(root, _cyl(0.03, 0.42, 8), dark, Vector3(0, 0.42, 0))
	_part(root, _cyl(0.16, 0.03, 14), dark, Vector3(0, 0.6, 0))  # dish ring
	var beacon := _part(root, _sphere(0.09, false, 10, 12), beacon_mat, Vector3(0, 0.72, 0))
	beacon.name = "Core"  # pulsed by the script
	# Two side whip-antennae for the signal-bot read.
	_part(root, _cyl(0.012, 0.3, 6), beacon_mat, Vector3(0.14, 0.34, 0.02), Vector3(0, 0, 28))
	_part(root, _cyl(0.012, 0.3, 6), beacon_mat, Vector3(-0.14, 0.34, 0.02), Vector3(0, 0, -28))

	# Spindly tripod legs (one front, two rear) — stands but looks fragile/low-HP.
	var feet := [Vector3(0.0, 0.0, -0.28), Vector3(0.26, 0.0, 0.2), Vector3(-0.26, 0.0, 0.2)]
	var li := 0
	for f in feet:
		var fv: Vector3 = f
		var attach := Vector3(fv.x * 0.4, -0.12, fv.z * 0.4)
		var foot := Vector3(fv.x, -0.72, fv.z)
		var pivot := Node3D.new()
		pivot.name = "Leg%d" % li
		pivot.position = attach
		root.add_child(pivot)
		_strut(pivot, Vector3.ZERO, foot - attach, 0.03, leg_mat)
		_part(pivot, _sphere(0.04, false, 6, 8), dark, foot - attach)
		li += 1
	return root


# ================================================================= ITEMS
# Items rest on the ground (built around local y≈0.15) and are framed by the icon
# renderer independent of size. Tints come from each id's CATALOG colour.


## Medkit — white case with a glowing red cross.
static func build_medkit() -> Node3D:
	var root := Node3D.new()
	var case_mat := _mat(Color(0.92, 0.94, 0.96), 0.0, 0.5)
	var edge := _mat(Color(0.7, 0.72, 0.74), 0.2, 0.5)
	var red := _mat(Color(0.85, 0.12, 0.12), 0.0, 0.4, Color(0.8, 0.1, 0.1), 1.6)
	_part(root, _box(Vector3(0.42, 0.26, 0.34)), case_mat, Vector3(0, 0.15, 0))
	_part(root, _box(Vector3(0.44, 0.05, 0.36)), edge, Vector3(0, 0.04, 0))
	_part(root, _box(Vector3(0.22, 0.06, 0.07)), red, Vector3(0, 0.29, 0))
	_part(root, _box(Vector3(0.07, 0.06, 0.22)), red, Vector3(0, 0.29, 0))
	return root


## Energy cell — battery with a glowing band + terminal.
static func build_battery(col: Color) -> Node3D:
	var root := Node3D.new()
	var shell := _mat(Color(0.2, 0.22, 0.25), 0.5, 0.4)
	var cap := _mat(Color(0.12, 0.13, 0.15), 0.4, 0.5)
	var band := _mat(col, 0.0, 0.3, col, 3.5)
	_part(root, _cyl(0.13, 0.34, 14), shell, Vector3(0, 0.2, 0))
	_part(root, _cyl(0.14, 0.07, 14), band, Vector3(0, 0.22, 0))
	_part(root, _cyl(0.135, 0.04, 14), cap, Vector3(0, 0.37, 0))
	_part(root, _box(Vector3(0.06, 0.05, 0.06)), cap, Vector3(0, 0.4, 0))
	return root


## Chemicals — canister with glowing liquid inside.
static func build_canister(col: Color) -> Node3D:
	var root := Node3D.new()
	var glass := _mat(Color(0.3, 0.34, 0.36), 0.1, 0.2)
	var liquid := _mat(col, 0.0, 0.2, col, 3.0)
	var cap := _mat(Color(0.15, 0.16, 0.18), 0.4, 0.5)
	_part(root, _cyl(0.12, 0.2, 14), liquid, Vector3(0, 0.16, 0))
	_part(root, _cyl(0.14, 0.34, 14), glass, Vector3(0, 0.2, 0))
	_part(root, _cyl(0.1, 0.08, 14), cap, Vector3(0, 0.39, 0))
	return root


## Combat stim — a syringe with glowing fluid.
static func build_stim() -> Node3D:
	var root := Node3D.new()
	var barrel := _mat(Color(0.7, 0.78, 0.82), 0.1, 0.2)
	var fluid := _mat(Color(0.3, 0.95, 0.6), 0.0, 0.2, Color(0.3, 0.95, 0.6), 3.0)
	var metal := _mat(Color(0.5, 0.53, 0.56), 0.6, 0.3)
	_part(root, _cyl(0.05, 0.26, 12), fluid, Vector3(0, 0.2, 0))
	_part(root, _cyl(0.06, 0.3, 12), barrel, Vector3(0, 0.2, 0))
	_part(root, _box(Vector3(0.16, 0.02, 0.05)), metal, Vector3(0, 0.34, 0))  # finger flange
	_part(root, _cyl(0.018, 0.12, 8), metal, Vector3(0, 0.42, 0))  # plunger
	_part(root, _cyl(0.07, 0.02, 12), metal, Vector3(0, 0.48, 0))  # thumb rest
	_part(root, _cone(0.012, 0.12, 8), metal, Vector3(0, 0.02, 0), Vector3(180, 0, 0))  # needle
	return root


## Circuit board — green PCB with glowing components (stack `layers` for a pack).
static func build_circuit(col: Color, layers: int) -> Node3D:
	var root := Node3D.new()
	var board := _mat(col, 0.1, 0.5)
	var chip := _mat(Color(0.1, 0.1, 0.12), 0.3, 0.5)
	var led := _mat(Color(0.9, 0.85, 0.3), 0.0, 0.3, Color(0.9, 0.8, 0.2), 3.0)
	for i in range(layers):
		var y := 0.06 + i * 0.07
		_part(root, _box(Vector3(0.34, 0.03, 0.26)), board, Vector3(i * 0.02, y, 0))
	var top := 0.06 + (layers - 1) * 0.07 + 0.03
	_part(root, _box(Vector3(0.12, 0.05, 0.1)), chip, Vector3(0.05, top, -0.03))
	_part(root, _box(Vector3(0.04, 0.04, 0.04)), led, Vector3(-0.08, top, 0.05))
	_part(root, _box(Vector3(0.04, 0.04, 0.04)), led, Vector3(-0.02, top, -0.06))
	return root


## Anomalous artifact — a faceted glowing core with angular shards.
static func build_artifact() -> Node3D:
	var root := Node3D.new()
	var core := _mat(Color(0.8, 0.4, 0.95), 0.0, 0.2, Color(0.7, 0.3, 0.95), 4.0)
	var shard := _mat(Color(0.45, 0.25, 0.6), 0.3, 0.3)
	_part(root, _sphere(0.16, false, 4, 6), core, Vector3(0, 0.26, 0))  # faceted core
	for i in range(5):
		var a := i * TAU / 5.0
		var p := Vector3(cos(a) * 0.16, 0.26 + sin(a * 2.0) * 0.06, sin(a) * 0.16)
		_part(root, _box(Vector3(0.06, 0.22, 0.06)), shard, p, Vector3(rad_to_deg(a), 30, 40))
	return root


## Frag grenade — sphere body + lever + pin (mk2 is bigger with a glowing band).
static func build_grenade(col: Color, mk2: bool) -> Node3D:
	var root := Node3D.new()
	var r := 0.16 if mk2 else 0.14
	var body := _mat(col, 0.2, 0.5)
	var metal := _mat(Color(0.45, 0.47, 0.5), 0.6, 0.3)
	_part(root, _sphere(r, false, 10, 12), body, Vector3(0, r + 0.02, 0))
	_part(root, _cyl(0.05, 0.06, 10), metal, Vector3(0, r * 2 + 0.02, 0))  # fuze top
	_part(
		root, _box(Vector3(0.03, 0.18, 0.05)), metal, Vector3(0.07, r + 0.06, 0), Vector3(0, 0, 18)
	)  # lever
	_part(root, _cyl(0.035, 0.02, 10), metal, Vector3(0.1, r * 2 + 0.0, 0.0), Vector3(90, 0, 0))  # pin ring
	if mk2:
		_part(
			root,
			_cyl(r + 0.01, 0.04, 12),
			_mat(Color(0.4, 1.0, 0.5), 0, 0.3, Color(0.3, 1.0, 0.4), 3.0),
			Vector3(0, r + 0.02, 0)
		)
	return root


## Ammo box — case with brass rounds poking out the top.
static func build_ammo() -> Node3D:
	var root := Node3D.new()
	var case_mat := _mat(Color(0.42, 0.4, 0.24), 0.2, 0.5)
	var lid := _mat(Color(0.32, 0.3, 0.18), 0.2, 0.5)
	var brass := _mat(Color(0.85, 0.65, 0.25), 0.7, 0.3)
	_part(root, _box(Vector3(0.36, 0.22, 0.26)), case_mat, Vector3(0, 0.13, 0))
	_part(root, _box(Vector3(0.38, 0.05, 0.28)), lid, Vector3(0, 0.25, 0))
	for i in range(4):
		var x := -0.12 + i * 0.08
		_part(root, _cyl(0.03, 0.12, 8), brass, Vector3(x, 0.32, 0.0))
		_part(root, _cone(0.03, 0.05, 8), brass, Vector3(x, 0.4, 0.0))
	return root


## Scrap — a cluster of irregular metal chunks.
static func build_scrap() -> Node3D:
	var root := Node3D.new()
	var m1 := _mat(Color(0.5, 0.45, 0.35), 0.6, 0.5)
	var m2 := _mat(Color(0.4, 0.38, 0.32), 0.5, 0.6)
	_part(root, _box(Vector3(0.22, 0.16, 0.18)), m1, Vector3(0, 0.1, 0), Vector3(12, 20, 8))
	_part(root, _box(Vector3(0.16, 0.12, 0.2)), m2, Vector3(0.12, 0.08, 0.06), Vector3(40, 10, 25))
	_part(
		root, _box(Vector3(0.14, 0.1, 0.12)), m1, Vector3(-0.1, 0.07, -0.05), Vector3(-20, 35, 15)
	)
	_part(root, _cyl(0.05, 0.18, 8), m2, Vector3(-0.02, 0.16, 0.1), Vector3(70, 0, 20))
	return root


## Plastic — stacked offset polymer panels.
static func build_plastic() -> Node3D:
	var root := Node3D.new()
	var cols := [Color(0.85, 0.85, 0.88), Color(0.78, 0.8, 0.83), Color(0.82, 0.83, 0.86)]
	for i in range(3):
		var c: Color = cols[i]
		_part(
			root,
			_box(Vector3(0.3, 0.05, 0.22)),
			_mat(c, 0.0, 0.6),
			Vector3((i - 1) * 0.04, 0.06 + i * 0.06, (i - 1) * 0.03),
			Vector3(0, i * 12, 0)
		)
	return root


## Data chip — a card with gold contacts and a glowing trace.
static func build_data_chip() -> Node3D:
	var root := Node3D.new()
	var card := _mat(Color(0.12, 0.14, 0.18), 0.3, 0.5)
	var gold := _mat(Color(0.85, 0.7, 0.3), 0.8, 0.3)
	var trace := _mat(Color(0.3, 0.85, 0.95), 0.0, 0.3, Color(0.3, 0.85, 0.95), 3.0)
	_part(root, _box(Vector3(0.3, 0.04, 0.2)), card, Vector3(0, 0.12, 0))
	_part(root, _box(Vector3(0.28, 0.045, 0.05)), gold, Vector3(0, 0.12, 0.09))
	_part(root, _box(Vector3(0.16, 0.05, 0.02)), trace, Vector3(0, 0.13, -0.02))
	_part(root, _box(Vector3(0.02, 0.05, 0.1)), trace, Vector3(0.06, 0.13, 0.02))
	return root


## Schematic — a blueprint board with a glowing grid/diagram.
static func build_schematic(col: Color) -> Node3D:
	var root := Node3D.new()
	var board := _mat(col * 0.5, 0.0, 0.5)
	var line := _mat(col, 0.0, 0.3, col * 1.3, 3.0)
	_part(root, _box(Vector3(0.34, 0.025, 0.26)), board, Vector3(0, 0.12, 0), Vector3(-12, 0, 0))
	# A few glowing grid lines + a diagram blip.
	for i in range(3):
		_part(
			root,
			_box(Vector3(0.3, 0.03, 0.012)),
			line,
			Vector3(0, 0.13 + i * 0.002, -0.07 + i * 0.07),
			Vector3(-12, 0, 0)
		)
	_part(root, _box(Vector3(0.012, 0.03, 0.2)), line, Vector3(0.0, 0.135, 0), Vector3(-12, 0, 0))
	_part(
		root, _box(Vector3(0.08, 0.04, 0.06)), line, Vector3(0.08, 0.14, 0.02), Vector3(-12, 0, 0)
	)
	return root


# --------------------------------------------------------------- attachments
## Optic — scope/sight tube with a glowing lens, mounted on a rail block.
static func build_att_optic(id: String) -> Node3D:
	var root := Node3D.new()
	var col := AssetRegistry.get_color(id)
	var body := _mat(Color(0.12, 0.13, 0.15), 0.5, 0.4)
	var lens := _mat(Color(0.4, 0.7, 1.0), 0.0, 0.2, Color(0.3, 0.6, 1.0), 2.5)
	var rail := _mat(Color(0.2, 0.21, 0.24), 0.6, 0.4)
	var long := id == "att_scope_4x"
	var tube_len := 0.34 if long else 0.18
	var tube_r := 0.07 if long else 0.06
	_part(root, _cyl(tube_r, tube_len, 14), body, Vector3(0, 0.22, 0), Vector3(90, 0, 0))  # tube along Z
	_part(
		root,
		_cyl(tube_r + 0.01, 0.03, 14),
		lens,
		Vector3(0, 0.22, -tube_len * 0.5),
		Vector3(90, 0, 0)
	)
	if not long:  # red-dot / holo get a flat hood
		_part(root, _box(Vector3(0.13, 0.1, 0.04)), body, Vector3(0, 0.26, -0.02))
		_part(root, _box(Vector3(0.09, 0.06, 0.01)), lens, Vector3(0, 0.26, -0.04))
	_part(root, _box(Vector3(0.06, 0.06, 0.12)), rail, Vector3(0, 0.12, 0))  # mount
	_part(root, _cyl(0.03, 0.06, 8), col_mat(col), Vector3(0, 0.32, 0.04))  # adj turret (tint)
	return root


## Magazine — curved box mag, or a drum cylinder for the drum mag.
static func build_att_mag(id: String) -> Node3D:
	var root := Node3D.new()
	var col := AssetRegistry.get_color(id)
	var body := _mat(col, 0.3, 0.45)
	var dark := _mat(Color(0.12, 0.13, 0.15), 0.4, 0.5)
	if id == "att_drum_mag":
		_part(root, _cyl(0.18, 0.14, 16), body, Vector3(0, 0.2, 0), Vector3(90, 0, 0))
		_part(root, _cyl(0.19, 0.04, 16), dark, Vector3(0, 0.2, 0.06), Vector3(90, 0, 0))
		_part(root, _box(Vector3(0.08, 0.14, 0.1)), dark, Vector3(0, 0.34, 0))  # feed neck
	else:
		var h := 0.24 if id == "att_light_mag" else 0.32
		_part(
			root,
			_box(Vector3(0.12, h, 0.09)),
			body,
			Vector3(0, h * 0.5 + 0.04, 0.0),
			Vector3(14, 0, 0)
		)
		_part(root, _box(Vector3(0.13, 0.05, 0.1)), dark, Vector3(0, h + 0.02, -0.02))  # feed lips
	return root


## Barrel — tube + a muzzle device that varies by id.
static func build_att_barrel(id: String) -> Node3D:
	var root := Node3D.new()
	var dark := _mat(Color(0.14, 0.15, 0.17), 0.6, 0.35)
	var steel := _mat(Color(0.3, 0.32, 0.35), 0.7, 0.3)
	var blen := 0.42 if id == "att_long_barrel" else 0.3
	_part(root, _cyl(0.045, blen, 12), dark, Vector3(0, 0.2, 0), Vector3(90, 0, 0))
	if id == "att_suppressor":
		_part(root, _cyl(0.075, 0.22, 14), steel, Vector3(0, 0.2, -0.18), Vector3(90, 0, 0))
	elif id == "att_compensator":
		_part(root, _cyl(0.06, 0.1, 12), steel, Vector3(0, 0.2, -blen * 0.5), Vector3(90, 0, 0))
		_part(root, _box(Vector3(0.14, 0.02, 0.08)), dark, Vector3(0, 0.24, -blen * 0.5))  # top port
	else:  # long barrel — slim extended muzzle
		_part(root, _cyl(0.05, 0.08, 12), steel, Vector3(0, 0.2, -blen * 0.5), Vector3(90, 0, 0))
	return root


## Grip — an angled foregrip block.
static func build_att_grip(id: String) -> Node3D:
	var root := Node3D.new()
	var col := AssetRegistry.get_color(id)
	var body := _mat(col, 0.2, 0.5)
	var dark := _mat(Color(0.13, 0.14, 0.16), 0.4, 0.5)
	var angled := id == "att_quickdraw_grip"
	_part(root, _box(Vector3(0.1, 0.05, 0.16)), dark, Vector3(0, 0.34, 0))  # rail clamp
	_part(
		root,
		_cyl(0.045, 0.28, 12),
		body,
		Vector3(0, 0.18, 0.02),
		Vector3(20, 0, 0) if angled else Vector3(2, 0, 0)
	)  # grip
	_part(root, _cyl(0.05, 0.04, 12), dark, Vector3(0, 0.05, 0.07 if angled else 0.03))  # base cap
	return root


## Small helper: a tinted low-metal material for accent bits.
static func col_mat(col: Color) -> StandardMaterial3D:
	return _mat(col, 0.3, 0.45)


# ================================================================= BIOME FAUNA (v0.3)
# Mechanical biome enemies — same discipline as the enemies above: StandardMaterial3D
# only (hit-flash compatible), authored facing -Z, named parts for the per-frame idle
# animation hooks in the enemy scripts (robot_worm / robot_kamikaze / robot_strafer).


## DESERT — Sand-worm: a segmented mechanical drill-worm. Horizontal body along Z with
## a drill-cone head (-Z), a glowing amber MAW ring (the weak point sits there in the
## scene), 7 tapered ring segments under pivots "Seg0".."Seg6" (the crawl undulation
## sways the pivots), dorsal fins, and a tail spike. ModelRoot at y=0 — body axis ≈y0.5.
static func build_robot_sandworm() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_sandworm")  # sandy amber
	var shell := ProcMaterials.weathered(
		Color(0.55, 0.42, 0.26), 0.55, 0.5, 0.55, 41, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.2, 0.17, 0.14), 0.5, 0.55)
	var plate := _mat(Color(0.4, 0.3, 0.18), 0.6, 0.45)
	var maw_mat := _mat(accent_col, 0.0, 0.3, accent_col, 6.0)

	# Drill head: a ribbed cone whose apex faces -Z (the travel direction).
	_part(root, _cone(0.4, 0.8, 12), dark, Vector3(0, 0.5, -0.85), Vector3(-90, 0, 0))
	_part(root, _cone(0.3, 0.62, 10), plate, Vector3(0, 0.5, -0.8), Vector3(-90, 0, 0))
	# Glowing maw ring just behind the drill (named for the emission pulse).
	var maw := _part(root, _cyl(0.46, 0.12, 16), maw_mat, Vector3(0, 0.5, -0.42), Vector3(90, 0, 0))
	maw.name = "Maw"

	# 7 tapered body segments, each under its own pivot so the crawl can undulate them.
	for i in 7:
		var t := float(i) / 6.0
		var r: float = lerpf(0.44, 0.2, t)
		var y: float = lerpf(0.5, 0.36, t)
		var pivot := Node3D.new()
		pivot.name = "Seg%d" % i
		pivot.position = Vector3(0, y, -0.15 + float(i) * 0.27)
		root.add_child(pivot)
		var seg_mat := shell if (i % 2 == 0) else dark
		_part(
			pivot,
			_sphere(r, false, 8, 14),
			seg_mat,
			Vector3.ZERO,
			Vector3.ZERO,
			Vector3(1.0, 0.85, 0.78)
		)
		# Dorsal fin on every other segment for a serrated silhouette.
		if i % 2 == 0:
			_part(pivot, _cone(0.1, 0.26, 6), plate, Vector3(0, r * 0.8, 0))
	# Tail spike (+Z rear).
	_part(root, _cone(0.16, 0.5, 8), dark, Vector3(0, 0.36, 1.85), Vector3(90, 0, 0))
	return root


## DESERT — Scarab: a squat kamikaze beetle. Domed rust-orange shell, 4 stub legs under
## pivots "Leg0".."Leg3", front mandibles, and a rear glowing red "Core" that the script
## blinks faster while ARMED. ModelRoot at y=0 — feet at ground.
static func build_robot_scarab() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_scarab")  # rust orange
	var shell := ProcMaterials.weathered(
		Color(0.5, 0.27, 0.12), 0.55, 0.5, 0.55, 43, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.16, 0.14, 0.13), 0.45, 0.55)
	var leg_mat := _mat(Color(0.3, 0.26, 0.22), 0.55, 0.45)
	var core_mat := _mat(Color(0.95, 0.2, 0.12), 0.0, 0.3, Color(0.95, 0.2, 0.12), 6.0)
	var accent := _mat(accent_col, 0.3, 0.45)

	# Domed carapace + dark underbelly.
	_part(
		root,
		_sphere(0.3, true, 8, 14),
		shell,
		Vector3(0, 0.16, 0),
		Vector3.ZERO,
		Vector3(1.2, 0.9, 1.35)
	)
	_part(root, _box(Vector3(0.4, 0.12, 0.5)), dark, Vector3(0, 0.12, 0))
	# Shell seam stripe + the rear ARMING core (named for the blink).
	_part(root, _box(Vector3(0.04, 0.04, 0.5)), accent, Vector3(0, 0.42, 0))
	var core := _part(root, _sphere(0.1, false, 8, 12), core_mat, Vector3(0, 0.4, 0.22))
	core.name = "Core"
	# Front mandible prongs (-Z).
	_part(root, _cone(0.045, 0.2, 6), dark, Vector3(0.1, 0.1, -0.42), Vector3(-100, 0, 0))
	_part(root, _cone(0.045, 0.2, 6), dark, Vector3(-0.1, 0.1, -0.42), Vector3(-100, 0, 0))
	# 4 stub legs under pivots (2 per side) for the skitter sway.
	var li := 0
	for side in [-1.0, 1.0]:
		for z in [-0.14, 0.18]:
			var zf := float(z)
			var attach := Vector3(side * 0.22, 0.12, zf)
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % li
			pivot.position = attach
			root.add_child(pivot)
			_strut(pivot, Vector3.ZERO, Vector3(side * 0.2, -0.12, 0.02), 0.04, leg_mat)
			_part(pivot, _sphere(0.045, false, 6, 8), dark, Vector3(side * 0.2, -0.12, 0.02))
			li += 1
	return root


## DESERT — Dust-devil: a grounded strafing gunner riding a SPINNING sand-skirt cone
## (pivot named "Skirt", spun by the script), with a slim torso, a single amber "Eye",
## and vent fins. ModelRoot at y=0 — skirt base at ground.
static func build_robot_dustdevil() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_dustdevil")  # sand amber
	var sand := ProcMaterials.weathered(
		Color(0.62, 0.5, 0.3), 0.4, 0.6, 0.5, 47, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.22, 0.2, 0.17), 0.5, 0.5)
	var eye_mat := _mat(accent_col, 0.0, 0.3, accent_col, 6.0)
	var plate := _mat(Color(0.45, 0.36, 0.22), 0.6, 0.45)

	# Spinning skirt: an inverted dust cone + 3 angled vanes, all under the "Skirt" pivot.
	var skirt := Node3D.new()
	skirt.name = "Skirt"
	root.add_child(skirt)
	_part(skirt, _cone(0.55, 0.95, 14), sand, Vector3(0, 0.48, 0))
	for i in 3:
		var ang := TAU * float(i) / 3.0
		_part(
			skirt,
			_box(Vector3(0.06, 0.5, 0.28)),
			plate,
			Vector3(cos(ang) * 0.34, 0.42, sin(ang) * 0.34),
			Vector3(0, rad_to_deg(-ang), 18)
		)
	# Torso column + shoulder ring + head dome.
	_part(root, _cyl(0.26, 0.5, 12), dark, Vector3(0, 1.18, 0))
	_part(root, _cyl(0.32, 0.1, 12), plate, Vector3(0, 1.0, 0))
	_part(root, _sphere(0.24, true, 8, 12), sand, Vector3(0, 1.46, 0))
	# Single amber sensor eye (-Z) + two rear vents.
	var eye := _part(root, _sphere(0.09, false, 8, 12), eye_mat, Vector3(0, 1.42, -0.22))
	eye.name = "Eye"
	_part(root, _box(Vector3(0.1, 0.18, 0.05)), dark, Vector3(0.14, 1.25, 0.24), Vector3(0, 15, 0))
	_part(
		root, _box(Vector3(0.1, 0.18, 0.05)), dark, Vector3(-0.14, 1.25, 0.24), Vector3(0, -15, 0)
	)
	return root


## SNOW — Frost-hound: a wolf-like quadruped. Low box body, wedge head with an
## ice-blue "Core" visor, 4 strut legs under pivots "Leg0".."Leg3" (trot gait),
## dorsal icicle fins, stub tail. ModelRoot at y=0 — paws at ground.
static func build_robot_frosthound() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_frosthound")  # ice blue
	var shell := ProcMaterials.weathered(
		Color(0.62, 0.7, 0.76), 0.55, 0.45, 0.5, 53, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.2, 0.23, 0.27), 0.5, 0.5)
	var ice := _mat(Color(0.7, 0.88, 0.98), 0.1, 0.25)
	var visor := _mat(accent_col, 0.0, 0.25, accent_col, 6.0)
	var leg_mat := _mat(Color(0.32, 0.36, 0.42), 0.55, 0.45)

	# Body + chest plate + wedge head (-Z) with the glowing visor.
	_part(root, _box(Vector3(0.5, 0.42, 1.05)), shell, Vector3(0, 0.66, 0.05))
	_part(root, _box(Vector3(0.42, 0.3, 0.4)), dark, Vector3(0, 0.6, -0.55))
	_part(root, _box(Vector3(0.34, 0.26, 0.34)), shell, Vector3(0, 0.82, -0.72), Vector3(12, 0, 0))
	var core := _part(root, _box(Vector3(0.26, 0.07, 0.06)), visor, Vector3(0, 0.86, -0.9))
	core.name = "Core"
	# Jaw + ear prongs.
	_part(root, _box(Vector3(0.2, 0.08, 0.24)), dark, Vector3(0, 0.66, -0.84))
	_part(root, _cone(0.05, 0.16, 6), dark, Vector3(0.12, 1.0, -0.62))
	_part(root, _cone(0.05, 0.16, 6), dark, Vector3(-0.12, 1.0, -0.62))
	# Dorsal icicle fins + tail stub.
	for i in 3:
		_part(
			root,
			_cone(0.07, 0.26 - float(i) * 0.05, 6),
			ice,
			Vector3(0, 0.92, -0.2 + float(i) * 0.3),
			Vector3(-12, 0, 0)
		)
	_part(root, _cone(0.06, 0.3, 6), shell, Vector3(0, 0.74, 0.68), Vector3(110, 0, 0))
	# 4 legs under pivots at the body corners.
	var li := 0
	for side in [-1.0, 1.0]:
		for z in [-0.38, 0.42]:
			var zf := float(z)
			var attach := Vector3(side * 0.24, 0.6, zf)
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % li
			pivot.position = attach
			root.add_child(pivot)
			_strut(pivot, Vector3.ZERO, Vector3(side * 0.06, -0.32, 0.06), 0.06, leg_mat)
			_strut(
				pivot,
				Vector3(side * 0.06, -0.32, 0.06),
				Vector3(side * 0.08, -0.6, -0.02),
				0.05,
				leg_mat
			)
			_part(pivot, _sphere(0.06, false, 6, 8), dark, Vector3(side * 0.08, -0.6, -0.02))
			li += 1
	return root


## SNOW — Cryo-mortar: a squat tripod artillery piece. Base disc on 3 splayed legs,
## a fat 45°-angled mortar "Tube" pivot (player-yaw tracked), cyan frost-tank "Core".
## ModelRoot at y=0.
static func build_robot_cryomortar() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_cryomortar")  # frost blue
	var shell := ProcMaterials.weathered(
		Color(0.45, 0.52, 0.6), 0.6, 0.45, 0.55, 59, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.18, 0.2, 0.24), 0.5, 0.55)
	var frost := _mat(accent_col, 0.0, 0.3, accent_col, 5.0)
	var leg_mat := _mat(Color(0.3, 0.34, 0.4), 0.55, 0.45)

	# 3 splayed tripod legs + the base platform.
	for i in 3:
		var ang := TAU * float(i) / 3.0 + 0.5
		var foot := Vector3(cos(ang) * 0.62, 0.0, sin(ang) * 0.62)
		_strut(root, Vector3(0, 0.5, 0), foot, 0.07, leg_mat)
		_part(root, _sphere(0.08, false, 6, 8), dark, foot)
	_part(root, _cyl(0.42, 0.22, 12), shell, Vector3(0, 0.55, 0))
	# The mortar tube under a yaw pivot, angled up 45° facing -Z.
	var tube := Node3D.new()
	tube.name = "Tube"
	tube.position = Vector3(0, 0.72, 0)
	root.add_child(tube)
	_part(tube, _cyl(0.2, 1.1, 12), dark, Vector3(0, 0.32, -0.3), Vector3(-45, 0, 0))
	_part(tube, _cyl(0.24, 0.18, 12), shell, Vector3(0, 0.66, -0.66), Vector3(-45, 0, 0))
	# Frost tanks: one glowing "Core" + a dark twin.
	var core := _part(root, _cyl(0.13, 0.4, 10), frost, Vector3(0.3, 0.9, 0.18))
	core.name = "Core"
	_part(root, _cyl(0.13, 0.4, 10), dark, Vector3(-0.3, 0.9, 0.18))
	return root


## SNOW — Avalanche: a hulking white-plated brute. Wide torso, huge "Fist0"/"Fist1"
## boxes (raised during the slam windup), small sensor head, blue chest "Core"
## (the weak point sits there in the scene). ModelRoot at y=0.
static func build_robot_avalanche() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_avalanche")  # glacial white-blue
	var plate := ProcMaterials.weathered(
		Color(0.78, 0.83, 0.88), 0.5, 0.5, 0.45, 61, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.22, 0.25, 0.3), 0.5, 0.55)
	var core_mat := _mat(Color(0.35, 0.7, 1.0), 0.0, 0.3, Color(0.35, 0.7, 1.0), 6.0)
	var ice := _mat(Color(0.7, 0.88, 0.98), 0.1, 0.25)

	# Thick legs + pelvis.
	_part(root, _box(Vector3(0.3, 0.7, 0.34)), dark, Vector3(0.26, 0.35, 0))
	_part(root, _box(Vector3(0.3, 0.7, 0.34)), dark, Vector3(-0.26, 0.35, 0))
	_part(root, _box(Vector3(0.84, 0.3, 0.5)), plate, Vector3(0, 0.82, 0))
	# Wide armored torso + shoulder pads + the glowing chest core (-Z face).
	_part(root, _box(Vector3(1.15, 0.95, 0.7)), plate, Vector3(0, 1.5, 0))
	_part(root, _box(Vector3(0.4, 0.34, 0.5)), ice, Vector3(0.74, 1.92, 0))
	_part(root, _box(Vector3(0.4, 0.34, 0.5)), ice, Vector3(-0.74, 1.92, 0))
	var core := _part(root, _sphere(0.16, false, 8, 12), core_mat, Vector3(0, 1.55, -0.36))
	core.name = "Core"
	# Small sensor head between the shoulders.
	_part(root, _box(Vector3(0.3, 0.24, 0.3)), dark, Vector3(0, 2.12, -0.05))
	_part(root, _box(Vector3(0.2, 0.05, 0.05)), core_mat, Vector3(0, 2.12, -0.22))
	# HUGE fists on arm struts, under pivots so the windup can RAISE them.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var fist := Node3D.new()
		fist.name = "Fist%d" % i
		fist.position = Vector3(side * 0.95, 1.0, -0.1)
		root.add_child(fist)
		_strut(root, Vector3(side * 0.74, 1.85, 0), Vector3(side * 0.95, 1.25, -0.1), 0.1, dark)
		_part(fist, _box(Vector3(0.42, 0.42, 0.46)), plate, Vector3(0, 0, 0))
		_part(fist, _box(Vector3(0.44, 0.16, 0.2)), dark, Vector3(0, -0.16, -0.18))
	return root


## RAIN — Oni: a temple-guardian samurai mech. Broad torso, kabuto helmet with horn
## cones, a glowing RED oni-mask face, a katana-arm blade, skirt plates. Its weak
## point (scene) sits on the BACK — the model marks it with a glowing seal. ModelRoot at y=0.
static func build_robot_oni() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_oni")  # oni red
	var armor := ProcMaterials.weathered(
		Color(0.26, 0.22, 0.24), 0.55, 0.5, 0.55, 67, Vector3(0.6, 0.6, 0.6), false
	)
	var lacquer := _mat(Color(0.5, 0.12, 0.12), 0.3, 0.4)
	var dark := _mat(Color(0.15, 0.14, 0.16), 0.5, 0.55)
	var mask := _mat(accent_col, 0.0, 0.3, accent_col, 6.0)
	var gold := _mat(Color(0.85, 0.68, 0.25), 0.7, 0.35)

	# Legs + skirt plates (kusazuri).
	_part(root, _box(Vector3(0.28, 0.66, 0.3)), dark, Vector3(0.22, 0.33, 0))
	_part(root, _box(Vector3(0.28, 0.66, 0.3)), dark, Vector3(-0.22, 0.33, 0))
	for i in 4:
		var a := -0.45 + float(i) * 0.3
		_part(
			root,
			_box(Vector3(0.26, 0.34, 0.06)),
			lacquer,
			Vector3(a, 0.78, -0.26),
			Vector3(8, 0, 0)
		)
		_part(
			root,
			_box(Vector3(0.26, 0.34, 0.06)),
			lacquer,
			Vector3(a, 0.78, 0.26),
			Vector3(-8, 0, 0)
		)
	# Broad torso + chest cords + shoulder sode plates.
	_part(root, _box(Vector3(0.95, 0.9, 0.55)), armor, Vector3(0, 1.4, 0))
	_part(root, _box(Vector3(0.5, 0.5, 0.04)), gold, Vector3(0, 1.45, -0.29))
	_part(root, _box(Vector3(0.42, 0.5, 0.3)), lacquer, Vector3(0.64, 1.7, 0), Vector3(0, 0, -10))
	_part(root, _box(Vector3(0.42, 0.5, 0.3)), lacquer, Vector3(-0.64, 1.7, 0), Vector3(0, 0, 10))
	# Kabuto head: helmet dome + horns + the glowing oni mask (-Z).
	_part(root, _sphere(0.24, true, 8, 12), armor, Vector3(0, 2.05, 0))
	_part(root, _cone(0.05, 0.34, 6), gold, Vector3(0.12, 2.28, -0.05), Vector3(0, 0, -22))
	_part(root, _cone(0.05, 0.34, 6), gold, Vector3(-0.12, 2.28, -0.05), Vector3(0, 0, 22))
	var face := _part(root, _box(Vector3(0.26, 0.22, 0.06)), mask, Vector3(0, 1.98, -0.24))
	face.name = "Core"
	# Katana arm (right): a long blade box angled down-forward.
	_strut(root, Vector3(0.64, 1.45, 0), Vector3(0.86, 1.0, -0.2), 0.08, dark)
	_part(
		root,
		_box(Vector3(0.05, 0.9, 0.14)),
		_mat(Color(0.75, 0.78, 0.85), 0.85, 0.2),
		Vector3(0.9, 0.65, -0.45),
		Vector3(30, 0, 0)
	)
	# Left fist.
	_strut(root, Vector3(-0.64, 1.45, 0), Vector3(-0.8, 1.05, -0.1), 0.08, dark)
	_part(root, _box(Vector3(0.24, 0.24, 0.26)), armor, Vector3(-0.8, 0.95, -0.12))
	# BACK seal — a glowing plate marking the scene's ×3 weak point.
	_part(root, _box(Vector3(0.3, 0.3, 0.05)), mask, Vector3(0, 1.55, 0.3))
	return root


## RAIN — Kappa: a hunched shell-backed pouncer. Forward-leaning body under a domed
## shell, claw arms, glowing green eye "Core", legs under "Leg0".."Leg3" pivots
## (shares the pouncer gait with the hound). ModelRoot at y=0.
static func build_robot_kappa() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_kappa")  # kappa green
	var shell := ProcMaterials.weathered(
		Color(0.24, 0.36, 0.28), 0.5, 0.5, 0.55, 71, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.16, 0.2, 0.18), 0.5, 0.55)
	var eye_mat := _mat(accent_col, 0.0, 0.25, accent_col, 6.0)
	var claw := _mat(Color(0.55, 0.58, 0.62), 0.7, 0.35)

	# Hunched body (tilted capsule) + the domed back shell with ridge plates.
	_part(root, _capsule(0.3, 0.9), shell, Vector3(0, 0.7, -0.05), Vector3(55, 0, 0))
	_part(
		root,
		_sphere(0.46, true, 8, 14),
		dark,
		Vector3(0, 0.78, 0.18),
		Vector3(-18, 0, 0),
		Vector3(1.0, 0.7, 1.1)
	)
	for i in 3:
		_part(
			root,
			_cone(0.06, 0.14, 6),
			shell,
			Vector3(0, 1.06 - float(i) * 0.1, 0.1 + float(i) * 0.22),
			Vector3(-20, 0, 0)
		)
	# Head: flat dish crown + the glowing eyes bar.
	_part(root, _sphere(0.18, false, 8, 12), shell, Vector3(0, 1.06, -0.42))
	_part(root, _cyl(0.16, 0.05, 12), dark, Vector3(0, 1.2, -0.42))
	var eyes := _part(root, _box(Vector3(0.22, 0.06, 0.06)), eye_mat, Vector3(0, 1.06, -0.58))
	eyes.name = "Core"
	# Claw arms (-Z reach).
	_strut(root, Vector3(0.3, 0.85, -0.15), Vector3(0.45, 0.5, -0.45), 0.06, dark)
	_part(root, _cone(0.07, 0.22, 6), claw, Vector3(0.45, 0.42, -0.52), Vector3(-115, 0, 0))
	_strut(root, Vector3(-0.3, 0.85, -0.15), Vector3(-0.45, 0.5, -0.45), 0.06, dark)
	_part(root, _cone(0.07, 0.22, 6), claw, Vector3(-0.45, 0.42, -0.52), Vector3(-115, 0, 0))
	# 4 squat legs under pouncer pivots.
	var li := 0
	for side in [-1.0, 1.0]:
		for z in [-0.18, 0.26]:
			var zf := float(z)
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % li
			pivot.position = Vector3(side * 0.28, 0.5, zf)
			root.add_child(pivot)
			_strut(pivot, Vector3.ZERO, Vector3(side * 0.1, -0.5, 0.04), 0.06, dark)
			_part(pivot, _sphere(0.07, false, 6, 8), claw, Vector3(side * 0.1, -0.5, 0.04))
			li += 1
	return root


## RAIN — Raiju: a sleek storm-spirit canine. Slim long body, thin legs, lightning-rod
## "Antler0"/"Antler1" cones, electric-blue chest "Core" + arc fins. ModelRoot at y=0.
static func build_robot_raiju() -> Node3D:
	var root := Node3D.new()
	var accent_col := AssetRegistry.get_color("robot_raiju")  # electric blue
	var body := ProcMaterials.weathered(
		Color(0.3, 0.34, 0.45), 0.6, 0.4, 0.5, 73, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.16, 0.18, 0.24), 0.5, 0.5)
	var bolt := _mat(accent_col, 0.0, 0.2, accent_col, 7.0)
	var leg_mat := _mat(Color(0.28, 0.32, 0.4), 0.55, 0.45)

	# Slim body + neck + fox head (-Z).
	_part(root, _box(Vector3(0.34, 0.3, 0.95)), body, Vector3(0, 0.62, 0.08))
	_part(root, _box(Vector3(0.24, 0.22, 0.3)), body, Vector3(0, 0.78, -0.5), Vector3(20, 0, 0))
	_part(root, _box(Vector3(0.22, 0.18, 0.3)), dark, Vector3(0, 0.92, -0.72))
	_part(root, _cone(0.05, 0.16, 6), dark, Vector3(0, 0.9, -0.92), Vector3(-100, 0, 0))
	# Electric core + dorsal arc fins.
	var core := _part(root, _sphere(0.1, false, 8, 12), bolt, Vector3(0, 0.66, -0.32))
	core.name = "Core"
	for i in 2:
		_part(
			root,
			_box(Vector3(0.04, 0.16, 0.2)),
			bolt,
			Vector3(0, 0.84, -0.05 + float(i) * 0.34),
			Vector3(-16, 0, 0)
		)
	# Lightning-rod antlers under quiver pivots.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var ant := Node3D.new()
		ant.name = "Antler%d" % i
		ant.position = Vector3(side * 0.1, 1.0, -0.66)
		root.add_child(ant)
		_part(
			ant,
			_cone(0.03, 0.3, 5),
			bolt,
			Vector3(side * 0.04, 0.12, 0.02),
			Vector3(0, 0, -side * 18.0)
		)
	# Bushy segmented tail (+Z) + 4 thin legs.
	_part(root, _cone(0.1, 0.5, 6), body, Vector3(0, 0.74, 0.72), Vector3(115, 0, 0))
	for side in [-1.0, 1.0]:
		for z in [-0.3, 0.38]:
			var zf := float(z)
			_strut(
				root,
				Vector3(side * 0.16, 0.55, zf),
				Vector3(side * 0.2, 0.0, zf + 0.04),
				0.045,
				leg_mat
			)
	return root


# ================================================================= BIOME MINIBOSSES (v0.3)
# Oversized landmark threats — each is the silhouette of its biome's grunt scaled up
# with extra plating. They reuse the SAME named animation parts as their base archetype
# (slammer Fist0/Fist1 + Core, strafer Skirt + Eye, oni back-seal, flyer RotorHub + Body
# + Core) so the inherited _animate_visual binds with no script change. ModelRoot at y=0.


## SNOW miniboss — Snow Golem: a colossal icy avalanche. Huge plated torso, massive
## shoulder slabs, two oversized "Fist0"/"Fist1" boxes (raised during the slam windup),
## a glowing pale-cyan chest "Core". ~2.6 m tall.
static func build_robot_snow_golem() -> Node3D:
	var root := Node3D.new()
	var glow_col := Color(0.55, 0.85, 1.0)  # pale cyan
	var plate := ProcMaterials.weathered(
		Color(0.62, 0.78, 0.95), 0.5, 0.5, 0.45, 83, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.2, 0.26, 0.34), 0.5, 0.55)
	var core_mat := _mat(glow_col, 0.0, 0.3, glow_col, 6.0)
	var ice := _mat(Color(0.72, 0.9, 1.0), 0.1, 0.22)

	# Thick legs + wide pelvis block.
	_part(root, _box(Vector3(0.4, 0.95, 0.46)), dark, Vector3(0.36, 0.48, 0))
	_part(root, _box(Vector3(0.4, 0.95, 0.46)), dark, Vector3(-0.36, 0.48, 0))
	_part(root, _box(Vector3(1.15, 0.4, 0.66)), plate, Vector3(0, 1.12, 0))
	# Massive armored torso + the glowing chest core (-Z face).
	_part(root, _box(Vector3(1.55, 1.3, 0.95)), plate, Vector3(0, 2.05, 0))
	var core := _part(root, _sphere(0.22, false, 8, 12), core_mat, Vector3(0, 2.1, -0.5))
	core.name = "Core"
	# Huge shoulder slabs (jagged ice crown on top of each).
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		_part(root, _box(Vector3(0.58, 0.5, 0.7)), ice, Vector3(side * 1.02, 2.6, 0))
		_part(
			root,
			_cone(0.12, 0.4, 6),
			ice,
			Vector3(side * 1.02, 2.95, 0),
			Vector3(0, 0, side * -10.0)
		)
	# Small sensor head sunk between the shoulders.
	_part(root, _box(Vector3(0.4, 0.32, 0.4)), dark, Vector3(0, 2.86, -0.06))
	_part(root, _box(Vector3(0.28, 0.06, 0.06)), core_mat, Vector3(0, 2.86, -0.28))
	# OVERSIZED fists on arm struts, under pivots so the slam windup can RAISE them.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var fist := Node3D.new()
		fist.name = "Fist%d" % i
		fist.position = Vector3(side * 1.28, 1.3, -0.12)
		root.add_child(fist)
		_strut(root, Vector3(side * 1.02, 2.5, 0), Vector3(side * 1.28, 1.65, -0.12), 0.14, dark)
		_part(fist, _box(Vector3(0.6, 0.6, 0.66)), plate, Vector3(0, 0, 0))
		_part(fist, _box(Vector3(0.64, 0.22, 0.28)), dark, Vector3(0, -0.22, -0.24))
		# Icy knuckle spikes.
		for k in 3:
			_part(
				fist,
				_cone(0.06, 0.2, 5),
				ice,
				Vector3(-0.18 + float(k) * 0.18, 0.0, -0.38),
				Vector3(-90, 0, 0)
			)
	return root


## DESERT miniboss — Dune Warden: a heavy sand-skirted strafing gunner. Wide spinning
## "Skirt" sand cone, twin torso, a triple barrel cluster (-Z) named "Barrel", an amber
## sensor "Eye". The strafer animator only spins the Skirt + pulses the Eye, but the
## barrel cluster keeps the heavy-gunner read. ~2 m tall.
static func build_robot_dune_warden() -> Node3D:
	var root := Node3D.new()
	var glow_col := Color(0.95, 0.62, 0.22)  # desert amber
	var sand := ProcMaterials.weathered(
		Color(0.82, 0.65, 0.3), 0.4, 0.6, 0.5, 89, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.24, 0.21, 0.16), 0.5, 0.5)
	var eye_mat := _mat(glow_col, 0.0, 0.3, glow_col, 6.0)
	var plate := _mat(Color(0.6, 0.46, 0.26), 0.6, 0.45)
	var gun := _mat(Color(0.28, 0.25, 0.2), 0.65, 0.4)

	# WIDE spinning sand skirt: a big inverted dust cone + 5 angled vanes under "Skirt".
	var skirt := Node3D.new()
	skirt.name = "Skirt"
	root.add_child(skirt)
	_part(skirt, _cone(0.85, 1.3, 16), sand, Vector3(0, 0.66, 0))
	for i in 5:
		var ang := TAU * float(i) / 5.0
		_part(
			skirt,
			_box(Vector3(0.08, 0.66, 0.38)),
			plate,
			Vector3(cos(ang) * 0.52, 0.6, sin(ang) * 0.52),
			Vector3(0, rad_to_deg(-ang), 16)
		)
	# Heavy torso column + shoulder ring + domed head.
	_part(root, _cyl(0.4, 0.7, 14), dark, Vector3(0, 1.62, 0))
	_part(root, _cyl(0.5, 0.14, 14), plate, Vector3(0, 1.36, 0))
	_part(root, _sphere(0.36, true, 8, 14), sand, Vector3(0, 2.0, 0))
	# Single amber sensor eye (-Z) + rear vents.
	var eye := _part(root, _sphere(0.14, false, 8, 12), eye_mat, Vector3(0, 1.92, -0.34))
	eye.name = "Eye"
	_part(root, _box(Vector3(0.14, 0.26, 0.06)), dark, Vector3(0.22, 1.7, 0.36), Vector3(0, 15, 0))
	_part(
		root, _box(Vector3(0.14, 0.26, 0.06)), dark, Vector3(-0.22, 1.7, 0.36), Vector3(0, -15, 0)
	)
	# Triple barrel cluster on a side arm (-Z), under "Barrel".
	var barrel := Node3D.new()
	barrel.name = "Barrel"
	barrel.position = Vector3(0.62, 1.6, -0.2)
	root.add_child(barrel)
	_part(barrel, _box(Vector3(0.24, 0.24, 0.34)), gun, Vector3(0, 0, 0))
	for i in 3:
		var off := -0.1 + float(i) * 0.1
		_part(barrel, _cyl(0.05, 0.6, 8), gun, Vector3(off, 0.02, -0.42), Vector3(-90, 0, 0))
	return root


## RAIN miniboss — Oni Chief: a hulking crimson temple-guardian. Broad lacquered torso,
## horned kabuto head, a glowing oni mask "Core" (-Z), a heavy club arm, and a bright
## BACK-PLATE seal (+Z) hinting the scene's ×3 weak point. ~2.4 m tall.
static func build_robot_oni_chief() -> Node3D:
	var root := Node3D.new()
	var glow_col := Color(0.75, 0.18, 0.15)  # crimson
	var armor := ProcMaterials.weathered(
		Color(0.36, 0.16, 0.14), 0.55, 0.5, 0.55, 97, Vector3(0.6, 0.6, 0.6), false
	)
	var lacquer := _mat(Color(0.62, 0.14, 0.13), 0.3, 0.4)
	var dark := _mat(Color(0.14, 0.12, 0.13), 0.5, 0.55)
	var mask := _mat(glow_col, 0.0, 0.3, glow_col, 6.0)
	var gold := _mat(Color(0.85, 0.68, 0.25), 0.7, 0.35)

	# Legs + skirt plates (kusazuri).
	_part(root, _box(Vector3(0.34, 0.8, 0.36)), dark, Vector3(0.28, 0.4, 0))
	_part(root, _box(Vector3(0.34, 0.8, 0.36)), dark, Vector3(-0.28, 0.4, 0))
	for i in 5:
		var a := -0.6 + float(i) * 0.3
		_part(
			root, _box(Vector3(0.3, 0.4, 0.07)), lacquer, Vector3(a, 0.95, -0.32), Vector3(8, 0, 0)
		)
		_part(
			root, _box(Vector3(0.3, 0.4, 0.07)), lacquer, Vector3(a, 0.95, 0.32), Vector3(-8, 0, 0)
		)
	# Broad torso + chest cords + shoulder sode plates.
	_part(root, _box(Vector3(1.2, 1.1, 0.7)), armor, Vector3(0, 1.72, 0))
	_part(root, _box(Vector3(0.6, 0.6, 0.05)), gold, Vector3(0, 1.78, -0.36))
	_part(root, _box(Vector3(0.52, 0.6, 0.36)), lacquer, Vector3(0.8, 2.06, 0), Vector3(0, 0, -10))
	_part(root, _box(Vector3(0.52, 0.6, 0.36)), lacquer, Vector3(-0.8, 2.06, 0), Vector3(0, 0, 10))
	# Kabuto head: helmet dome + horns + the glowing oni mask (-Z).
	_part(root, _sphere(0.3, true, 8, 12), armor, Vector3(0, 2.5, 0))
	_part(root, _cone(0.06, 0.42, 6), gold, Vector3(0.15, 2.78, -0.06), Vector3(0, 0, -22))
	_part(root, _cone(0.06, 0.42, 6), gold, Vector3(-0.15, 2.78, -0.06), Vector3(0, 0, 22))
	var face := _part(root, _box(Vector3(0.32, 0.26, 0.07)), mask, Vector3(0, 2.42, -0.3))
	face.name = "Core"
	# Heavy club arm (right): a thick spiked tetsubo angled down-forward.
	_strut(root, Vector3(0.8, 1.78, 0), Vector3(1.06, 1.2, -0.24), 0.1, dark)
	_part(root, _box(Vector3(0.2, 0.95, 0.2)), dark, Vector3(1.12, 0.85, -0.5), Vector3(30, 0, 0))
	for k in 4:
		_part(
			root,
			_cone(0.06, 0.16, 5),
			gold,
			Vector3(1.12, 0.62 + float(k) * 0.18, -0.62),
			Vector3(-60, 0, 0)
		)
	# Left fist.
	_strut(root, Vector3(-0.8, 1.78, 0), Vector3(-1.0, 1.26, -0.12), 0.1, dark)
	_part(root, _box(Vector3(0.3, 0.3, 0.32)), armor, Vector3(-1.0, 1.14, -0.14))
	# BACK seal — a bright glowing plate marking the scene's ×3 weak point (+Z).
	_part(root, _box(Vector3(0.4, 0.4, 0.06)), mask, Vector3(0, 1.85, 0.38))
	_part(root, _box(Vector3(0.5, 0.5, 0.04)), gold, Vector3(0, 1.85, 0.34))
	return root


## RECON drone — Specter: a slim hovering scout. Thin grey-violet chassis "Body", a 4-rotor
## ring under "RotorHub" (Rotor0..Rotor3 spin), one big cyan lens "Core", a tall antenna.
## Smaller than the wasp (~0.9 m span). Hovers; the flyer animator bobs Body + spins rotors.
static func build_robot_specter() -> Node3D:
	var root := Node3D.new()
	var glow_col := Color(0.4, 0.85, 1.0)  # cyan
	var body := ProcMaterials.weathered(
		Color(0.34, 0.3, 0.42), 0.6, 0.4, 0.6, 101, Vector3(0.7, 0.7, 0.7), false
	)
	var dark := _mat(Color(0.14, 0.13, 0.18), 0.5, 0.5)
	var rotor := _mat(Color(0.24, 0.22, 0.3), 0.4, 0.3)
	var lens := _mat(glow_col, 0.0, 0.3, glow_col, 6.0)

	# A body pivot wrapping the slim chassis + lens + antenna so the script bobs just the
	# body (named "Body") without moving the rotors' spin hub.
	var bodyp := Node3D.new()
	bodyp.name = "Body"
	root.add_child(bodyp)
	# Slim flattened chassis with a forward sensor lens.
	_part(bodyp, _box(Vector3(0.34, 0.12, 0.5)), body, Vector3(0, 0, 0))
	_part(bodyp, _sphere(0.13, true, 8, 12), dark, Vector3(0, 0.05, 0), Vector3.ZERO)
	var core := _part(bodyp, _sphere(0.1, false, 10, 14), lens, Vector3(0, 0.0, -0.26))
	core.name = "Core"
	# Tall sensor antenna with a glowing tip.
	_strut(bodyp, Vector3(0, 0.04, 0.14), Vector3(0, 0.34, 0.18), 0.012, dark)
	_part(bodyp, _sphere(0.03, false, 6, 8), lens, Vector3(0, 0.36, 0.18))
	# Four small rotor arms to the diagonals, each disc under its own pivot in "RotorHub".
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
		_strut(root, Vector3(tv.x * 0.4, 0.02, tv.z * 0.4), tv, 0.02, dark)
		var pivot := Node3D.new()
		pivot.name = "Rotor%d" % ri
		pivot.position = tv + Vector3(0, 0.015, 0)
		hub.add_child(pivot)
		_part(pivot, _cyl(0.11, 0.02, 12), rotor)
		_part(pivot, _box(Vector3(0.22, 0.028, 0.03)), dark, Vector3(0, 0.015, 0))
		_part(pivot, _box(Vector3(0.03, 0.028, 0.22)), dark, Vector3(0, 0.015, 0))
		_part(root, _sphere(0.04, false, 6, 8), dark, tv)
		ri += 1
	return root


# ================================================================= DEPLOYABLE GADGETS (v0.3)
# Friendly placed gadgets — same StandardMaterial3D discipline + authored facing -Z as the
# enemies. Each exposes a NAMED tracking part the gadget script rotates per frame on every
# peer: the turret's "Barrel" yaws+pitches toward its target, the sensor's "Head" spins.


## Auto-Turret: a boxy body on a wide tripod with a forward twin-barrel gun. The barrel
## assembly is a distinct Node3D child named "Barrel" (origin at the gun pivot ~y0.6,
## facing -Z) so gadget_turret.gd can rotate it toward the nearest enemy. Built around
## local y0 = ground (feet on the floor); the spawner places the root at the ground point.
static func build_gadget_turret() -> Node3D:
	var root := Node3D.new()
	var shell := ProcMaterials.weathered(
		Color(0.24, 0.42, 0.32), 0.5, 0.5, 0.5, 79, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.14, 0.18, 0.16), 0.5, 0.55)
	var steel := _mat(Color(0.3, 0.34, 0.32), 0.7, 0.35)
	var lamp := _mat(Color(0.4, 0.95, 0.6), 0.0, 0.3, Color(0.4, 0.95, 0.6), 5.0)

	# Wide tripod: 3 splayed legs down to footpads + a base disc (the deploy footprint).
	for i in 3:
		var ang := TAU * float(i) / 3.0 + 0.5
		var foot := Vector3(cos(ang) * 0.42, 0.0, sin(ang) * 0.42)
		_strut(root, Vector3(0, 0.34, 0), foot, 0.045, steel)
		_part(root, _cyl(0.07, 0.04, 8), dark, foot)
	_part(root, _cyl(0.26, 0.1, 14), dark, Vector3(0, 0.36, 0))
	# Rotating body block + a small status lamp on the back.
	_part(root, _box(Vector3(0.4, 0.3, 0.42)), shell, Vector3(0, 0.56, 0))
	_part(root, _box(Vector3(0.44, 0.08, 0.46)), steel, Vector3(0, 0.42, 0))
	_part(root, _sphere(0.05, false, 8, 10), lamp, Vector3(0, 0.66, 0.22))

	# Barrel assembly under its own named pivot at the gun height, facing -Z.
	var barrel := Node3D.new()
	barrel.name = "Barrel"
	barrel.position = Vector3(0, 0.6, 0)
	root.add_child(barrel)
	_part(barrel, _box(Vector3(0.22, 0.16, 0.22)), dark, Vector3(0, 0, -0.04))  # mantlet
	for sx in [-0.07, 0.07]:
		_part(
			barrel, _cyl(0.035, 0.5, 10), steel, Vector3(float(sx), 0.02, -0.34), Vector3(90, 0, 0)
		)
		_part(
			barrel, _cyl(0.05, 0.08, 10), dark, Vector3(float(sx), 0.02, -0.12), Vector3(90, 0, 0)
		)
	# A small forward muzzle eye so the gun reads as "aimed".
	var eye := _part(barrel, _sphere(0.04, false, 8, 10), lamp, Vector3(0, 0.08, -0.16))
	eye.name = "MuzzleGlow"
	return root


## Shield-Dome emitter: a low pod with a glowing top ring — the actual translucent dome
## hemisphere is built in gadget_dome.gd (it needs the runtime DOME_RADIUS). Built around
## local y0 = ground. Small + unobtrusive so it sits under the dome shell.
static func build_gadget_dome_emitter() -> Node3D:
	var root := Node3D.new()
	var shell := ProcMaterials.weathered(
		Color(0.22, 0.3, 0.42), 0.5, 0.5, 0.5, 83, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.13, 0.16, 0.2), 0.5, 0.55)
	var glow := _mat(Color(0.35, 0.7, 1.0), 0.0, 0.3, Color(0.35, 0.7, 1.0), 6.0)

	# Stubby base + body cylinder.
	_part(root, _cyl(0.22, 0.06, 14), dark, Vector3(0, 0.04, 0))
	_part(root, _cyl(0.16, 0.22, 14), shell, Vector3(0, 0.18, 0))
	# Three vent slats around the body.
	for i in 3:
		var ang := TAU * float(i) / 3.0
		_part(
			root,
			_box(Vector3(0.05, 0.12, 0.06)),
			dark,
			Vector3(cos(ang) * 0.16, 0.18, sin(ang) * 0.16),
			Vector3(0, rad_to_deg(-ang), 0)
		)
	# Glowing emitter ring + finial on top (the dome springs from here).
	_part(root, _cyl(0.13, 0.04, 16), glow, Vector3(0, 0.32, 0))
	_part(root, _sphere(0.06, false, 8, 12), glow, Vector3(0, 0.4, 0))
	return root


## Motion-Sensor: a tripod pole topped with a rotating sweep head (a distinct Node3D
## named "Head" that gadget_sensor.gd spins) — a flat dish + an amber sweep blade + a
## glowing core. Built around local y0 = ground.
static func build_gadget_sensor() -> Node3D:
	var root := Node3D.new()
	var shell := ProcMaterials.weathered(
		Color(0.4, 0.38, 0.22), 0.5, 0.5, 0.5, 89, Vector3(0.6, 0.6, 0.6), false
	)
	var dark := _mat(Color(0.16, 0.16, 0.13), 0.5, 0.55)
	var steel := _mat(Color(0.32, 0.32, 0.28), 0.7, 0.35)
	var amber := _mat(Color(0.98, 0.72, 0.25), 0.0, 0.3, Color(0.98, 0.72, 0.25), 6.0)

	# Tripod legs + a center pole up to the head.
	for i in 3:
		var ang := TAU * float(i) / 3.0 + 0.5
		var foot := Vector3(cos(ang) * 0.34, 0.0, sin(ang) * 0.34)
		_strut(root, Vector3(0, 0.3, 0), foot, 0.035, steel)
		_part(root, _cyl(0.055, 0.03, 8), dark, foot)
	_part(root, _cyl(0.05, 0.62, 10), dark, Vector3(0, 0.6, 0))

	# Rotating sweep head under a named pivot near the pole top.
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 0.94, 0)
	root.add_child(head)
	_part(head, _cyl(0.16, 0.05, 16), shell, Vector3.ZERO)  # dish base
	_part(head, _box(Vector3(0.05, 0.04, 0.3)), amber, Vector3(0, 0.05, -0.12))  # sweep blade
	var core := _part(head, _sphere(0.06, false, 8, 12), amber, Vector3(0, 0.08, 0))
	core.name = "Core"
	# A couple of fixed antenna whips off the pole for the "sensor" read.
	_part(root, _cyl(0.012, 0.24, 6), amber, Vector3(0.06, 0.78, 0.04), Vector3(0, 0, 24))
	_part(root, _cyl(0.012, 0.24, 6), amber, Vector3(-0.06, 0.78, 0.04), Vector3(0, 0, -24))
	return root
