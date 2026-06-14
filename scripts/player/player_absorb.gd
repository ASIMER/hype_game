class_name PlayerAbsorb
extends Node
## Absorption component of the PLAYER (the "Absorb" child in Player.tscn). Keeps the player's
## absorb logic off the god file (player.gd sits at the gdlint max-file-lines ceiling) — the only
## thing ON the player is the replicated `absorbed` Dictionary (so the SceneReplicationConfig can
## sync it). This node owns:
##   • the trophy CLUSTER on the back — rebuilt on EVERY peer whenever the replicated `absorbed`
##     changes (or the body was rebuilt), so co-op peers see the identical cluster (cosmetics
##     pattern), attached under the animated player body so it rides PlayerAnimator;
##   • the local CHARGE meter (authority-local) + the BURST input (Q), routed server-side via
##     AbsorbDirector (the grenade pattern). AbsorbDirector.gain() feeds parts in on the owner.

var _p: Node3D = null  # the owning player (duck-typed: absorbed/global_position/is_downed live there)
var _charge: float = 0.0  # 0..ABSORB_CHARGE_MAX (authority-local; HUD + burst gate)
var _built: String = "NONE"  # signature of the `absorbed` the cluster was last built from
var _cluster: Node3D = null  # the current AbsorbCluster (re-welded if the body rebuilds)
var _headless: bool = false


func _ready() -> void:
	_p = get_parent() as Node3D
	_headless = DisplayServer.get_name() == "headless"


func _process(_delta: float) -> void:
	# Rebuild the back cluster on EVERY peer when the replicated dict changes, or after the body
	# was rebuilt (which frees the old cluster). Skipped on a dedicated headless server.
	if _p == null or _headless:
		return
	var sig: String = str(_p.absorbed)
	if sig != _built or not is_instance_valid(_cluster):
		_rebuild(sig)


# ------------------------------------------------------------ accumulation (owner)
## Add one signature part of `enemy_id` (capped per type) + charge the meter. Called on the
## OWNER's machine by AbsorbDirector so the owner mutates its OWN replicated `absorbed` dict.
func gain(enemy_id: String) -> void:
	if not _p.is_multiplayer_authority():
		return
	var def: Dictionary = Settings.ABSORB_PARTS.get(enemy_id, Settings.ABSORB_FALLBACK)
	var cap: int = int(def["cap"])
	var d: Dictionary = _p.absorbed.duplicate()
	var cur: int = int(d.get(enemy_id, 0))
	if cur < cap:
		d[enemy_id] = cur + 1
		_p.absorbed = d  # owner-authoritative → replicates to every peer
	# A capped type still feeds the meter (the kill counts even if the back is "full" of it).
	_charge = minf(_charge + Settings.ABSORB_CHARGE_PER_PART, Settings.ABSORB_CHARGE_MAX)
	Events.absorb_charge_changed.emit(_charge, Settings.ABSORB_CHARGE_MAX)


## Wipe the trophy + meter (per-raid reset, called from PlayerGear.apply_loadout on the owner).
func reset() -> void:
	_charge = 0.0
	if _p.is_multiplayer_authority():
		_p.absorbed = {}
	Events.absorb_charge_changed.emit(0.0, Settings.ABSORB_CHARGE_MAX)


func charge() -> float:
	return _charge


# ------------------------------------------------------------ burst (owner)
## Burst cast (Q) — owner only, event-based (the synthetic-input path the harness drives). When
## the meter is full, reset it locally (trusted like the grenade/consumable economy) and ask the
## server to apply the AoE.
func _unhandled_input(event: InputEvent) -> void:
	if _p == null or not _p.is_multiplayer_authority():
		return
	if not event.is_action_pressed("absorb_burst"):
		return
	if _charge < Settings.ABSORB_CHARGE_MAX:
		return
	if _p.has_method("is_downed") and _p.is_downed():
		return
	_charge = 0.0
	Events.absorb_charge_changed.emit(0.0, Settings.ABSORB_CHARGE_MAX)
	AbsorbDirector.request_burst(_p.global_position)


# ------------------------------------------------------------ cluster (every peer)
## The animated player body (model_root's first child) — the cluster mounts under it so it rides
## the PlayerAnimator. Null while the body hasn't been built yet (retry next frame).
func _mount() -> Node3D:
	var mr: Node = _p.get_node_or_null("ModelRoot")
	if mr == null or mr.get_child_count() == 0:
		return null
	var body: Node = mr.get_child(0)
	return body as Node3D if body is Node3D else null


func _rebuild(sig: String) -> void:
	var mount: Node3D = _mount()
	if mount == null:
		return  # body not ready yet — _built stays so we retry next frame
	if _cluster != null and is_instance_valid(_cluster):
		_cluster.queue_free()
	_cluster = ProceduralAbsorbed.build_absorbed_cluster(_p.absorbed, str(_p.name).to_int())
	mount.add_child(_cluster)
	_built = sig
