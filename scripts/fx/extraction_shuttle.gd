class_name ExtractionShuttle
extends Node3D
## The EVAC DROPSHIP — staging for the raid's most important moment (D6.1). While someone
## fills an extraction beacon a procedural dropship banks in over the skyline, hangs above the
## zone with its ramp light burning a dust ring into the ground, and — the instant the fill
## completes — lights its mains and goes up like a candle. A cancelled fill gets the same
## departure WITHOUT the burn (it just lifts off and drifts away).
##
## PURE RENDER, PER-PEER, ZERO NETCODE. This node is not replicated and never writes game
## state: the owning ExtractionZone builds ONE locally on every peer out of state that peer
## ALREADY has (a player body overlapping the zone's Area3D, plus the server's own fill timers
## when it IS the server) and drives it through set_fill()/depart(). Nothing here touches
## input, the camera, physics or the Events bus — a client that never hears an extraction RPC
## still gets the identical show, and the player keeps full control throughout (this is a
## BACKDROP, not a cutscene).
##
## PERF: one instance per ACTIVE zone (the zone distance-gates the build and frees us once the
## camera leaves), every mesh with shadow casting OFF, exactly two lights (ramp spot + belly
## glow), no collision shapes, and the whole assembly self-frees at the end of the departure.
##
## Authored facing -Z (the project's model convention) in ZONE-local space: the shuttle node
## itself stays parked at the zone origin, `_ship` is what flies, and `_ground` holds the
## downwash FX pinned to the terrain under the beacon.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

enum Phase { APPROACH, HOVER, DEPART, DONE }

# --- choreography -------------------------------------------------------------------
const APPROACH_TIME: float = 3.8  # seconds of the banked arc from the skyline to the hover
const START_DIST: float = 95.0  # m out where the arc begins
const START_ALT: float = 52.0  # m up where the arc begins
const HOVER_ALT: float = 12.5  # m above the terrain the ship holds station at
const DEPART_MAX: float = 5.2  # hard cap on the departure before we free ourselves
const BOOST_HOLD: float = 0.35  # nozzles flare this long before the candle actually climbs
const BOOST_ACCEL: float = 13.0  # m/s² on a SUCCESSFUL extraction (the payoff)
const DRIFT_ACCEL: float = 1.7  # m/s² on a cancel/fail (tired lift-off, no burn)

# --- palette (machine-family: painted plate + dark frame + emissive signage) -----------
const _HULL := Color(0.34, 0.37, 0.41)
const _HULL_DARK := Color(0.19, 0.21, 0.24)
const _THRUST := Color(1.0, 0.68, 0.32)
const _NAV_PORT := Color(1.0, 0.2, 0.16)
const _NAV_STAR := Color(0.25, 1.0, 0.45)
const _STROBE := Color(1.0, 0.88, 0.6)
const _DUST := Color(0.42, 0.38, 0.33, 0.34)
const _FLARE_Z: float = 3.62  # z of the nozzle mouth the flame cone is welded to
const _FLARE_HALF: float = 1.1  # half the flame cone's authored length (it scales about its centre)

var _tint: Color = Color(0.25, 1.0, 0.6)  # zone hue — accents, ramp light, downwash ring
var _ground_y: float = -2.0  # zone-LOCAL y of the terrain under the beacon
var _heading: float = 0.0  # bearing (rad) the ship comes in on / drifts away along

var _ship: Node3D = null  # the flying assembly (everything below moves with it)
var _ground: Node3D = null  # static downwash FX pinned at the terrain
var _beam: MeshInstance3D = null  # additive ramp-light cone, stretched belly→ground
var _spot: SpotLight3D = null
var _belly_light: OmniLight3D = null
var _wash: MeshInstance3D = null  # flat ring the downwash burns into the ground
var _wash_mat: StandardMaterial3D = null
var _dust: GPUParticles3D = null
var _dust_on: bool = false
var _flares: Array[MeshInstance3D] = []  # thruster flame cones (scaled by throttle)
var _flare_mats: Array[StandardMaterial3D] = []
var _nozzle_mats: Array[StandardMaterial3D] = []
var _strobe_mats: Array[StandardMaterial3D] = []
var _beam_mat: StandardMaterial3D = null

