class_name ChemistryQA
extends RefCounted
## Harness QA for Machine Chemistry (Phase 5) — kept OUT of AgentBridge (it sits at the
## 1800-line ceiling), the same size-discipline split as NemesisQA. The harness can't land
## a thrown grenade on a moving target, so chemistry is applied DIRECTLY to a named enemy.
##   {cmd:"chemistry", action:"apply", target:"RobotHeavy", kind:"burn", dur:5, mag:8}
##   {cmd:"chemistry", action:"state", target:"RobotHeavy"}      → per-enemy remaining seconds
##   {cmd:"chemistry", action:"biome", x:130, z:130}             → biome + wetness at a point
## Also the misc-QA hub (AgentBridge is at ITS ceiling): music_state, hijack_*, and the
## model-overhaul candidate preview:
##   {cmd:"chemistry", action:"preview", path:"C:/dl/bot.glb", name:"cand1", height:1.8,
##    world:true, dist:5, yaw:0}   → runtime-loads an EXTERNAL glb (no project import),
##   saves a hero render to agent/<name>.png and (world:true) plants it in front of the
##   local player under the game's real lighting/grade. preview_clear removes it.

## In-world candidate holder — consecutive previews replace each other.
static var _preview_root: Node3D = null


static func run(tree: SceneTree, json: Dictionary) -> Dictionary:
	var action: String = String(json.get("action", "state"))
	if action == "biome":
		var bx: float = float(json.get("x", 0.0))
		var bz: float = float(json.get("z", 0.0))
		return {
			"ok": true,
			"biome": WorldBounds.biome_at(bx, bz),
			"wet": MachineChemistry.is_wet(bx, bz),
		}
	# Music-layer QA (v0.5-B3): read the threat-stem mixes/flags on THIS instance.
	if action == "music_state":
		var am: Node = tree.root.get_node_or_null("AudioManager")
		if am == null:
			return {"ok": false, "error": "no AudioManager"}
		return {
			"ok": true,
			"combat": [float(am.get("_combat_mix")), bool(am.get("_combat_hot"))],
			"tension": [float(am.get("_tension_mix")), bool(am.get("_tension_hot"))],
			"boss": [float(am.get("_boss_mix")), bool(am.get("_boss_hot"))],
		}
	# Hijack & Pilot QA (v0.5-B2 — chemistry's cousin verb; AgentBridge is at its ceiling):
	#   hijack_state              → server pilot map {peer: enemy_name}
	#   hijack_force + target+peer → server-side _try_start bypassing the client hold path
	if action == "hijack_state":
		var dirn: Node = tree.root.get_node_or_null("HijackDirector")
		if dirn == null:
			return {"ok": false, "error": "no HijackDirector"}
		var out: Dictionary = {}
		var pilots: Dictionary = dirn.get("_pilots")
		for peer in pilots:
			out[str(peer)] = str(((pilots[peer] as Dictionary).get("enemy") as Node).name)
		return {"ok": true, "pilots": out}
	if action == "hijack_probe":
		# LOCAL player's Hijack component internals (runs on ANY instance — not server-gated).
		var hjp: Node = null
		for pl in tree.get_nodes_in_group(Groups.PLAYERS):
			if pl.is_multiplayer_authority():
				hjp = pl.get_node_or_null(Groups.NODE_HIJACK)
		if hjp == null:
			return {"ok": false, "error": "no component"}
		var pl_node: Node3D = hjp.get_parent() as Node3D
		var near_name := ""
		var near_d := 9999.0
		var near_id := ""
		for en in tree.get_nodes_in_group(Groups.ENEMIES):
			if not (en is Node3D) or pl_node == null:
				continue
			var dd: float = pl_node.global_position.distance_to((en as Node3D).global_position)
			if dd < near_d:
				near_d = dd
				near_name = str(en.name)
				near_id = str(en.get("enemy_id"))
		return {
			"ok": true,
			"candidate": str(hjp.get("_candidate")),
			"stunned": bool(hjp.get("_candidate_stunned")),
			"hold": float(hjp.get("_hold")),
			"pressed": Input.is_action_pressed("hijack"),
			"piloting": bool(hjp.call("is_piloting")),
			"group_n": tree.get_nodes_in_group(Groups.ENEMIES).size(),
			"near": [near_name, near_d, near_id],
		}
	if action == "hijack_force":
		if not GameState.is_local_authority_server():
			return {"ok": false, "error": "not server"}
		var dirf: Node = tree.root.get_node_or_null("HijackDirector")
		var tgt: Node = _find_enemy(tree, String(json.get("target", "")))
		if dirf == null or tgt == null:
			return {"ok": false, "error": "no director/enemy"}
		dirf.call("_try_start", int(json.get("peer", 1)), tgt.get_path())
		return {"ok": true, "pilots": (await run(tree, {"action": "hijack_state"})).get("pilots")}
	if action == "shuttle_state":
		# D6.1 QA: the evac dropship is render-only and short-lived, and extraction resolves
		# in seconds — filming it reliably is hard, so ask the tree instead.
		var ships: Array = []
		for z in tree.get_nodes_in_group(Groups.EXTRACTION):
			var s: Variant = z.get("_shuttle")
			if s != null and is_instance_valid(s):
				# The ROOT stays pinned to the zone; the flying hull is the inner "_ship"
				# node, so report that — reading the root just says "the zone is where the
				# zone is" and makes a working approach look frozen.
				var hull: Variant = (s as Node).get("_ship")
				var body: Node3D = (hull as Node3D) if hull is Node3D else (s as Node3D)
				(
					ships
					. append(
						{
							"zone": str(z.name),
							"phase": int(s.get("_phase")),
							"pos":
							[
								snappedf(body.global_position.x, 0.1),
								snappedf(body.global_position.y, 0.1),
								snappedf(body.global_position.z, 0.1),
							],
						}
					)
				)
		return {
			"ok": true, "ships": ships, "zones": tree.get_nodes_in_group(Groups.EXTRACTION).size()
		}
	if action == "preview":
		return await _preview(tree, json)
	if action == "preview_clear":
		_clear_preview()
		return {"ok": true}
	var target: Node = _find_enemy(tree, String(json.get("target", "")))
	if target == null:
		return {"ok": false, "error": "no enemy"}
	if action == "apply":
		if not GameState.is_local_authority_server():
			return {"ok": false, "error": "not server"}
		var applied: bool = MachineChemistry.apply(
			target,
			String(json.get("kind", "burn")),
			float(json.get("dur", 5.0)),
			float(json.get("mag", 8.0))
		)
		return {"ok": true, "applied": applied, "name": str(target.name), "status": _status(target)}
	return {"ok": true, "name": str(target.name), "status": _status(target)}


