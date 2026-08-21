extends StaticBody3D
class_name BreakableGlass
## A breakable transparent window pane (built by ProceduralBuildings.wall() into every
## window opening). Solid on layer 1 until shattered — it stops bullets AND enemy LOS —
## then a shot/blast breaks it: collision off, mesh hidden, shard burst + tinkle, and
## the opening is genuinely free.
##
## REPLICATION (the locked_door discipline, but INDEX-keyed): wall roots are anonymous
## nodes whose paths differ per peer, so node-path RPCs can't target a pane. Instead
## every pane carries the deterministic `index` from ProceduralBuildings._glass_seq
## (reset by arena before each build → identical on every peer) and registers itself
## in a static registry. A hit routes through NetworkManager.request_break_glass(index)
## → the SERVER validates and broadcasts → every peer shatters the same pane. Indices
## are PER-BUILD only (never persist them); a restart rebuilds all panes intact.
##
## Determinism: no procedural variation here — pane size/placement comes from the
## builder. Server-side effects gate in NetworkManager; visuals run on every peer.

## How loud a breaking pane is to enemy hearing (m) — quieter than gunfire (22).
const NOISE_LOUDNESS := 12.0

## Deterministic pane id (ProceduralBuildings._glass_seq at build time).
var index: int = -1
## True once shattered (collision disabled, mesh hidden). Per-build state.
var broken: bool = false
## Full pane size (the builder sets it) — sizes the shard-burst emission box.
var pane_size: Vector3 = Vector3(1.0, 1.0, 0.1)

## index -> pane. Static so NetworkManager/grenades can resolve panes without a scene
## walk. Cleared per-pane in _exit_tree with an identity check (an arena rebuild frees
## the old building AFTER the new one registered the same index).
static var _registry: Dictionary = {}


func _ready() -> void:
	add_to_group(Groups.BREAKABLE_GLASS)
	_registry[index] = self


func _exit_tree() -> void:
	if _registry.get(index) == self:
		_registry.erase(index)


static func by_index(idx: int) -> BreakableGlass:
	var p: Variant = _registry.get(idx)
	return p if (p is BreakableGlass and is_instance_valid(p)) else null


## SERVER-side helper: shatter every unbroken pane within `radius` of `center`
## (grenade blasts). Routes each through the authoritative break path.
static func break_in_radius(center: Vector3, radius: float) -> void:
	for p in _registry.values():
		if p is BreakableGlass and is_instance_valid(p) and not p.broken:
			if p.global_position.distance_to(center) <= radius:
				NetworkManager.request_break_glass(p.index)


## Runs on EVERY peer (post-replication). Idempotent: collision off (deferred — may
## land mid-physics-step), mesh hidden, pooled shard burst, bus signal for audio/QA.
func shatter() -> void:
	if broken:
		return
	broken = true
	var col := get_node_or_null("CollisionShape3D")
	if col != null:
		col.set_deferred("disabled", true)
	var mesh := get_node_or_null("Pane")
	if mesh != null:
		(mesh as MeshInstance3D).visible = false
	# Shard FX (pooled; null-safe on a headless server where FXPool never spawned).
	if FXPool.active != null:
		var fx: Node = FXPool.acquire_or_new(
			"glass_shatter", load("res://scripts/fx/glass_shatter.gd"), get_tree().current_scene
		)
		if fx != null:
			(fx as Node3D).global_transform = global_transform
			if fx.has_method("set_pane"):
				fx.call("set_pane", pane_size)
			if fx.has_method("fire"):
				fx.call("fire")
	Events.glass_broken.emit(self)


## QA summary for the AgentBridge "glass" verb (kept here so the verb stays thin
## under that file's line ceiling).
static func debug_summary() -> Dictionary:
	var panes: Array = []
	var broken_n: int = 0
	var keys: Array = _registry.keys()
	keys.sort()
	for k in keys:
		var p: Variant = _registry[k]
		if not (p is BreakableGlass and is_instance_valid(p)):
			continue
		if p.broken:
			broken_n += 1
		(
			panes
			. append(
				{
					"index": p.index,
					"broken": p.broken,
					"pos": [p.global_position.x, p.global_position.y, p.global_position.z],
				}
			)
		)
	return {"ok": true, "total": panes.size(), "broken": broken_n, "panes": panes}


## QA helper: the nearest unbroken pane index to `pos`, or -1.
static func nearest_unbroken(pos: Vector3) -> int:
	var best: int = -1
	var best_d: float = 1e9
	for p in _registry.values():
		if p is BreakableGlass and is_instance_valid(p) and not p.broken:
			var d: float = p.global_position.distance_to(pos)
			if d < best_d:
				best_d = d
				best = p.index
	return best
