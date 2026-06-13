extends Grenade
class_name GrenadeIncendiary
## Incendiary Grenade (Machine Chemistry, Phase 5) — on detonation sets every robot in
## range ON FIRE (a BURN damage-over-time) instead of a single blast. Server-authoritative
## status application (the burn ticks replicate via the enemy's Health.current); the fire
## ring is local FX on every peer. Desert heat amplifies the burn; rain/water douses it
## (resolved inside MachineChemistry.apply).

const _RING_TIME := 0.4
const _RING_MAX_SCALE := 6.0
const _COLOR := Color(1.0, 0.5, 0.12)


func _init() -> void:
	grenade_type = "incendiary"


func _detonate_effect(pos: Vector3) -> void:
	if GameState.is_local_authority_server():
		for e in _enemies_in_radius(pos):
			if e.has_method("apply_chemistry"):
				MachineChemistry.apply(
					e, "burn", Settings.INCENDIARY_BURN_DUR, Settings.INCENDIARY_BURN_DPS
				)
	_spawn_ring(pos)


# Every "enemies" Node3D whose body is within INCENDIARY_RADIUS of `center`.
func _enemies_in_radius(center: Vector3) -> Array:
	var hits: Array = []
	var tree := get_tree()
	if tree == null:
		return hits
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if e == null or not (e is Node3D):
			continue
		if (e as Node3D).global_position.distance_to(center) <= Settings.INCENDIARY_RADIUS:
			hits.append(e)
	return hits


# A brief expanding additive ring at the blast centre (local FX on every peer).
func _spawn_ring(pos: Vector3) -> void:
	var host := _fx_host()
	if host == null:
		return
	var disc := PlaneMesh.new()
	disc.size = Vector2(1.0, 1.0)
	var ring := MeshInstance3D.new()
	ring.mesh = disc
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(_COLOR.r, _COLOR.g, _COLOR.b, 0.9)
	ring.material_override = mat
	host.add_child(ring)
	ring.global_position = pos + Vector3(0, 0.15, 0)
	ring.scale = Vector3.ONE
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * _RING_MAX_SCALE, _RING_TIME)
	tw.tween_property(mat, "albedo_color:a", 0.0, _RING_TIME)
	tw.chain().tween_callback(ring.queue_free)
