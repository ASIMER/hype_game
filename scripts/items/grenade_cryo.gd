extends Grenade
class_name GrenadeCryo
## Cryo Grenade (Machine Chemistry, Phase 5) — on detonation SLOWS every robot in range
## (a cryo movement penalty). A deep enough slow latches BRITTLE (the freeze→shatter combo,
## handled in MachineChemistry.apply); snow lengthens the freeze. Server-authoritative status
## (the slowed body replicates via position); the frost ring is local FX on every peer.

const _RING_TIME := 0.4
const _RING_MAX_SCALE := 6.0


func _init() -> void:
	grenade_type = "cryo"


func _detonate_effect(pos: Vector3) -> void:
	if GameState.is_local_authority_server():
		for e in _enemies_in_radius(pos):
			if e.has_method("apply_chemistry"):
				MachineChemistry.apply(e, "slow", Settings.CRYO_SLOW_DUR, Settings.CRYO_SLOW_MULT)
	# D4.4: the pooled composite blast, keyed by grenade_type so this reads as its own
	# element rather than the generic orange puff. It carries its own expanding ring, so
	# the hand-rolled disc this replaced is gone.
	FXPool.spawn_explosion(_fx_host(), pos, grenade_type, Settings.CRYO_RADIUS)


# Every "enemies" Node3D whose body is within CRYO_RADIUS of `center`.
func _enemies_in_radius(center: Vector3) -> Array:
	var hits: Array = []
	var tree := get_tree()
	if tree == null:
		return hits
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if e == null or not (e is Node3D):
			continue
		if (e as Node3D).global_position.distance_to(center) <= Settings.CRYO_RADIUS:
			hits.append(e)
	return hits