var _phase: int = Phase.APPROACH
var _t: float = 0.0  # clock of the CURRENT phase
var _bob: float = 0.0  # free-running clock (bob / strobes / shimmer)
var _fill: float = 0.0  # extraction progress 0..1, fed by the zone
var _yaw: float = 0.0
var _target_yaw: float = 0.0
var _roll: float = 0.0
var _vel: float = 0.0  # departure climb rate
var _boost: bool = false  # departing on a SUCCESS (candle) vs a cancel (drift)
var _p0: Vector3 = Vector3.ZERO  # approach bezier: start / control / hover
var _p1: Vector3 = Vector3.ZERO
var _p2: Vector3 = Vector3.ZERO


## Build a dropship for a zone. `tint` is the beacon hue (accents/ramp light), `ground_y` the
## ZONE-LOCAL height of the terrain under it, `heading` the (deterministic, per-zone) bearing
## it flies in on. Static so the zone can `ExtractionShuttle.make(...)` + add_child it, exactly
## like PowerCore.make(). Caller is responsible for never building this on a headless server.
static func make(tint: Color, ground_y: float, heading: float) -> ExtractionShuttle:
	var s := ExtractionShuttle.new()
	s.name = "EvacShuttle"
	s._tint = tint
	s._ground_y = ground_y
	s._heading = heading
	s._build()
	return s


# ============================================================================ public API


## Feed the live extraction fill (0..1). Drives the strobe rate, ramp-light intensity and the
## downwash strength, so the ship visibly "spools up" as the bar completes.
func set_fill(ratio: float) -> void:
	_fill = clampf(ratio, 0.0, 1.0)


## Leave. `success` = the squad actually extracted → vertical candle with a real burn;
## otherwise a slow lift-off drifting back out along the approach bearing. Idempotent.
func depart(success: bool) -> void:
	if _phase == Phase.DEPART or _phase == Phase.DONE:
		return
	_phase = Phase.DEPART
	_t = 0.0
	_boost = success
	_vel = 2.0 if success else 1.1
	# AUDIO HOOK (lead): the departure cue belongs HERE — e.g.
	#   AudioManager.play_evac_shuttle("out_boost" if success else "out_soft", global_position)
	# Deliberately NOT called from this file: AudioManager is another lane's file and would
	# need a small public wrapper (its _play_at/_play are private). This node already exists
	# once per peer, so a plain local play here is correct — no RPC.


## True once the ship has committed to leaving (the zone stops feeding it).
func is_leaving() -> bool:
	return _phase == Phase.DEPART or _phase == Phase.DONE


## True when the show is over (the node also queue_free()s itself at that point).
func is_done() -> bool:
	return _phase == Phase.DONE


# ============================================================================ assembly


