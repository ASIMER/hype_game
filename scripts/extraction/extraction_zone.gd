extends Area3D
class_name ExtractionZone
## Server-authoritative extraction point. While a player (group "players") stays
## inside the zone, a per-player timer fills toward Settings.EXTRACTION_TIME; on
## completion the peer is marked extracted and, once every peer is resolved
## (dead or extracted), the match is won. Leaving the zone cancels and resets that
## player's progress.
##
## Attach to the Arena's ExtractionZone Area3D (collision layer extraction=16,
## mask player=2). Only the local authority server advances timers; progress is
## broadcast over Events so the HUD can render it. Clients simply listen.

# player node -> elapsed seconds inside the zone
var _timers: Dictionary = {}
# players that have already finished extracting (avoid double-completion)
var _completed: Dictionary = {}
var _is_server: bool = false

# --- Procedural beacon (visual only; built in _ready, animated in _process) ---
# A bright emissive core + a tall additive light pillar + an OmniLight3D for local
# glow + a couple of expanding/fading rings, so the zone reads as a landmark from
# across the 160x160 map. Tinted by open/closed state. Skipped on a headless server.
var _beacon: Node3D = null
var _beacon_core: MeshInstance3D = null
var _beacon_pillar: MeshInstance3D = null
var _beacon_light: OmniLight3D = null
var _beacon_rings: Array[MeshInstance3D] = []
var _beacon_spin_ring: MeshInstance3D = null       # slowly-rotating glowing ground ring
var _beacon_decal: Decal = null                    # soft radial ground glow (recoloured on flip)
var _beacon_mats: Array[StandardMaterial3D] = []   # all tinted mats (recolour on flip)
var _beacon_time: float = 0.0
var _beacon_pulse_base: float = 1.0          # 1.0 open / dimmer when closed
const _OPEN_TINT := Color(0.25, 1.0, 0.6)    # green/teal
const _CLOSED_TINT := Color(0.95, 0.6, 0.15) # dim amber

# --- Timed open/close window (driven server-auth by ExtractionDirector) ---
# Zones rotate between OPEN (extraction works) and CLOSED (fill is paused/ignored).
# Defaults to OPEN so the zone is usable even before a director attaches and on
# pure clients (which mirror state via Events.extraction_window_changed).
var _open: bool = true
var _window_remaining: float = 0.0

## True while this zone accepts extraction progress.
func is_open() -> bool:
	return _open

## Seconds left in the current open/closed window (informational; the director owns
## the authoritative countdown). 0 if unknown.
func window_remaining() -> float:
	return _window_remaining

## Server-auth: flip the open/closed state. Closing resets every in-progress fill
## (players must re-start when it reopens). Re-emits the window state for UIs.
## Single-player counts as server, so this drives offline play too.
func set_window(open: bool, remaining: float) -> void:
	_window_remaining = maxf(remaining, 0.0)
	if open == _open:
		# Same state — just refresh the countdown for listeners.
		Events.extraction_window_changed.emit(self, _open, _window_remaining)
		return
	_open = open
	_apply_beacon_tint()   # recolour the landmark beacon on a state flip (visual only)
	if not _open:
		# Closing: cancel anyone mid-extraction so they don't silently bank progress.
		for body in _timers.keys():
			if not _completed.has(body) and is_instance_valid(body):
				Events.extraction_cancelled.emit(body)
		_timers.clear()
	elif _is_server:
		# Reopening: pick up anyone already standing inside (body_entered won't re-fire).
		for body in get_overlapping_bodies():
			_on_body_entered(body)
	Events.extraction_window_changed.emit(self, _open, _window_remaining)

func _ready() -> void:
	add_to_group(Groups.EXTRACTION)   # so the minimap/compass can mark zones
	# Visual beacon (clients build it too so the landmark shows on every machine).
	_build_beacon()
	_is_server = GameState.is_local_authority_server()
	if not _is_server:
		# Clients don't advance extraction timers (server-auth), but still animate the
		# beacon via _process. Disable only the server-auth _physics_process.
		set_physics_process(false)
		return
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	# Pick up any players already overlapping when we attach.
	for body in get_overlapping_bodies():
		_on_body_entered(body)

