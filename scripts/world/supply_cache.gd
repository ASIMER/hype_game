extends Area3D
## SupplyCache — a guarded loot cache that players must hold to crack open.
##
## Mirror of ExtractionZone (Area3D, collision_layer=16 / mask=2) — server-auth hold
## timer → crack → loot drop. The WorldEventDirector instances this, sets `tier`, and
## connects `cache_cracked` to know when to clear `_active_kind`.
##
## "world_events" group convention (for Lane C — map / HUD):
##   - This node is added to the group "world_events" in _ready.
##   - get_meta("event_kind")  -> 0
##   - get_meta("event_label") -> "Supply Cache"
##   - get_meta("event_pos")   -> Vector3 (set in _ready from global_position)
##   - func event_ratio()      -> float  0..1 (hold-timer fill ratio)
##   - func event_label()      -> String ("Supply Cache")

## Emitted when the cache is successfully cracked (director clears active_kind).
signal cache_cracked

## Loot rarity tier (1 low … 3 high). Set by the director before add_child.
var tier: int = 2

## Optional: the director sets this to Net/Loot so spawned pickups replicate.
var _loot_parent: Node = null

func set_loot_parent(parent: Node) -> void:
	_loot_parent = parent

# ─── hold-timer state ────────────────────────────────────────────────────────

var _hold_elapsed: float = 0.0   # seconds a player has been holding
var _cracked: bool = false
var _is_server: bool = false

# ─── beacon visual ────────────────────────────────────────────────────────────

var _beacon: Node3D = null
var _beacon_core: MeshInstance3D = null
var _beacon_pillar: MeshInstance3D = null
var _beacon_light: OmniLight3D = null
var _beacon_rings: Array[MeshInstance3D] = []
var _beacon_mats: Array[StandardMaterial3D] = []
var _beacon_time: float = 0.0
var _beacon_pulse_base: float = 1.0

# Gold/amber tint while holding; bright gold on crack.
const _IDLE_TINT := Color(0.9, 0.7, 0.1)    # amber-gold (supply)
const _HOLD_TINT := Color(0.2, 0.9, 1.0)    # cyan while held
const _CRACK_TINT := Color(1.0, 0.9, 0.3)   # bright gold on crack

# ─── lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group(Groups.WORLD_EVENTS)
	# Expose Lane C metadata.
	set_meta("event_kind", 0)
	set_meta("event_label", tr("Supply Cache"))
	# event_pos is set after global_position is available (call_deferred).
	call_deferred("_set_pos_meta")

	_build_beacon()

	_is_server = GameState.is_local_authority_server()
	if not _is_server:
		# Clients see the visual but don't run the hold logic.
		set_physics_process(false)
		return

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _set_pos_meta() -> void:
	set_meta("event_pos", global_position)

# ─── proximity tracking ───────────────────────────────────────────────────────

var _nearby_players: int = 0

func _on_body_entered(body: Node) -> void:
	if _cracked:
		return
	if body != null and body.is_in_group(Groups.PLAYERS):
		_nearby_players += 1
		Events.interaction_available.emit(tr("[Hold] Crack supply cache"), self)

func _on_body_exited(body: Node) -> void:
	if body != null and body.is_in_group(Groups.PLAYERS):
		_nearby_players = maxi(0, _nearby_players - 1)
	if _nearby_players == 0 and not _cracked:
		Events.interaction_cleared.emit()

# ─── server-authoritative hold tick ──────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if _cracked or not _is_server:
		return

	if _nearby_players > 0:
		_hold_elapsed = minf(_hold_elapsed + delta, Settings.SUPPLY_CACHE_HOLD_TIME)
		var ratio: float = _hold_elapsed / maxf(Settings.SUPPLY_CACHE_HOLD_TIME, 0.001)
		Events.world_event_progress.emit(0, ratio)
		if _hold_elapsed >= Settings.SUPPLY_CACHE_HOLD_TIME:
			_crack()
	else:
		# Drain slowly when no one is holding (grace: drain at 0.5× the fill rate).
		if _hold_elapsed > 0.0:
			_hold_elapsed = maxf(0.0, _hold_elapsed - delta * 0.5)
			var ratio: float = _hold_elapsed / maxf(Settings.SUPPLY_CACHE_HOLD_TIME, 0.001)
			Events.world_event_progress.emit(0, ratio)

## Lane C interface: current hold ratio (0..1).
func event_ratio() -> float:
	if _cracked:
		return 1.0
	return clampf(_hold_elapsed / maxf(Settings.SUPPLY_CACHE_HOLD_TIME, 0.001), 0.0, 1.0)

## Lane C interface: label string.
func event_label() -> String:
	return tr("Supply Cache")

# ─── crack: spawn loot + signals ─────────────────────────────────────────────

