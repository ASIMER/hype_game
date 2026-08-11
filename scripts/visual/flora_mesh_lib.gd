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

# --- canopy life ------------------------------------------------------------
# Foliage in the Quaternius kit is a FROZEN set of named materials whose colour lives in a
# 2-tone atlas — the imported albedo_color is plain WHITE, so a "lift dark albedos" test
# reading albedo_color would always see 1.0 and do nothing. The gain is therefore keyed by
# material name. Values are the intended LINEAR albedo gain (see _light_foliage).
const _CANOPY_GAIN := {
	"Leaves_Pine": 1.45,  # (51,88,0) — darkest canopy of the kit, reads black in shade
	"Leaf_Pine": 1.45,  # same atlas, name fallback
	"Leaves_TwistedTree": 1.40,  # red maple
	"Leaves_NormalTree": 1.20,
}
## Light bleeding THROUGH a leaf card — the single biggest fix for "flat dark blob" canopies.
const _BACKLIGHT := Color(0.30, 0.38, 0.22)
const _LIT_META := "flora_lit"


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
	_light_foliage(meshes)
	_mesh_cache[id] = meshes
	return meshes


## Give every foliage surface backlight + a canopy-specific albedo lift, ONCE per material
## (meta-guarded — the gain multiplies, so a second pass would compound it). Done here so
## every flora consumer (trees, bushes, ferns, flowers) gets it from the one load path.
static func _light_foliage(meshes: Array) -> void:
	for i in meshes.size():
		var m: Mesh = meshes[i]
		if m == null:
			continue
		for s in range(m.get_surface_count()):
			var mat: StandardMaterial3D = m.surface_get_material(s) as StandardMaterial3D
			if mat == null or mat.has_meta(_LIT_META):
				continue
			var key: String = _foliage_key(mat)
			if key.is_empty():
				continue
			mat.set_meta(_LIT_META, true)
			mat.backlight_enabled = true
			mat.backlight = _BACKLIGHT
			var gain: float = float(_CANOPY_GAIN.get(key, 1.0))
			if gain <= 1.0:
				continue
			# albedo_color is authored in sRGB and LINEARISED by the engine (the same trap
			# ProcMaterials documents), so writing ×1.40 straight would land as ×2.2 of
			# actual light — push the intended LINEAR gain back through linear_to_srgb.
			var g: Color = Color(gain, gain, gain).linear_to_srgb()
			var a: Color = mat.albedo_color
			mat.albedo_color = Color(a.r * g.r, a.g * g.g, a.b * g.b, a.a)


## "" when the material is not foliage, else its lookup key: the material name, or the
## atlas texture's file stem when an import drops the name (Leaves_NormalTree_C → …Tree).
static func _foliage_key(mat: StandardMaterial3D) -> String:
	var nm: String = str(mat.resource_name)
	if nm.is_empty():
		var tex: Texture2D = mat.albedo_texture
		nm = tex.resource_path.get_file().get_basename() if tex != null else ""
		if nm.ends_with("_C"):
			nm = nm.left(nm.length() - 2)
	# "Leaves*" AND "Leaf*" — the kit uses both spellings ("Leaves_Pine" material on a
	# "Leaf_Pine_C" atlas), and "Leaves" does NOT begin with "Leaf".
	var foliage: bool = nm.begins_with("Leaves") or nm.begins_with("Leaf") or nm == "Flowers"
	return nm if foliage else ""


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
	vis_end: float = 0.0,
	out_map: Array = []
) -> void:
	if meshes.is_empty() or xforms.is_empty():
		return
	# Optional out_map (destructible trees): index-aligned to `xforms`, each entry
	# {"mmis": Array[MultiMeshInstance3D], "idx": int} — the tile MMIs holding that
	# transform + its per-instance slot, so a caller can later zero-scale ONE instance.
	var want_map: bool = out_map != null and not xforms.is_empty() and out_map.is_empty()
	if want_map:
		out_map.resize(xforms.size())
	var buckets: Dictionary = {}
	var bucket_orig: Dictionary = {}
	for i in xforms.size():
		var xf: Transform3D = xforms[i]
		var gx: int = int(floor((xf.origin.x - WorldBounds.X_MIN) / tile_m))
		var gz: int = int(floor((xf.origin.z - WorldBounds.Z_MIN) / tile_m))
		var key: int = gx * 1000 + gz
		if not buckets.has(key):
			buckets[key] = [] as Array[Transform3D]
			bucket_orig[key] = []
		(buckets[key] as Array[Transform3D]).append(xf)
		(bucket_orig[key] as Array).append(i)
	var keys: Array = buckets.keys()
	keys.sort()  # deterministic node order across machines
	for key in keys:
		var mmis: Array = emit_model_mm(
			parent, "%s_t%d" % [nm, int(key)], meshes, buckets[key], vis_end
		)
		if want_map:
			var origs: Array = bucket_orig[key]
			for j in origs.size():
				out_map[int(origs[j])] = {"mmis": mmis, "idx": j}


## Emit one MultiMeshInstance3D per mesh in `meshes` (suffix _s<i> when several),
## all sharing `xforms`. `vis_end` > 0 applies a visibility range (fade-self) so a
## distant layer culls; 0 = always-on (small clutter layers, one MMI map-wide).
## Returns the created MMIs (destructible trees edit instances later; other callers
## ignore the return).
static func emit_model_mm(
	parent: Node3D, nm: String, meshes: Array, xforms: Array[Transform3D], vis_end: float = 0.0
) -> Array:
	var out: Array = []
	if meshes.is_empty() or xforms.is_empty():
		return out
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
		out.append(mmi)
	return out
