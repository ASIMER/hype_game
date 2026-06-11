extends GadgetBase
class_name GadgetTurret
## Auto-Turret: a placed sentry that auto-fires at the nearest enemy in range with clear
## line-of-sight, dealing TURRET_DAMAGE every TURRET_TICK. It has its own small HP pool so
## enemies could destroy it (apply_hit), and a "Barrel" model part that tracks the target on
## every peer (cosmetic — enemy positions replicate so each peer aims the same).
##
## Damage is SERVER-AUTHORITATIVE (only the host applies hits to enemy hurtboxes). Barrel
## tracking + the muzzle blink run on every peer off each peer's own nearest-enemy pick, so
## a brief cosmetic divergence on clients is acceptable.

const MUZZLE_HEIGHT := 1.2  # local-Y the LOS ray + tracer fire from
const AIM_HEIGHT := 0.9  # aim at the enemy body center (its origin sits at the feet)
const TURN_SPEED := 9.0  # rad/s the barrel slews toward the target
const FLASH_TIME := 0.08  # s the muzzle glow stays bright after a shot

var hp: float = Settings.TURRET_HP

var _barrel: Node3D = null
var _muzzle_glow: GeometryInstance3D = null
var _glow_base := 5.0  # captured emission energy of the muzzle eye (restored after a flash)
var _flash_t: float = 0.0
var _fire_t: float = 0.0
var _target: Node3D = null  # nearest valid enemy (for both server damage + cosmetic aim)


func _gadget_ready() -> void:
	_gadget_type = "gadget_turret"
	_lifetime = Settings.TURRET_LIFETIME
	var model := ProceduralModels.build("gadget_turret")
	if model != null:
		model.name = "ModelRoot"
		add_child(model)
		_barrel = model.get_node_or_null("Barrel")
		var glow := model.get_node_or_null("Barrel/MuzzleGlow")
		if glow is GeometryInstance3D:
			_muzzle_glow = glow
			var mat: Variant = _muzzle_glow.get("material_override")
			if mat is StandardMaterial3D:
				_glow_base = (mat as StandardMaterial3D).emission_energy_multiplier


func _gadget_tick(delta: float) -> void:
	_acquire_target()
	_aim_barrel(delta)
	_update_flash(delta)
	if not _server():
		return
	_fire_t += delta
	if _fire_t >= Settings.TURRET_TICK:
		_fire_t = 0.0
		_try_fire()


## Picks the nearest in-range enemy with clear LOS. Runs on every peer (the result drives
## cosmetic aim); the server additionally uses it as the damage target.
func _acquire_target() -> void:
	var best: Node3D = null
	var best_d := Settings.TURRET_RANGE
	for e in get_tree().get_nodes_in_group(Groups.ENEMIES):
		if e == null or not is_instance_valid(e) or not (e is Node3D):
			continue
		var en := e as Node3D
		var d := global_position.distance_to(en.global_position)
		if d > best_d:
			continue
		if not _has_los(en):
			continue
		best = en
		best_d = d
	_target = best


## Clear line of sight from the turret muzzle to the enemy body center, blocked only by the
## world (physics layer 1) — not by enemies/players/loot, so a target behind cover is skipped
## but a target behind another robot is still shootable.
func _has_los(enemy: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var from := global_position + Vector3(0, MUZZLE_HEIGHT, 0)
	var to := enemy.global_position + Vector3(0, AIM_HEIGHT, 0)
	var params := PhysicsRayQueryParameters3D.create(from, to, 1)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var hit := space.intersect_ray(params)
	return hit.is_empty()


## Slews the "Barrel" pivot on every peer to face the current target (yaw + a little pitch).
func _aim_barrel(delta: float) -> void:
	if _barrel == null:
		return
	if _target == null or not is_instance_valid(_target):
		return
	var muzzle := global_position + Vector3(0, MUZZLE_HEIGHT, 0)
	var aim := _target.global_position + Vector3(0, AIM_HEIGHT, 0)
	var dir := aim - muzzle
	if dir.length_squared() < 0.0001:
		return
	var want_yaw := atan2(-dir.x, -dir.z)  # authored facing -Z
	var flat := Vector2(dir.x, dir.z).length()
	var want_pitch := atan2(dir.y, flat)
	_barrel.rotation.y = lerp_angle(_barrel.rotation.y, want_yaw - rotation.y, TURN_SPEED * delta)
	_barrel.rotation.x = lerp_angle(_barrel.rotation.x, want_pitch, TURN_SPEED * delta)


## SERVER: damage the current target through its Hurtbox + trigger the muzzle flash.
func _try_fire() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	if global_position.distance_to(_target.global_position) > Settings.TURRET_RANGE:
		return
	var hb := _target.get_node_or_null(Groups.NODE_HURTBOX)
	if hb != null and hb.has_method("apply_hit"):
		hb.apply_hit(Settings.TURRET_DAMAGE, self)
	_flash_t = FLASH_TIME


## Muzzle glow brightens on a shot then decays. On clients (no server damage) the blink is
## driven off the local nearest-enemy pick — fire when a target is in range, refractory-gated
## by the same tick so it pulses roughly in sync with the host.
func _update_flash(delta: float) -> void:
	if not _server():
		_fire_t += delta
		if _fire_t >= Settings.TURRET_TICK:
			_fire_t = 0.0
			if _target != null and is_instance_valid(_target):
				_flash_t = FLASH_TIME
	if _muzzle_glow == null:
		return
	var mat: Variant = _muzzle_glow.get("material_override")
	if not (mat is StandardMaterial3D):
		return
	var sm := mat as StandardMaterial3D
	if _flash_t > 0.0:
		_flash_t = maxf(0.0, _flash_t - delta)
		sm.emission_energy_multiplier = _glow_base * 3.0
	else:
		sm.emission_energy_multiplier = _glow_base


## Lets enemy strikes chip the turret down (the lead may route enemy melee here later). Frees
## the turret when destroyed; SERVER-authoritative.
func apply_hit(amount: float, _source: Node = null) -> void:
	if not _server():
		return
	hp -= amount
	if hp <= 0.0:
		Events.gadget_expired.emit(_gadget_type, global_position)
		queue_free()
