class_name FellableTree
extends RefCounted
## DESTRUCTIBLE TREES ("разрушение-как-оружие", panel P5 + user ask): every scattered
## tree can be SHOT DOWN — the trunk takes HP, then the whole model tips over as a
## RigidBody that CRUSHES enemies under it, settles into cover, fades, and leaves a
## stump. Replicated BY INDEX like BreakableGlass/BreakableChunk (the trunk shapes are
## children of ONE anonymous "TreeTrunks" body → node-path RPCs are impossible; the
## deterministic build order IS the id): the server owns HP, every peer executes the
## same fell locally off the broadcast.
##
## Registry lifecycle: `reset()` at arena build start → `register()` per placed tree
## (procedural_flora._place_tree) → `bind_instances()` after the tiled MultiMeshes are
## emitted (maps each tree to its MMI set + per-instance slot so the standing visual
## can be zero-scaled on fell). Restart rebuilds the arena → fresh registry, all trees
## restored — the glass/chunk discipline.

const NOISE_LOUDNESS := 13.0  # felling a tree is LOUD — AI investigates

# index (TreeTrunks child order) -> record:
#   shape: CollisionShape3D · id: String (model) · xform: Transform3D · hp: float
#   mmis: Array[MultiMeshInstance3D] · inst: int (per-tile instance slot) · felled: bool
static var _trees: Dictionary = {}


static func reset() -> void:
	_trees.clear()


static func register(
	index: int, shape: CollisionShape3D, model_id: String, xform: Transform3D
) -> void:
	_trees[index] = {
		"shape": shape,
		"id": model_id,
		"xform": xform,
		"hp": Settings.TREE_HP,
		"mmis": [],
		"inst": -1,
		"felled": false,
	}


## Attach the visual handles for tree `index`: the tile's MMI list + the shared
## per-instance slot inside them (every surface-MMI of a tile shares transforms).
static func bind_instances(index: int, mmis: Array, inst: int) -> void:
	if not _trees.has(index):
		return
	_trees[index]["mmis"] = mmis
	_trees[index]["inst"] = inst


static func count() -> int:
	return _trees.size()


static func position_of(index: int) -> Vector3:
	if not _trees.has(index):
		return Vector3.ZERO
	return (_trees[index]["xform"] as Transform3D).origin


## Nearest still-standing tree index to `pos` (QA helper); -1 when none.
static func nearest_standing(pos: Vector3) -> int:
	var best: int = -1
	var best_d: float = INF
	for k in _trees:
		var rec: Dictionary = _trees[k]
		if bool(rec["felled"]):
			continue
		var d: float = (rec["xform"] as Transform3D).origin.distance_to(pos)
		if d < best_d:
			best_d = d
			best = int(k)
	return best


## SERVER: apply damage; returns true when this hit fells the tree.
static func server_take_damage(index: int, dmg: float) -> bool:
	if not Settings.TREE_FELL_ENABLED or not _trees.has(index):
		return false
	var rec: Dictionary = _trees[index]
	if bool(rec["felled"]):
		return false
	rec["hp"] = float(rec["hp"]) - dmg
	if float(rec["hp"]) > 0.0:
		return false
	rec["felled"] = true
	return true


## EVERY PEER (authority call_local broadcast): hide the standing instance, shrink the
## trunk collider to a stump, spawn the falling body + stump visual. `normal` points
## toward the shooter — the tree tips AWAY from it.
static func do_fell(host: Node, index: int, normal: Vector3) -> void:
	if not _trees.has(index):
		return
	var rec: Dictionary = _trees[index]
	rec["felled"] = true  # clients mark too (server already did in take_damage)
	# 1) Zero-scale the standing MultiMesh instance (per-instance transform edit).
	var inst: int = int(rec["inst"])
	for mmi in rec["mmis"]:
		var m := mmi as MultiMeshInstance3D
		if m != null and m.multimesh != null and inst >= 0 and inst < m.multimesh.instance_count:
			m.multimesh.set_instance_transform(
				inst, Transform3D(Basis().scaled(Vector3(0.001, 0.001, 0.001)), Vector3(0, -200, 0))
			)
	# 2) Trunk collider → stump height (keeps a nub of collision; navmesh untouched).
	var shape := rec["shape"] as CollisionShape3D
	var base_pos := Vector3.ZERO
	if shape != null and shape.shape is CylinderShape3D:
		var cyl := shape.shape as CylinderShape3D
		base_pos = shape.position - Vector3(0, cyl.height * 0.5, 0)
		var stump := CylinderShape3D.new()
		stump.radius = cyl.radius
		stump.height = 0.7
		shape.shape = stump
		shape.position = base_pos + Vector3(0, 0.35, 0)
	else:
		base_pos = (rec["xform"] as Transform3D).origin
	# 3) Stump visual + the falling tree body.
	var xf: Transform3D = rec["xform"]
	_spawn_stump(host, base_pos, xf)
	_spawn_falling(host, String(rec["id"]), xf, normal)


