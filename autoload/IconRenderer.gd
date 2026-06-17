extends Node
## Renders a logical id's 3D model to a flat transparent texture for inventory icons
## (and doubles as the QA inspection tool — a clean, isolated 3/4 hero shot of any
## model). One shared off-screen SubViewport + ortho camera + lights; render-once,
## cache by id. On headless (dedicated server) there is no viewport → returns null
## and the UI falls back to its colored box.

const ICON_SIZE := 256
## 3/4 hero direction the camera sits along, looking at the model centre. Models are
## authored facing -Z, so a -Z (front) + right + slightly-above offset shows the
## "face" + silhouette + legs (a steep top-down angle hides ground creatures' legs).
const VIEW_DIR := Vector3(0.8, 0.42, -1.1)

var _cache: Dictionary = {}  # id -> ImageTexture
var _busy: bool = false  # serialize captures (the SubViewport is shared)
var _vp: SubViewport = null
var _cam: Camera3D = null
var _holder: Node3D = null
var last_debug: Dictionary = {}  # framing diagnostics for QA


func _ready() -> void:
	# No rendering on a headless dedicated server — icons are never shown there.
	if DisplayServer.get_name() == "headless":
		return
	_vp = SubViewport.new()
	_vp.size = Vector2i(ICON_SIZE, ICON_SIZE)
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.msaa_3d = Viewport.MSAA_4X
	add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR  # transparent icon background
	# Bright flat ambient so low-metallic parts read in full colour (a sky-based
	# ambient needs a radiance bake that a single force_draw doesn't complete).
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.54, 0.62)
	env.ambient_light_energy = 0.55
	var world := World3D.new()
	world.environment = env
	_vp.world_3d = world

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48, -128, 0)
	key.light_energy = 1.1
	_vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, 60, 0)
	fill.light_energy = 0.35
	_vp.add_child(fill)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_vp.add_child(_cam)
	_cam.current = true
	_cam.make_current()

	_holder = Node3D.new()
	_vp.add_child(_holder)

	# Pre-render every icon-less id into the cache so the UI's synchronous get_icon
	# is a cache hit. Deferred + awaited because the first SubViewport capture needs
	# real frames to pass.
	_prewarm.call_deferred()


func _prewarm() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	for id in AssetRegistry.CATALOG:
		var entry: Dictionary = AssetRegistry.CATALOG[id]
		if String(entry.get("icon", "")) == "":
			await render_now(id)
	# Also prewarm ids that have a ProceduralModels builder but no CATALOG row (gadgets,
	# utility grenades, energy cores) — without this get_icon returns null -> a grey UI box.
	var builder_ids: Array = (
		ProceduralModels.GADGET_BUILDERS
		+ ProceduralModels.ITEM_BUILDERS
		+ ProceduralModels.GEAR_BUILDERS
	)
	for id in builder_ids:
		if not _cache.has(id):
			await render_now(id)


## SYNC: cached rendered icon for `id`, or null (UI fallback to colored box). The
## cache is filled by _prewarm / render_now.
func render_icon(id: String) -> Texture2D:
	return _cache.get(id, null)


## ASYNC: renders `id`'s model to a texture (awaits a real frame — the SubViewport's
## first capture is empty otherwise), caches and returns it. null on headless/failure.
func render_now(id: String) -> Texture2D:
	if _cache.has(id):
		return _cache[id]
	if _vp == null:
		return null
	var model: Node3D
	if id.begins_with("bodypart_"):
		# Mutant-Harvest limb: not an AssetRegistry id — build the recognizable arm/leg directly.
		var sdef: Dictionary = Settings.skill_def(id.substr(9))
		model = ProceduralAbsorbed.build_limb_model(id.substr(9), sdef["color"])
	else:
		model = AssetRegistry.get_model(id)
	if model == null:
		return null
	return await _capture(id, model)


## Serialized off-screen capture of `node` into a texture cached by `key`. The SubViewport
## + holder are SHARED, so concurrent callers must NOT have two models in the holder when
## it captures (that composites them into one icon). We gate on _busy and clear the holder
## so each capture renders exactly one model. Frees the node.
func _capture(key: String, node: Node3D) -> Texture2D:
	# Wait for any in-flight capture to finish before touching the shared viewport.
	while _busy:
		await get_tree().process_frame
	if _cache.has(key):  # a concurrent caller may have filled it while we waited
		node.queue_free()
		return _cache[key]
	_busy = true
	# Clean slate: free any leftover so only `node` is in frame.
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	_holder.add_child(node)
	_frame(node)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	_holder.remove_child(node)
	node.queue_free()
	_busy = false
	if img == null:
		return null
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## Render an arbitrary prebuilt Node3D to a texture, cached by `key` (for previews whose
## model isn't a CATALOG id, e.g. cosmetic parts). Frees the node. null on headless/failure.
func render_node(key: String, node: Node3D) -> Texture2D:
	if _cache.has(key):
		node.queue_free()
		return _cache[key]
	if _vp == null:
		node.queue_free()
		return null
	return await _capture(key, node)


## Render a character cosmetic variant preview (cached by category+variant+paint). For
## "paint" this renders the whole body in that scheme; otherwise just that part.
func render_cosmetic(category: String, variant_id: String, paint_id: String) -> Texture2D:
	var key := "cos:%s:%s:%s" % [category, variant_id, paint_id]
	if _cache.has(key):
		return _cache[key]
	return await render_node(key, ProceduralPlayer.build_part(category, variant_id, paint_id))


func has_cached(id: String) -> bool:
	return _cache.has(id)


func clear_cache() -> void:
	_cache.clear()


# ----------------------------------------------------------------- framing
## Fits the orthographic camera to the model's combined AABB from VIEW_DIR.
func _frame(model: Node3D) -> void:
	var aabb := _aabb_of(model)
	if aabb.size == Vector3.ZERO:
		aabb = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	var center := aabb.position + aabb.size * 0.5
	# Diagonal of the bounding box guarantees the model fits from any view angle.
	var diag := aabb.size.length()
	var dir := VIEW_DIR.normalized()
	_cam.global_transform = Transform3D(Basis.IDENTITY, center + dir * (diag * 2.0 + 2.0))
	_cam.look_at(center, Vector3.UP)
	_cam.size = maxf(diag * 1.35, 0.5)
	_cam.near = 0.05
	_cam.far = diag * 6.0 + 20.0
	last_debug = {"aabb_pos": aabb.position, "aabb_size": aabb.size, "ortho": _cam.size}


## Combined AABB (in `model`-local space) over all MeshInstance3D descendants.
func _aabb_of(model: Node3D) -> AABB:
	var out := AABB()
	var have := false
	var stack: Array = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var local := model.global_transform.affine_inverse() * mi.global_transform
			var box := local * mi.mesh.get_aabb()
			if have:
				out = out.merge(box)
			else:
				out = box
				have = true
		for c in n.get_children():
			stack.append(c)
	return out
