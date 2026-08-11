class_name BossBrain
extends Node
## M2 BOSS FIGHT — turns the boss from «толстый крип» into a staged encounter.
## Runtime component added by robot_enemy._ready ON EVERY PEER when the enemy is
## boss-class (deterministic child name → node-path rpc works). Server drives the
## phase logic + special attacks; telegraphs/FX broadcast to all peers.
##
## Phases by HP ratio:
##   P1 (>0.66)  — baseline behavior (the existing chase/shoot).
##   P2 (≤0.66)  — CHARGE: a telegraphed lane (0.9 s) → the boss dashes down it,
##                 SMASHING breakable walls (BreakableChunk) + an arrival slam.
##   P3 (≤0.33)  — ENRAGE: red flare + periodic expanding SHOCKWAVE rings
##                 (telegraph → ring sweeps outward, damaging on pass).
## Death: multi-stage secondary explosions + a heavy kill beat.
## Also attaches the BossBarkDriver (talking boss) when its script exists.

const CHARGE_COOLDOWN := 9.0
const CHARGE_TELEGRAPH := 0.9
const CHARGE_SPEED := 26.0
const CHARGE_BREAK_R := 1.6
const CHARGE_DAMAGE := 30.0
const RING_COOLDOWN := 6.0
const RING_TELEGRAPH := 0.8
const RING_MAX_R := 12.0
const RING_SWEEP_TIME := 1.1
const RING_DAMAGE := 22.0
const RING_BAND := 1.6  # hit window thickness around the sweeping radius

var _boss: Node3D = null
var _health: Node = null
var _phase: int = 1
var _charge_cd: float = 4.0
var _ring_cd: float = 3.0
var _charging: bool = false
var _dead: bool = false
# Players already hit by the CURRENT charge (name → true): the lane sweeps in
# ~1.2 m steps, so without this one charge would tick a standing player 5+ times.
var _charge_hit: Dictionary = {}


func _ready() -> void:
	_boss = get_parent() as Node3D
	if _boss == null:
		return
	_health = _boss.get_node_or_null("Health")
	# Talking boss (lane B): attach the bark driver if the script shipped. It must be a
	# child of the BOSS BODY (it reads get_parent() as its subject), not of this brain.
	if ResourceLoader.exists("res://scripts/enemies/boss_bark_driver.gd"):
		var drv_script: GDScript = load("res://scripts/enemies/boss_bark_driver.gd")
		var drv: Node = drv_script.new()
		drv.name = "BarkDriver"
		_boss.add_child(drv)
	# Intro beat on every peer (render/audio local).
	if DisplayServer.get_name() != "headless":
		Events.screen_shake.emit(0.5)
		_dress_boss()
	Events.notify.emit(tr("⚠ BOSS ON THE FIELD — REAPER"), 2)


## Render-only boss distinction (every peer): a bigger silhouette + a slowly
## spinning emissive CROWN ring + a deep-red core light. The crown scales/spins
## on the MODEL child, not ModelRoot — the spawn-assemble tween owns ModelRoot.
func _dress_boss() -> void:
	var mr := _boss.get_node_or_null("ModelRoot") as Node3D
	if mr == null:
		return
	if mr.get_child_count() > 0:
		var model := mr.get_child(0) as Node3D
		if model != null:
			model.scale *= 1.3
	var crown := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.62
	tm.outer_radius = 0.78
	crown.mesh = tm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(1.0, 0.3, 0.2, 0.8)
	crown.material_override = m
	crown.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	crown.position = Vector3(0, 3.4, 0)
	crown.rotation.x = 0.35
	mr.add_child(crown)
	var tw := crown.create_tween().set_loops()
	tw.tween_property(crown, "rotation:y", TAU, 4.0).from(0.0)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.3, 0.2)
	light.light_energy = 1.4
	light.omni_range = 6.0
	light.shadow_enabled = false
	light.position = Vector3(0, 2.4, 0)
	mr.add_child(light)


