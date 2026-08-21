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
]
# v0.3 biome fauna + minibosses + the recon drone — built in ProceduralModelsFauna
# (split out for the max-file-lines ceiling; this file only dispatches).
const FAUNA_BUILDERS := [
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
	"loot_data_chip",
	# v0.4.1 audit — ids that previously fell back to a bare tinted cube + blank icon.
	"loot_grenade_emp",
	"loot_grenade_smoke",
	"loot_grenade_decoy",
	"loot_grenade_incendiary",
	"loot_grenade_cryo",
	"loot_power_core",
	"loot_nemesis_core",
	"loot_self_revive",
	"loot_knockdown_shield",
	"power_cache",
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
	if id in FAUNA_BUILDERS:
		return true
	if id in ProceduralModelsTroopers.IDS:
		return true
	return id.begins_with("schematic_")


## Returns a fresh Node3D assembly for `id`, or null if there is no builder.
static func build(id: String) -> Node3D:
	if id in GEAR_BUILDERS:
		return ProceduralModelsGear.build(id)
	if id in FAUNA_BUILDERS:
		return ProceduralModelsFauna.build(id)
	# v0.5-B4: the three starter bots (the last .glb enemies) — split file, fauna pattern.
	if id in ProceduralModelsTroopers.IDS:
		return ProceduralModelsTroopers.build(id)
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
		"loot_grenade_emp":
			return build_utility_grenade(Color(0.3, 0.7, 1.0), "emp")
		"loot_grenade_smoke":
			return build_utility_grenade(Color(0.55, 0.6, 0.55), "smoke")
		"loot_grenade_decoy":
			return build_utility_grenade(Color(0.9, 0.75, 0.2), "decoy")
		"loot_grenade_incendiary":
			return build_utility_grenade(Color(1.0, 0.45, 0.1), "incendiary")
		"loot_grenade_cryo":
			return build_utility_grenade(Color(0.6, 0.85, 1.0), "cryo")
		"loot_power_core":
			return build_energy_core(Color(1.0, 0.62, 0.18), false)
		"loot_nemesis_core":
			return build_energy_core(Color(0.95, 0.15, 0.12), true)
		"loot_self_revive":
			return build_self_revive()
		"loot_knockdown_shield":
			return build_knockdown_shield()
		"power_cache":
			return build_power_cache()
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


## A ring lying in the XZ plane (axis +Y) — the one primitive that gives a body a real
## HOLE. At 100 m a machine is 15-31 px: an outline plus a light blob is all that lands,
## and a cluster of rings is the only shape a ground unit can never fake, which is why the
## hover drones are built out of ducts rather than out of more boxes.
static func _torus(inner: float, outer: float, rings := 14, seg := 6) -> TorusMesh:
	var m := TorusMesh.new()
	m.inner_radius = inner
	m.outer_radius = outer
	m.rings = rings
	m.ring_segments = seg
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


# ----------------------------------------------------------------- nemesis scars
## Signature parts a scar must NEVER touch (hiding the eye/core/head reads as broken, not
## battle-worn; legs animate). Any MeshInstance3D whose name starts with one of these is
## protected — scars land on the anonymous plating parts (`_part` leaves them auto-named).
const _SCAR_PROTECTED := [
	"Eye", "Core", "Head", "Body", "Torso", "ChestCore", "WeakDome", "TurretHead", "Leg"
]


## Pick `count` distinct, deterministically-seeded plating MeshInstance3D under `root` (a
## procedural enemy assembly) for the Machine Nemesis scar deltas (caller hides / bends /
## chars them). Deterministic in `seed` so every co-op peer scars the SAME parts (the seed
## rides the node name). Returns [] for .glb / single-primitive bodies (no enumerable parts).
static func scar_parts(root: Node3D, seed: int, count: int) -> Array:
	var parts: Array = []
	_collect_scar_candidates(root, parts)
	if parts.is_empty():
		return []
	var picked: Array = []
	var used := {}
	var n := parts.size()
	var s := absi(seed)
	for _i in mini(count, n):
		s = (s * 1103515245 + 12345) & 0x7fffffff  # LCG — deterministic, no Math.random
		var idx := s % n
		var tries := 0
		while used.has(idx) and tries < n:
			idx = (idx + 1) % n
			tries += 1
		used[idx] = true
		picked.append(parts[idx])
	return picked


static func _collect_scar_candidates(node: Node, out: Array) -> void:
	if node is MeshInstance3D:
		var nm := str(node.name)
		var protected := false
		for p in _SCAR_PROTECTED:
			if nm.begins_with(p):
				protected = true
				break
		if not protected:
			out.append(node)
	for c in node.get_children():
		_collect_scar_candidates(c, out)


## The full Machine Nemesis scar look, shared by the in-world enemy AND the Hub codex
## portrait: a charred wash on the body's StandardMaterial3D, a blood-red under-foot glow
## ring, and deterministic blown-off/bent plating (scar count scales with tier). `model_root`
## carries the tint + ring; `proc_root` (the assembly) carries the part-scars — for the enemy
## they differ (ModelRoot vs its child); for the codex pass the same built model for both.
## Deterministic in `scar_seed`. Render-only; caller guards headless.
static func apply_nemesis_scars(
	model_root: Node3D, proc_root: Node3D, scar_seed: int, tier: int
) -> void:
	if model_root == null:
		return
	var mats: Array[StandardMaterial3D] = []
	_collect_std_materials(model_root, mats)
	EnemyModifiers.tint_materials(mats, Color(0.16, 0.14, 0.13), 0.42)
	EnemyModifiers.build_glow_ring(model_root, Color(0.92, 0.10, 0.10))
	if proc_root == null:
		return  # .glb / single-primitive body: the charred tint + ring is the whole scar
	var parts: Array = scar_parts(proc_root, scar_seed, mini(tier + 1, 4))
	var s := absi(scar_seed)
	for part in parts:
		if not (part is Node3D):
			continue
		s = (s * 1103515245 + 12345) & 0x7fffffff
		if s % 2 == 0:
			(part as Node3D).visible = false  # blown-off plate
		else:
			(part as Node3D).position += Vector3(0.04, -0.03, 0.0)  # bent / dented
			(part as Node3D).rotation_degrees += Vector3(8.0, 0.0, 6.0)


## Collect the active StandardMaterial3D off every MeshInstance3D under `node` (recursive).
static func _collect_std_materials(node: Node, out: Array[StandardMaterial3D]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh != null:
			for si in mesh.get_surface_count():
				var mat := mi.get_active_material(si)
				if mat is StandardMaterial3D and not out.has(mat):
					out.append(mat)
	for c in node.get_children():
		_collect_std_materials(c, out)


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
## Tick — the ground-hugging SKITTERER, and the family rule is that it must not read as a
## robot at all: a flat two-lobe carapace pinned LOW over a splayed six-leg cluster whose
## knees arc ABOVE the shell line. The abris is a dark smear with a spiky fringe — nothing
## vertical, nothing humanoid, so it separates from every other machine by outline alone.
## Collision: capsule r0.3 h0.7 @ world y0.35; ModelRoot @ y0.35, so local y0 = world 0.35,
## feet at local y≈-0.35. The shell footprint is TIGHTER than the old one (x ±0.33, z ±0.42)
## — the body must never grow past the capsule it is shot through.
static func build_robot_tick() -> Node3D:
	var root := Node3D.new()
	# Material kit: light plate over black frame; identity orange as restrained accent
	# paint; legs read as bare worn steel.
	var k := ProcEnemyKits.kit("robot_tick")
	var hull: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var acc: StandardMaterial3D = k["accent"]
	var glow: StandardMaterial3D = k["glow"]
	var steel: StandardMaterial3D = k["steel"]

	# Dark underbelly + the two-lobe beetle body: thorax dome, then a longer tapered
	# abdomen. Two lobes (not one dome) is what reads as chitin instead of a casing.
	_part(root, _box(Vector3(0.38, 0.09, 0.46)), dark, Vector3(0, -0.19, 0.02))
	var wide := Vector3(1.24, 0.46, 1.2)
	_part(root, _sphere(0.26, false, 8, 14), hull, Vector3(0, -0.09, -0.08), Vector3.ZERO, wide)
	var tail := Vector3(1.04, 0.44, 1.25)
	_part(root, _sphere(0.22, false, 8, 12), hull, Vector3(0, -0.1, 0.16), Vector3.ZERO, tail)
	# Segment ridges across the abdomen — pointwise density, the one busy zone.
	for i in 3:
		var rz := 0.06 + float(i) * 0.1
		_part(root, _box(Vector3(0.28 - float(i) * 0.05, 0.03, 0.02)), dark, Vector3(0, -0.03, rz))
	# Identity paint on the flanks only (the 10% channel).
	_part(root, _box(Vector3(0.04, 0.035, 0.28)), acc, Vector3(0.23, -0.09, -0.04))
	_part(root, _box(Vector3(0.04, 0.035, 0.28)), acc, Vector3(-0.23, -0.09, -0.04))
	# Head wedge with a horizontal sensor SLIT (a bar, not a bulb — the ARC sensor
	# language) + two mandible prongs.
	_part(root, _box(Vector3(0.18, 0.1, 0.12)), dark, Vector3(0, -0.12, -0.36))
	var eye := _part(root, _box(Vector3(0.14, 0.035, 0.02)), glow, Vector3(0, -0.11, -0.42))
	eye.name = "Eye"
	_part(root, _cone(0.035, 0.16), dark, Vector3(0.1, -0.18, -0.43), Vector3(-105, 0, 12))
	_part(root, _cone(0.035, 0.16), dark, Vector3(-0.1, -0.18, -0.43), Vector3(-105, 0, -12))

	# Six legs under their own "Leg0".."Leg5" pivots (robot_enemy micro-sways the pivot):
	# attach LOW on the flank, knee high and wide, foot planted on the ground. The arc of
	# knees above the shell is the whole insect read, so the knees clear the carapace top.
	var zs := [-0.2, 0.02, 0.24]
	var li := 0
	for side in [-1.0, 1.0]:
		for z in zs:
			var sf := float(side)
			var zf := float(z)
			var attach := Vector3(sf * 0.16, -0.1, zf)
			var knee := Vector3(sf * 0.34, 0.11, zf + sf * 0.04)
			var foot := Vector3(sf * 0.47, -0.35, zf + sf * 0.06)
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % li
			pivot.position = attach
			root.add_child(pivot)
			# Build the leg in pivot-local space (subtract the attach point).
			_strut(pivot, Vector3.ZERO, knee - attach, 0.045, steel)
			_strut(pivot, knee - attach, foot - attach, 0.032, steel)
			_part(pivot, _sphere(0.042, false, 6, 8), dark, foot - attach)
			li += 1
	return root


## Wasp — the HOVER DRONE family, and the family rule is NEGATIVE SPACE: four ducted fan
## RINGS on short stalks around a small pod, so what the eye locks onto is the pattern of
## holes between them — a shape no ground machine can fake, and the reason a drone stays
## legible against bright sky at any range. Rear thrust nozzles are the kill window: from
## behind they are two bright circles. Collision sphere r0.4, ModelRoot @ y0 (it hovers),
## so build symmetric about local y0; ring tips reach 0.42, inside the old 0.5 rotor span.
static func build_robot_wasp() -> Node3D:
	var root := Node3D.new()
	var k := ProcEnemyKits.kit("robot_wasp")
	var hull: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var acc: StandardMaterial3D = k["accent"]
	var glow: StandardMaterial3D = k["glow"]

	# A body pivot wrapping the pod so the script can bob just the body (named "Body")
	# without moving the rotors' spin hub.
	var bodyp := Node3D.new()
	bodyp.name = "Body"
	root.add_child(bodyp)
	# Small flattened pod — deliberately UNDER-sized against the ducts, so the rings own
	# the outline and the body is only the bright blob at the centre of them.
	var pod := Vector3(1.0, 0.78, 1.3)
	_part(bodyp, _sphere(0.17, false, 9, 14), hull, Vector3.ZERO, Vector3.ZERO, pod)
	_part(bodyp, _box(Vector3(0.1, 0.07, 0.44)), dark, Vector3(0, 0.02, 0.02))
	# Forward sensor: one lens recessed in a dark cowl (the pulsed "Core").
	_part(bodyp, _cyl(0.1, 0.05, 12), dark, Vector3(0, 0, -0.19), Vector3(90, 0, 0))
	var core := _part(bodyp, _cyl(0.075, 0.03, 12), glow, Vector3(0, 0, -0.22), Vector3(90, 0, 0))
	core.name = "Core"
	# Rear thrust nozzles — the KILL WINDOW, shrouded so they only light up from behind.
	for sx in [-0.085, 0.085]:
		var nx := float(sx)
		_part(bodyp, _cyl(0.062, 0.09, 10), dark, Vector3(nx, 0, 0.19), Vector3(90, 0, 0))
		_part(bodyp, _cyl(0.045, 0.02, 10), glow, Vector3(nx, 0, 0.235), Vector3(90, 0, 0))
	# Short chin gun (its ranged strike), angled down-forward.
	_part(bodyp, _cone(0.045, 0.2), steel, Vector3(0, -0.075, -0.16), Vector3(-110, 0, 0))

	# Four ducted fans on short stalks. The RING is the silhouette (a real hole through
	# it) and the blades are two thin bars, so the duct stays see-through while it spins.
	# Each fan sits under its OWN pivot centred on the duct (a Y rotation spins the blades
	# in place, not around the body); the pivots are grouped under "RotorHub" so the flyer
	# script finds and spins them in one cheap loop.
	var hub := Node3D.new()
	hub.name = "RotorHub"
	root.add_child(hub)
	var arms := [
		Vector3(0.27, 0.05, -0.27),
		Vector3(-0.27, 0.05, -0.27),
		Vector3(0.27, 0.05, 0.27),
		Vector3(-0.27, 0.05, 0.27)
	]
	var ri := 0
	for tip in arms:
		var tv: Vector3 = tip
		_strut(root, Vector3(tv.x * 0.35, 0.02, tv.z * 0.35), tv, 0.028, dark)
		_part(root, _torus(0.1, 0.15), hull, tv)
		if tv.z < 0.0:  # identity paint on the forward pair only
			_part(root, _box(Vector3(0.09, 0.025, 0.05)), acc, tv + Vector3(0, 0.03, -0.115))
		var pivot := Node3D.new()
		pivot.name = "Rotor%d" % ri
		pivot.position = tv
		hub.add_child(pivot)
		_part(pivot, _cyl(0.032, 0.05, 8), steel)
		_part(pivot, _box(Vector3(0.19, 0.012, 0.03)), steel)
		_part(pivot, _box(Vector3(0.03, 0.012, 0.19)), steel)
		ri += 1
	return root


## Bastion — the SIEGE WALKER family: mass parked high on four splayed JACK legs, so the
## signature is the gap between the ground and its belly plus a narrow waist under a big
## CALM turret. It was a box on a box (i.e. a bigger version of everything else); now the
## outline is unmistakable at any range and from any angle, and the jacks say "deployed,
## not walking". Collision box 1.8×2.4 @ world y1.2; ModelRoot @ y1.3; WeakPoint hurtbox
## 1.0×0.7 @ world y2.6 → feet at local y≈-1.3, weak-point dome centred at local y≈+1.2.
static func build_robot_bastion() -> Node3D:
	var root := Node3D.new()
	# Material kit: plated armour — the panel-seam bake does the heavy lifting on these
	# big calm plates. WeakDome keeps its AMBER signage glow (gameplay contract).
	var k := ProcEnemyKits.kit("robot_bastion")
	var hull: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var acc: StandardMaterial3D = k["accent"]
	var weak := ProcPlating.glow(Color(1.0, 0.55, 0.15), 3.5)

	# Four jack legs down to planted footpads + a NARROW waist — STATIC (the base does
	# not track). The open belly under the turret is the whole silhouette idea.
	for i in 4:
		var ang := TAU * float(i) / 4.0 + PI * 0.25
		var dx := cos(ang)
		var dz := sin(ang)
		_strut(
			root,
			Vector3(dx * 0.24, -0.4, dz * 0.24),
			Vector3(dx * 0.76, -1.08, dz * 0.76),
			0.09,
			steel
		)
		_part(root, _cyl(0.1, 0.36, 8), hull, Vector3(dx * 0.78, -1.06, dz * 0.78))
		_part(root, _cyl(0.17, 0.1, 10), dark, Vector3(dx * 0.8, -1.25, dz * 0.8))
	_part(root, _cyl(0.3, 0.66, 10), dark, Vector3(0, -0.62, 0))
	_part(root, _cyl(0.46, 0.16, 12), hull, Vector3(0, -0.26, 0))

	# The whole upper turret rotates on Y to face the player: hull + barrels + weak point
	# + drums all live under "TurretHead" (pivoted on the waist column so it spins about
	# the centre). The gunner script yaws this node toward the nearest player.
	var head := Node3D.new()
	head.name = "TurretHead"
	root.add_child(head)
	# Big calm turret hull: one main mass, one stepped deck, one dark under-plate.
	_part(head, _box(Vector3(1.35, 0.66, 1.15)), hull, Vector3(0, 0.12, 0))
	_part(head, _box(Vector3(1.42, 0.16, 1.2)), dark, Vector3(0, -0.24, 0))
	_part(head, _box(Vector3(1.02, 0.28, 0.92)), hull, Vector3(0, 0.54, 0))
	_part(head, _box(Vector3(1.38, 0.06, 1.18)), acc, Vector3(0, 0.44, 0))
	_part(head, _box(Vector3(0.68, 0.42, 0.28)), dark, Vector3(0, 0.06, -0.62))
	# Twin forward cannon barrels (face -Z), named so the script can find the gun.
	var bi := 0
	for sx in [-0.24, 0.24]:
		var bx := float(sx)
		var barrel := _part(
			head, _cyl(0.11, 0.9, 12), steel, Vector3(bx, 0.06, -1.0), Vector3(90, 0, 0)
		)
		barrel.name = "Barrel%d" % bi
		_part(head, _cyl(0.14, 0.18, 12), acc, Vector3(bx, 0.06, -0.7), Vector3(90, 0, 0))
		bi += 1
	# Side ammo drums — mass where the shoulders used to be, but read as hardware.
	for sx2 in [-0.62, 0.62]:
		_part(head, _cyl(0.22, 0.5, 10), dark, Vector3(float(sx2), 0.1, 0.16), Vector3(0, 0, 90))
	# Glowing weak point dome on top — deliberately parked INSIDE the WeakPoint hurtbox
	# (world y2.6 ±0.35 = local 0.95..1.65), so the bright thing IS the ×2.5 shot.
	_part(head, _cyl(0.4, 0.24, 10), dark, Vector3(0, 0.86, 0))
	var tall := Vector3(1.0, 1.2, 1.0)
	var dome := _part(
		head, _sphere(0.36, true, 10, 16), weak, Vector3(0, 1.0, 0), Vector3.ZERO, tall
	)
	dome.name = "WeakDome"
	return root


## Boss — the multi-leg TITAN family: a body-POD slung high between two enlarged
## three-segment legs, so a player standing at its feet reads INSIDE the silhouette
## (the arch under the belly is ~2 m of open air). It stops being "the big humanoid mech"
## the moment the arms come off: the guns are hull-mounted side pods and the head is a
## visor bar sunk into the pod, leaving big calm surfaces to carry the mass.
## Collision box 3.0×4.2 @ world y2.1; ModelRoot @ y2.2 → feet at local y≈-2.2, pod
## centred near local y0.6, dorsal top ≈+1.6 (boss_brain scales the model ×1.3 on top and
## hangs its crown at ModelRoot-local 3.4, so the top must stay well under that).
static func build_robot_boss() -> Node3D:
	var root := Node3D.new()
	# Material kit: plated armour; cannons are bare steel; the eyes keep their bespoke
	# pink (vs the identity chest core) at restrained energy.
	var k := ProcEnemyKits.kit("robot_boss")
	var hull: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var acc: StandardMaterial3D = k["accent"]
	var core_mat: StandardMaterial3D = k["glow"]
	var eye_mat := ProcPlating.glow(Color(1.0, 0.2, 0.4), 3.0)

	# Two enlarged digitigrade legs — thigh kicks BACK to a high knee, shin drives FORWARD
	# to a low ankle, foot plants wide. STATIC base (only the pod turns).
	for sx in [-1.0, 1.0]:
		var fx := float(sx)
		var hip := Vector3(fx * 0.5, -0.62, 0)
		var knee := Vector3(fx * 0.84, -1.14, 0.4)
		var ankle := Vector3(fx * 1.0, -1.76, -0.16)
		var foot := Vector3(fx * 1.02, -2.06, -0.04)
		_strut(root, hip, knee, 0.3, hull)
		_strut(root, knee, ankle, 0.23, hull)
		_strut(root, ankle, foot, 0.16, steel)
		_part(root, _sphere(0.3, false, 8, 10), dark, knee)
		_part(root, _sphere(0.19, false, 8, 10), dark, ankle)
		_part(root, _box(Vector3(0.6, 0.28, 0.98)), dark, foot)
		_part(root, _box(Vector3(0.5, 0.12, 0.26)), steel, foot + Vector3(0, -0.06, -0.56))
		_part(root, _box(Vector3(0.34, 0.4, 0.16)), acc, Vector3(fx * 0.96, -1.2, 0.28))
	# Hip yoke slung between the legs — STATIC.
	_part(root, _box(Vector3(1.44, 0.4, 0.86)), dark, Vector3(0, -0.62, 0))
	_part(root, _box(Vector3(1.2, 0.26, 0.72)), hull, Vector3(0, -0.4, 0))

	# The POD (body + core + guns + sensor) rotates on Y to face the player. Pivoted at
	# the hips ("Torso") so the whole upper mass swings toward the target.
	var torso := Node3D.new()
	torso.name = "Torso"
	torso.position = Vector3(0, -0.2, 0)
	root.add_child(torso)
	# Pod shell (torso-local: subtract the pivot y-offset). Two big quiet plates.
	_part(torso, _box(Vector3(1.86, 1.02, 1.32)), hull, Vector3(0, 0.85, 0))
	_part(torso, _box(Vector3(1.46, 0.36, 1.04)), dark, Vector3(0, 0.28, 0.02))
	_part(torso, _box(Vector3(0.98, 0.42, 0.78)), hull, Vector3(0, 1.55, 0.24))
	for i in 3:
		_part(torso, _box(Vector3(0.86, 0.14, 0.09)), dark, Vector3(0, 1.8, 0.06 + float(i) * 0.16))
	_part(torso, _box(Vector3(0.5, 0.06, 0.03)), acc, Vector3(0, 0.36, -0.68))
	# Glowing chest core in a dark iris — the kill window, dead centre of the pod face.
	_part(torso, _cyl(0.46, 0.16, 10), dark, Vector3(0, 0.85, -0.62), Vector3(90, 0, 0))
	var core := _part(torso, _sphere(0.34, false, 12, 16), core_mat, Vector3(0, 0.85, -0.6))
	core.name = "ChestCore"
	# Hull-mounted gun pods (NOT arms) — the anti-humanoid move.
	for sx3 in [-1.0, 1.0]:
		var ax := float(sx3)
		_part(torso, _box(Vector3(0.5, 0.6, 1.0)), hull, Vector3(ax * 1.0, 0.96, 0.06))
		_part(torso, _box(Vector3(0.54, 0.14, 1.04)), dark, Vector3(ax * 1.0, 0.62, 0.06))
		_part(torso, _cyl(0.17, 1.15, 12), steel, Vector3(ax * 1.0, 0.74, -0.72), Vector3(90, 0, 0))
		_part(torso, _cyl(0.21, 0.22, 12), acc, Vector3(ax * 1.0, 0.74, -1.2), Vector3(90, 0, 0))
	# Sensor visor sunk into the pod brow: a wide dark housing + one emissive bar.
	var head := _part(torso, _box(Vector3(0.86, 0.3, 0.5)), dark, Vector3(0, 1.4, -0.44))
	head.name = "Head"
	var eyes := _part(torso, _box(Vector3(0.62, 0.09, 0.04)), eye_mat, Vector3(0, 1.4, -0.68))
	eyes.name = "Eyes"
	return root


## Caller / "Snitch" — the MAST family. Its job is to be shot FIRST, so the outline has to
## announce the job: a tiny canister body on a spindly tripod carrying a wide RADAR DISH on
## a thin neck. The width of the dish does the reading (a T/mushroom no fighter has), not
## extra height — the mast mass stays INSIDE the capsule so the thing you aim at is the
## thing that takes the bullet. Collision capsule r0.4 h1.5 @ world y0.75; ModelRoot @
## y0.75 → local y0 = world 0.75, feet at local y≈-0.72, dish rim ≈+0.7. The script pulses
## "Eye" (and the beacon keeps the "Core" name) and sways "Leg0".."Leg2".
static func build_robot_caller() -> Node3D:
	var root := Node3D.new()
	# Material kit: pale hull canister; beacon + eye share the identity alarm glow
	# (one kit instance — within-model sharing is fine for the hit-flash).
	var k := ProcEnemyKits.kit("robot_caller")
	var hull: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var acc: StandardMaterial3D = k["accent"]
	var glow: StandardMaterial3D = k["glow"]

	# Small canister body low on the legs + a dark collar — deliberately UNDER-built so
	# the dish above it owns the silhouette and the machine reads as fragile.
	_part(root, _cyl(0.15, 0.28, 12), hull, Vector3(0, -0.06, 0))
	_part(root, _cyl(0.17, 0.05, 12), dark, Vector3(0, 0.09, 0))
	_part(root, _box(Vector3(0.06, 0.14, 0.02)), acc, Vector3(0, -0.1, -0.15))
	# Forward sensor slit.
	var eye := _part(root, _box(Vector3(0.11, 0.03, 0.02)), glow, Vector3(0, 0.0, -0.155))
	eye.name = "Eye"

	# Thin neck → wide tilted DISH (rim ring + shallow bowl) → the alarm beacon at its
	# focus. The rim ring is what survives distance: a circle on a stick.
	_part(root, _cyl(0.025, 0.34, 8), dark, Vector3(0, 0.28, 0))
	var bowl := Vector3(1.0, 0.45, 1.0)
	_part(root, _sphere(0.27, true, 6, 14), hull, Vector3(0, 0.42, 0.05), Vector3(110, 0, 0), bowl)
	_part(root, _torus(0.25, 0.29), acc, Vector3(0, 0.42, 0.05), Vector3(110, 0, 0))
	_part(root, _cyl(0.014, 0.18, 6), steel, Vector3(0, 0.47, -0.03), Vector3(110, 0, 0))
	var beacon := _part(root, _sphere(0.055, false, 8, 10), glow, Vector3(0, 0.51, -0.11))
	beacon.name = "Core"  # pulsed by the script
	# Whip antennae off the collar — steel with a lit bead, so the glow budget stays on
	# the beacon (one signal, not a christmas tree).
	for sx in [-1.0, 1.0]:
		var wx := float(sx)
		_part(
			root, _cyl(0.01, 0.3, 6), steel, Vector3(wx * 0.13, 0.2, 0.06), Vector3(0, 0, wx * -30)
		)
		_part(root, _sphere(0.022, false, 6, 8), glow, Vector3(wx * 0.2, 0.33, 0.06))

	# Spindly tripod legs (one front, two rear) — stands but looks fragile/low-HP.
	var feet := [Vector3(0.0, 0.0, -0.3), Vector3(0.28, 0.0, 0.22), Vector3(-0.28, 0.0, 0.22)]
	var li := 0
	for f in feet:
		var fv: Vector3 = f
		var attach := Vector3(fv.x * 0.35, -0.16, fv.z * 0.35)
		var knee := Vector3(fv.x * 0.85, -0.4, fv.z * 0.85)
		var foot := Vector3(fv.x, -0.72, fv.z)
		var pivot := Node3D.new()
		pivot.name = "Leg%d" % li
		pivot.position = attach
		root.add_child(pivot)
		_strut(pivot, Vector3.ZERO, knee - attach, 0.028, steel)
		_strut(pivot, knee - attach, foot - attach, 0.022, steel)
		_part(pivot, _sphere(0.035, false, 6, 8), dark, foot - attach)
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
	var band := _mat(col, 0.0, 0.3, col, 2.1)
	_part(root, _cyl(0.13, 0.34, 14), shell, Vector3(0, 0.2, 0))
	_part(root, _cyl(0.14, 0.07, 14), band, Vector3(0, 0.22, 0))
	_part(root, _cyl(0.135, 0.04, 14), cap, Vector3(0, 0.37, 0))
	_part(root, _box(Vector3(0.06, 0.05, 0.06)), cap, Vector3(0, 0.4, 0))
	return root


## Chemicals — canister with glowing liquid inside.
static func build_canister(col: Color) -> Node3D:
	var root := Node3D.new()
	var glass := _mat(Color(0.3, 0.34, 0.36), 0.1, 0.2)
	var liquid := _mat(col, 0.0, 0.2, col, 2.0)
	var cap := _mat(Color(0.15, 0.16, 0.18), 0.4, 0.5)
	_part(root, _cyl(0.12, 0.2, 14), liquid, Vector3(0, 0.16, 0))
	_part(root, _cyl(0.14, 0.34, 14), glass, Vector3(0, 0.2, 0))
	_part(root, _cyl(0.1, 0.08, 14), cap, Vector3(0, 0.39, 0))
	return root


## Combat stim — a syringe with glowing fluid.
static func build_stim() -> Node3D:
	var root := Node3D.new()
	var barrel := _mat(Color(0.7, 0.78, 0.82), 0.1, 0.2)
	var fluid := _mat(Color(0.3, 0.95, 0.6), 0.0, 0.2, Color(0.3, 0.95, 0.6), 2.0)
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
	var led := _mat(Color(0.9, 0.85, 0.3), 0.0, 0.3, Color(0.9, 0.8, 0.2), 2.0)
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
	var core := _mat(Color(0.8, 0.4, 0.95), 0.0, 0.2, Color(0.7, 0.3, 0.95), 2.2)
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
			_mat(Color(0.4, 1.0, 0.5), 0, 0.3, Color(0.3, 1.0, 0.4), 2.0),
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


## Utility grenade (EMP/smoke/decoy/incendiary/cryo) — a tactical CANISTER (distinct from the
## frag sphere) with a top cap, a glowing accent band + per-type flourish; tinted per type.
static func build_utility_grenade(col: Color, kind: String) -> Node3D:
	var root := Node3D.new()
	var body := _mat(col.darkened(0.35), 0.4, 0.4)
	var metal := _mat(Color(0.45, 0.47, 0.5), 0.6, 0.3)
	var glow := _mat(col, 0.0, 0.3, col, 2.4)
	_part(root, _cyl(0.11, 0.3, 14), body, Vector3(0, 0.18, 0))  # canister body
	_part(root, _cyl(0.115, 0.05, 14), glow, Vector3(0, 0.2, 0))  # accent band
	_part(root, _cyl(0.09, 0.05, 14), metal, Vector3(0, 0.35, 0))  # top cap
	_part(root, _box(Vector3(0.03, 0.16, 0.05)), metal, Vector3(0.07, 0.28, 0), Vector3(0, 0, 16))
	_part(root, _cyl(0.03, 0.018, 10), metal, Vector3(0.1, 0.36, 0.0), Vector3(90, 0, 0))  # pin ring
	match kind:
		"decoy":
			_part(root, _cyl(0.01, 0.16, 6), metal, Vector3(0, 0.46, 0))  # antenna whip
			_part(root, _sphere(0.025), glow, Vector3(0, 0.55, 0))  # blink beacon
		"smoke":
			for i in range(3):
				var a := i * TAU / 3.0
				_part(
					root, _cyl(0.018, 0.05, 6), metal, Vector3(cos(a) * 0.05, 0.38, sin(a) * 0.05)
				)
		"cryo":
			for i in range(4):
				var a2 := i * TAU / 4.0
				var fp := Vector3(cos(a2) * 0.06, 0.4, sin(a2) * 0.06)
				_part(
					root, _box(Vector3(0.03, 0.08, 0.03)), glow, fp, Vector3(20, rad_to_deg(a2), 20)
				)
		"incendiary":
			_part(root, _cyl(0.12, 0.03, 14), glow, Vector3(0, 0.1, 0))  # lower burn band
		_:  # emp
			_part(root, _cyl(0.13, 0.02, 14), glow, Vector3(0, 0.3, 0))  # electronic discharge ring
	return root


## A contained energy core — a faceted glowing sphere in crossed containment struts + a ring.
## `scarred` = the Nemesis trophy variant: charred frame, blood-red core, blown-off plate shards.
static func build_energy_core(col: Color, scarred: bool) -> Node3D:
	var root := Node3D.new()
	var frame_col := Color(0.18, 0.16, 0.16) if scarred else Color(0.3, 0.32, 0.36)
	var frame := _mat(frame_col, 0.6, 0.4)
	var core := _mat(col, 0.0, 0.2, col, 2.6)
	_part(root, _sphere(0.15, false, 5, 8), core, Vector3(0, 0.26, 0))  # faceted core
	_part(root, _box(Vector3(0.04, 0.04, 0.4)), frame, Vector3(0, 0.26, 0))
	_part(root, _box(Vector3(0.4, 0.04, 0.04)), frame, Vector3(0, 0.26, 0))
	_part(root, _box(Vector3(0.04, 0.4, 0.04)), frame, Vector3(0, 0.26, 0))
	_part(root, _cyl(0.19, 0.03, 6), frame, Vector3(0, 0.26, 0), Vector3(90, 0, 0))  # containment ring
	if scarred:
		_part(
			root,
			_box(Vector3(0.08, 0.02, 0.06)),
			frame,
			Vector3(0.16, 0.34, 0.05),
			Vector3(30, 10, 40)
		)
		_part(
			root,
			_box(Vector3(0.06, 0.02, 0.07)),
			frame,
			Vector3(-0.14, 0.2, -0.06),
			Vector3(-20, 25, 15)
		)
	return root


## Self-revive auto-injector — a stim-pen (red): barrel, thumb collar, needle, red cross indicator.
static func build_self_revive() -> Node3D:
	var root := Node3D.new()
	var barrel := _mat(Color(0.85, 0.86, 0.88), 0.1, 0.3)
	var grip := _mat(Color(0.2, 0.21, 0.23), 0.3, 0.5)
	var red := _mat(Color(0.9, 0.15, 0.15), 0.0, 0.3, Color(0.9, 0.1, 0.1), 2.2)
	var metal := _mat(Color(0.5, 0.53, 0.56), 0.6, 0.3)
	_part(root, _cyl(0.06, 0.3, 12), barrel, Vector3(0, 0.2, 0))  # barrel
	_part(root, _cyl(0.07, 0.06, 12), grip, Vector3(0, 0.12, 0))  # thumb collar
	_part(root, _box(Vector3(0.03, 0.16, 0.02)), red, Vector3(0.06, 0.22, 0))  # indicator strip
	_part(root, _box(Vector3(0.06, 0.05, 0.05)), red, Vector3(0, 0.36, 0))  # red cross
	_part(root, _box(Vector3(0.14, 0.02, 0.02)), red, Vector3(0, 0.36, 0))
	_part(root, _cyl(0.012, 0.1, 8), metal, Vector3(0, 0.03, 0))  # needle
	return root


## Knockdown shield — a folded ballistic shield panel (blue): curved plate, energy edge, ribs, grip.
static func build_knockdown_shield() -> Node3D:
	var root := Node3D.new()
	var plate := _mat(Color(0.2, 0.34, 0.5), 0.3, 0.4)
	var rib := _mat(Color(0.28, 0.45, 0.62), 0.4, 0.4)
	var edge := _mat(Color(0.35, 0.6, 0.9), 0.0, 0.3, Color(0.3, 0.55, 0.9), 1.8)
	var grip := _mat(Color(0.15, 0.16, 0.18), 0.3, 0.5)
	_part(root, _box(Vector3(0.34, 0.46, 0.04)), plate, Vector3(0, 0.26, 0))  # main plate
	_part(root, _box(Vector3(0.36, 0.04, 0.05)), edge, Vector3(0, 0.48, 0))  # top energy edge
	for i in range(3):
		_part(root, _box(Vector3(0.03, 0.42, 0.05)), rib, Vector3(-0.1 + i * 0.1, 0.26, 0.03))
	_part(root, _cyl(0.02, 0.16, 8), grip, Vector3(0, 0.26, -0.06), Vector3(90, 0, 0))  # back grip
	return root


## Power cache — a cracked-open loot chest (weathered steel) with a glowing gold interior.
static func build_power_cache() -> Node3D:
	var root := Node3D.new()
	var steel := _mat(Color(0.34, 0.36, 0.4), 0.6, 0.45)
	var gold := _mat(Color(0.98, 0.8, 0.3), 0.0, 0.3, Color(0.98, 0.78, 0.25), 2.4)
	var stud := _mat(Color(0.5, 0.52, 0.55), 0.7, 0.3)
	_part(root, _box(Vector3(0.7, 0.42, 0.5)), steel, Vector3(0, 0.21, 0))  # base crate
	_part(root, _box(Vector3(0.62, 0.2, 0.42)), gold, Vector3(0, 0.36, 0))  # glowing interior
	_part(root, _box(Vector3(0.72, 0.12, 0.52)), steel, Vector3(0, 0.5, -0.18), Vector3(-28, 0, 0))
	for sx in [-0.32, 0.32]:
		for sz in [-0.23, 0.23]:
			_part(root, _box(Vector3(0.06, 0.42, 0.06)), stud, Vector3(sx, 0.21, sz))  # corner studs
	_part(root, _box(Vector3(0.14, 0.08, 0.04)), stud, Vector3(0, 0.16, 0.26))  # front latch
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
	var trace := _mat(Color(0.3, 0.85, 0.95), 0.0, 0.3, Color(0.3, 0.85, 0.95), 2.0)
	_part(root, _box(Vector3(0.3, 0.04, 0.2)), card, Vector3(0, 0.12, 0))
	_part(root, _box(Vector3(0.28, 0.045, 0.05)), gold, Vector3(0, 0.12, 0.09))
	_part(root, _box(Vector3(0.16, 0.05, 0.02)), trace, Vector3(0, 0.13, -0.02))
	_part(root, _box(Vector3(0.02, 0.05, 0.1)), trace, Vector3(0.06, 0.13, 0.02))
	return root


## Schematic — a blueprint board with a glowing grid/diagram.
static func build_schematic(col: Color) -> Node3D:
	var root := Node3D.new()
	var board := _mat(col * 0.5, 0.0, 0.5)
	var line := _mat(col, 0.0, 0.3, col * 1.3, 2.0)
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
	# Material kit (v2): gadgets share the enemy kit pipeline (friendly hardware).
	var k := ProcEnemyKits.kit("gadget_turret")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var lamp: StandardMaterial3D = k["glow"]

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
	var k := ProcEnemyKits.kit("gadget_dome")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var glow: StandardMaterial3D = k["glow"]

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
	var k := ProcEnemyKits.kit("gadget_sensor")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var amber: StandardMaterial3D = k["glow"]

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
