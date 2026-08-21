class_name NemesisQA
extends RefCounted
## Harness QA for the Machine Nemesis — kept OUT of AgentBridge (it sits at the 1800-line
## ceiling), the same size-discipline split as GoldenSnapshot / the gear/quest debug helpers.
## Drives the NemesisDirector debug hooks:
##   {cmd:"nemesis"}                                                  → current state
##   {cmd:"nemesis", action:"force_birth", archetype:"robot_bastion", traits:["emp_hard"]}
##   {cmd:"nemesis", action:"inject"}                                 → spawn the saved rival
##   {cmd:"nemesis", action:"state"}

## Archetype id → scene path (QA convenience only — the production birth path captures the
## scene from the live candidate node, so this duplication never reaches gameplay).
const _SCENE_FOR_ID := {
	"robot_bastion": "res://scenes/enemies/RobotBastion.tscn",
	"robot_elite": "res://scenes/enemies/RobotElite.tscn",
	"robot_heavy": "res://scenes/enemies/RobotHeavy.tscn",
	"robot_caller": "res://scenes/enemies/RobotCaller.tscn",
	"robot_oni": "res://scenes/enemies/RobotOni.tscn",
	"robot_avalanche": "res://scenes/enemies/RobotAvalanche.tscn",
}


static func run(tree: SceneTree, json: Dictionary) -> Dictionary:
	var dir: Node = tree.root.get_node_or_null("NemesisDirector")
	if dir == null:
		return {"ok": false, "error": "no NemesisDirector"}
	if not GameState.is_local_authority_server():
		return {"ok": false, "error": "not server"}
	var action: String = String(json.get("action", "state"))
	match action:
		"force_birth":
			var arch: String = String(json.get("archetype", "robot_bastion"))
			var scene: String = String(json.get("scene_path", _SCENE_FOR_ID.get(arch, "")))
			if scene == "":
				return {"ok": false, "error": "unknown archetype (pass scene_path)"}
			var traits: Array = (
				json.get("traits", ["emp_hard"]) if json.get("traits") is Array else ["emp_hard"]
			)
			return _ok(dir.call("debug_force_birth", arch, scene, traits))
		"inject":
			return _ok(dir.call("debug_inject"))
		"raid_over":
			return _ok(dir.call("debug_raid_over"))
		"set_telemetry":
			return _ok(
				dir.call(
					"debug_set_telemetry",
					int(json.get("emp", 0)),
					int(json.get("weakpoint", 0)),
					int(json.get("blast", 0)),
					float(json.get("stealth", 0.0)),
					int(json.get("chem", 0))
				)
			)
		"set_lost":
			var ids: Array = json.get("ids", []) if json.get("ids") is Array else []
			return _ok(dir.call("debug_set_lost", ids))
		"set_zone":
			return _ok(
				dir.call("debug_set_zone", String(json.get("zone", "")), int(json.get("count", 2)))
			)
		"codex":
			return _ok({"codex": dir.call("codex_data")})
		"core_spawn":
			# Phase 4: drop a Power-Core near the local player (no boss kill needed).
			var pcd: Node = tree.root.get_node_or_null("PowerCoreDirector")
			if pcd == null:
				return {"ok": false, "error": "no PowerCoreDirector"}
			return _ok(pcd.call("debug_spawn", _local_player_pos(tree)))
		"core_state":
			var pcd2: Node = tree.root.get_node_or_null("PowerCoreDirector")
			return _ok(pcd2.call("debug_state") if pcd2 != null else {})
		_:
			return _ok(dir.call("debug_state"))


static func _ok(d: Dictionary) -> Dictionary:
	d["ok"] = true
	return d


static func _local_player_pos(tree: SceneTree) -> Vector3:
	for pl in tree.get_nodes_in_group(Groups.PLAYERS):
		if pl is Node3D and pl.is_multiplayer_authority():
			return (pl as Node3D).global_position
	return Vector3.ZERO
