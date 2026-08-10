class_name PlayerBodyFeel
extends Node
## M1 BODY FEEL — the player's weight made visible (owner-local render only):
##   • landing SQUASH: a hard landing compresses the body scale + kicks a dust puff
##     and a little camera trauma (fall speed scaled);
##   • body LEAN: the torso banks into acceleration/turns (world accel → local
##     roll/pitch, smoothed) so movement stops looking like ice-sliding;
##   • sprint DUST: distance-metered puffs under the feet while sprinting.
## Created in player._ready (the "Gear" component pattern). Never networked —
## remote peers see none of this (their own machine runs it for their player).

const LEAN_ROLL_MAX := 0.085  # rad — bank into lateral acceleration
const LEAN_PITCH_MAX := 0.06  # rad — nose into forward acceleration
const LAND_SQUASH_VY := 6.0  # |vy| on touchdown that triggers the squash
const SPRINT_DUST_STEP := 2.6  # metres between sprint puffs

var _p: CharacterBody3D = null
var _model: Node3D = null
var _was_on_floor := true
var _prev_vy: float = 0.0
var _prev_hvel := Vector3.ZERO
var _lean := Vector2.ZERO  # x = roll, y = pitch (smoothed radians)
var _dust_accum: float = 0.0
var _headless := false


func _ready() -> void:
	_p = get_parent() as CharacterBody3D
	_headless = DisplayServer.get_name() == "headless"


func _process(delta: float) -> void:
	if _headless or _p == null or not _p.is_multiplayer_authority():
		return
	if _model == null or not is_instance_valid(_model):
		_model = _p.get_node_or_null("ModelRoot") as Node3D
		if _model == null:
			return
	var on_floor: bool = _p.is_on_floor()
	var hv: Vector3 = _p.velocity
	var vy: float = hv.y
	hv.y = 0.0

	# --- Body lean from horizontal acceleration (local space) ---
	var accel: Vector3 = (hv - _prev_hvel) / maxf(delta, 0.001)
	_prev_hvel = hv
	var local_acc: Vector3 = _p.global_transform.basis.inverse() * accel
	var target := Vector2.ZERO
	if on_floor and hv.length() > 0.5:
		target.x = clampf(-local_acc.x * 0.005, -LEAN_ROLL_MAX, LEAN_ROLL_MAX)
		target.y = clampf(local_acc.z * 0.0035, -LEAN_PITCH_MAX, LEAN_PITCH_MAX)
	_lean = _lean.lerp(target, 1.0 - exp(-9.0 * delta))
	# Small absolute angles; the dodge-roll owns bigger model rotation while it runs
	# and simply overwrites these for its frames (last writer wins, no fight).
	_model.rotation.z = _lean.x
	_model.rotation.x = _lean.y

	# --- Landing squash + dust ---
	if on_floor and not _was_on_floor and _prev_vy < -LAND_SQUASH_VY:
		var k: float = clampf((absf(_prev_vy) - LAND_SQUASH_VY) / 12.0, 0.0, 1.0)
		_model.scale = Vector3(1.0 + 0.10 * k, 1.0 - 0.16 * k, 1.0 + 0.10 * k)
		var tw := _model.create_tween()
		tw.tween_property(_model, "scale", Vector3.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(
			Tween.EASE_OUT
		)
		_puff(1.0 + k)
		Events.screen_shake.emit(0.1 + 0.2 * k)

	# --- Sprint dust (distance-metered) ---
	if on_floor and hv.length() > Settings.PLAYER_SPRINT_SPEED * 0.7:
		_dust_accum += hv.length() * delta
		if _dust_accum >= SPRINT_DUST_STEP:
			_dust_accum = 0.0
			_puff(0.55)
	_was_on_floor = on_floor
	_prev_vy = vy


## A tiny one-shot dust puff at the feet (scaled by `power`).
func _puff(power: float) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var p := GPUParticles3D.new()
	p.amount = int(8 * power)
	p.lifetime = 0.55
	p.one_shot = true
	p.explosiveness = 0.9
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.25
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 70.0
	pm.initial_velocity_min = 0.8 * power
	pm.initial_velocity_max = 2.2 * power
	pm.gravity = Vector3(0, -2.0, 0)
	pm.scale_min = 0.25
	pm.scale_max = 0.55 * power
	pm.color = Color(0.55, 0.52, 0.48, 0.5)
	p.process_material = pm
	var mesh := SphereMesh.new()
	mesh.radius = 0.09
	mesh.height = 0.18
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.55, 0.52, 0.48, 0.42)
	mesh.material = m
	p.draw_pass_1 = mesh
	scene.add_child(p)
	p.global_position = _p.global_position + Vector3(0, 0.1, 0)
	p.emitting = true
	get_tree().create_timer(0.9).timeout.connect(
		func() -> void:
			if is_instance_valid(p):
				p.queue_free()
	)
