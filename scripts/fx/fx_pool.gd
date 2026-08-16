class_name FXPool
extends Node3D
## Generic pool for the per-shot combat FX (PERF): impact bursts, muzzle flashes,
## muzzle smoke, shell casings. The old path instantiated a fresh node tree (+
## fresh ParticleProcessMaterials/meshes) per shot per peer and queue_freed it —
## a 4-player firefight churned hundreds of nodes per second. Each pooled FX is
## built ONCE (children/materials in its _ready), then parked (invisible,
## process off) and revived via `fire()` on reuse.
##
## Instanced once per raid by main.load_arena (non-headless), like RemoteShotFX.
## Per-peer local visuals only. `static var active` is the call-site handle;
## callers fall back to the legacy instantiate path when no pool exists.

static var active: FXPool = null

const _KINDS := {
	"impact": {"scene": "res://scenes/fx/Impact.tscn", "count": 32},
	"surface_impact": {"script": "res://scripts/fx/fx_sprites.gd", "count": 20},
	"muzzle_flash": {"scene": "res://scenes/fx/MuzzleFlash.tscn", "count": 8},
	"muzzle_smoke": {"script": "res://scripts/fx/muzzle_smoke.gd", "count": 48},
	"shells": {"script": "res://scripts/fx/shell_casings.gd", "count": 64},
	"glass_shatter": {"script": "res://scripts/fx/glass_shatter.gd", "count": 8},
}

# --- surface materials (D4.4) ------------------------------------------------
## WHAT the bullet hit, in FX terms: picked at the call site with `material_of(hit_node)`
## and consumed by FXSprites (the per-material burst). The vocabulary lives HERE, not in
## fx_sprites.gd, so the class dependency stays one-way (FXSprites -> FXPool, like every
## other pooled FX script) — the pool only ever names its FX by PATH, which is what keeps
## a cyclic reference from forming.
const MAT_DEFAULT := 0  # unknown/mixed surface — neutral dust (the pre-D4.4 look, directional)
const MAT_CONCRETE := 1
const MAT_METAL := 2
const MAT_STONE := 3
const MAT_DIRT := 4  # terrain ground — its dust takes the biome's colour
const MAT_GLASS := 5
const MAT_WOOD := 6

## Impacts further than this from the camera are skipped whole (perf; mirrors the
## CHEM_FX_DIST/SKILL_FX_DIST gates, kept local so Settings stays untouched). Generous
## because a sniper's hit MUST still puff at the far end of the shot.
const IMPACT_FX_DIST := 90.0

var _free: Dictionary = {}  # kind -> Array[Node]
var _busy: Dictionary = {}  # kind -> Array[Node], oldest first (steal order)

static var _fallbacks: Dictionary = {}  # kind -> the lazily-loaded no-pool fallback resource
static var _headless: int = -1  # -1 unknown / 0 no / 1 yes (the display server never changes)


func _enter_tree() -> void:
	active = self


func _exit_tree() -> void:
	if active == self:
		active = null


func _ready() -> void:
	for kind in _KINDS:
		_free[kind] = []
		_busy[kind] = []
		var def: Dictionary = _KINDS[kind]
		for _i in range(int(def["count"])):
			var node := _make(def)
			if node == null:
				break
			node.set_meta("fx_kind", kind)
			if "pooled" in node:
				node.set("pooled", true)
			add_child(node)
			_park(node)
			(_free[kind] as Array).append(node)


func _make(def: Dictionary) -> Node:
	if def.has("scene") and ResourceLoader.exists(String(def["scene"])):
		return (load(String(def["scene"])) as PackedScene).instantiate()
	if def.has("script") and ResourceLoader.exists(String(def["script"])):
		var n := Node3D.new()
		n.set_script(load(String(def["script"])))
		return n
	return null


func _park(node: Node) -> void:
	if node is Node3D:
		(node as Node3D).visible = false
	node.set_process(false)


## Take an FX from the pool (stealing the OLDEST in-flight one when empty — a
## near-dead burst vanishing a beat early is invisible under sustained fire).
## The caller positions/configures it, then calls its `fire()`.
func acquire(kind: String) -> Node:
	var free_list: Array = _free.get(kind, [])
	var busy_list: Array = _busy.get(kind, [])
	var node: Node = null
	if not free_list.is_empty():
		node = free_list.pop_back()
	elif not busy_list.is_empty():
		node = busy_list.pop_front()
		_park(node)
	if node != null:
		busy_list.append(node)
	return node


## Call-site helper: take from the active pool, else instantiate the legacy
## fallback (PackedScene or GDScript) under `host`. Callers then position/
## configure the node and call its `fire()`.
static func acquire_or_new(kind: String, fallback: Variant, host: Node) -> Node:
	if active != null:
		var pooled_node := active.acquire(kind)
		if pooled_node != null:
			return pooled_node
	if host == null:
		return null
	if fallback is PackedScene:
		var inst := (fallback as PackedScene).instantiate()
		host.add_child(inst)
		return inst
	if fallback is GDScript:
		var scripted: Node = (fallback as GDScript).new()
		host.add_child(scripted)
		return scripted
	return null