## First enemy whose name matches (exact or prefix — tolerant of the _mod/_NEM token suffix).
static func _find_enemy(tree: SceneTree, name_q: String) -> Node:
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if name_q == "" or str(e.name) == name_q or str(e.name).begins_with(name_q):
			return e
	return null


static func _status(e: Node) -> Dictionary:
	return e.chemistry_status() if e.has_method("chemistry_status") else {}


# ------------------------------------------------------- external-glb candidate preview
static func _preview(tree: SceneTree, json: Dictionary) -> Dictionary:
	var path: String = String(json.get("path", ""))
	var pname: String = String(json.get("name", "preview"))
	var model: Node3D = null
	if path == "":
		# No file → "id" is a CATALOG/builder id: big FRESH hero shots of current models
		# (the icon cache serves stale 256px pre-warms — this path bypasses it).
		model = AssetRegistry.get_model(String(json.get("id", "")))
		if model == null:
			return {"ok": false, "error": "no path and unknown id"}
	elif path.begins_with("res://"):
		# Project-imported candidate (FBX goes through the editor ufbx import, then
		# loads here as a PackedScene — the runtime GLTFDocument path is glb-only).
		var packed := load(path) as PackedScene
		if packed == null:
			return {"ok": false, "error": "res load failed: %s" % path}
		model = packed.instantiate() as Node3D
	else:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err: int = doc.append_from_file(path, state)
		if err != OK:
			return {"ok": false, "error": "gltf load failed (%d): %s" % [err, path]}
		model = doc.generate_scene(state)
		if model == null:
			return {"ok": false, "error": "generate_scene returned null"}
	# Optional albedo-atlas override ("tex": path) — some FBX (Quaternius) carry no
	# texture link at all; their gradient atlas maps by UV, so one override material
	# restores the authored colors.
	var tex_path: String = String(json.get("tex", ""))
	if tex_path != "":
		var timg := Image.load_from_file(tex_path)
		if timg != null:
			var tmat := StandardMaterial3D.new()
			tmat.albedo_texture = ImageTexture.create_from_image(timg)
			tmat.roughness = 0.85
			_override_materials(model, tmat)
	var boxes: Array = []
	_collect_aabbs(model, Transform3D.IDENTITY, boxes)
	var aabb := AABB()
	for i in boxes.size():
		aabb = boxes[i] if i == 0 else aabb.merge(boxes[i])
	var scale_f: float = 1.0
	var want_h: float = float(json.get("height", 0.0))
	if want_h > 0.0 and aabb.size.y > 0.001:
		scale_f = want_h / aabb.size.y
	# Ground the candidate: wrapper origin = the model's feet.
	var root := Node3D.new()
	root.name = "GlbPreview"
	model.scale = Vector3.ONE * scale_f
	model.position = Vector3(0, -aabb.position.y * scale_f, 0)
	# glTF forward is +Z but our renders/world-facing assume -Z fronts: yaw spins the
	# MODEL inside the wrapper so it applies to the hero shot AND the world plant.
	model.rotate_y(deg_to_rad(float(json.get("yaw", 0.0))))
	root.add_child(model)
	var out: Dictionary = {
		"ok": true,
		"aabb": [aabb.size.x, aabb.size.y, aabb.size.z],
		"scale": scale_f,
	}
	# Hero render — fresh each call (the icon cache would return the previous candidate),
	# at a bigger canvas than the 256 icon size (restored after).
	var px: int = int(json.get("px", 640))
	IconRenderer._cache.erase("glbprev")
	if IconRenderer._vp != null:
		IconRenderer._vp.size = Vector2i(px, px)
	var tex: Texture2D = await IconRenderer.render_node("glbprev", root.duplicate())
	if IconRenderer._vp != null:
		IconRenderer._vp.size = Vector2i(IconRenderer.ICON_SIZE, IconRenderer.ICON_SIZE)
	IconRenderer._cache.erase("glbprev")
	if tex != null:
		var dir := (
			"user://agent"
			if Settings.instance_tag == ""
			else "user://agent/%s" % Settings.instance_tag
		)
		DirAccess.make_dir_recursive_absolute(dir)
		var png := "%s/%s.png" % [dir, pname.validate_filename()]
		tex.get_image().save_png(png)
		out["png"] = ProjectSettings.globalize_path(png)
	if not bool(json.get("world", false)):
		root.queue_free()
		return out
	# Plant in front of the local player, facing them, feet on the terrain.
	_clear_preview()
	var pl: Node3D = null
	for p in tree.get_nodes_in_group(Groups.PLAYERS):
		if p.is_multiplayer_authority():
			pl = p as Node3D
	if pl == null:
		root.queue_free()
		out["world"] = "no player"
		return out
	var fwd: Vector3 = -pl.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var spot: Vector3 = pl.global_position + fwd * float(json.get("dist", 4.5))
	spot.y = ProceduralTerrain.height_at(spot.x, spot.z)
	tree.current_scene.add_child(root)
	root.global_position = spot
	root.look_at(Vector3(pl.global_position.x, spot.y, pl.global_position.z), Vector3.UP)
	_preview_root = root
	out["world"] = [spot.x, spot.y, spot.z]
	return out


static func _override_materials(n: Node, m: Material) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_override = m
	for c in n.get_children():
		_override_materials(c, m)


## Local-space AABB walk (accumulated transforms — no in-tree/global_transform needed).
static func _collect_aabbs(n: Node, xf: Transform3D, acc: Array) -> void:
	var t: Transform3D = xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		acc.append(t * (n as MeshInstance3D).mesh.get_aabb())
	for c in n.get_children():
		_collect_aabbs(c, t, acc)


static func _clear_preview() -> void:
	if _preview_root != null and is_instance_valid(_preview_root):
		_preview_root.queue_free()
	_preview_root = null
