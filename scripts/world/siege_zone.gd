extends Area3D
## SiegeZone — a "defend the position" world event (kind 4).
##
## Structural sibling of SupplyCache (Area3D, collision_layer=16 / mask=2): a server-auth
## hold zone the squad must occupy under escalating reinforcement waves. The
## WorldEventDirector instances this at a high-tier POI, calls set_loot_parent(Net/Loot),
## and connects `siege_completed` to take the success path.
##
## DIFFERENCE vs SupplyCache: progress PAUSES (never drains) when the zone is empty — a
## 60 s defend with a drain would be punitive — and the zone summons its OWN escalating
## waves of hunters via the WaveManager every SIEGE_WAVE_INTERVAL.
##
## "world_events" group convention (for the map / HUD lane):
##   - This node is added to the group "world_events" in _ready.
##   - get_meta("event_kind")  -> 4
##   - get_meta("event_label") -> "Siege"
##   - get_meta("event_pos")   -> Vector3 (set in _ready from global_position)
##   - func event_ratio()      -> float  0..1 (defend-timer fill ratio)
##   - func event_label()      -> String ("Siege")

## Emitted when the siege is held to completion (director takes the success path).
signal siege_completed

## Optional: the director sets this to Net/Loot so spawned pickups replicate.
var _loot_parent: Node = null


func set_loot_parent(parent: Node) -> void:
	_loot_parent = parent


# ─── defend-timer state ──────────────────────────────────────────────────────

var _hold_elapsed: float = 0.0  # seconds the squad has held the zone (never drains)
var _won: bool = false
var _is_server: bool = false
var _last_emit_ratio: float = -1.0  # throttle world_event_progress to ~4 Hz of change

# Escalating reinforcement waves.
var _wave_timer: float = 0.0
var _wave_idx: int = 0

# Lazy-cached WaveManager (re-located if freed).
var _wave_manager: Node = null

# ─── beacon visual ────────────────────────────────────────────────────────────

var _beacon: Node3D = null
var _beacon_core: MeshInstance3D = null
var _beacon_pillar: MeshInstance3D = null
var _beacon_light: OmniLight3D = null
var _beacon_rings: Array[MeshInstance3D] = []
var _beacon_mats: Array[StandardMaterial3D] = []
var _beacon_time: float = 0.0
var _beacon_pulse_base: float = 1.0

# Red/orange war-zone tint; bright orange on success.
const _IDLE_TINT := Color(0.95, 0.25, 0.12)  # hostile red-orange (siege)
const _HELD_TINT := Color(1.0, 0.55, 0.1)  # warmer orange while held
const _WIN_TINT := Color(1.0, 0.75, 0.25)  # bright gold-orange on success

# ─── lifecycle ───────────────────────────────────────────────────────────────


func _ready() -> void:
	add_to_group(Groups.WORLD_EVENTS)
	# Expose map / HUD metadata.
	set_meta("event_kind", 4)
	set_meta("event_label", tr("Siege"))
	# event_pos is set after global_position is available (call_deferred).
	call_deferred("_set_pos_meta")

	_build_beacon()

	_is_server = GameState.is_local_authority_server()
	if not _is_server:
		# Clients see the visual but don't run the defend logic.
		set_physics_process(false)
		return

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _set_pos_meta() -> void:
	set_meta("event_pos", global_position)


# ─── proximity tracking ───────────────────────────────────────────────────────

var _nearby_players: int = 0


func _on_body_entered(body: Node) -> void:
	if _won:
		return
	if body != null and body.is_in_group(Groups.PLAYERS):
		_nearby_players += 1


func _on_body_exited(body: Node) -> void:
	if body != null and body.is_in_group(Groups.PLAYERS):
		_nearby_players = maxi(0, _nearby_players - 1)


# ─── server-authoritative defend tick ────────────────────────────────────────


func _physics_process(delta: float) -> void:
	if _won or not _is_server:
		return

	# Reinforcement waves run regardless of occupancy — the siege keeps pressing.
	_wave_timer += delta
	if _wave_timer >= Settings.SIEGE_WAVE_INTERVAL:
		_wave_timer -= Settings.SIEGE_WAVE_INTERVAL
		_spawn_siege_wave()

	# Progress accrues ONLY while the squad is in the zone; it PAUSES (no drain) empty.
	if _nearby_players > 0:
		_hold_elapsed = minf(_hold_elapsed + delta, Settings.SIEGE_HOLD_TIME)
		_emit_progress()
		if _hold_elapsed >= Settings.SIEGE_HOLD_TIME:
			_win()


## Emit world_event_progress at most when the ratio changes by ~1/240 (≈4 Hz at 60 fps).
func _emit_progress() -> void:
	var ratio: float = event_ratio()
	if absf(ratio - _last_emit_ratio) < 0.004 and ratio < 1.0:
		return
	_last_emit_ratio = ratio
	Events.world_event_progress.emit(4, ratio)


