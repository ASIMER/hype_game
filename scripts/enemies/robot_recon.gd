extends RobotFlyer
class_name RobotRecon
## Recon drone (robot_specter). A FLYING, NON-LETHAL support enemy: it never deals
## damage. Instead, when it holds confirmed line-of-sight to a player for
## `channel_time` seconds (orbiting the whole time so it's a moving target), it
## "marks" that player — emitting a loud alert + calling a squad of HUNTER
## reinforcements onto the player's position — then flees for RECON_RETREAT_TIME and
## locks itself out of re-channelling for RECON_RECHANNEL_CD. Kill it fast, break its
## sightline, or smoke it to deny the call.
##
## Extends RobotFlyer (wasp): inherits hover/orbit movement, separation, the HP-bar,
## the perception FSM and the smoke-aware _check_line_of_sight. We KEEP the flyer's
## orbit-while-in-ATTACK behaviour but rip out the hitscan (_strike → no-op) and layer
## the channel state machine on top.
##
## NET MODEL: all channel/spawn/retreat logic is SERVER-authoritative (it runs inside
## _do_attack/_do_chase, which the base only ticks on the authority). `_channel_t` and
## the retreat/cooldown bookkeeping are server-side only — they are NOT replicated.
## Clients render the telegraph BEAM purely off the replicated `current_state`: on this
## archetype ATTACK uniquely means "channelling", so every peer can draw the beam from
## the replicated state without any extra synced fields.

# How long the marking beam takes to lock (read from stats in _ready). The visual
# telegraph ramps over this same window so a player sees the lock coming.
var _channel_time: float = 2.5
# How many hunter reinforcements a completed channel summons.
var _recon_reinforce: int = 3

# SERVER-ONLY channel accumulator. Named exactly `_channel_t` so AgentBridge can read
# it via e.get("_channel_t"). Counts UP while ATTACK + LOS; decays fast on LOS break.
var _channel_t: float = 0.0
# SERVER-ONLY retreat state: true → flee directly away from the marked target.
var _retreating: bool = false
var _retreat_until_ms: int = 0
# SERVER-ONLY re-channel lockout deadline (Time.get_ticks_msec()); 0 = ready.
var _rechannel_at_ms: int = 0

# --- Telegraph beam (visual only, every peer; skipped on a headless server) ---
# A thin unshaded red cylinder stretched from the drone toward the nearest player
# visual, rebuilt each frame while current_state == ATTACK. Width/alpha rise over
# ~_channel_time so the mark reads as charging. Lazily created, hidden when not
# channelling. Lives under ModelRoot so it inherits no body-yaw surprises (we set its
# global transform explicitly each frame anyway).
const BEAM_RADIUS: float = 0.06
var _beam: MeshInstance3D = null
var _beam_mat: StandardMaterial3D = null
# Local accumulator driving the beam pulse on CLIENTS (server uses _channel_t; clients
# have no _channel_t, so they ramp their own timer while the replicated state is ATTACK).
var _beam_t: float = 0.0


func _ready() -> void:
	super._ready()
	var stats: Dictionary = Settings.ENEMY_STATS.get(enemy_id, {})
	_channel_time = stats.get("channel_time", 2.5)
	_recon_reinforce = int(stats.get("recon_reinforce", 3))


## OVERRIDE: the recon drone deals NO damage — its "attack" is the channel, handled in
## _do_attack. Make the no-op explicit so a stray cooldown tick can never hurt a player.
func _strike(_target_node: Node) -> void:
	pass


## OVERRIDE: while ATTACKing, keep orbiting (moving target) and advance the channel.
## During an active retreat, flee instead. The base flyer's _do_attack would call
## _strike on cooldown; we replace it wholesale so cooldown is irrelevant.
func _do_attack(delta: float) -> void:
	if _retreating:
		_flee(delta)
		return
	# Orbit like the wasp so the drone is hard to hit while it marks.
	_apply_movement(_orbit_dir(delta), delta)
	if _target and is_instance_valid(_target):
		_face_towards(_target.global_position, delta)
	_advance_channel(delta)


## OVERRIDE: a retreating drone flees even if the FSM still wants to CHASE (it lost the
## marked target's range). Otherwise behave exactly like the flyer's orbit-approach.
func _do_chase(delta: float) -> void:
	if _retreating:
		_flee(delta)
		return
	# Not channelling (out of attack range / no LOS yet) — let the channel decay so a
	# brief re-acquire doesn't instantly complete a near-finished mark.
	_decay_channel(delta)
	super._do_chase(delta)


## SERVER: grow the channel while LOS is confirmed; decay it fast when the sightline is
## broken (e.g. the player ducks behind cover or pops smoke) — _check_line_of_sight is
## smoke-aware, so a smoked target stalls the mark. On completion, fire the call + retreat.
func _advance_channel(delta: float) -> void:
	if not GameState.is_local_authority_server():
		return
	if _rechannel_at_ms > 0 and Time.get_ticks_msec() < _rechannel_at_ms:
		# Locked out after a recent call — sit in ATTACK orbiting but never charge.
		return
	var locked_on := (
		_target != null and is_instance_valid(_target) and _check_line_of_sight(_target)
	)
	if locked_on:
		_channel_t += delta
		if _channel_t >= _channel_time:
			_complete_channel()
	else:
		_decay_channel(delta)


## SERVER: fast decay (×3) so the mark can't be slowly farmed through intermittent LOS.
func _decay_channel(delta: float) -> void:
	if not GameState.is_local_authority_server():
		return
	if _channel_t > 0.0:
		_channel_t = maxf(0.0, _channel_t - delta * 3.0)


