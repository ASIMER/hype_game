class_name LimbBurst
extends RefCounted
## M1 feel — the dying machine BREAKS APART: 2-3 recognizable LIMBS of its own
## skill family (the very model its loot drop uses) fly off the corpse with
## physics and tumble away. Sells Mutant-Harvest («убил → разобрал на
## конечности») wordlessly. Render-only, spawned per peer from
## robot_enemy._start_death_fx; parked in the FX-safe container so it survives
## the enemy's queue_free. Extracted here for robot_enemy's 1800-line ceiling.


## M1 SPAWN ASSEMBLY — a machine doesn't pop into existence: its body scales up
## from the ground with a quick spin-settle + a spawn ring, reading as «собралась
## из деталей». Render-only, runs on every peer from robot_enemy._ready.
static func assemble(model_root: Node3D, host: Node3D) -> void:
	if model_root == null or DisplayServer.get_name() == "headless":
		return
	model_root.scale = Vector3.ONE * 0.05
	model_root.rotation.y = 2.4
	var tw := model_root.create_tween()
	tw.set_parallel(true)
	tw.tween_property(model_root, "scale", Vector3.ONE, 0.38).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	tw.tween_property(model_root, "rotation:y", 0.0, 0.34).set_trans(Tween.TRANS_CUBIC)
	# Spawn ring at the feet (unshaded, self-freeing).
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.5
	tm.outer_radius = 0.62
	ring.mesh = tm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(0.9, 0.75, 0.35, 0.8)
	ring.material_override = m
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(ring)
	ring.global_position = host.global_position + Vector3(0, 0.15, 0)
	var rtw := ring.create_tween()
	rtw.set_parallel(true)
	rtw.tween_property(ring, "scale", Vector3.ONE * 3.2, 0.4)
	rtw.tween_property(m, "albedo_color", Color(0.9, 0.75, 0.35, 0.0), 0.4)
	rtw.set_parallel(false)
	rtw.tween_callback(ring.queue_free)


static func burst(enemy_id: String, pos: Vector3, container: Node, scale_hint: float) -> void:
	if container == null or DisplayServer.get_name() == "headless":
		return
	var sid: String = Settings.skill_for_enemy(enemy_id)
	var def: Dictionary = Settings.skill_def(sid)
	var col: Color = def["color"]
	var count: int = 2 + randi() % 2
	for i in count:
		var body := RigidBody3D.new()
		body.collision_layer = 0
		body.collision_mask = 1
		body.mass = 1.2
		var limb: Node3D = ProceduralAbsorbed.build_limb_model(sid, col)
		limb.scale = Vector3.ONE * clampf(scale_hint, 0.7, 1.4)
		body.add_child(limb)
		var shape := CollisionShape3D.new()
		var cs := SphereShape3D.new()
		cs.radius = 0.24
		shape.shape = cs
		body.add_child(shape)
		container.add_child(body)
		body.global_position = pos + Vector3(0, 0.9, 0)
		var ang: float = randf() * TAU
		body.apply_impulse(
			Vector3(cos(ang) * (2.5 + randf() * 2.0), 4.5 + randf() * 2.5, sin(ang) * 3.0)
		)
		body.angular_velocity = Vector3(
			randf_range(-9.0, 9.0), randf_range(-9.0, 9.0), randf_range(-9.0, 9.0)
		)
		var tw := body.create_tween()
		tw.tween_interval(2.3)
		tw.tween_callback(body.queue_free)