func _on_body_entered(body: Node) -> void:
	if not _is_player(body):
		return
	if _completed.has(body):
		return
	if _timers.has(body):
		return
	# Closed zone: no fill accrues while standing inside (re-entry on reopen handled
	# by _physics_process, which only fills overlapping bodies once _open is true).
	if not _open:
		return
	_timers[body] = 0.0
	Events.extraction_started.emit(body, self)
	Events.extraction_progress.emit(body, 0.0)

func _on_body_exited(body: Node) -> void:
	if not _timers.has(body):
		return
	_timers.erase(body)
	# Don't fire a spurious cancel for a player who already finished.
	if not _completed.has(body):
		Events.extraction_cancelled.emit(body)

func _physics_process(delta: float) -> void:
	# Closed window: no progress accrues (timers are cleared on close, but guard so a
	# late body_entered race can't sneak in a fill).
	if not _open:
		return
	if _timers.is_empty():
		return
	# Iterate a copy so completion can erase from _timers mid-loop.
	for body in _timers.keys():
		if not is_instance_valid(body):
			_timers.erase(body)
			continue
		var elapsed: float = _timers[body] + delta
		var ratio: float = clampf(elapsed / maxf(Settings.EXTRACTION_TIME, 0.001), 0.0, 1.0)
		_timers[body] = elapsed
		Events.extraction_progress.emit(body, ratio)
		if ratio >= 1.0:
			_complete(body)

func _complete(body: Node) -> void:
	_timers.erase(body)
	_completed[body] = true
	# A DOWNED player can crawl into an OPEN evac and self-extract — clear their downed
	# state first so the bleedout timer can't true-kill them as they extract.
	if body.has_method("is_downed") and body.is_downed() and body.has_method("cancel_downed_for_extract"):
		body.cancel_downed_for_extract()
	Events.extraction_completed.emit(body)
	_mark_extracted(body)
	_grant_extraction(body)
	if GameState.all_players_resolved():
		NetworkManager.broadcast_match_won()

## Server-authoritative payout: the extracting player KEEPS its haul. We build the
## deposit from the found-loot Inventory (server-side authoritative) + the surviving
## brought consumables (replicated), then hand it to RaidManager, which deposits it into
## THAT peer's own stash (locally for the host, via RPC for a remote client) plus a
## wave-scaled survival-bonus currency. Death deposits nothing — gear is lost.
func _grant_extraction(body: Node) -> void:
	var peer_id := _peer_id_for(body)
	var stacks: Array = []
	var inv: Node = body.get_node_or_null("Inventory")
	if inv and "stacks" in inv:
		for s in inv.stacks:
			var it: ItemData = s.get("item", null)
			if it != null:
				stacks.append({ "id": it.id, "count": int(s.get("count", 0)) })
	if body.has_method("extracted_consumables"):
		stacks.append_array(body.extracted_consumables())
	var survival_bonus := 50 + GameState.current_wave * 25
	RaidManager.grant_extraction(peer_id, stacks, survival_bonus)

## Resolve the player node to a peer id and flag it extracted in GameState.
func _mark_extracted(body: Node) -> void:
	var peer_id := _peer_id_for(body)
	if peer_id != 0 and GameState.peers.has(peer_id):
		GameState.peers[peer_id]["extracted"] = true

func _peer_id_for(body: Node) -> int:
	# Player nodes are named after their peer id (see arena.gd _spawn_player).
	if body.name.is_valid_int():
		return body.name.to_int()
	if body.has_method("get_multiplayer_authority"):
		return body.get_multiplayer_authority()
	return 0

func _is_player(body: Node) -> bool:
	return body != null and body.is_in_group(Groups.PLAYERS)

# ============================================================ PROCEDURAL BEACON
# Visual landmark only — none of this touches the server-auth window/progress logic.

