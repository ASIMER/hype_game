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
const _MUZZLE_SMOKE_SCRIPT := "res://scripts/fx/muzzle_smoke.gd"
const _SHELL_CASINGS_SCRIPT := "res://scripts/fx/shell_casings.gd"

var _muzzle_flash_ps: PackedScene
var _tracer_ps: PackedScene
var _impact_ps: PackedScene
var _muzzle_smoke_script: GDScript
var _shell_script: GDScript


func _ready() -> void:
	if ResourceLoader.exists(_MUZZLE_FLASH_SCENE):
		_muzzle_flash_ps = load(_MUZZLE_FLASH_SCENE)
	if ResourceLoader.exists(_TRACER_SCENE):
		_tracer_ps = load(_TRACER_SCENE)
	if ResourceLoader.exists(_IMPACT_SCENE):
		_impact_ps = load(_IMPACT_SCENE)
	if ResourceLoader.exists(_MUZZLE_SMOKE_SCRIPT):
		_muzzle_smoke_script = load(_MUZZLE_SMOKE_SCRIPT)
	if ResourceLoader.exists(_SHELL_CASINGS_SCRIPT):
		_shell_script = load(_SHELL_CASINGS_SCRIPT)
	if not Events.remote_shot.is_connected(_on_remote_shot):
		Events.remote_shot.connect(_on_remote_shot)


func _on_remote_shot(
	muzzle: Vector3,
	hit_point: Vector3,
	arc: PackedVector3Array,
	enemy_hit: bool,
	normal: Vector3,
	wid: String = ""
) -> void:
	var host := _fx_host()
	if host == null:
		return
	# v0.5-B3: teammates' gunfire was VISUAL-ONLY since the co-op FX pass — squad fire
	# was mute. One positional crack per broadcast, per-class via the shot's weapon id.
	AudioManager.play_remote_shot(muzzle, wid)
	# Muzzle flash at the teammate's barrel (pooled when the FXPool exists — PERF).
	var mf := FXPool.acquire_or_new("muzzle_flash", _muzzle_flash_ps, host)
	if mf != null:
		if mf is Node3D:
			(mf as Node3D).global_position = muzzle
		if mf.has_method("fire"):
			mf.call("fire")
	# Muzzle smoke + a few shells so a teammate's gun also reads as a real gun (no orientation
	# in the broadcast → shells eject with the FX default direction; close enough for remotes).
	var sm := FXPool.acquire_or_new("muzzle_smoke", _muzzle_smoke_script, host)
	if sm != null:
		if sm is Node3D:
			(sm as Node3D).global_position = muzzle
		if sm.has_method("fire"):
			sm.call("fire")
	var sc := FXPool.acquire_or_new("shells", _shell_script, host)
	if sc != null:
		if sc is Node3D:
			(sc as Node3D).global_position = muzzle
		if sc.has_method("fire"):
			sc.call("fire")
	# Tracer following the ballistic arc, anchored at the real muzzle (see weapon.gd for why
	# this is the pooled streak and not TracerPool); legacy per-segment nodes as fallback.
	if FXPool.spawn_tracer(host, arc, muzzle) == null and _tracer_ps and arc.size() >= 2:
		for i in range(arc.size() - 1):
			var a: Vector3 = muzzle if i == 0 else arc[i]
			var b: Vector3 = arc[i + 1]
			var tr := _tracer_ps.instantiate()
			if tr is Tracer:
				(tr as Tracer).setup(a, b)
			host.add_child(tr)
	# Impact burst at the hit point (sparks for enemies, dust for the world).
	# The shot broadcast carries no surface material — only the hit point, normal and the
	# enemy flag — so a teammate's world hits get the neutral directional dust rather than a
	# guess. Adding one int to broadcast_shot would give full parity; it is not worth a
	# net-format change for a debris colour.
	FXPool.spawn_impact(
		host, hit_point, normal, enemy_hit, FXPool.MAT_DEFAULT, (hit_point - muzzle).normalized()
	)


func _fx_host() -> Node:
	var tree := get_tree()
	if tree and tree.current_scene:
		return tree.current_scene
	return get_parent()