## Assemble the ship + the ground downwash and seed the approach arc.
func _build() -> void:
	_ground = Node3D.new()
	_ground.name = "Downwash"
	_ground.position = Vector3(0.0, _ground_y, 0.0)
	add_child(_ground)
	_build_ground(_ground)

	_ship = Node3D.new()
	_ship.name = "Ship"
	add_child(_ship)
	var plate: StandardMaterial3D = ProcPlating.armor_plate(_HULL, 71)
	var dark: StandardMaterial3D = ProcPlating.mech_hull(_HULL_DARK, 72)
	var frame: StandardMaterial3D = ProcPlating.steel(0.45)
	_build_hull(_ship, plate, dark, frame)
	_build_engines(_ship, plate, frame)
	_build_gear(_ship, frame)
	_build_lights(_ship)

	# Approach arc: in from `_heading`, curving through a side control point so the ship
	# BANKS through the turn instead of sliding down a straight line.
	_p2 = Vector3(0.0, _ground_y + HOVER_ALT, 0.0)
	_p0 = Vector3(cos(_heading) * START_DIST, _ground_y + START_ALT, sin(_heading) * START_DIST)
	var mid: float = START_DIST * 0.5
	_p1 = Vector3(
		cos(_heading + 0.85) * mid, _ground_y + START_ALT * 0.72, sin(_heading + 0.85) * mid
	)
	_ship.position = _p0
	# Enter already pointing down the path (model faces -Z) — otherwise frame 1 snaps.
	var lead: Vector3 = _p1 - _p0
	_target_yaw = atan2(-lead.x, -lead.z)
	_yaw = _target_yaw
	_ship.rotation = Vector3(0.0, _yaw, 0.0)
	_shadows_off(self)
	# AUDIO HOOK (lead): the arrival/approach cue belongs HERE (start of the arc) — e.g.
	#   AudioManager.play_evac_shuttle("in", global_position)


## Fuselage: dark keel frame, plated main body, faceted prow, canopy, dorsal spine + tail fin,
## angled side armour, the rear belly ramp and the tinted signage strips.
func _build_hull(
	root: Node3D, plate: StandardMaterial3D, dark: StandardMaterial3D, frame: StandardMaterial3D
) -> void:
	var accent: StandardMaterial3D = ProcPlating.glow(_tint, 3.0)
	_mi(root, _box(Vector3(1.9, 0.55, 8.2)), frame, Vector3(0.0, -0.55, 0.3))
	_mi(root, _box(Vector3(2.9, 1.5, 5.6)), plate, Vector3(0.0, 0.1, 0.2))
	_mi(root, _box(Vector3(2.4, 0.5, 4.6)), dark, Vector3(0.0, -0.78, 0.4))
	# Prow — a 6-sided cone laid on its side (tip forward, flattened vertically).
	_mi(
		root,
		_cone(1.45, 3.0, 6),
		plate,
		Vector3(0.0, 0.05, -4.0),
		Vector3(-90.0, 0.0, 0.0),
		Vector3(1.05, 1.0, 0.72)
	)
	# Canopy — raked dark glass with a faint interior glow.
	_mi(
		root,
		_box(Vector3(1.5, 0.5, 1.7)),
		_glass(_tint),
		Vector3(0.0, 0.82, -1.95),
		Vector3(-12.0, 0.0, 0.0)
	)
	_mi(root, _box(Vector3(1.3, 0.4, 3.6)), dark, Vector3(0.0, 0.95, 1.0))
	_mi(root, _box(Vector3(0.22, 1.5, 1.5)), plate, Vector3(0.0, 1.5, 2.6), Vector3(14.0, 0, 0))
	for s: float in [-1.0, 1.0]:
		# Angled shoulder armour + the tinted signage strip riding on it.
		_mi(
			root,
			_box(Vector3(0.45, 1.0, 3.8)),
			dark,
			Vector3(1.62 * s, 0.15, 0.4),
			Vector3(0.0, 0.0, -16.0 * s)
		)
		_mi(root, _box(Vector3(0.1, 0.12, 3.0)), accent, Vector3(1.88 * s, 0.42, 0.3))
	# Rear belly ramp (the light below pours out of it) + its glowing lip.
	_mi(root, _box(Vector3(1.7, 0.16, 2.0)), dark, Vector3(0.0, -1.02, 1.5))
	_mi(root, _box(Vector3(1.8, 0.07, 0.12)), accent, Vector3(0.0, -1.06, 0.52))


