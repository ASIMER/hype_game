class_name MachineChemistry
## Machine Chemistry (Phase 5) — the static reaction engine, a sibling of CombatAoe / Steering.
## Holds ALL cross-cutting chemistry logic so robot_enemy.gd stays thin: climate/wetness
## amplification, the freeze→shatter combo, and the wet+shock chain discharge. Plus the
## per-status FX factory (built per peer, parented to the enemy by robot_enemy).
##
## SERVER-side: apply()/discharge() are only ever reached on the authority (grenades + QA
## gate themselves; the raw enemy.apply_chemistry setter gates too). The thesis: machines
## react to electro/thermo/cryo effects no human enemy can — water conducts, heat overheats,
## cold freezes, and a frozen machine shatters.

const _COLORS := {
	"shock": Color(0.4, 0.9, 1.0),
	"burn": Color(1.0, 0.5, 0.12),
	"slow": Color(0.6, 0.85, 1.0),
	"brittle": Color(0.85, 0.92, 1.0),
}

## Node-meta key for the per-enemy elemental-ammo shock ICD (the EnemyDance meta pattern).
const _AMMO_ICD_META := "chem_ammo_icd"


## Apply a status to one machine, resolving climate/wetness first, then firing reactions.
## `dur`/`mag` are the RAW source values; biome amplifiers adjust them here. Returns true
## if the status landed.
static func apply(enemy: Node, kind: String, dur: float, mag: float) -> bool:
	if not _alive(enemy) or not (enemy is Node3D) or not enemy.has_method("apply_chemistry"):
		return false
	var pos: Vector3 = (enemy as Node3D).global_position
	var biome: String = WorldBounds.biome_at(pos.x, pos.z)
	var wet: bool = is_wet(pos.x, pos.z)
	var d: float = dur
	var m: float = mag
	match kind:
		"burn":
			if wet:
				d *= Settings.CHEM_BURN_RAIN_MULT  # rain/river douses the fire
			elif biome == "desert":
				m *= Settings.CHEM_BURN_DESERT_MULT  # desert heat amplifies the dps
		"slow":
			if biome == "snow":
				d *= Settings.CHEM_SLOW_SNOW_MULT  # cold lengthens the freeze
	if kind == "burn" and d <= 0.0:
		return false  # extinguished outright by wetness
	# Nemesis "chemistry_resist" learned counter (Phase 6): a rival the squad kept dousing
	# in statuses shrugs most of every element off — durations cut (shock's stun rides the
	# MAGNITUDE, so that is what gets cut), and a deep freeze can never latch on it.
	var nt: Variant = enemy.get("nemesis_traits")
	if nt is Array and "chemistry_resist" in (nt as Array):
		d *= Settings.NEMESIS_CHEM_MULT
		if kind == "shock":
			m *= Settings.NEMESIS_CHEM_MULT
		elif kind == "slow":
			m = maxf(m, Settings.CHEM_FREEZE_THRESHOLD + 0.05)
	enemy.apply_chemistry(kind, d, m)
	# Freeze→shatter: a deep enough slow latches BRITTLE (snow widens the window for free).
	if kind == "slow" and m <= Settings.CHEM_FREEZE_THRESHOLD:
		enemy.apply_chemistry("brittle", Settings.CHEM_BRITTLE_DUR, Settings.CHEM_BRITTLE_MULT)
	# Conductive chain: a SHOCK on a wet machine arcs to nearby wet machines.
	if kind == "shock" and wet:
		discharge(enemy, Settings.CHEM_CHAIN_JUMPS, [enemy], maxf(m, Settings.CHEM_SHOCK_STUN))
	return true