## Build the beacon assembly under the zone: hide the old translucent box, add a
## glowing core, a tall additive light pillar, an OmniLight3D, and animated rings.
## Cheap on headless (skips meshes/lights — pure server keeps zero visual cost).
func _build_beacon() -> void:
	# Hide BOTH placeholder boxes from Arena.tscn: the styled translucent "Beacon" AND the
	# plain unlit "Mesh" — the latter renders as a DEFAULT GREY CUBE (no material override) and
	# was the "ugly grey box" obscuring this beacon. Hiding it in code covers all 12 zones.
	for placeholder in ["Beacon", "Mesh"]:
		var old: Node = get_node_or_null(placeholder)
		if old is MeshInstance3D:
			(old as MeshInstance3D).visible = false

	if DisplayServer.get_name() == "headless":
		# Dedicated server: no visuals needed, and no _process animation.
		set_process(false)
		return

	_beacon = Node3D.new()
	_beacon.name = "ProcBeacon"
	add_child(_beacon)
	var tint := _OPEN_TINT if _open else _CLOSED_TINT

	# Glowing core — a small bright sphere just above the ground.
	var core_mat := _emis(tint, 6.0)
	_beacon_core = MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.6
	core_mesh.height = 1.2
	core_mesh.radial_segments = 16
	core_mesh.rings = 8
	_beacon_core.mesh = core_mesh
	_beacon_core.material_override = core_mat
	_beacon_core.position = Vector3(0, 1.2, 0)
	_beacon.add_child(_beacon_core)

	# A short emissive plinth ring at the base so the footprint glows too.
	var base_ring := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 2.6
	base_mesh.bottom_radius = 2.8
	base_mesh.height = 0.2
	base_mesh.radial_segments = 24
	base_ring.mesh = base_mesh
	base_ring.material_override = _emis(tint, 3.0)
	base_ring.position = Vector3(0, 0.1, 0)
	_beacon.add_child(base_ring)

	# Tall additive light pillar — the see-it-from-across-the-map shaft.
	_beacon_pillar = MeshInstance3D.new()
	var pillar_mesh := CylinderMesh.new()
	pillar_mesh.top_radius = 0.35
	pillar_mesh.bottom_radius = 1.1
	pillar_mesh.height = 16.0
	pillar_mesh.radial_segments = 16
	_beacon_pillar.mesh = pillar_mesh
	_beacon_pillar.material_override = _additive(tint, 1.6)
	_beacon_pillar.position = Vector3(0, 8.0, 0)
	_beacon.add_child(_beacon_pillar)

	# Local glow light.
	_beacon_light = OmniLight3D.new()
	_beacon_light.light_color = tint
	_beacon_light.light_energy = 4.0
	_beacon_light.omni_range = 14.0
	_beacon_light.position = Vector3(0, 1.5, 0)
	_beacon.add_child(_beacon_light)

	# A couple of expanding/fading rings (flat thin cylinders) animated in _process.
	for i in range(2):
		var ring := MeshInstance3D.new()
		var rm := CylinderMesh.new()
		rm.top_radius = 1.0
		rm.bottom_radius = 1.0
		rm.height = 0.06
		rm.radial_segments = 28
		ring.mesh = rm
		ring.material_override = _additive(tint, 2.0)
		ring.position = Vector3(0, 0.3, 0)
		_beacon.add_child(ring)
		_beacon_rings.append(ring)

	# ── "Divine light" upgrade ───────────────────────────────────────────────────
	# A wide god-ray CONE beaming DOWN from the sky onto the zone (wide at the top, narrowing
	# to the ground) — additive + soft so it reads as a shaft of light from above, not solid.
	var beam := MeshInstance3D.new()
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 6.0
	beam_mesh.bottom_radius = 1.3
	beam_mesh.height = 22.0
	beam_mesh.radial_segments = 24
	beam.mesh = beam_mesh
	beam.material_override = _additive(tint, 0.6)   # softer than the central pillar
	beam.position = Vector3(0, 11.0, 0)
	_beacon.add_child(beam)

	# A flat glowing RING flush on the ground that slowly SPINS — the "крутящийся круг".
	_beacon_spin_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 2.4
	torus.outer_radius = 3.0
	torus.rings = 32
	torus.ring_segments = 10
	_beacon_spin_ring.mesh = torus
	_beacon_spin_ring.material_override = _additive(tint, 2.8)
	_beacon_spin_ring.position = Vector3(0, 0.12, 0)
	_beacon.add_child(_beacon_spin_ring)

	# A soft radial ground glow so the circle reads on the terrain (reuses the climate-zone
	# radial mask). Pure emissive — modulate carries the green/amber tint, recoloured on flip.
	_beacon_decal = Decal.new()
	_beacon_decal.size = Vector3(9.0, 6.0, 9.0)
	var glow_tex: Texture2D = ProceduralClimateZones._radial_texture()
	_beacon_decal.texture_albedo = glow_tex
	_beacon_decal.texture_emission = glow_tex
	_beacon_decal.emission_energy = 1.8
	_beacon_decal.albedo_mix = 0.25
	_beacon_decal.modulate = tint
	_beacon_decal.upper_fade = 0.4
	_beacon_decal.lower_fade = 0.4
	_beacon_decal.position = Vector3(0, 1.0, 0)
	_beacon.add_child(_beacon_decal)

	_apply_beacon_tint()
	set_process(true)

