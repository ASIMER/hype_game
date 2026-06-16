class_name AgentChunkDebug
extends RefCounted
## Harness QA for BreakableChunk wall destruction — kept OUT of AgentBridge (it sits at the
## 1800-line ceiling), the same size-discipline split as NemesisQA / ChemistryQA / GoldenSnapshot.
## Verbs (cmd:"chunk"):
##   {action:"state"}                       → {total, broken} registry counts
##   {action:"nearest"}                     → nearest unbroken chunk to the local player
##                                            {index, hp, broken, pos, dist}
##   {action:"damage", index:N, amount:F}   → route damage through the SERVER (deplete → crumble)
##   {action:"crumble", index:N}            → force-crumble (lethal damage)
##   {action:"crumble", nearest:true}       → force-crumble the nearest unbroken chunk to the player


static func run(tree: SceneTree, json: Dictionary) -> Dictionary:
	var action: String = String(json.get("action", "state"))
	match action:
		"nearest":
			var idx: int = BreakableChunk.nearest_unbroken(_player_pos(tree))
			var c: BreakableChunk = BreakableChunk.by_index(idx)
			if c == null:
				return {"ok": true, "index": -1, "total": _total()}
			var p: Vector3 = c.global_position
			return {
				"ok": true,
				"index": idx,
				"hp": c.hp,
				"kind": c.material_kind,
				"broken": c.broken,
				"pos": [p.x, p.y, p.z],
				"dist": _player_pos(tree).distance_to(p),
			}
		"damage":
			if GameState.is_local_authority_server():
				var di: int = int(json.get("index", -1))
				if bool(json.get("nearest", false)):
					di = BreakableChunk.nearest_unbroken(_player_pos(tree))
				NetworkManager.request_damage_chunk(di, float(json.get("amount", 30.0)))
			return BreakableChunk.debug_summary()
		"crumble":
			if GameState.is_local_authority_server():
				var ci: int = int(json.get("index", -1))
				if bool(json.get("nearest", false)):
					ci = BreakableChunk.nearest_unbroken(_player_pos(tree))
				NetworkManager.request_damage_chunk(ci, 1e9)
			return BreakableChunk.debug_summary()
		_:
			return BreakableChunk.debug_summary()


static func _total() -> int:
	return int(BreakableChunk.debug_summary().get("total", 0))


static func _player_pos(tree: SceneTree) -> Vector3:
	for pl in tree.get_nodes_in_group(Groups.PLAYERS):
		if pl is Node3D and pl.is_multiplayer_authority():
			return (pl as Node3D).global_position
	return Vector3.ZERO