func _crack() -> void:
	if _cracked:
		return
	_cracked = true
	set_physics_process(false)

	Events.world_event_progress.emit(0, 1.0)
	Events.world_event_ended.emit(0, true)
	Events.notify.emit(tr("Supply cache cracked! Loot secured."), 1)
	Events.interaction_cleared.emit()

	# Tell the director we're done (it will clear _active_kind).
	cache_cracked.emit()

	# Spawn loot pickups — load LootTables dynamically so this file parses
	# even if loot_tables.gd hasn't landed yet.
	_spawn_loot()

	# Beacon goes bright gold then fades.
	_apply_beacon_crack()

	# Free ourselves after a short delay so the beacon flash is visible.
	await get_tree().create_timer(3.0).timeout
	queue_free()

func _spawn_loot() -> void:
	# Determine the loot container to parent pickups into.
	var loot_parent: Node = _loot_parent
	if loot_parent == null or not is_instance_valid(loot_parent):
		# Fallback: walk up to the arena (group "arena") and find Net/Loot.
		if get_tree() != null:
			for arena in get_tree().get_nodes_in_group(Groups.ARENA):
				var nl: Node = arena.get_node_or_null("Net/Loot")
				if nl != null:
					loot_parent = nl
					break
	if loot_parent == null:
		loot_parent = get_parent()

	# Dynamically load LootTables (lane A; guard null).
	var lt_script: GDScript = null
	var lt_path := "res://scripts/loot/loot_tables.gd"
	if ResourceLoader.exists(lt_path):
		lt_script = load(lt_path) as GDScript

	# Dynamically load LootPickup static.
	var lp_script: GDScript = null
	var lp_path := "res://scripts/loot/loot_pickup.gd"
	if ResourceLoader.exists(lp_path):
		lp_script = load(lp_path) as GDScript

	if lp_script == null:
		push_warning("SupplyCache: loot_pickup.gd not found — no loot spawned")
		return

	var count: int = Settings.SUPPLY_CACHE_LOOT
	for i in range(count):
		var item_id: String = "loot_scrap"   # fallback id
		if lt_script != null and lt_script.has_method("roll_by_tier"):
			var rolled: String = lt_script.call("roll_by_tier", tier)
			if rolled != "":
				item_id = rolled

		var jitter := Vector3(
			randf_range(-1.5, 1.5),
			0.1,
			randf_range(-1.5, 1.5)
		)
		lp_script.call("spawn_at", loot_parent, global_position + jitter, item_id, 1)

# ─── procedural beacon ───────────────────────────────────────────────────────
# Mirrors extraction_zone.gd's beacon — a core sphere + pillar + OmniLight + rings.
# Tinted amber-gold (supply cache aesthetic). Headless skips all visuals.

func _build_beacon() -> void:
	if DisplayServer.get_name() == "headless":
		set_process(false)
		return

	_beacon = Node3D.new()
	_beacon.name = "CacheBeacon"
	add_child(_beacon)

	var tint := _IDLE_TINT

	# Glowing core sphere.
	var core_mat := _emis(tint, 5.0)
	_beacon_core = MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.5
	core_mesh.height = 1.0
	core_mesh.radial_segments = 16
	core_mesh.rings = 8
	_beacon_core.mesh = core_mesh
	_beacon_core.material_override = core_mat
	_beacon_core.position = Vector3(0.0, 1.0, 0.0)
	_beacon.add_child(_beacon_core)

	# Base plinth ring.
	var base_ring := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 2.2
	base_mesh.bottom_radius = 2.4
	base_mesh.height = 0.15
	base_mesh.radial_segments = 24
	base_ring.mesh = base_mesh
	base_ring.material_override = _emis(tint, 2.5)
	base_ring.position = Vector3(0.0, 0.07, 0.0)
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
	_beacon_light.omni_range = 12.0
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

func _apply_beacon_crack() -> void:
	# Bright gold flash on crack.
	_apply_beacon_tint(_CRACK_TINT, 2.0)

func _process(delta: float) -> void:
	if _beacon == null:
		return
	_beacon_time += delta

	# Shift tint based on hold progress (idle amber → hold cyan).
	if not _cracked and _is_server:
		var ratio: float = event_ratio()
		if ratio > 0.05:
			var tint: Color = _IDLE_TINT.lerp(_HOLD_TINT, ratio)
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
			pm.emission_energy_multiplier = (1.4 * _beacon_pulse_base) * (1.0 + 0.18 * sin(_beacon_time * 1.3))

	# Expanding/fading rings.
	var n: int = _beacon_rings.size()
	for i in range(n):
		var ring: MeshInstance3D = _beacon_rings[i]
		if ring == null:
			continue
		var phase: float = fmod(_beacon_time * 0.45 + float(i) / float(maxi(n, 1)), 1.0)
		var radius: float = 1.0 + phase * 3.0
		ring.scale = Vector3(radius, 1.0, radius)
		ring.position.y = 0.25 + phase * 1.0
		var rm := ring.material_override as StandardMaterial3D
		if rm != null:
			var fade: float = (1.0 - phase) * 0.55
			var tint: Color = _IDLE_TINT if not _cracked else _CRACK_TINT
			rm.albedo_color = Color(tint.r, tint.g, tint.b, fade * 0.45)
			rm.emission_energy_multiplier = 1.8 * fade * _beacon_pulse_base
