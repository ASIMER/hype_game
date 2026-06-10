## Shared radial player-damage loop (docs/AUDIT.md F4) — the ONE implementation behind
## the worm bite, kamikaze blast, slammer ground-slam and pouncer swipe (they used to be
## four near-identical copies; a falloff/team-damage fix in one missed the others).
## Server-side only (callers are already authority-gated enemy attacks).
class_name CombatAoe


## Damages every alive player within `radius` of `center` through its Hurtbox.
## Returns how many players were hit (the slammer uses it for its close-impact FX).
##   falloff_scale: 0.0 = flat damage; 1.0 = full linear falloff (kamikaze);
##     0.5 = half-at-rim (slammer). Applied as damage * clamp(1 - scale*d/r, floor, 1).
##   floor_frac: the falloff clamp floor (ignored when falloff_scale == 0).
##   include_downed: true hits DOWNED players too (the kamikaze blast finishes them);
##     melee-style swipes skip them (downed players are only threatened by bleedout).
static func damage_players(center: Vector3, radius: float, damage: float, source: Node3D,
		falloff_scale: float = 0.0, floor_frac: float = 1.0,
		include_downed: bool = false) -> int:
	var hit := 0
	for p in source.get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		var pn := p as Node3D
		if not include_downed and pn.has_method("is_downed") and pn.is_downed():
			continue
		var d := center.distance_to(pn.global_position)
		if d > radius:
			continue
		var dmg := damage
		if falloff_scale > 0.0:
			dmg = damage * clampf(1.0 - falloff_scale * d / radius, floor_frac, 1.0)
		var hb := pn.get_node_or_null(Groups.NODE_HURTBOX)
		if hb and hb.has_method("apply_hit"):
			hb.apply_hit(dmg, source)
			hit += 1
	return hit