## Two outboard nacelles: pylon, plated barrel, intake ring, nozzle bell, the emissive throat
## disc and an additive flame cone whose length/energy IS the throttle readout.
func _build_engines(root: Node3D, plate: StandardMaterial3D, frame: StandardMaterial3D) -> void:
	var rot90 := Vector3(90.0, 0.0, 0.0)
	for s: float in [-1.0, 1.0]:
		var x: float = 2.3 * s
		_mi(root, _box(Vector3(0.9, 0.35, 1.4)), frame, Vector3(1.6 * s, 0.12, 1.3))
		_mi(root, _cyl(0.62, 2.8, 12), plate, Vector3(x, 0.1, 1.4), rot90)
		_mi(root, _cyl(0.72, 0.26, 12), frame, Vector3(x, 0.1, 0.05), rot90)
		# Nozzle bell — cone tip forward so the wide end flares backwards.
		_mi(root, _cone(0.78, 1.0, 12), frame, Vector3(x, 0.1, 3.1), Vector3(-90.0, 0.0, 0.0))
		var throat: StandardMaterial3D = ProcPlating.glow(_THRUST, 2.0)
		_nozzle_mats.append(throat)
		_mi(root, _cyl(0.5, 0.08, 12), throat, Vector3(x, 0.1, 3.56), rot90)
		var fm: StandardMaterial3D = _additive(_THRUST, 3.0, 0.5)
		_flare_mats.append(fm)
		var fz: float = _FLARE_Z + _FLARE_HALF * 0.2
		var flare: MeshInstance3D = _mi(root, _cone(0.5, 2.2, 10), fm, Vector3(x, 0.1, fz), rot90)
		flare.scale = Vector3(1.0, 0.2, 1.0)
		_flares.append(flare)


## Four splayed landing struts with rubber feet — the silhouette that says "this thing lands".
func _build_gear(root: Node3D, frame: StandardMaterial3D) -> void:
	var pad: StandardMaterial3D = ProcPlating.rubber(Color(0.12, 0.13, 0.14), 73)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_mi(
				root,
				_cyl(0.13, 1.5, 8),
				frame,
				Vector3(1.35 * sx, -1.45, 1.6 * sz),
				Vector3(0.0, 0.0, 12.0 * sx)
			)
			_mi(root, _cyl(0.34, 0.14, 10), pad, Vector3(1.66 * sx, -2.19, 1.6 * sz))


## Signage + the ramp light: steady nav lights (port red / starboard green), two blinking
## strobes, the downward ramp SpotLight and its additive beam cone, plus one soft belly glow.
func _build_lights(root: Node3D) -> void:
	_mi(root, _sphere(0.14), ProcPlating.glow(_NAV_PORT, 3.0), Vector3(-2.8, 0.42, 0.6))
	_mi(root, _sphere(0.14), ProcPlating.glow(_NAV_STAR, 3.0), Vector3(2.8, 0.42, 0.6))
	for pos: Vector3 in [Vector3(0.0, -1.15, -0.6), Vector3(0.0, 2.18, 2.9)]:
		var sm: StandardMaterial3D = ProcPlating.glow(_STROBE, 4.0)
		_strobe_mats.append(sm)
		_mi(root, _sphere(0.13), sm, pos)

	_beam_mat = _additive(_tint, 1.1, 0.18)
	_beam = _mi(root, _tube(0.55, 2.9, 18), _beam_mat, Vector3(0.0, -1.1, 0.9))
	_spot = SpotLight3D.new()
	_spot.light_color = _tint
	_spot.light_energy = 0.0
	_spot.spot_range = 34.0
	_spot.spot_angle = 24.0
	_spot.spot_angle_attenuation = 0.7
	_spot.shadow_enabled = false
	_spot.position = Vector3(0.0, -1.1, 0.9)
	_spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	root.add_child(_spot)
	_belly_light = OmniLight3D.new()
	_belly_light.light_color = _THRUST
	_belly_light.light_energy = 0.6
	_belly_light.omni_range = 9.0
	_belly_light.shadow_enabled = false
	_belly_light.position = Vector3(0.0, 0.1, 3.4)
	root.add_child(_belly_light)


