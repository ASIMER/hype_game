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
	"muzzle_flash": {"scene": "res://scenes/fx/MuzzleFlash.tscn", "count": 8},
	"muzzle_smoke": {"script": "res://scripts/fx/muzzle_smoke.gd", "count": 48},
	"shells": {"script": "res://scripts/fx/shell_casings.gd", "count": 64},
	"glass_shatter": {"script": "res://scripts/fx/glass_shatter.gd", "count": 8},
}

var _free: Dictionary = {}  # kind -> Array[Node]
var _busy: Dictionary = {}  # kind -> Array[Node], oldest first (steal order)


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
