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
var _combo_until_ms: int = 0  # combo window deadline ms (authority-local)
var _combo_last: String = ""  # last skill cast — a combo needs a DIFFERENT skill next
# MOBA targeting indicator (hold-to-aim, release-to-cast for AIMED abilities): while a
# skill key is HELD the AoE circle follows the crosshair ground point in the skill's
# color; releasing casts there. Owner-local render only — never networked.
var _aiming_slot: int = -1
var _indicator: Node3D = null
var _indicator_t: float = 0.0


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
	# Cooldown tick + cast input — owner only. POLL-based (Input.is_action_*) so both
	# real keys AND the harness `hold` verb (engine-state press) drive the aiming.
	if _p.is_multiplayer_authority():
		_tick_cooldowns(delta)
		_poll_cast_input(delta)


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
	_aiming_slot = -1
	_hide_indicator()
	if _p.is_multiplayer_authority():
		_p.skills = {}
	Events.skill_changed.emit()


func _exit_tree() -> void:
	# The indicator lives under the SCENE (not this node) — never leak it past death.
	_hide_indicator()


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


## The hotbar slot currently HOLD-AIMED (1-based; -1 = none) — HUD highlight.
func aiming_slot() -> int:
	return _aiming_slot


# ------------------------------------------------------------ passives + set synergies
## Aggregate passive bonuses from held skills (level-scaled) + archetype SET bonuses.
## Returns {"damage": bonus, "toughness": reduction} (0-based, capped). Cheap (≤5 skills).
func passive_totals() -> Dictionary:
	var dmg: float = 0.0
	var tough: float = 0.0
	var arch_counts: Dictionary = {}
	for sid in _p.skills:
		var lvl: int = int(_p.skills[sid])
		var pas: Dictionary = Settings.SKILL_PASSIVES.get(sid, {})
		if pas.has("stat"):
			var add: float = float(pas["per_level"]) * float(lvl)
			if String(pas["stat"]) == "damage":
				dmg += add
			else:
				tough += add
		var arch: String = Settings.skill_archetype(String(sid))
		if arch != "":
			arch_counts[arch] = int(arch_counts.get(arch, 0)) + 1
	for arch in arch_counts:
		var cnt: int = int(arch_counts[arch])
		var best_dmg: float = 0.0
		var best_tough: float = 0.0
		for tier in Settings.SKILL_SETS.get(arch, []):
			if cnt >= int(tier[0]):
				if String(tier[1]) == "damage":
					best_dmg = float(tier[2])
				else:
					best_tough = float(tier[2])
		dmg += best_dmg
		tough += best_tough
	return {
		"damage": minf(dmg, Settings.SKILL_PASSIVE_DMG_CAP),
		"toughness": minf(tough, Settings.SKILL_PASSIVE_TOUGH_CAP),
	}


## Gun/ability DAMAGE multiplier from limb passives (≥ 1.0). Read by weapon_controller + casts.
func passive_damage_mult() -> float:
	return 1.0 + float(passive_totals()["damage"])


## Incoming-damage REDUCTION fraction from limb passives (0..cap). Read by PlayerGear.
func passive_toughness() -> float:
	return float(passive_totals()["toughness"])


func _tick_cooldowns(delta: float) -> void:
	for sid in _cd.keys():
		var rem: float = float(_cd[sid]) - delta
		if rem <= 0.0:
			_cd.erase(sid)
			Events.skill_cooldown_changed.emit(sid, 0.0)
		else:
			_cd[sid] = rem


## Poll the skill keys each frame: AIMED abilities (meteor / leap slam) enter a
## hold-to-aim state showing the target circle and cast on RELEASE at the aimed
## point; instant abilities cast on press as before.
func _poll_cast_input(delta: float) -> void:
	if _aiming_slot > 0:
		if Input.is_action_pressed("skill_%d" % _aiming_slot):
			_update_indicator(delta)
		else:
			var s: int = _aiming_slot
			_aiming_slot = -1
			_hide_indicator()
			cast(s)
		return
	for slot in range(1, Settings.SKILL_MAX_SLOTS + 1):
		if not Input.is_action_just_pressed("skill_%d" % slot):
			continue
		if slot > _slot_order.size():
			return
		var sid: String = _slot_order[slot - 1]
		if float(_cd.get(sid, 0.0)) > 0.0:
			return
		if _p.has_method("is_downed") and _p.is_downed():
			return
		if _is_aimed(sid):
			_aiming_slot = slot
			_show_indicator(sid)
		else:
			cast(slot)
		return