## One landed hit from an ELEMENTAL mag (Chemistry Phase 6). Server-side; every number is
## derived HERE from Settings — clients only ever claim the kind (request_chemistry). Shock
## procs behind a chance + a per-enemy ICD (node meta) so autofire can't stunlock; cryo
## RAMPS: each hit deepens the current slow by a step until the floor crosses the freeze
## threshold. Routes through apply() so climate, reactions, and nemesis resist all fire.
static func apply_ammo(enemy: Node, kind: String) -> bool:
	if not _alive(enemy):
		return false
	match kind:
		"shock":
			var now: int = Time.get_ticks_msec()
			if now < int(enemy.get_meta(_AMMO_ICD_META, 0)):
				return false
			if randf() > Settings.CHEM_AMMO_SHOCK_CHANCE:
				return false
			var icd_ms: int = int(Settings.CHEM_AMMO_SHOCK_ICD * 1000.0)
			enemy.set_meta(_AMMO_ICD_META, now + icd_ms)
			return apply(enemy, "shock", 0.0, Settings.CHEM_AMMO_SHOCK_STUN)
		"burn":
			return apply(enemy, "burn", Settings.CHEM_AMMO_BURN_DUR, Settings.CHEM_AMMO_BURN_DPS)
		"slow":
			var status: Node = enemy.get("_status") as Node
			var cur: float = 1.0
			if status != null and status.has_method("speed_mult"):
				cur = float(status.speed_mult())
			var next_mag: float = maxf(
				Settings.CHEM_AMMO_SLOW_FLOOR, cur - Settings.CHEM_AMMO_SLOW_STEP
			)
			return apply(enemy, "slow", Settings.CHEM_AMMO_SLOW_DUR, next_mag)
	return false


## Arc a shock from `origin` to the nearest unvisited WET machine within reach, with a
## per-hop falloff, recursing up to `jumps_left` times. Returns the number of links made.
static func discharge(origin: Node, jumps_left: int, visited: Array, mag: float) -> int:
	if jumps_left <= 0 or not (origin is Node3D):
		return 0
	var op: Vector3 = (origin as Node3D).global_position
	var best: Node = null
	var best_d: float = Settings.CHEM_CHAIN_RADIUS
	for e in origin.get_tree().get_nodes_in_group(Groups.ENEMIES):
		if (
			e in visited
			or not _alive(e)
			or not (e is Node3D)
			or not e.has_method("apply_chemistry")
		):
			continue
		var ep: Vector3 = (e as Node3D).global_position
		if not is_wet(ep.x, ep.z):
			continue
		var dd: float = op.distance_to(ep)
		if dd <= best_d:
			best_d = dd
			best = e
	if best == null:
		return 0
	visited.append(best)
	var next_mag: float = mag * Settings.CHEM_CHAIN_FALLOFF
	best.apply_chemistry("shock", 0.0, next_mag)
	return 1 + discharge(best, jumps_left - 1, visited, next_mag)


## A machine at (x,z) is WET — and thus conductive / fireproof — if it stands in the rain
## biome OR over the river channel (the frozen pure water contract, NAN off-river).
static func is_wet(x: float, z: float) -> bool:
	if WorldBounds.biome_at(x, z) == "rain":
		return true
	return not is_nan(ProceduralTerrain.water_surface_at(x, z))


## A per-status visual aura (GPUParticles), built per peer and parented to the enemy by
## robot_enemy.apply_chemistry_fx while the status is active. Render-only; never networked.
static func make_fx(kind: String) -> Node3D:
	var col: Color = _COLORS.get(kind, Color.WHITE)
	var rising: bool = kind == "burn"
	var p := GPUParticles3D.new()
	p.amount = 18
	p.lifetime = 0.7
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(0.0, 1.0, 0.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.7
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 60.0 if rising else 180.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 2.0
	var grav_y: float = 1.5 if rising else -1.0
	pm.gravity = Vector3(0.0, grav_y, 0.0)
	pm.scale_min = 0.15
	pm.scale_max = 0.4
	pm.color = col
	p.process_material = pm
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.08, 0.08, 0.08)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.albedo_color = col
	mesh.material = sm
	p.draw_pass_1 = mesh
	p.emitting = true
	return p


## Canonical status-kind → bit mapping (the visual-sync flag set + QA share it).
static func bit_for(kind: String) -> int:
	match kind:
		"shock":
			return Settings.CHEM_SHOCK
		"burn":
			return Settings.CHEM_BURN
		"slow":
			return Settings.CHEM_SLOW
		"brittle":
			return Settings.CHEM_BRITTLE
	return 0


## True while `n` is a live, valid enemy (not dying, HP > 0).
static func _alive(n: Node) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	if "_dying" in n and bool(n.get("_dying")):
		return false
	var hp: Node = n.get_node_or_null(Groups.NODE_HEALTH)
	return hp == null or not bool(hp.get("is_dead"))