## Lane interface: current defend ratio (0..1).
func event_ratio() -> float:
	if _won:
		return 1.0
	return clampf(_hold_elapsed / maxf(Settings.SIEGE_HOLD_TIME, 0.001), 0.0, 1.0)


## Lane interface: label string.
func event_label() -> String:
	return tr("Siege")


# ─── escalating reinforcement waves ──────────────────────────────────────────


func _spawn_siege_wave() -> void:
	var wm: Node = _get_wave_manager()
	if wm == null:
		return
	# Each wave grows by one; the WaveManager caps to its own reinforcement headroom.
	var count: int = Settings.SIEGE_WAVE_BASE + _wave_idx
	wm.call("spawn_reinforcements", count, global_position, true)
	_wave_idx += 1


## Locate the per-match WaveManager (the node exposing spawn_reinforcements). Mirrors the
## director's discipline: prefer the "wave_manager" group, fall back to an arena child scan.
func _get_wave_manager() -> Node:
	if is_instance_valid(_wave_manager):
		return _wave_manager
	if get_tree() == null:
		return null
	for node in get_tree().get_nodes_in_group(Groups.WAVE_MANAGER):
		if is_instance_valid(node) and node.has_method("spawn_reinforcements"):
			_wave_manager = node
			return _wave_manager
	# Fallback: scan the arena's children.
	for arena in get_tree().get_nodes_in_group(Groups.ARENA):
		for child in arena.get_children():
			if child.has_method("spawn_reinforcements"):
				_wave_manager = child
				return _wave_manager
	return null


# ─── win: spawn the loot burst + signals ─────────────────────────────────────


func _win() -> void:
	if _won:
		return
	_won = true
	set_physics_process(false)

	Events.world_event_progress.emit(4, 1.0)
	Events.notify.emit(tr("Position held — the siege breaks!"), 1)

	# Spawn the tier-3 loot burst on a ring around the zone center.
	_spawn_loot()

	# Tell the director we succeeded (it emits world_event_ended(4, true)).
	siege_completed.emit()

	# Beacon flashes bright gold-orange, then the zone fades out.
	_apply_beacon_win()

	# Free ourselves after a short delay so the win flash is visible.
	await get_tree().create_timer(3.0).timeout
	queue_free()


func _spawn_loot() -> void:
	# Resolve the loot container to parent pickups into (Net/Loot for replication).
	var loot_parent: Node = _loot_parent
	if loot_parent == null or not is_instance_valid(loot_parent):
		if get_tree() != null:
			for arena in get_tree().get_nodes_in_group(Groups.ARENA):
				var nl: Node = arena.get_node_or_null("Net/Loot")
				if nl != null:
					loot_parent = nl
					break
	if loot_parent == null:
		loot_parent = get_parent()
	if loot_parent == null:
		return

	# Dynamically load the loot helpers (guard null so this file parses standalone).
	var lt_script: GDScript = null
	var lt_path := "res://scripts/loot/loot_tables.gd"
	if ResourceLoader.exists(lt_path):
		lt_script = load(lt_path) as GDScript

	var lp_script: GDScript = null
	var lp_path := "res://scripts/loot/loot_pickup.gd"
	if ResourceLoader.exists(lp_path):
		lp_script = load(lp_path) as GDScript

	if lp_script == null:
		push_warning("SiegeZone: loot_pickup.gd not found — no loot spawned")
		return

	var count: int = Settings.SIEGE_LOOT_COUNT
	for i in range(count):
		var item_id: String = "loot_scrap"  # fallback id
		if lt_script != null and lt_script.has_method("roll_by_tier"):
			var rolled: String = lt_script.call("roll_by_tier", 3)
			if rolled != "":
				item_id = rolled
		# Even ring around the center so the burst reads as a reward pile.
		var ang: float = TAU * float(i) / float(maxi(count, 1))
		var r: float = 2.2
		var pos := global_position + Vector3(cos(ang) * r, 0.4, sin(ang) * r)
		lp_script.call("spawn_at", loot_parent, pos, item_id, 1)


# ─── procedural beacon ───────────────────────────────────────────────────────
# Mirrors supply_cache.gd's beacon idiom — a core sphere + pillar + OmniLight + rings —
# tinted hostile red-orange (siege aesthetic). Headless skips all visuals.


