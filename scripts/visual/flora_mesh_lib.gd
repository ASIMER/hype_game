class_name FloraMeshLib
extends RefCounted
## Shared glTF-mesh loading + MultiMesh emission for the flora family
## (ProceduralFlora trees/bushes/boulders + FloraClutter ferns/flowers/pebbles).
## ONE copy of the mechanics (the AUDIT F1 rule — never copy-paste helpers):
##   - model_meshes(id): pull EVERY MeshInstance3D Mesh out of an imported glTF
##     PackedScene once (multi-node models like Flower_*_Group have several), cached.
##   - emit_model_mm(): one render-only MultiMeshInstance3D per mesh from a shared
##     transform list, so N instances cost a handful of draw calls, not N nodes.
## Headless-safe: model_meshes returns [] (no rendering server) and emitters no-op,
## so the arena still builds deterministically on a dedicated server.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

static var _mesh_cache: Dictionary = {}


## Every Mesh inside the glTF (depth-first MeshInstance3D order — deterministic).
## Returns [] when the model is missing or in headless. Cached per id.
static func model_meshes(id: String) -> Array:
	if _mesh_cache.has(id):
		return _mesh_cache[id]
	var meshes: Array = []
	var ps: PackedScene = load("res://assets/models/flora/%s.gltf" % id)
	if ps != null:
		var inst: Node = ps.instantiate()
		_collect_meshes(inst, meshes)
		inst.free()
	_mesh_cache[id] = meshes
	return meshes


## Back-compat single-mesh accessor (the first mesh, or null).
static func model_mesh(id: String) -> Mesh:
	var meshes: Array = model_meshes(id)
	return meshes[0] if not meshes.is_empty() else null


static func _collect_meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append((n as MeshInstance3D).mesh)
	for c in n.get_children():
		_collect_meshes(c, out)


## SPATIALLY TILED emission (the grass lesson, applied to trees/bushes/ferns):
## a map-wide MultiMesh has a map-wide AABB, so `visibility_range` keys off a
## distance that is always ~0 and the layer NEVER culls — every instance renders
## into the camera AND all four shadow splits every frame (760 trees ≈ millions of
## shadow tris). Bucketing instances into `tile_m`-metre tiles gives each MMI a
## tile-sized AABB so distant tiles genuinely cull. One MMI per (mesh, tile).
static func emit_model_mm_tiled(
	parent: Node3D,
	nm: String,
	meshes: Array,
	xforms: Array[Transform3D],
	tile_m: float,
	vis_end: float = 0.0
) -> void:
	if meshes.is_empty() or xforms.is_empty():
		return
	var buckets: Dictionary = {}
	for xf in xforms:
		var gx: int = int(floor((xf.origin.x - WorldBounds.X_MIN) / tile_m))
		var gz: int = int(floor((xf.origin.z - WorldBounds.Z_MIN) / tile_m))
		var key: int = gx * 1000 + gz
		if not buckets.has(key):
			buckets[key] = [] as Array[Transform3D]
		(buckets[key] as Array[Transform3D]).append(xf)
	var keys: Array = buckets.keys()
	keys.sort()  # deterministic node order across machines
	for key in keys:
		emit_model_mm(parent, "%s_t%d" % [nm, int(key)], meshes, buckets[key], vis_end)


## Emit one MultiMeshInstance3D per mesh in `meshes` (suffix _s<i> when several),
## all sharing `xforms`. `vis_end` > 0 applies a visibility range (fade-self) so a
## distant layer culls; 0 = always-on (small clutter layers, one MMI map-wide).
static func emit_model_mm(
	parent: Node3D, nm: String, meshes: Array, xforms: Array[Transform3D], vis_end: float = 0.0
) -> void:
	if meshes.is_empty() or xforms.is_empty():
		return
	for i in range(meshes.size()):
		var mesh: Mesh = meshes[i]
		if mesh == null:
			continue
		var mmi := MultiMeshInstance3D.new()
		mmi.name = nm if meshes.size() == 1 else "%s_s%d" % [nm, i]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = false
		mm.mesh = mesh
		mm.instance_count = xforms.size()
		for j in range(xforms.size()):
			mm.set_instance_transform(j, xforms[j])
		mmi.multimesh = mm
		if vis_end > 0.0:
			mmi.visibility_range_end = vis_end
			mmi.visibility_range_end_margin = 12.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		parent.add_child(mmi)
