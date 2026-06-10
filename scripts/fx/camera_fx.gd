extends Node
class_name CameraFX
## Camera game-feel effects: screen shake (trauma model), per-shot recoil kick,
## hit-stop (time-scale dip), and FOV punch.
##
## ATTACH AS: a child Node named "CameraFX" directly under the player's Camera3D:
##   Player/CameraPivot/SpringArm3D/Camera3D/CameraFX
##
## player.gd integration (ONE line the lead must add to _update_camera, after
## writing camera.fov):
##   camera.fov += $CameraFX.fov_offset()
## That line gives the FOV punch without CameraFX ever writing camera.fov itself.
##
## Everything else (shake, recoil, hit-stop) wires itself via Events — no
## other edits to player.gd or any existing file are needed.
##
## process_mode: PAUSABLE (default). Hit-stop timers use ignore_time_scale=true
## so the restore fires in real time even while Engine.time_scale is near zero.

# --- Shake constants ----------------------------------------------------------
const TRAUMA_DECAY      := 1.5        # trauma/sec drain rate
const SHAKE_ROT_MAX_DEG := 2.8        # max rotation offset (each axis) at full shake
const SHAKE_POS_MAX     := 0.012      # max positional jitter at full shake (metres)

# --- Recoil constants (punchy but RECOVERS — the spring returns aim to centre) ----
const RECOIL_PITCH_BASE := 0.062      # base upward pitch radians per recoil unit
const RECOIL_YAW_RANGE  := 0.022      # ± random yaw radians per recoil unit
const RECOIL_SPRING     := 13.0       # spring constant: how fast recoil lerps to zero
const RECOIL_TRAUMA_ADD := 0.11       # trauma added per shot (pre-scaled by recoil)
const FOV_PUNCH_FIRE    := 0.7        # degrees of FOV kick per recoil unit on each shot

# --- FOV punch constants ------------------------------------------------------
const FOV_PUNCH_NEAR_SCALE := 5.0     # degrees added per recoil unit on grenade nearby
const FOV_PUNCH_HIT_ADD    := 3.0     # degrees added on local heavy damage
const FOV_PUNCH_DECAY      := 8.0     # degrees/sec decay

# --- Hit-stop constants -------------------------------------------------------
const HIT_STOP_SCALE := 0.08          # Engine.time_scale during a hit-stop

# --- Runtime state ------------------------------------------------------------
var _camera: Camera3D = null
var _player: Node    = null

var _trauma: float    = 0.0           # 0..1 shake trauma (decays over time)
var _noise: FastNoiseLite             # smooth random source for shake

var _recoil_offset: Vector2 = Vector2.ZERO  # x = yaw, y = pitch (radians), springs to 0

var _fov_punch: float  = 0.0          # current extra FOV degrees (decays to 0)

var _hit_stop_active: bool = false    # guard against stacked hit-stops


func _ready() -> void:
	# Resolve the camera (our direct parent must be Camera3D).
	if get_parent() is Camera3D:
		_camera = get_parent() as Camera3D
	else:
		push_warning("CameraFX: parent is not Camera3D — all effects disabled.")
		return

	# Walk up ancestors to find the owning player (first ancestor in group "players").
	_player = _find_player()
	if _player == null:
		push_warning("CameraFX: no ancestor in group 'players' found.")

	# Smooth noise for the shake rotation (no visible repeats at normal play).
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.frequency  = 0.8
	_noise.seed       = randi()

	# Wire Events bus signals.
	Events.weapon_fired.connect(_on_weapon_fired)
	Events.damage_dealt.connect(_on_damage_dealt)
	Events.grenade_exploded.connect(_on_grenade_exploded)
	Events.hit_stop.connect(_on_hit_stop)
	Events.screen_shake.connect(_on_screen_shake)


## Returns the transient FOV delta the lead adds to camera.fov in _update_camera:
##   camera.fov += $CameraFX.fov_offset()
func fov_offset() -> float:
	return _fov_punch


# --- Public API ---------------------------------------------------------------

## Add shake trauma clamped to [0, 1]. Called by Events.screen_shake and internally.
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


# --- _process: apply all offsets each frame -----------------------------------

