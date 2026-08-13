class_name ChemistryQA
extends RefCounted
## Harness QA for Machine Chemistry (Phase 5) — kept OUT of AgentBridge (it sits at the
## 1800-line ceiling), the same size-discipline split as NemesisQA. The harness can't land
## a thrown grenade on a moving target, so chemistry is applied DIRECTLY to a named enemy.
##   {cmd:"chemistry", action:"apply", target:"RobotHeavy", kind:"burn", dur:5, mag:8}
##   {cmd:"chemistry", action:"state", target:"RobotHeavy"}      → per-enemy remaining seconds
##   {cmd:"chemistry", action:"biome", x:130, z:130}             → biome + wetness at a point


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
		return {"ok": true, "pilots": run(tree, {"action": "hijack_state"}).get("pilots")}
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