func _process(delta: float) -> void:
	if _boss == null or _dead or not GameState.is_local_authority_server():
		return
	if _health == null or not ("current" in _health):
		return
	if bool(_health.get("is_dead")):
		_on_boss_death()
		return
	var ratio: float = float(_health.current) / maxf(1.0, float(_health.max_health))
	var new_phase: int = 1
	if ratio <= 0.33:
		new_phase = 3
	elif ratio <= 0.66:
		new_phase = 2
	if new_phase != _phase:
		_phase = new_phase
		_phase_fx.rpc(_phase)
	if _phase >= 2 and not _charging:
		_charge_cd -= delta
		if _charge_cd <= 0.0:
			_charge_cd = CHARGE_COOLDOWN * (0.7 if _phase == 3 else 1.0)
			_begin_charge()
	if _phase >= 3:
		_ring_cd -= delta
		if _ring_cd <= 0.0:
			_ring_cd = RING_COOLDOWN
			_begin_ring()


## SERVER: telegraph a charge lane at the current target player, then dash.
func _begin_charge() -> void:
	var target: Node3D = _nearest_player()
	if target == null:
		return
	_charging = true
	var from: Vector3 = _boss.global_position
	var dir: Vector3 = target.global_position - from
	dir.y = 0.0
	if dir.length() < 1.0:
		_charging = false
		return
	dir = dir.normalized()
	_charge_hit.clear()
	var lane_len: float = minf(from.distance_to(target.global_position) + 4.0, 26.0)
	_charge_telegraph_fx.rpc(from, dir, lane_len)
	var t := get_tree().create_timer(CHARGE_TELEGRAPH)
	t.timeout.connect(_do_charge.bind(dir, lane_len))


func _do_charge(dir: Vector3, lane_len: float) -> void:
	if _dead or _boss == null or not is_instance_valid(_boss):
		return
	# Sweep the lane in steps: move the boss, smash walls, damage players in the path.
	var steps: int = int(lane_len / 1.2)
	var step_t: float = (lane_len / CHARGE_SPEED) / float(maxi(1, steps))
	_charge_step(dir, steps, step_t)


func _charge_step(dir: Vector3, steps_left: int, step_t: float) -> void:
	if _dead or _boss == null or not is_instance_valid(_boss):
		_charging = false
		return
	if steps_left <= 0:
		_charging = false
		_slam_fx.rpc(_boss.global_position)
		_damage_players_near(_boss.global_position, 4.5, CHARGE_DAMAGE)
		NetworkManager.report_noise(_boss.global_position, 16.0, 2)
		return
	var next: Vector3 = _boss.global_position + dir * 1.2
	next.y = _boss.global_position.y
	_boss.global_position = next
	BreakableChunk.break_in_radius(next + Vector3.UP * 1.2, CHARGE_BREAK_R)
	BreakableChunk.break_in_radius(next + Vector3.UP * 2.8, CHARGE_BREAK_R * 0.8)
	_damage_players_near(next, 2.2, CHARGE_DAMAGE)
	var t := get_tree().create_timer(step_t)
	t.timeout.connect(_charge_step.bind(dir, steps_left - 1, step_t))


## SERVER: telegraph then sweep an expanding shockwave ring outward.
func _begin_ring() -> void:
	var center: Vector3 = _boss.global_position
	_ring_telegraph_fx.rpc(center)
	var t := get_tree().create_timer(RING_TELEGRAPH)
	t.timeout.connect(_do_ring.bind(center))


func _do_ring(center: Vector3) -> void:
	if _dead:
		return
	_ring_fx.rpc(center)
	# Damage players as the ring passes their radius (sampled at 5 moments).
	for i in 5:
		var frac: float = float(i + 1) / 5.0
		var t := get_tree().create_timer(RING_SWEEP_TIME * frac)
		t.timeout.connect(_ring_hit.bind(center, RING_MAX_R * frac))


func _ring_hit(center: Vector3, radius: float) -> void:
	if _dead:
		return
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if not (p is Node3D):
			continue
		var d: float = (p as Node3D).global_position.distance_to(center)
		if absf(d - radius) <= RING_BAND:
			var hp: Node = p.get_node_or_null(Groups.NODE_HEALTH)
			if hp != null and hp.has_method("take_damage"):
				hp.take_damage(RING_DAMAGE, _boss)


