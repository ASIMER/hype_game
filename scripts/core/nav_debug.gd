class_name NavDebug
extends RefCounted
## QA-only NavigationServer dump (AgentBridge `navdbg`): every nav map's region/agent
## counts + the arena region's bake state + each enemy agent's path verdict. Built for
## the ground-enemy freeze hunt — enemies pinned at spawn mean an empty/unsynced map.


static func capture(tree: SceneTree) -> Dictionary:
	var out := {"maps": [], "region": {}, "enemies": []}
	for m: RID in NavigationServer3D.get_maps():
		(
			(out["maps"] as Array)
			. append(
				{
					"active": NavigationServer3D.map_is_active(m),
					"regions": NavigationServer3D.map_get_regions(m).size(),
					"agents": NavigationServer3D.map_get_agents(m).size(),
					"iteration": NavigationServer3D.map_get_iteration_id(m),
					"cell_size": NavigationServer3D.map_get_cell_size(m),
				}
			)
		)
	var arena_node: Node = tree.get_first_node_in_group(Groups.ARENA)
	var reg: NavigationRegion3D = null
	if arena_node != null:
		reg = arena_node.get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if reg != null:
		var polys: int = 0
		if reg.navigation_mesh != null:
			polys = reg.navigation_mesh.get_polygon_count()
		var reg_map := reg.get_navigation_map()
		out["region"] = {
			"enabled": reg.enabled,
			"baking": reg.is_baking(),
			"polygons": polys,
			"map_valid": reg_map.is_valid(),
			"map_iteration":
			NavigationServer3D.map_get_iteration_id(reg_map) if reg_map.is_valid() else -1,
		}
		var pl: Node = _authority_player(tree)
		if pl is Node3D and reg_map.is_valid():
			var ppos: Vector3 = (pl as Node3D).global_position
			out["player_snap"] = _vec(NavigationServer3D.map_get_closest_point(reg_map, ppos))
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if not is_instance_valid(e) or not ("_agent" in e):
			continue
		var ag: NavigationAgent3D = e._agent
		if ag == null:
			continue
		(
			(out["enemies"] as Array)
			. append(
				{
					"name": String(e.name),
					"target": _vec(ag.target_position),
					"reachable": ag.is_target_reachable(),
					"finished": ag.is_navigation_finished(),
					"path_len": ag.get_current_navigation_path().size(),
					"agent_map_iteration":
					(
						NavigationServer3D.map_get_iteration_id(ag.get_navigation_map())
						if ag.get_navigation_map().is_valid()
						else -1
					),
				}
			)
		)
	return out


static func _authority_player(tree: SceneTree) -> Node:
	var players := tree.get_nodes_in_group(Groups.PLAYERS)
	for p in players:
		if p.is_multiplayer_authority():
			return p
	return players[0] if players.size() > 0 else null


static func _vec(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