## Emissive solid material (registered for recolour on state flip).
func _emis(tint: Color, energy: float) -> StandardMaterial3D:
	var m := ProcMaterials.emissive(tint, energy, tint * 0.4)
	_beacon_mats.append(m)
	return m

## Additive, transparent, unshaded material for the pillar/rings (so they read as
## light, not solid geometry). Registered for recolour on state flip.
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

## Recolour every beacon material + the light to match the current open/closed state.
func _apply_beacon_tint() -> void:
	if _beacon == null:
		return
	var tint := _OPEN_TINT if _open else _CLOSED_TINT
	var energy_mul := 1.0 if _open else 0.55   # dim when closed
	for m in _beacon_mats:
		m.emission = tint
		# Preserve each material's relative alpha while restating the hue.
		var a: float = m.albedo_color.a
		m.albedo_color = Color(tint.r, tint.g, tint.b, a) if a < 1.0 else tint * 0.4
	if _beacon_light != null:
		_beacon_light.light_color = tint
		_beacon_light.light_energy = (5.0 if _open else 2.0)
	# A bigger, brighter pillar when open.
	if _beacon_pillar != null:
		_beacon_pillar.scale = Vector3(1.0, 1.0, 1.0) if _open else Vector3(0.7, 0.7, 0.7)
	# The ground glow decal carries its tint via modulate (not in _beacon_mats).
	if _beacon_decal != null:
		_beacon_decal.modulate = tint
	_beacon_pulse_base = energy_mul

## Animate the beacon: a gentle core pulse + expanding/fading rings + a slow pillar
## shimmer. Cheap; disabled entirely on headless (set_process(false) in _build).
func _process(delta: float) -> void:
	if _beacon == null:
		return
	_beacon_time += delta
	# Core pulse (brightness breathes).
	if _beacon_core != null:
		var pulse := 1.0 + 0.35 * sin(_beacon_time * 3.0)
		var cm := _beacon_core.material_override as StandardMaterial3D
		if cm != null:
			cm.emission_energy_multiplier = (6.0 * _beacon_pulse_base) * pulse
		_beacon_core.scale = Vector3.ONE * (1.0 + 0.06 * sin(_beacon_time * 3.0))
	# Slowly spin the glowing ground ring (the "spinning glowing circle").
	if _beacon_spin_ring != null:
		_beacon_spin_ring.rotation.y += delta * 0.6
	# Pillar subtle vertical shimmer.
	if _beacon_pillar != null:
		var pm := _beacon_pillar.material_override as StandardMaterial3D
		if pm != null:
			pm.emission_energy_multiplier = (1.6 * _beacon_pulse_base) * (1.0 + 0.2 * sin(_beacon_time * 1.5))
	# Expanding/fading rings — each ring grows from ~1 to ~4.5 then resets, fading out.
	var n := _beacon_rings.size()
	for i in range(n):
		var ring := _beacon_rings[i]
		if ring == null:
			continue
		var phase: float = fmod(_beacon_time * 0.5 + float(i) / float(maxi(n, 1)), 1.0)
		var radius := 1.0 + phase * 3.5
		ring.scale = Vector3(radius, 1.0, radius)
		ring.position.y = 0.3 + phase * 1.2
		var rm := ring.material_override as StandardMaterial3D
		if rm != null:
			var fade := (1.0 - phase) * (0.6 if _open else 0.3)
			var tint := _OPEN_TINT if _open else _CLOSED_TINT
			rm.albedo_color = Color(tint.r, tint.g, tint.b, fade * 0.5)
			rm.emission_energy_multiplier = 2.0 * fade * _beacon_pulse_base
