class_name GoldenSnapshot
## Deterministic-world snapshot for refactor verification (docs/AUDIT.md "golden
## snapshot"): pure terrain height/water probes on a fixed 9x9 grid, extraction-zone
## positions + their pad heights, and a placement checksum per procedural container
## under the arena's NavigationRegion3D. Two runs of the same build MUST byte-match
## (tools/lint/check_golden.py canonicalizes + compares). Deliberately EXCLUDED:
## loot (field/world rolls use unseeded RNG) and Grass_* tiles (stream with the player).
## Extracted from AgentBridge (the `golden` cmd calls capture()) for size discipline.


static func capture(tree: SceneTree) -> Dictionary:
	var heights: Array = []
	var water: Array = []
	for iz in range(9):
		for ix in range(9):
			var x := -80.0 + 40.0 * float(ix)
			var z := -80.0 + 40.0 * float(iz)
			heights.append([x, z, snappedf(ProceduralTerrain.height_at(x, z), 0.0001)])
			var w := ProceduralTerrain.water_surface_at(x, z)
			water.append([x, z, null if is_nan(w) else snappedf(w, 0.0001)])
	var zones: Array = []
	for zn in tree.get_nodes_in_group(Groups.EXTRACTION):
		if not (zn is Node3D):
			continue
		var zp: Vector3 = (zn as Node3D).global_position
		(
			zones
			. append(
				{
					"name": str(zn.name),
					"pos": [snappedf(zp.x, 0.001), snappedf(zp.y, 0.001), snappedf(zp.z, 0.001)],
					"pad_h": snappedf(ProceduralTerrain.height_at(zp.x, zp.z), 0.0001),
				}
			)
		)
	zones.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	var containers: Dictionary = {}
	var arena: Node = tree.get_first_node_in_group(Groups.ARENA)
	var nav: Node = arena.get_node_or_null("NavigationRegion3D") if arena else null
	if nav:
		for child in nav.get_children():
			var acc: Array = []
			var cnt := _fold_node(child, acc)
			containers[str(child.name)] = {"nodes": cnt, "hash": hash(acc)}
	return {
		"ok": nav != null,
		"version": Settings.GAME_VERSION,
		"heights": heights,
		"water": water,
		"zones": zones,
		"containers": containers,
	}


## Folds a node subtree into acc for the golden checksum: name, class, quantized
## global transform (mm origin / 1e-3 basis), and MultiMesh instance buffers (full
## per-instance transforms). Returns the folded node count. Grass_* subtrees are
## skipped — their tiles rebuild around the player, so they are not run-deterministic.
static func _fold_node(n: Node, acc: Array) -> int:
	var nm := str(n.name)
	if nm.begins_with("Grass_"):
		return 0
	# Auto-generated names (@Class@N) carry a process-global counter that changes on
	# every arena rebuild — fold them as "@anon" so only EXPLICIT names are load-bearing.
	acc.append("@anon" if nm.begins_with("@") else nm)
	acc.append(n.get_class())
	if n is Node3D:
		var t: Transform3D = (n as Node3D).global_transform
		for v: Vector3 in [t.origin, t.basis.x, t.basis.y, t.basis.z]:
			acc.append(int(round(v.x * 1000.0)))
			acc.append(int(round(v.y * 1000.0)))
			acc.append(int(round(v.z * 1000.0)))
	if n is MultiMeshInstance3D:
		var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
		if mm:
			acc.append(mm.instance_count)
			acc.append(hash(mm.buffer))
	var cnt := 1
	for c in n.get_children():
		cnt += _fold_node(c, acc)
	return cnt