## Abilities that get a hold-to-aim indicator: ground-circle casts + the breach lane.
func _is_aimed(sid: String) -> bool:
	var ability: String = String(Settings.skill_def(sid)["ability"])
	return ability == "meteor" or ability == "leap_slam" or ability == "breach"


## The AoE radius the indicator previews (matches the server's damage radius).
func _indicator_radius(sid: String) -> float:
	var ability: String = String(Settings.skill_def(sid)["ability"])
	var lvl: int = int(_p.skills.get(sid, 1))
	if ability == "meteor":
		return Settings.SKILL_METEOR_RADIUS + 0.3 * float(lvl - 1)
	return Settings.SKILL_SLAM_RADIUS + 0.4 * float(lvl - 1)


## Build the aim indicator: a target CIRCLE (ring + fill + dot) for ground-point
## casts, or a LANE rectangle + end chevron for the breach charge. Parented to the
## scene (world space); repositioned every frame while aiming.
func _show_indicator(sid: String) -> void:
	_hide_indicator()
	var def: Dictionary = Settings.skill_def(sid)
	var col: Color = def["color"]
	if String(def["ability"]) == "breach":
		_show_lane(col)
		return
	var r: float = _indicator_radius(sid)
	var root := Node3D.new()
	root.name = "SkillAimIndicator"
	# Dark contrast under-ring so the bright ring reads on ANY ground brightness.
	var base := MeshInstance3D.new()
	var bm := TorusMesh.new()
	bm.inner_radius = maxf(0.1, r - 0.26)
	bm.outer_radius = r + 0.1
	base.mesh = bm
	base.material_override = _indicator_mat(Color(0.03, 0.05, 0.07), 0.75)
	base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(base)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = maxf(0.1, r - 0.16)
	tm.outer_radius = r
	ring.mesh = tm
	ring.position.y = 0.02
	ring.material_override = _indicator_mat(col, 0.95)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = 0.02
	disc.mesh = cm
	disc.material_override = _indicator_mat(col, 0.14)
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(disc)
	var dot := MeshInstance3D.new()
	var dm := SphereMesh.new()
	dm.radius = 0.18
	dm.height = 0.36
	dot.mesh = dm
	dot.material_override = _indicator_mat(Color(1, 1, 1), 0.95)
	dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(dot)
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	scene.add_child(root)
	_indicator = root
	_indicator_t = 0.0
	_update_indicator(0.0)


## The BREACH lane: a flat rectangle from the player along the aim direction
## (length = charge range, width = the wall-smash swath) + an end chevron.
func _show_lane(col: Color) -> void:
	var lane_l: float = Settings.SKILL_RAM_RANGE
	var lane_w: float = Settings.SKILL_BREACH_BREAK_R * 2.0
	var root := Node3D.new()
	root.name = "SkillAimIndicator"
	var base := MeshInstance3D.new()
	var bb := BoxMesh.new()
	bb.size = Vector3(lane_w + 0.3, 0.02, lane_l)
	base.mesh = bb
	base.material_override = _indicator_mat(Color(0.03, 0.05, 0.07), 0.6)
	base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	base.position = Vector3(0, 0.0, -lane_l * 0.5)
	root.add_child(base)
	var fill := MeshInstance3D.new()
	var fb := BoxMesh.new()
	fb.size = Vector3(lane_w, 0.02, lane_l)
	fill.mesh = fb
	fill.material_override = _indicator_mat(col, 0.28)
	fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fill.position = Vector3(0, 0.02, -lane_l * 0.5)
	root.add_child(fill)
	# End chevron: a flat "arrowhead" prism pointing down-lane.
	var tip := MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = Vector3(lane_w + 0.6, 0.02, 1.2)
	tip.mesh = pm
	tip.material_override = _indicator_mat(col, 0.9)
	tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tip.rotation_degrees = Vector3(0, 180, 0)
	tip.position = Vector3(0, 0.03, -lane_l - 0.5)
	root.add_child(tip)
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	scene.add_child(root)
	root.set_meta("lane", true)
	_indicator = root
	_indicator_t = 0.0
	_update_indicator(0.0)


