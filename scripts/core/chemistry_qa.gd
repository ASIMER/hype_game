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
