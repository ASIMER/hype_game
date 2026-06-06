extends Node
class_name RemoteShotFX
## Spawns combat FX (muzzle flash, ballistic tracer chain, impact burst) for shots
## fired by OTHER players. A peer's own weapon spawns its FX locally via its `fired`
## signal; teammates never saw it because the hitscan + FX were purely local. The
## server now broadcasts every shot (NetworkManager.broadcast_shot → Events.remote_shot)
## and this node renders the remote shot in the world so the whole squad sees combat.
##
## Instanced once per raid by main.gd (non-headless). Mirrors the spawn logic in
## weapon.gd so the look is identical regardless of who fired.

const _MUZZLE_FLASH_SCENE := "res://scenes/fx/MuzzleFlash.tscn"
const _TRACER_SCENE := "res://scenes/fx/Tracer.tscn"
const _IMPACT_SCENE := "res://scenes/fx/Impact.tscn"

var _muzzle_flash_ps: PackedScene
var _tracer_ps: PackedScene
var _impact_ps: PackedScene

func _ready() -> void:
	if ResourceLoader.exists(_MUZZLE_FLASH_SCENE):
		_muzzle_flash_ps = load(_MUZZLE_FLASH_SCENE)
	if ResourceLoader.exists(_TRACER_SCENE):
		_tracer_ps = load(_TRACER_SCENE)
	if ResourceLoader.exists(_IMPACT_SCENE):
		_impact_ps = load(_IMPACT_SCENE)
	if not Events.remote_shot.is_connected(_on_remote_shot):
		Events.remote_shot.connect(_on_remote_shot)

func _on_remote_shot(muzzle: Vector3, hit_point: Vector3, arc: PackedVector3Array, enemy_hit: bool, normal: Vector3) -> void:
	var host := _fx_host()
	if host == null:
		return
	# Muzzle flash at the teammate's barrel.
	if _muzzle_flash_ps:
		var mf := _muzzle_flash_ps.instantiate()
		host.add_child(mf)
		if mf is Node3D:
			(mf as Node3D).global_position = muzzle
	# Tracer chain following the ballistic arc (anchored at the real muzzle).
	if _tracer_ps and arc.size() >= 2:
		for i in range(arc.size() - 1):
			var a: Vector3 = muzzle if i == 0 else arc[i]
			var b: Vector3 = arc[i + 1]
			var tr := _tracer_ps.instantiate()
			if tr is Tracer:
				(tr as Tracer).setup(a, b)
			host.add_child(tr)
	# Impact burst at the hit point (sparks for enemies, dust for the world).
	if _impact_ps:
		var im := _impact_ps.instantiate()
		if im is Impact:
			(im as Impact).set_enemy_hit(enemy_hit)
			(im as Impact).set_surface_normal(normal)
		host.add_child(im)
		if im is Node3D:
			(im as Node3D).global_position = hit_point

func _fx_host() -> Node:
	var tree := get_tree()
	if tree and tree.current_scene:
		return tree.current_scene
	return get_parent()