func _update_indicator(delta: float) -> void:
	if _indicator == null or not is_instance_valid(_indicator):
		return
	_indicator_t += delta
	if _indicator.has_meta("lane"):
		# Lane: anchored at the player's feet, rotated toward the aim point.
		_indicator.global_position = _p.global_position + Vector3(0, 0.14, 0)
		var dir: Vector3 = _aim_point() - _p.global_position
		dir.y = 0.0
		if dir.length() > 0.05:
			# Yaw that maps the node's local -Z (the lane axis) onto `dir`.
			_indicator.rotation.y = atan2(-dir.x, -dir.z)
		var lpulse: float = 1.0 + 0.04 * sin(_indicator_t * 8.0)
		_indicator.scale = Vector3(lpulse, 1.0, 1.0)
		return
	_indicator.global_position = _aim_point() + Vector3(0, 0.12, 0)
	var pulse: float = 1.0 + 0.05 * sin(_indicator_t * 7.0)
	_indicator.scale = Vector3(pulse, 1.0, pulse)


func _hide_indicator() -> void:
	if _indicator != null and is_instance_valid(_indicator):
		_indicator.queue_free()
	_indicator = null


## Unshaded ALPHA-blend material for the indicator (additive washed out to nothing
## on sunlit ground — the QA lesson; MOBA circles are solid-ish for exactly this).
func _indicator_mat(col: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	return m


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
	# COMBO: a DIFFERENT skill cast within the window is empowered (bigger effect + cd refund).
	var now: int = Time.get_ticks_msec()
	var empowered: bool = now < _combo_until_ms and sid != _combo_last
	_combo_until_ms = now + int(Settings.SKILL_COMBO_WINDOW * 1000.0)
	_combo_last = sid
	# Cooldown shrinks 5%/level; reset locally + trusted (the grenade/consumable economy).
	var cd: float = float(def["cooldown"]) * pow(0.95, lvl - 1)
	if empowered:
		cd *= 1.0 - Settings.SKILL_COMBO_CD_REFUND
	_cd[sid] = cd
	Events.skill_cooldown_changed.emit(sid, float(_cd[sid]))
	Events.skill_cast.emit(sid, lvl)
	if empowered:
		Events.notify.emit(tr("COMBO!"), 0)
	# Damage scale folds in the limb passive (the owner knows its own passives) × combo × evolve.
	var dmg_power: float = passive_damage_mult()
	if empowered:
		dmg_power *= Settings.SKILL_COMBO_MULT
	var evolved: bool = lvl >= int(def["max_level"])
	if evolved:
		dmg_power *= Settings.SKILL_EVOLVE_MULT
	SkillDirector.request_cast(
		sid, lvl, _p.global_position, _aim_point(), _facing(), dmg_power, empowered or evolved
	)


## Forward direction of the body (faces -Z), flat on the ground plane.
func _facing() -> Vector3:
	var f: Vector3 = -_p.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.01 else Vector3.FORWARD


## MOBA-style targeting: the CAMERA CROSSHAIR ray projected into the world — a
## targeted cast lands «в точку куда смотрим». Clamped to SKILL_TARGET_RANGE from
## the caster, then snapped to the ground below; falls back to 8 m ahead when the
## camera is missing (headless/QA).
func _aim_point() -> Vector3:
	var cam := _p.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if cam == null:
		return _p.global_position + _facing() * 8.0
	var space := _p.get_world_3d().direct_space_state
	var from: Vector3 = cam.global_position
	var to: Vector3 = from + (-cam.global_transform.basis.z) * (Settings.SKILL_TARGET_RANGE * 1.6)
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)  # world geometry only
	var hit: Dictionary = space.intersect_ray(q)
	var point: Vector3 = hit.get("position", to) if not hit.is_empty() else to
	# Clamp the PLANAR reach from the caster (a sky-aimed shot stays castable nearby).
	var flat: Vector3 = point - _p.global_position
	flat.y = 0.0
	if flat.length() > Settings.SKILL_TARGET_RANGE:
		point = _p.global_position + flat.normalized() * Settings.SKILL_TARGET_RANGE
		point.y = _p.global_position.y
	# Snap to the ground below the point so ground-target AoEs sit ON the floor.
	var gq := PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * 10.0, point + Vector3.DOWN * 40.0, 1
	)
	var ghit: Dictionary = space.intersect_ray(gq)
	if not ghit.is_empty():
		point = ghit["position"]
	return point


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
