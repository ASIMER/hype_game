extends Grenade
class_name GrenadeSmoke
## Smoke Grenade — on detonation spawns a lingering SmokeCloud (LOS-blocking)
## instead of dealing damage. The cloud is deterministic local FX + a group node
## (Groups.SMOKE) the enemy AI tests against, so it is built on EVERY peer (the
## grenade itself is spawned everywhere by the throw spawner). Only a faint
## noise pop accompanies the pop — nowhere near a frag's bang.

const _CLOUD_SCENE := "res://scenes/fx/SmokeCloud.tscn"


func _init() -> void:
	grenade_type = "smoke"


func _detonate_effect(pos: Vector3) -> void:
	var host := _fx_host()
	if host and ResourceLoader.exists(_CLOUD_SCENE):
		var cloud = load(_CLOUD_SCENE).instantiate()
		if cloud:
			host.add_child(cloud)
			if cloud is Node3D:
				(cloud as Node3D).global_position = pos

	# A muffled foomph, not an explosion — quiet enough to break contact behind.
	# 8.0 ≈ Settings.NOISE_WALK (a footstep), far below NOISE_GRENADE.
	if GameState.is_local_authority_server():
		NetworkManager.report_noise(pos, 8.0, 2)
