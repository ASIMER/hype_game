class_name LimbBurst
extends RefCounted
## M1 feel — the dying machine BREAKS APART: 2-3 recognizable LIMBS of its own
## skill family (the very model its loot drop uses) fly off the corpse with
## physics and tumble away. Sells Mutant-Harvest («убил → разобрал на
## конечности») wordlessly. Render-only, spawned per peer from
## robot_enemy._start_death_fx; parked in the FX-safe container so it survives
## the enemy's queue_free. Extracted here for robot_enemy's 1800-line ceiling.


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