static func _spawn_stump(host: Node, base_pos: Vector3, xf: Transform3D) -> void:
	var mesh := CylinderMesh.new()
	var r: float = maxf(0.22, 0.3 * xf.basis.get_scale().x)
	mesh.top_radius = r * 0.92
	mesh.bottom_radius = r * 1.1
	mesh.height = 0.6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.24, 0.16)
	mat.roughness = 0.95
	# Pale broken-wood top ring via a second lighter surface is overkill — one tone reads.
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = base_pos + Vector3(0, 0.3, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(mi)


## The tipping tree: a RigidBody at the tree's transform carrying the REAL model
## meshes, given a topple impulse away from the shooter. Server-side contact damage
## CRUSHES enemies (Hurtbox.apply_hit). Purely local visuals on every peer (crumble
## debris discipline); only the SERVER's copy deals damage.
static func _spawn_falling(host: Node, model_id: String, xf: Transform3D, normal: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var body := RigidBody3D.new()
	body.name = "FallenTree"
	body.mass = 40.0
	body.collision_layer = 0
	body.collision_mask = 1 | 4  # world + enemy bodies (crush contacts)
	body.contact_monitor = true
	body.max_contacts_reported = 6
	body.can_sleep = true
	# Visual: the real model meshes under the tree's own basis (scale+yaw preserved).
	var meshes: Array = FloraMeshLib.model_meshes(model_id)
	for m in meshes:
		if m == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.transform = Transform3D(xf.basis, Vector3.ZERO)
		body.add_child(mi)
	# Collision: one trunk capsule along the model height (enough for topple + crush).
	var sc: float = xf.basis.get_scale().x
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = maxf(0.3, 0.35 * sc)
	cap.height = 5.5 * sc
	col.shape = cap
	col.position = Vector3(0, 2.75 * sc, 0)
	body.add_child(col)
	body.position = xf.origin
	host.add_child(body)
	# Topple: push the TOP sideways (away from the shooter) — torque from an offset impulse.
	var dir := -normal
	dir.y = 0.0
	if dir.length() < 0.05:
		dir = Vector3(1, 0, 0).rotated(Vector3.UP, randf() * TAU)
	dir = dir.normalized()
	body.apply_impulse(dir * 26.0, Vector3(0, 4.5 * sc, 0))
	# Server-only crush damage on contact.
	if GameState.is_local_authority_server():
		body.body_entered.connect(_on_fall_contact.bind(body))
	# Settle → fade → free (leaves the stump). Timer parented to the body dies with it.
	var t := host.get_tree().create_timer(Settings.TREE_FALLEN_LIFETIME)
	t.timeout.connect(
		func() -> void:
			if is_instance_valid(body):
				var tw := body.create_tween()
				for c in body.get_children():
					if c is MeshInstance3D:
						tw.parallel().tween_property(c, "transparency", 1.0, 1.6)
				tw.tween_callback(body.queue_free)
	)


## SERVER: a falling trunk touched something — enemies under it get crushed. Damage
## scales with how fast the trunk is still moving (a settled log is harmless).
static func _on_fall_contact(other: Node, body: RigidBody3D) -> void:
	if other == null or not is_instance_valid(body):
		return
	if not other.is_in_group(Groups.ENEMIES):
		return
	var speed: float = body.linear_velocity.length() + body.angular_velocity.length() * 2.0
	if speed < 1.2:
		return
	var dmg: float = clampf(speed * 9.0, 12.0, Settings.TREE_CRUSH_DMG)
	var hb := other.get_node_or_null(Groups.NODE_HURTBOX)
	if hb != null and hb.has_method("apply_hit"):
		hb.apply_hit(dmg, body)