## An FX finished (its own _process end-of-life calls this when pooled).
func release(node: Node) -> void:
	var kind := String(node.get_meta("fx_kind", ""))
	if kind == "":
		return
	_park(node)
	(_busy.get(kind, []) as Array).erase(node)
	var free_list: Array = _free.get(kind, [])
	if not free_list.has(node):
		free_list.append(node)


# --- bullet impacts (D4.4) ---------------------------------------------------


## THE call-site entry point for a bullet impact. `pos`/`normal` come from the shot's
## raycast; `material` is a MAT_* (resolve it with `material_of(hit_node)`); `incoming` is
## the shot direction (muzzle -> hit), which reflects the spark cone off the surface when
## the caller knows it. A WORLD hit gets the per-material FXSprites burst (cone along the
## normal + material dressing + a mark projected INTO the surface); an ENEMY hit keeps the
## tuned robot burst (Impact) exactly as it was. Returns the FX node, or null when skipped
## (headless / beyond IMPACT_FX_DIST / no pool and no host).
## BACK-COMPAT: everything past `normal` defaults, so a call site that knows nothing about
## materials still gets the old world burst — only directional instead of a 180-degree ball.
static func spawn_impact(
	host: Node,
	pos: Vector3,
	normal: Vector3 = Vector3.ZERO,
	is_enemy: bool = false,
	material: int = MAT_DEFAULT,
	incoming: Vector3 = Vector3.ZERO,
	weak: bool = false
) -> Node:
	if _is_headless() or not _within_fx_range(pos, host):
		return null
	var fx: Node = null
	# D4.5: a WEAK-POINT hit leaves the machine burst and takes the FXSprites path, because
	# that is where the gold ring lives. The robo-burst has no ring and cannot grow one
	# without giving every ordinary chassis hit the same cost.
	if is_enemy and not weak:
		fx = acquire_or_new("impact", _fallback_for("impact"), host)
		if fx == null:
			return null
		# Duck-typed: naming Impact/FXSprites here would point the class dependency back at
		# scripts that already reference FXPool.
		if fx.has_method("set_enemy_hit"):
			fx.call("set_enemy_hit", true)
		if fx.has_method("set_surface_normal"):
			fx.call("set_surface_normal", normal)
	else:
		fx = acquire_or_new("surface_impact", _fallback_for("surface_impact"), host)
		if fx == null:
			return null
		if fx.has_method("setup"):
			fx.call("setup", normal, material, incoming, weak)
	if fx is Node3D:
		# Identity basis on purpose: the emitters' cone direction is a WORLD vector, so any
		# rotation inherited from a previous use would tilt the spray.
		(fx as Node3D).global_transform = Transform3D(Basis(), pos)
	# Position first — a fired burst reads its own global_position (the ground biome tint).
	if fx.has_method("fire"):
		fx.call("fire")
	return fx


## Resolve WHAT was hit into a MAT_*. Duck-typed on purpose (see spawn_impact): the world
## classes already reference FXPool, so this file must not name them back. Anything
## unrecognised falls through to the neutral MAT_DEFAULT dust.
static func material_of(node: Node) -> int:
	if node == null:
		return MAT_DEFAULT
	if "material_kind" in node:  # BreakableChunk — carries the Settings.CHUNK_KIND_*
		return from_chunk_kind(int(node.get("material_kind")))
	if "pane_size" in node:  # BreakableGlass window pane
		return MAT_GLASS
	var n := String(node.name)
	if n == "TreeTrunks":  # the one merged trunk body (procedural_flora)
		return MAT_WOOD
	if n == "Terrain":  # the ground body (procedural_terrain)
		return MAT_DIRT
	return MAT_DEFAULT


## Settings.CHUNK_KIND_* (the destruction system's material) -> MAT_*. Kept as ifs, not a
## match: match patterns want constants and these live on an autoload.
static func from_chunk_kind(kind: int) -> int:
	if kind == Settings.CHUNK_KIND_METAL:
		return MAT_METAL
	if kind == Settings.CHUNK_KIND_STONE:
		return MAT_STONE
	return MAT_CONCRETE


## The no-pool fallback resource for a kind, taken from the SAME _KINDS table that seeds the
## pool (never a second copy of the path) and cached — it must not re-load per shot.
static func _fallback_for(kind: String) -> Resource:
	var cached: Variant = _fallbacks.get(kind)
	if cached is Resource:
		return cached
	var def: Dictionary = _KINDS.get(kind, {})
	var path: String = String(def.get("script", def.get("scene", "")))
	if path == "" or not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	_fallbacks[kind] = res
	return res


## Distance gate against the LOCAL camera. Unknown viewport/camera => allow (a missing
## camera is a boot frame, not a reason to swallow combat feedback).
static func _within_fx_range(pos: Vector3, host: Node) -> bool:
	var probe: Node = active if active != null else host
	if probe == null or not probe.is_inside_tree():
		return true
	var vp := probe.get_viewport()
	if vp == null:
		return true
	var cam := vp.get_camera_3d()
	if cam == null:
		return true
	return cam.global_position.distance_squared_to(pos) <= IMPACT_FX_DIST * IMPACT_FX_DIST


## A dedicated server draws nothing — impacts there are pure allocation (the pool itself is
## only spawned non-headless, but the legacy fallback path would still build nodes).
static func _is_headless() -> bool:
	if _headless < 0:
		_headless = 1 if DisplayServer.get_name() == "headless" else 0
	return _headless == 1