## The downwash on the terrain: a flat additive ring + a ring-emitting dust burst. Lives under
## `_ground` (pinned at the pad) so it never rides along with the banking ship.
func _build_ground(root: Node3D) -> void:
	_wash_mat = _additive(_tint, 1.6, 0.0)
	var torus := TorusMesh.new()
	torus.inner_radius = 1.9
	torus.outer_radius = 3.3
	torus.rings = 28
	torus.ring_segments = 8
	_wash = MeshInstance3D.new()
	_wash.mesh = torus
	_wash.material_override = _wash_mat
	_wash.position = Vector3(0.0, 0.14, 0.0)
	root.add_child(_wash)

	_dust = GPUParticles3D.new()
	_dust.amount = 48
	_dust.lifetime = 1.5
	_dust.emitting = false
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0, 1, 0)
	pm.emission_ring_radius = 3.2
	pm.emission_ring_inner_radius = 1.1
	pm.emission_ring_height = 0.3
	pm.direction = Vector3(0, 0.35, 1)
	pm.flatness = 0.55
	pm.spread = 55.0
	pm.initial_velocity_min = 1.6
	pm.initial_velocity_max = 4.2
	pm.gravity = Vector3(0, 0.5, 0)
	pm.damping_min = 1.0
	pm.damping_max = 2.4
	pm.scale_min = 0.5
	pm.scale_max = 1.5
	pm.color = _DUST
	_dust.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 0.9)
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dm.albedo_color = _DUST
	dm.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material = dm
	_dust.draw_pass_1 = quad
	_dust.position = Vector3(0.0, 0.25, 0.0)
	root.add_child(_dust)


# ============================================================================ animation


func _process(delta: float) -> void:
	_bob += delta
	_t += delta
	match _phase:
		Phase.APPROACH:
			_tick_approach(delta)
		Phase.HOVER:
			_tick_hover(delta)
		Phase.DEPART:
			_tick_depart(delta)
		_:
			return
	_tick_lights(delta)


## The arc in: ease-OUT along the bezier so a heavy machine decelerates into its hover.
func _tick_approach(delta: float) -> void:
	var u: float = clampf(_t / APPROACH_TIME, 0.0, 1.0)
	var e: float = 1.0 - pow(1.0 - u, 2.4)
	var cur: Vector3 = _bezier(e)
	var nxt: Vector3 = _bezier(minf(e + 0.02, 1.0))
	_ship.position = cur
	_aim(cur, nxt, delta)
	if u >= 1.0:
		_phase = Phase.HOVER
		_t = 0.0


## Station-keeping: a slow bob/sway plus a lazy yaw drift, so it reads as ALIVE and holding.
func _tick_hover(delta: float) -> void:
	_ship.position = (
		_p2 + Vector3(sin(_bob * 0.7) * 0.16, sin(_bob * 1.1) * 0.26, cos(_bob * 0.9) * 0.12)
	)
	_yaw += delta * 0.09
	_roll = lerpf(_roll, sin(_bob * 0.6) * 0.05, 1.0 - exp(-3.0 * delta))
	_ship.rotation = Vector3(sin(_bob * 0.8) * 0.02, _yaw, _roll)


## Out: a SUCCESS holds a beat while the mains flare, then climbs like a candle with real
## acceleration; a cancel just lifts off and slides away along the approach bearing.
func _tick_depart(delta: float) -> void:
	var accel: float = BOOST_ACCEL if _boost else DRIFT_ACCEL
	if not _boost or _t > BOOST_HOLD:
		_vel += accel * delta
	_ship.position.y += _vel * delta
	if not _boost:
		var away: Vector3 = Vector3(cos(_heading), 0.0, sin(_heading))
		_ship.position += away * (delta * 8.0)
		_target_yaw = atan2(-away.x, -away.z)
		_yaw = lerp_angle(_yaw, _target_yaw, 1.0 - exp(-1.6 * delta))
	_roll = lerpf(_roll, 0.0, 1.0 - exp(-3.0 * delta))
	var pitch: float = -0.14 if _boost else -0.05
	_ship.rotation = Vector3(lerpf(_ship.rotation.x, pitch, 1.0 - exp(-2.0 * delta)), _yaw, _roll)
	# Shrink away over the last beat rather than POPPING out of existence — a material-free
	# stand-in for distance (the hull plates are opaque; runtime alpha would mean new mats).
	var tail: float = DEPART_MAX - 0.9
	if _t > tail:
		_ship.scale = Vector3.ONE * lerpf(1.0, 0.05, clampf((_t - tail) / 0.9, 0.0, 1.0))
	if _t > DEPART_MAX or _ship.position.y > _ground_y + 160.0:
		_phase = Phase.DONE
		queue_free()