func _build_beacon() -> void:
	if DisplayServer.get_name() == "headless":
		set_process(false)
		return

	_beacon = Node3D.new()
	_beacon.name = "SiegeBeacon"
	add_child(_beacon)

	var tint := _IDLE_TINT

	# Glowing core sphere.
	_beacon_core = MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.5
	core_mesh.height = 1.0
	core_mesh.radial_segments = 16
	core_mesh.rings = 8
	_beacon_core.mesh = core_mesh
	_beacon_core.material_override = _emis(tint, 5.0)
	_beacon_core.position = Vector3(0.0, 1.0, 0.0)
	_beacon.add_child(_beacon_core)

	# Base plinth ring sized to the defend radius so the hold area reads on the ground.
	var base_ring := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = Settings.SIEGE_RADIUS
	base_mesh.bottom_radius = Settings.SIEGE_RADIUS
	base_mesh.height = 0.12
	base_mesh.radial_segments = 32
	base_ring.mesh = base_mesh
	base_ring.material_override = _additive(tint, 1.2)
	base_ring.position = Vector3(0.0, 0.06, 0.0)
	_beacon.add_child(base_ring)

	# Tall additive pillar.
	_beacon_pillar = MeshInstance3D.new()
	var pillar_mesh := CylinderMesh.new()
	pillar_mesh.top_radius = 0.28
	pillar_mesh.bottom_radius = 0.9
	pillar_mesh.height = 12.0
	pillar_mesh.radial_segments = 16
	_beacon_pillar.mesh = pillar_mesh
	_beacon_pillar.material_override = _additive(tint, 1.4)
	_beacon_pillar.position = Vector3(0.0, 6.0, 0.0)
	_beacon.add_child(_beacon_pillar)

	# OmniLight glow.
	_beacon_light = OmniLight3D.new()
	_beacon_light.light_color = tint
	_beacon_light.light_energy = 3.5
	_beacon_light.omni_range = 14.0
	_beacon_light.position = Vector3(0.0, 1.2, 0.0)
	_beacon.add_child(_beacon_light)

	# Two expanding/fading rings.
	for i in range(2):
		var ring := MeshInstance3D.new()
		var rm := CylinderMesh.new()
		rm.top_radius = 1.0
		rm.bottom_radius = 1.0
		rm.height = 0.05
		rm.radial_segments = 28
		ring.mesh = rm
		ring.material_override = _additive(tint, 1.8)
		ring.position = Vector3(0.0, 0.25, 0.0)
		_beacon.add_child(ring)
		_beacon_rings.append(ring)

	set_process(true)


func _emis(tint: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint * 0.4
	m.emission_enabled = true
	m.emission = tint
	m.emission_energy_multiplier = energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beacon_mats.append(m)
	return m


func _additive(tint: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(tint.r, tint.g, tint.b, 0.35)
	m.emission_enabled = true
	m.emission = tint
	m.emission_energy_multiplier = energy
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beacon_mats.append(m)
	return m


func _apply_beacon_tint(tint: Color, energy_mul: float) -> void:
	if _beacon == null:
		return
	for m in _beacon_mats:
		m.emission = tint
		var a: float = m.albedo_color.a
		if a < 1.0:
			m.albedo_color = Color(tint.r, tint.g, tint.b, a)
		else:
			m.albedo_color = tint * 0.4
	if _beacon_light != null:
		_beacon_light.light_color = tint
		_beacon_light.light_energy = 4.0 * energy_mul
	_beacon_pulse_base = energy_mul


func _apply_beacon_win() -> void:
	# Bright gold-orange flash on success.
	_apply_beacon_tint(_WIN_TINT, 2.0)


func _process(delta: float) -> void:
	if _beacon == null:
		return
	_beacon_time += delta

	# Shift tint with defend progress (idle red → held orange).
	if not _won and _is_server:
		var ratio: float = event_ratio()
		if ratio > 0.05:
			var tint: Color = _IDLE_TINT.lerp(_HELD_TINT, ratio)
			_apply_beacon_tint(tint, 1.0 + ratio * 0.5)

	# Core pulse.
	if _beacon_core != null:
		var pulse: float = 1.0 + 0.3 * sin(_beacon_time * 2.8)
		var cm := _beacon_core.material_override as StandardMaterial3D
		if cm != null:
			cm.emission_energy_multiplier = (5.0 * _beacon_pulse_base) * pulse
		_beacon_core.scale = Vector3.ONE * (1.0 + 0.05 * sin(_beacon_time * 2.8))

	# Pillar shimmer.
	if _beacon_pillar != null:
		var pm := _beacon_pillar.material_override as StandardMaterial3D
		if pm != null:
			pm.emission_energy_multiplier = (
				(1.4 * _beacon_pulse_base) * (1.0 + 0.18 * sin(_beacon_time * 1.3))
			)

	# Expanding/fading rings.
	var n: int = _beacon_rings.size()
	for i in range(n):
		var ring: MeshInstance3D = _beacon_rings[i]
		if ring == null:
			continue
		var phase: float = fmod(_beacon_time * 0.45 + float(i) / float(maxi(n, 1)), 1.0)
		var radius: float = 1.0 + phase * 4.0
		ring.scale = Vector3(radius, 1.0, radius)
		ring.position.y = 0.25 + phase * 1.0
		var rm := ring.material_override as StandardMaterial3D
		if rm != null:
			var fade: float = (1.0 - phase) * 0.55
			var tint: Color = _IDLE_TINT if not _won else _WIN_TINT
			rm.albedo_color = Color(tint.r, tint.g, tint.b, fade * 0.45)
			rm.emission_energy_multiplier = 1.8 * fade * _beacon_pulse_base