## SERVER: a successful mark. Emit a loud alert at the player (waking nearby patrols via
## the existing cascade), summon a squad of HUNTER reinforcements onto the player's
## position, then enter the retreat + re-channel lockout and reset the accumulator.
func _complete_channel() -> void:
	if _target == null or not is_instance_valid(_target):
		_channel_t = 0.0
		return
	var mark_pos := _target.global_position
	Events.enemy_alerted.emit(mark_pos, 1.5)
	var wm := get_tree().get_first_node_in_group(Groups.WAVE_MANAGER)
	if wm != null and wm.has_method("spawn_reinforcements"):
		wm.call("spawn_reinforcements", _recon_reinforce, mark_pos, true)
	_channel_t = 0.0
	_retreating = true
	_retreat_until_ms = Time.get_ticks_msec() + int(Settings.RECON_RETREAT_TIME * 1000.0)
	_rechannel_at_ms = Time.get_ticks_msec() + int(Settings.RECON_RECHANNEL_CD * 1000.0)


## SERVER: flee straight away from the marked target at full hover speed for the retreat
## window. _apply_movement (flyer override) keeps us at hover height while we run.
func _flee(delta: float) -> void:
	if Time.get_ticks_msec() >= _retreat_until_ms:
		_retreating = false
		return
	var away := Vector3.ZERO
	if _target != null and is_instance_valid(_target):
		away = global_position - _target.global_position
		away.y = 0.0
		away = away.normalized() if away.length() > 0.001 else Vector3.ZERO
	if away == Vector3.ZERO:
		# Lost the target mid-flee — drift on current facing so we still clear the area.
		away = -global_transform.basis.z
		away.y = 0.0
		away = away.normalized() if away.length() > 0.001 else Vector3.ZERO
	_apply_movement(away, delta)
	if away != Vector3.ZERO:
		_face_towards(global_position + away, delta)


# --- Telegraph beam (visual only) -------------------------------------------


## OVERRIDE: drive the wasp idle anim (rotors/body/core) AND the marking beam. The base
## _process calls _animate_visual on all peers, so the beam updates on clients too —
## they key it off the replicated `current_state` (ATTACK == channelling here).
func _animate_visual(delta: float) -> void:
	super._animate_visual(delta)
	_update_beam(delta)


## Build (lazily) / show / hide the marking beam. On a headless server there is no
## rendering, so we skip entirely. While current_state == ATTACK we point a stretched
## cylinder from the body at the nearest player visual and ramp its width + alpha over
## ~_channel_time for the telegraph; otherwise we hide it and reset the ramp.
func _update_beam(delta: float) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var channelling := current_state == State.ATTACK
	if not channelling:
		_beam_t = 0.0
		if _beam != null:
			_beam.visible = false
		return
	var target := _nearest_player_visual()
	if target == null:
		if _beam != null:
			_beam.visible = false
		return
	_beam_t = minf(_channel_time, _beam_t + delta)
	if _beam == null:
		_build_beam()
	_beam.visible = true

	# Endpoints in WORLD space: from our core toward the player's chest.
	var from := global_position + Vector3.UP * 0.3
	var to := target.global_position + Vector3.UP * 1.0
	var seg := to - from
	var len := seg.length()
	if len < 0.05:
		_beam.visible = false
		return

	# Stretch the unit-height cylinder (default axis +Y) along the segment: scale Y to
	# the length, then aim +Y down the direction. We set the global transform directly
	# (the mesh sits under ModelRoot but we don't want to inherit the body yaw/flinch).
	var dir := seg / len
	var basis_y := dir
	var up_ref := Vector3.UP if absf(basis_y.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var basis_x := up_ref.cross(basis_y).normalized()
	var basis_z := basis_x.cross(basis_y).normalized()
	# Ramp: thin/faint at the start, full by lock.
	var k := _beam_t / maxf(0.01, _channel_time)  # 0 -> 1
	var width := lerpf(0.4, 1.0, k)
	var b := Basis(basis_x * width, basis_y * len, basis_z * width)
	_beam.global_transform = Transform3D(b, from + dir * (len * 0.5))
	if _beam_mat != null:
		# Pulse the alpha so it shimmers, rising to near-opaque at the lock.
		var pulse := 0.75 + 0.25 * sin(_anim_time * 14.0)
		_beam_mat.albedo_color.a = clampf(lerpf(0.12, 0.85, k) * pulse, 0.0, 1.0)
		_beam_mat.emission_energy_multiplier = lerpf(1.5, 5.0, k)


func _build_beam() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = BEAM_RADIUS
	mesh.bottom_radius = BEAM_RADIUS
	mesh.height = 1.0  # unit height; we scale Y to the live segment length
	mesh.radial_segments = 6
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_mat.albedo_color = Color(1.0, 0.18, 0.12, 0.4)
	_beam_mat.emission_enabled = true
	_beam_mat.emission = Color(1.0, 0.2, 0.12)
	_beam_mat.emission_energy_multiplier = 2.0
	# Don't let the thin beam write depth/cast shadows; keep it cheap + always visible.
	_beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beam = MeshInstance3D.new()
	_beam.mesh = mesh
	_beam.material_override = _beam_mat
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.visible = false
	# Park under the FX-safe container so it shares the scene root, not the rotating body.
	add_child(_beam)
	_beam.top_level = true  # ignore parent transform; we drive global_transform directly
