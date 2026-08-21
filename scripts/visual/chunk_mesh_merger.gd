class_name ChunkMeshMerger
extends RefCounted
## Merged rendering for BreakableChunk BOX cells (Разрушаемость 2.3 — the draw-call fix).
## The 0.8 m wall grid made every cell its own MeshInstance3D (~5k instances → that many
## extra draw calls → fps halved at POIs). Instead, _solid(breakable) QUEUES the cell here
## and the arena FLUSHES once per build: all cells of one (parent node, material) group are
## baked into ONE ArrayMesh under ONE MeshInstance3D ("ChunkMesh_N").
##
## The bake uses THE repo-proven merge recipe (AssetRegistry._merge_model — how merged
## loot pickups render): SurfaceTool.append_from(BoxMesh, 0, cell_transform) + commit +
## surface_set_material. Hand-rolled vertex arrays and MultiMesh batches both rendered
## these triplanar StandardMaterials BLACK in 4.6.3 (verified by live arm-isolation);
## SurfaceTool's engine-canonical attribute set + a surface material (NOT material_override)
## is the combination that works.
##
## Crumble: the cell marks its group DIRTY; the group re-bakes once per frame (deferred,
## coalesced) skipping broken cells — a grenade burst costs one rebuild per group, not one
## per cell. Collision/HP/replication are untouched (the BreakableChunk body keeps its
## CollisionShape3D + index). Deterministic: queue order == build order on every peer.
## Stairs flights / flora boulders build their own visuals and never queue here.


## One baked (parent, material) batch. RefCounted — held by its member chunks; the
## MeshInstance3D dies with the arena tree.
class MergeGroup:
	extends RefCounted

	var mi: MeshInstance3D = null
	var mat: Material = null
	var cells: Array[Dictionary] = []  # {"chunk": BreakableChunk, "size": Vector3}
	var _dirty: bool = false

	func mark_dirty() -> void:
		if _dirty:
			return
		_dirty = true
		_rebuild.call_deferred()

	func _rebuild() -> void:
		_dirty = false
		if is_instance_valid(mi):
			mi.mesh = ChunkMeshMerger.bake_mesh(cells, mat)


static var _pending: Array[Dictionary] = []
static var _seq: int = 0
static var _box_cache: Dictionary = {}  # "x_y_z" size key → shared BoxMesh


## Full reset at the start of an arena build (alongside the _chunk_seq reset).
static func reset() -> void:
	_pending.clear()
	_box_cache.clear()
	_seq = 0


## Called by ProceduralBuildings._solid for every merged breakable cell. `chunk` already
## carries its local transform under `parent`; the baked mesh lives under the SAME parent,
## so vertices bake in parent-local space and follow wherever the builder places the root.
static func queue(parent: Node3D, chunk: BreakableChunk, size: Vector3, mat: Material) -> void:
	_pending.append({"parent": parent, "chunk": chunk, "size": size, "mat": mat})


## Drain the queue into baked per-(parent, material) meshes. Safe to call repeatedly (a
## later flush only handles newly queued cells). Runs identically on every peer.
static func flush() -> void:
	if _pending.is_empty():
		return
	# Group by parent → material, preserving first-seen order (determinism).
	var by_parent: Dictionary = {}
	for e: Dictionary in _pending:
		var parent: Node3D = e["parent"]
		if not by_parent.has(parent):
			by_parent[parent] = {}
		var groups: Dictionary = by_parent[parent]
		var mat: Material = e["mat"]
		if not groups.has(mat):
			groups[mat] = []
		(groups[mat] as Array).append(e)
	_pending.clear()
	for parent: Node3D in by_parent.keys():
		if not is_instance_valid(parent):
			continue
		var groups: Dictionary = by_parent[parent]
		for mat: Material in groups.keys():
			_build_group(parent, mat, groups[mat] as Array)


static func _build_group(parent: Node3D, mat: Material, entries: Array) -> void:
	_seq += 1
	var group := MergeGroup.new()
	group.mat = mat
	for e: Dictionary in entries:
		var chunk: BreakableChunk = e["chunk"]
		group.cells.append({"chunk": chunk, "size": e["size"]})
		chunk.merge_group = group
	var mi := MeshInstance3D.new()
	mi.name = "ChunkMesh_%d" % _seq
	mi.mesh = bake_mesh(group.cells, mat)
	group.mi = mi
	parent.add_child(mi)


## Bake every UNBROKEN cell into one ArrayMesh carrying `mat` as its surface material.
## Returns null when nothing is left (the group's MeshInstance then draws nothing).
static func bake_mesh(cells: Array[Dictionary], mat: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for e: Dictionary in cells:
		var chunk: BreakableChunk = e["chunk"]
		if not is_instance_valid(chunk) or chunk.broken:
			continue
		any = true
		st.append_from(_box(e["size"]), 0, chunk.transform)
	if not any:
		return null
	var arr := ArrayMesh.new()
	st.commit(arr)
	arr.surface_set_material(0, mat)
	return arr


## Shared per-size BoxMesh (cells of one wall segment all share a size, so the cache
## stays small — cleared each build).
static func _box(size: Vector3) -> BoxMesh:
	var key := "%.4f_%.4f_%.4f" % [size.x, size.y, size.z]
	if not _box_cache.has(key):
		var box := BoxMesh.new()
		box.size = size
		_box_cache[key] = box
	return _box_cache[key]