func _damage_players_near(center: Vector3, radius: float, dmg: float) -> void:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if not (p is Node3D):
			continue
		if _charge_hit.get(p.name, false):
			continue
		if (p as Node3D).global_position.distance_to(center) <= radius:
			var hp: Node = p.get_node_or_null(Groups.NODE_HEALTH)
			if hp != null and hp.has_method("take_damage"):
				_charge_hit[p.name] = true
				hp.take_damage(dmg, _boss)


## SERVER: staged death spectacle (secondary explosions), broadcast per stage.
func _on_boss_death() -> void:
	if _dead:
		return
	_dead = true
	for i in 3:
		var t := get_tree().create_timer(0.3 + 0.45 * float(i))
		t.timeout.connect(_death_pop_fx.rpc.bind(i))


func _nearest_player() -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if not (p is Node3D):
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		var d: float = (p as Node3D).global_position.distance_to(_boss.global_position)
		if d < best_d:
			best_d = d
			best = p as Node3D
	return best


# ------------------------------------------------------------ broadcast FX (all peers)
@rpc("authority", "call_local", "unreliable")
func _phase_fx(phase: int) -> void:
	if DisplayServer.get_name() == "headless":
		return
	Events.screen_shake.emit(0.4)
	if phase == 2:
		Events.notify.emit(tr("REAPER: RAM PROTOCOL"), 2)
	elif phase == 3:
		Events.notify.emit(tr("REAPER: CORE FURY"), 2)
		_tint_boss(Color(1.0, 0.25, 0.2))


func _tint_boss(col: Color) -> void:
	var mr := _boss.get_node_or_null("ModelRoot") as Node3D
	if mr == null:
		return
	var light := OmniLight3D.new()
	light.light_color = col
	light.light_energy = 2.2
	light.omni_range = 7.0
	light.shadow_enabled = false
	light.position = Vector3(0, 2.0, 0)
	mr.add_child(light)


@rpc("authority", "call_local", "unreliable")
func _charge_telegraph_fx(from: Vector3, dir: Vector3, lane_len: float) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var lane := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(3.2, 0.03, lane_len)
	lane.mesh = bm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.2, 0.15, 0.4)
	lane.material_override = m
	lane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(lane)
	lane.global_position = from + dir * (lane_len * 0.5) + Vector3(0, 0.2, 0)
	lane.rotation.y = atan2(-dir.x, -dir.z)
	var tw := lane.create_tween()
	tw.tween_property(m, "albedo_color", Color(1.0, 0.3, 0.2, 0.75), CHARGE_TELEGRAPH)
	tw.tween_callback(lane.queue_free)
	AudioManager.play_skill("robot_alert")


@rpc("authority", "call_local", "unreliable")
func _slam_fx(_pos: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	Events.screen_shake.emit(0.55)
	AudioManager.play_skill("skill_slam")


@rpc("authority", "call_local", "unreliable")
func _ring_telegraph_fx(center: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = RING_MAX_R
	cm.bottom_radius = RING_MAX_R
	cm.height = 0.02
	disc.mesh = cm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.25, 0.15, 0.16)
	disc.material_override = m
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(disc)
	disc.global_position = center + Vector3(0, 0.15, 0)
	var tw := disc.create_tween()
	tw.tween_property(m, "albedo_color", Color(1.0, 0.3, 0.2, 0.3), RING_TELEGRAPH)
	tw.tween_callback(disc.queue_free)


@rpc("authority", "call_local", "unreliable")
func _ring_fx(center: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.8
	tm.outer_radius = 1.0
	ring.mesh = tm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(1.0, 0.35, 0.2, 0.85)
	ring.material_override = m
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(ring)
	ring.global_position = center + Vector3(0, 0.4, 0)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * RING_MAX_R, RING_SWEEP_TIME)
	tw.tween_property(m, "albedo_color", Color(1.0, 0.35, 0.2, 0.0), RING_SWEEP_TIME)
	tw.set_parallel(false)
	tw.tween_callback(ring.queue_free)
	Events.screen_shake.emit(0.35)


@rpc("authority", "call_local", "unreliable")
func _death_pop_fx(stage: int) -> void:
	if DisplayServer.get_name() == "headless" or _boss == null or not is_instance_valid(_boss):
		return
	Events.screen_shake.emit(0.4 + 0.15 * float(stage))
	AudioManager.play_skill("explosion")
