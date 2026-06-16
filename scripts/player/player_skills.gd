class_name PlayerSkills
extends Node
## Mutant-Harvest SKILLS component of the PLAYER (the "Skills" child in Player.tscn). Keeps the
## skill logic off the god file (player.gd is at the gdlint max-file-lines ceiling) — the only
## thing ON the player is the replicated `skills` Dictionary {skill_id: level} (so the
## SceneReplicationConfig syncs it). This node owns:
##   • acquisition (E-pickup → acquire): max 5 distinct skills, a duplicate UPGRADES, a 6th
##     distinct is refused; per-raid; the owner mutates its OWN replicated `skills` dict so every
##     peer rebuilds the identical visible LIMBS (cosmetics pattern);
##   • the visible LIMBS on the body — rebuilt on EVERY peer when `skills` changes (or the body
##     was rebuilt), mounted under the animated body so they ride PlayerAnimator;
##   • the active-ability hotbar input (5 keys → cast slot) + authority-local cooldowns, routed
##     server-side via SkillDirector (the grenade pattern).

const _LIMBS := preload("res://scripts/visual/procedural_absorbed.gd")

var _p: Node3D = null  # owning player (duck-typed: skills/global_position/is_downed live there)
var _built: String = "NONE"  # signature of the `skills` the limbs were last built from
var _limbs: Node3D = null  # the current limb assembly (re-welded if the body rebuilds)
var _headless: bool = false
var _slot_order: Array[String] = []  # acquisition order → hotbar slot index (authority-local)
var _cd: Dictionary = {}  # skill_id -> cooldown seconds remaining (authority-local)


func _ready() -> void:
	_p = get_parent() as Node3D
	_headless = DisplayServer.get_name() == "headless"


func _process(delta: float) -> void:
	if _p == null:
		return
	# Rebuild the limbs on EVERY peer when the replicated dict changes / the body was rebuilt.
	if not _headless:
		var sig: String = str(_p.skills)
		if sig != _built or not is_instance_valid(_limbs):
			_rebuild(sig)
	# Cooldown tick — owner only.
	if _p.is_multiplayer_authority():
		_tick_cooldowns(delta)


# ------------------------------------------------------------ acquisition (owner)
## Pick up a body-part skill: new slot (≤5), or UPGRADE a held one, or REFUSE a 6th distinct.
## Runs on the OWNER's machine (SkillDirector routes it there) so the owner mutates its own
## replicated `skills` dict.
func acquire(skill_id: String) -> void:
	if not _p.is_multiplayer_authority() or skill_id == "":
		return
	var def: Dictionary = Settings.skill_def(skill_id)
	var cap: int = int(def["max_level"])
	var name_key: String = String(def["name_key"])
	var d: Dictionary = _p.skills.duplicate()
	var lvl: int
	if d.has(skill_id):
		lvl = mini(int(d[skill_id]) + 1, cap)
		d[skill_id] = lvl
	elif d.size() >= Settings.SKILL_MAX_SLOTS:
		Events.notify.emit(tr("Skill panel full — pick up a duplicate to upgrade"), 0)
		return
	else:
		lvl = 1
		d[skill_id] = 1
		_slot_order.append(skill_id)
	_p.skills = d  # owner-authoritative → replicates to every peer
	Events.notify.emit(tr("Skill: %s (lvl %d)") % [tr(name_key), lvl], 1)
	Events.skill_acquired.emit(skill_id, lvl)
	Events.skill_changed.emit()


## Wipe all skills + cooldowns (per-raid reset, called from PlayerGear.apply_loadout on the owner).
func reset() -> void:
	_cd.clear()
	_slot_order.clear()
	if _p.is_multiplayer_authority():
		_p.skills = {}
	Events.skill_changed.emit()


# ------------------------------------------------------------ hotbar / casting (owner)
## Slot ids in acquisition order (for the HUD hotbar + the cast input mapping).
func slot_order() -> Array:
	return _slot_order


## Cooldown fraction 0..1 (1 = fully on cooldown) for the HUD radial.
func cooldown_frac(skill_id: String) -> float:
	var rem: float = float(_cd.get(skill_id, 0.0))
	if rem <= 0.0:
		return 0.0
	var def: Dictionary = Settings.skill_def(skill_id)
	var total: float = float(def["cooldown"])
	return clampf(rem / maxf(0.01, total), 0.0, 1.0)


## Cooldown seconds REMAINING (0 = ready) for the HUD countdown text.
func cooldown_remaining(skill_id: String) -> float:
	return maxf(0.0, float(_cd.get(skill_id, 0.0)))


func _tick_cooldowns(delta: float) -> void:
	for sid in _cd.keys():
		var rem: float = float(_cd[sid]) - delta
		if rem <= 0.0:
			_cd.erase(sid)
			Events.skill_cooldown_changed.emit(sid, 0.0)
		else:
			_cd[sid] = rem


## Cast the skill in hotbar `slot` (1..5) — owner only, event-based (the harness `act` path).
func _unhandled_input(event: InputEvent) -> void:
	if _p == null or not _p.is_multiplayer_authority():
		return
	for slot in range(1, Settings.SKILL_MAX_SLOTS + 1):
		if event.is_action_pressed("skill_%d" % slot):
			cast(slot)
			return


func cast(slot: int) -> void:
	if slot < 1 or slot > _slot_order.size():
		return
	var sid: String = _slot_order[slot - 1]
	if _p.has_method("is_downed") and _p.is_downed():
		return
	if float(_cd.get(sid, 0.0)) > 0.0:
		return
	var lvl: int = int(_p.skills.get(sid, 1))
	var def: Dictionary = Settings.skill_def(sid)
	# Cooldown shrinks 5%/level; reset locally + trusted (the grenade/consumable economy).
	_cd[sid] = float(def["cooldown"]) * pow(0.95, lvl - 1)
	Events.skill_cooldown_changed.emit(sid, float(_cd[sid]))
	Events.skill_cast.emit(sid, lvl)
	SkillDirector.request_cast(sid, lvl, _p.global_position, _aim_point(), _facing())


## Forward direction of the body (faces -Z), flat on the ground plane.
func _facing() -> Vector3:
	var f: Vector3 = -_p.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.01 else Vector3.FORWARD


## A ground-aim point in front of the player (Phase-5 abilities refine this with the camera ray).
func _aim_point() -> Vector3:
	return _p.global_position + _facing() * 8.0


# ------------------------------------------------------------ limbs (every peer)
## The animated player body (model_root's first child) — limbs mount under it so they ride the
## PlayerAnimator. Null while the body hasn't been built yet (retry next frame).
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
	if _limbs != null and is_instance_valid(_limbs):
		_limbs.queue_free()
	_limbs = _LIMBS.build_limbs(_p.skills, str(_p.name).to_int())
	mount.add_child(_limbs)
	_built = sig