## Everything emissive: strobe cadence (ramps with the fill), thruster throttle, the ramp beam
## stretched from the belly to the terrain, and the dust ring under it.
func _tick_lights(delta: float) -> void:
	# Strobes blink faster the closer the fill is to done — a visible countdown in the sky.
	var rate: float = 1.5 + _fill * 3.2
	var on: float = 1.0 if fmod(_bob * rate, 1.0) < 0.22 else 0.06
	for m in _strobe_mats:
		m.emission_energy_multiplier = 5.5 * on

	# Throttle: spools UP with the fill while hovering (the payoff has to be readable BEFORE
	# the bar completes — a solo extract cuts to the summary screen almost immediately), then
	# a hard burn on a successful departure.
	var throttle: float = 0.18 + _fill * 0.5 + 0.08 * sin(_bob * 6.0)
	if _phase == Phase.APPROACH:
		throttle = 0.55
	elif _phase == Phase.DEPART:
		throttle = (1.0 if _boost else 0.4) * minf(1.0, 0.25 + _t * 1.6)
	for m in _nozzle_mats:
		m.emission_energy_multiplier = 1.6 + throttle * 5.0
	for m in _flare_mats:
		m.emission_energy_multiplier = 1.2 + throttle * 4.5
		m.albedo_color = Color(_THRUST.r, _THRUST.g, _THRUST.b, 0.16 + throttle * 0.5)
	var flen: float = 0.15 + throttle * 1.9
	var fwid: float = 0.7 + throttle * 0.5
	for f in _flares:
		f.scale = Vector3(fwid, flen, fwid)
		# The cone scales about its CENTRE — walk it back so its mouth stays welded to the bell.
		f.position.z = _FLARE_Z + _FLARE_HALF * flen
	if _belly_light != null:
		_belly_light.light_energy = 0.4 + throttle * 5.0

	# Ramp light + downwash: full only while holding station, fading out on the way up.
	var lamp: float = 0.0
	if _phase == Phase.HOVER:
		lamp = 0.45 + 0.55 * _fill
	elif _phase == Phase.DEPART:
		lamp = maxf(0.0, 0.7 - _t * 1.4)
	_apply_beam(lamp)
	_apply_wash(lamp, delta)


## Stretch the additive ramp cone from the belly down to the terrain and match the spot energy.
func _apply_beam(lamp: float) -> void:
	if _beam == null:
		return
	var span: float = maxf(1.0, (_ship.position.y - 1.1) - _ground_y)
	_beam.scale = Vector3(1.0, span, 1.0)
	_beam.position = Vector3(0.0, -1.1 - span * 0.5, 0.9)
	_beam.visible = lamp > 0.02
	if _beam_mat != null:
		_beam_mat.albedo_color = Color(_tint.r, _tint.g, _tint.b, 0.05 + lamp * 0.16)
		_beam_mat.emission_energy_multiplier = 0.5 + lamp * 1.4
	if _spot != null:
		_spot.light_energy = lamp * 5.0


