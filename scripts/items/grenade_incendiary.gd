extends Grenade
class_name GrenadeIncendiary
## Incendiary Grenade (Machine Chemistry, Phase 5) — on detonation sets every robot in
## range ON FIRE (a BURN damage-over-time) instead of a single blast. Server-authoritative
## status application (the burn ticks replicate via the enemy's Health.current); the fire
## ring is local FX on every peer. Desert heat amplifies the burn; rain/water douses it
## (resolved inside MachineChemistry.apply).

const _RING_TIME := 0.4
const _RING_MAX_SCALE := 6.0


func _init() -> void:
	grenade_type = "incendiary"


func _detonate_effect(pos: Vector3) -> void:
	if GameState.is_local_authority_server():
		for e in _enemies_in_radius(pos):
			if e.has_method("apply_chemistry"):
				MachineChemistry.apply(
					e, "burn", Settings.INCENDIARY_BURN_DUR, Settings.INCENDIARY_BURN_DPS
				)
	# D4.4: the pooled composite blast, keyed by grenade_type so this reads as its own
	# element rather than the generic orange puff. It carries its own expanding ring, so
	# the hand-rolled disc this replaced is gone.
	FXPool.spawn_explosion(_fx_host(), pos, grenade_type, Settings.INCENDIARY_RADIUS)


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
