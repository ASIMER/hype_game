extends RefCounted
class_name TeammateUtil
## Shared helper for co-op teammate indicators (minimap / compass / on-screen markers).
## Enumerates the OTHER players (not the local one) with their world node, peer id, display
## name, and downed flag. Single-player-safe: returns [] when there are no teammates.

## Friendly green (distinct from the extraction beacon-green by shape+size) and the
## downed/needs-help amber, shared across every surface so the palette stays consistent.
const TEAM_GREEN := Color(0.36, 0.92, 0.55)
const TEAM_DOWN  := Color(0.95, 0.65, 0.20)
## World Y above a player's origin for the over-head nameplate (≈ the 1.5 m camera + clearance).
const HEAD_OFFSET := 1.9

## [{ node: Node3D, peer_id: int, name: String, downed: bool }] for every teammate.
static func list(tree: SceneTree) -> Array:
	var out: Array = []
	if tree == null:
		return out
	var local: int = GameState.local_peer_id()
	for p in tree.get_nodes_in_group(Groups.PLAYERS):
		if not (p is Node3D) or not is_instance_valid(p):
			continue
		var pid: int = str((p as Node).name).to_int()
		if pid <= 0 or pid == local:
			continue
		out.append({
			"node": p, "peer_id": pid, "name": _name_of(pid),
			"downed": GameState.is_downed(pid),
		})
	return out

static func _name_of(pid: int) -> String:
	var info: Variant = GameState.peers.get(pid, null)
	if info is Dictionary:
		var n := String((info as Dictionary).get("name", ""))
		if n != "":
			return n
	return "P%d" % pid