func _process(delta: float) -> void:
	if _camera == null or not _camera.current:
		# Not the active local camera — zero everything and skip.
		_camera.position = Vector3.ZERO
		_camera.rotation = Vector3.ZERO
		return

	# 1. Decay trauma.
	_trauma = maxf(0.0, _trauma - TRAUMA_DECAY * delta)
	var shake := _trauma * _trauma   # quadratic feel

	# 2. Decay recoil spring toward zero.
	var spring_factor := clampf(1.0 - RECOIL_SPRING * delta, 0.0, 1.0)
	_recoil_offset *= spring_factor

	# 3. Decay FOV punch.
	if _fov_punch != 0.0:
		var sign := signf(_fov_punch)
		_fov_punch -= sign * FOV_PUNCH_DECAY * delta
		# Clamp back to zero if we overshot.
		if signf(_fov_punch) != sign:
			_fov_punch = 0.0

	# 4. Build the combined local transform offset.
	#    player.gd does NOT touch Camera3D's own position/rotation — this is free.
	var t := Time.get_ticks_msec() * 0.001   # seconds for noise input

	# Shake rotation: sample three noise slices offset in time so x/y/z are uncorrelated.
	var rot_x := 0.0
	var rot_y := 0.0
	var rot_z := 0.0
	var pos_x := 0.0
	var pos_y := 0.0
	if shake > 0.001:
		var max_r := deg_to_rad(SHAKE_ROT_MAX_DEG) * shake
		rot_x = _noise.get_noise_2d(t,         0.0) * max_r
		rot_y = _noise.get_noise_2d(t + 100.0, 0.0) * max_r
		rot_z = _noise.get_noise_2d(t + 200.0, 0.0) * max_r
		pos_x = _noise.get_noise_2d(t + 300.0, 0.0) * SHAKE_POS_MAX * shake
		pos_y = _noise.get_noise_2d(t + 400.0, 0.0) * SHAKE_POS_MAX * shake

	# Recoil: upward pitch + lateral yaw spring offset (local camera space).
	rot_x += _recoil_offset.y   # pitch up (negative x in Godot camera = look up)
	rot_y += _recoil_offset.x   # yaw

	# Write combined local transform. player.gd owns SpringArm/CameraPivot rotation
	# but NOT Camera3D's local position or rotation — safe to set directly here.
	_camera.position = Vector3(pos_x, pos_y, 0.0)
	_camera.rotation = Vector3(rot_x, rot_y, rot_z)


# --- Event handlers -----------------------------------------------------------

func _on_weapon_fired(shooter: Node, _weapon_id: String) -> void:
	if _camera == null or not _camera.current:
		return
	if shooter != _player:
		return

	# Look up recoil magnitude from the WeaponController if present.
	var recoil := 1.0
	if _player != null:
		var wc := _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D/WeaponController")
		if wc and wc.has_method("current_recoil"):
			recoil = float(wc.current_recoil())

	# Recoil kick: pitch up + small random yaw.
	_recoil_offset.y -= RECOIL_PITCH_BASE * recoil            # negative = look up
	_recoil_offset.x += randf_range(-RECOIL_YAW_RANGE, RECOIL_YAW_RANGE) * recoil

	# Small trauma per shot for micro-shake feel.
	add_trauma(RECOIL_TRAUMA_ADD * recoil)
	# Tiny FOV kick per shot for "weight" (decays back via FOV_PUNCH_DECAY).
	_fov_punch += FOV_PUNCH_FIRE * recoil


func _on_damage_dealt(target: Node, amount: float, _source: Node) -> void:
	if _camera == null or not _camera.current:
		return
	# Only react when the LOCAL player takes a heavy hit (> 15 HP).
	if target != _player:
		return
	if amount < 15.0:
		return
	# FOV punch proportional to damage.
	_fov_punch += clampf(amount * 0.15, 1.0, FOV_PUNCH_HIT_ADD)


func _on_grenade_exploded(world_pos: Vector3, _damage: float, radius: float) -> void:
	if _camera == null or not _camera.current:
		return
	var dist := _camera.global_position.distance_to(world_pos)
	var margin := radius + 8.0
	if dist > margin:
		return
	# Closeness 0..1; closer = more effect.
	var closeness := 1.0 - clampf(dist / margin, 0.0, 1.0)
	_fov_punch += FOV_PUNCH_NEAR_SCALE * closeness
	add_trauma(0.6 * closeness)


func _on_hit_stop(duration: float) -> void:
	if _camera == null or not _camera.current:
		return
	# Guard: don't stack hit-stops on top of each other.
	if _hit_stop_active:
		return
	_hit_stop_active = true
	Engine.time_scale = HIT_STOP_SCALE

	# Restore must fire in REAL time (ignore_time_scale = true) so it triggers even
	# while Engine.time_scale is near zero. Signature:
	#   create_timer(time, process_always, process_in_physics, ignore_time_scale)
	var timer := get_tree().create_timer(duration, true, false, true)
	timer.timeout.connect(_restore_time_scale)


func _restore_time_scale() -> void:
	Engine.time_scale = 1.0
	_hit_stop_active = false


func _on_screen_shake(amount: float) -> void:
	add_trauma(amount)


# --- Helpers ------------------------------------------------------------------

func _find_player() -> Node:
	var n: Node = self
	while n != null:
		if n.is_in_group(Groups.PLAYERS):
			return n
		n = n.get_parent()
	return null