## The ground ring + dust burst under the ship. Toggling `emitting` only on the EDGE (a
## per-frame flip would restart the particle system every frame).
func _apply_wash(lamp: float, delta: float) -> void:
	var want: bool = lamp > 0.05
	if _dust != null and want != _dust_on:
		_dust_on = want
		_dust.emitting = want
	if _dust != null and want:
		_dust.amount_ratio = clampf(0.35 + lamp * 0.65, 0.0, 1.0)
	if _wash == null or _wash_mat == null:
		return
	_wash.visible = want
	if not want:
		return
	var puff: float = 1.0 + 0.06 * sin(_bob * 2.4)
	_wash.scale = Vector3(puff, 1.0, puff)
	_wash.rotation.y += delta * 0.35
	_wash_mat.albedo_color = Color(_tint.r, _tint.g, _tint.b, lamp * 0.22)
	_wash_mat.emission_energy_multiplier = 0.6 + lamp * 1.8


# ============================================================================ helpers


## Quadratic bezier along the approach arc.
func _bezier(u: float) -> Vector3:
	var iv: float = 1.0 - u
	return _p0 * (iv * iv) + _p1 * (2.0 * iv * u) + _p2 * (u * u)


## Point the hull down its flight path and bank into the turn (roll from the yaw RATE), with a
## touch of pitch from the climb/descent. Model faces -Z, so yaw = atan2(-dx, -dz).
func _aim(cur: Vector3, nxt: Vector3, delta: float) -> void:
	var d := Vector2(nxt.x - cur.x, nxt.z - cur.z)
	if d.length_squared() > 0.0004:
		_target_yaw = atan2(-d.x, -d.y)
	var prev: float = _yaw
	_yaw = lerp_angle(_yaw, _target_yaw, 1.0 - exp(-5.0 * delta))
	var rate: float = wrapf(_yaw - prev, -PI, PI) / maxf(delta, 0.0001)
	_roll = lerpf(_roll, clampf(-rate * 0.55, -0.6, 0.6), 1.0 - exp(-4.0 * delta))
	var pitch: float = clampf((nxt.y - cur.y) * 0.5, -0.22, 0.22)
	_ship.rotation = Vector3(pitch, _yaw, _roll)


# ------------------------------------------------------------------ part / material makers
# Thin aliases onto the shared procedural-model helpers so the ship is authored EXACTLY like
# every other model in the project (same primitives, same StandardMaterial3D contract).


static func _mi(
	root: Node3D,
	mesh: Mesh,
	mat: StandardMaterial3D,
	off: Vector3,
	rot: Vector3 = Vector3.ZERO,
	scl: Vector3 = Vector3.ONE
) -> MeshInstance3D:
	return ProceduralModels._part(root, mesh, mat, off, rot, scl)


static func _box(size: Vector3) -> BoxMesh:
	return ProceduralModels._box(size)


static func _cyl(r: float, h: float, seg: int = 10) -> CylinderMesh:
	return ProceduralModels._cyl(r, h, seg)


static func _cone(r: float, h: float, seg: int = 10) -> CylinderMesh:
	return ProceduralModels._cone(r, h, seg)


static func _sphere(r: float) -> SphereMesh:
	return ProceduralModels._sphere(r, false, 8, 12)


## Truncated cone of unit height (scaled per-frame into the ramp beam).
static func _tube(top_r: float, bottom_r: float, seg: int) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top_r
	m.bottom_radius = bottom_r
	m.height = 1.0
	m.radial_segments = seg
	return m


## Additive, unshaded, double-sided glow — beams, flames and the ground wash read as LIGHT.
static func _additive(tint: Color, energy: float, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(tint.r, tint.g, tint.b, alpha)
	m.emission_enabled = true
	m.emission = tint
	m.emission_energy_multiplier = energy
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Dark cockpit glass with a faint interior glow in the zone hue.
static func _glass(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.05, 0.06, 0.08)
	m.metallic = 0.9
	m.roughness = 0.12
	m.emission_enabled = true
	m.emission = tint
	m.emission_energy_multiplier = 0.5
	return m


## PERF: a 9 m ship overhead casting into the shadow atlas is pure cost for zero read.
static func _shadows_off(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in node.get_children():
		_shadows_off(c)
