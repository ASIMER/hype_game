extends Grenade
class_name GrenadeEmp
## EMP Grenade — on detonation stuns every robot in range instead of dealing
## damage. The stun is server-authoritative (only the host applies it, so it
## replicates through the enemy's own state); the crackling spark FX is local on
## every peer. Boss stun resistance (EMP_BOSS_STUN_MULT) is the enemy's concern
## inside its own apply_stun — we just hand it the full duration.

const _SPARK_TIME := 3.5  # how long the per-enemy spark VFX lingers
const _RING_TIME := 0.45  # expanding shock-ring lifetime
const _RING_MAX_SCALE := 7.0


func _init() -> void:
	grenade_type = "emp"


func _detonate_effect(pos: Vector3) -> void:
	# Authoritative stun — server only, so clients don't double-apply (the stun
	# replicates via the enemy's own synced state).
	if GameState.is_local_authority_server():
		for e in _enemies_in_radius(pos):
			if e.has_method("apply_stun"):
				e.apply_stun(Settings.EMP_STUN_TIME)
				Events.enemy_stunned.emit(e, Settings.EMP_STUN_TIME)

	# Local FX on EVERY peer: a sky-blue shock-ring + a spark burst on each robot
	# caught in the pulse.
	_spawn_ring(pos)
	for e in _enemies_in_radius(pos):
		_attach_sparks(e as Node3D)


# Every "enemies" Node3D whose body is within EMP_RADIUS of `center`.
func _enemies_in_radius(center: Vector3) -> Array:
	var hits: Array = []
	var tree := get_tree()
	if tree == null:
		return hits
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if e == null or not (e is Node3D):
			continue
		if (e as Node3D).global_position.distance_to(center) <= Settings.EMP_RADIUS:
			hits.append(e)
	return hits


# A one-shot cyan spark crackle parented to the stunned robot (follows it).
# Frees itself after _SPARK_TIME via a Tween (no per-frame node needed).
func _attach_sparks(enemy: Node3D) -> void:
	if enemy == null:
		return
	var p := GPUParticles3D.new()
	p.amount = 24
	p.lifetime = 0.35
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.8
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 6.0
	pm.gravity = Vector3(0, -2.0, 0)
	pm.scale_min = 0.3
	pm.scale_max = 0.8
	pm.color = Color(0.4, 0.85, 1.0)
	p.process_material = pm
	var spark := BoxMesh.new()
	spark.size = Vector3(0.03, 0.03, 0.25)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.albedo_color = Color(0.5, 0.9, 1.0)
	spark.material = sm
	p.draw_pass_1 = spark
	enemy.add_child(p)
	p.position = Vector3(0, 1.0, 0)
	p.emitting = true
	# Self-clean after the crackle so we never leak particle nodes onto enemies.
	var tw := p.create_tween()
	tw.tween_interval(_SPARK_TIME)
	tw.tween_callback(p.queue_free)


# A brief expanding additive ring at the blast centre, parented to the world so
# it survives this grenade freeing. Scale + fade driven by a Tween.
func _spawn_ring(pos: Vector3) -> void:
	var host := _fx_host()
	if host == null:
		return
	# PlaneMesh lies flat on the XZ plane by default, so the ring hugs the ground.
	var disc := PlaneMesh.new()
	disc.size = Vector2(1.0, 1.0)
	var ring := MeshInstance3D.new()
	ring.mesh = disc
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(0.45, 0.85, 1.0, 0.9)
	ring.material_override = mat
	host.add_child(ring)
	ring.global_position = pos + Vector3(0, 0.15, 0)
	ring.scale = Vector3.ONE
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * _RING_MAX_SCALE, _RING_TIME)
	tw.tween_property(mat, "albedo_color:a", 0.0, _RING_TIME)
	tw.chain().tween_callback(ring.queue_free)
