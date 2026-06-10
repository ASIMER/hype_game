extends CharacterBody3D
class_name Player
## Third-person, camera-relative player controller for the co-op extraction
## shooter. Owns movement, an over-the-shoulder SpringArm camera, mouse-look,
## and held-to-fire shooting via the sibling Weapon. Health/Inventory/Hurtbox
## are reusable child components from the frozen foundation.
##
## AUTHORITY MODEL (listen-server): each Player's multiplayer authority is the
## peer that owns it (set by the world's MultiplayerSpawner via the node name).
## Only the authority reads input, drives the camera, and mutates Health; the
## MultiplayerSynchronizer replicates position + camera yaw + health to everyone.
## In single-player there is no peer, so is_multiplayer_authority() is true and
## everything runs locally.

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var model_root: Node3D = $ModelRoot
@onready var health: Health = $Health
@onready var _weapon_controller: Node = $CameraPivot/SpringArm3D/Camera3D/WeaponController

var _input_enabled: bool = true
var _agent_jump_prev: bool = false   # edge-detect a HELD agent jump so it fires once

# --- Co-op DOWNED / REVIVE / CARRY (server-authoritative; authority drives its own) ---
## Synced (Player.tscn MultiplayerSynchronizer): every peer renders a teammate as downed.
var downed: bool = false
## The peer id currently carrying THIS downed player (0 = not carried). Synced so all peers
## see the body follow its carrier.
var _carried_by_peer: int = 0
var _bleedout: float = 0.0            # seconds left before true death while downed (authority)
var _giveup_held: float = 0.0         # seconds the give_up key has been held while downed (authority)
var _downed_resolved: bool = false    # guards true-death from firing twice
var _shield_charges: float = 0.0      # remaining knockdown-shield absorb while downed
var _self_revives: int = 0            # SELF_REVIVE_ITEM count from the bring-list
var _shields: int = 0                 # KNOCKDOWN_SHIELD_ITEM count from the bring-list
const DOWNED_HEALTH: float = 30.0     # nominal HP pool while downed (drained by finish damage)
# Reviver side (authority): the downed teammate we're channeling a revive on + progress.
var _revive_target: Node = null
var _revive_progress: float = 0.0
var _revive_guard_hp: float = -1.0   # reviver HP snapshot at channel start; a drop cancels the revive
var _revive_ui_shown: bool = false   # whether the revive progress HUD is currently active (anti-spam)
var _coop_prompt_active: bool = false # whether the shared "[E]" prompt is currently showing a coop (revive/carry) hint, so we clear it on leave
# Carry side (authority): the downed teammate we are carrying.
var _carry_target: Node = null

# Camera / aim state (authority only).
var _ads: bool = false                # aim-down-sights active
var _ads_toggled: bool = false        # latched ADS when Settings.ads_toggle
var _shoulder_sign: float = 1.0       # over-the-shoulder side; flipped by shoulder_swap
var _medkits: int = 0                 # set at spawn from the bring-list; heal consumes
var _grenades: int = 0                # set at spawn from the bring-list; grenade consumes
var _stamina: float = Settings.MAX_STAMINA
var _max_stamina: float = Settings.MAX_STAMINA  # base * meta stamina upgrade (set in _ready)
var _sprint_locked: bool = false      # true after exhausting stamina, until it regens
var _interact_target: Node = null     # nearest interactable (for the "[E]" prompt)
var _interact_timer: float = 0.0

# --- Stance state machine (authority only) ---
## Movement stance. PUBLIC so the combat lane can read it (stance_spread_mult()).
enum Stance { STAND, CROUCH, SLIDE }
var stance: int = Stance.STAND

# --- Character customization (spawn-replicated; see Player.tscn MultiplayerSynchronizer) ---
## This player's equipped cosmetic part ids {head,torso,arms,legs,paint}. The AUTHORITY
## sets it from its OWN MetaProgression at spawn; replication_mode=1 syncs it to every peer
## so remotes render this player's chosen look. The body is (re)built whenever it changes.
var cosmetics: Dictionary = {}
var _built_cos_str: String = ""        # signature of the cosmetics the body was last built from
var _slide_timer: float = 0.0          # counts down during a SLIDE
var _slide_dir: Vector3 = Vector3.ZERO # locked horizontal entry direction of the slide
var _cam_base_y: float = 1.5           # CameraPivot's base local Y (cached once in _ready)

# --- View toggle + camera-from-settings (authority only) ---
var _first_person: bool = false        # init from Settings.default_first_person in _ready
var _cam_distance_scale: float = 1.0   # cached Settings.camera_distance_scale
var _cam_shoulder_scale: float = 1.0   # cached Settings.camera_shoulder_scale

# --- Water immersion (LOCAL/cosmetic, authority-only) ---
enum Water { DRY, WADING, SUBMERGED }
var _water_state: int = Water.DRY
const CAM_HEIGHT: float = 1.5         # camera Y above the player root (= feet)
const WATER_SLOW: float = 0.65        # speed multiplier while wading/submerged (~35% slow)
const _TERRAIN_SCRIPT := "res://scripts/visual/procedural_terrain.gd"
var _terrain_gd: GDScript = null      # cached terrain script (for water_surface_at)
var _terrain_checked: bool = false
var _bubbles: GPUParticles3D = null   # rising bubbles while submerged (lazy)
var _ripple: GPUParticles3D = null    # feet ripple while wading (lazy)

# --- Audible movement noise (sound stealth; read by the server-side enemy AI) ---
# Planar speed observed from the SYNCED position on EVERY peer, so the server can
# derive a remote client's footstep loudness without syncing velocity. noise_radius()
# maps (stance + this speed) to an audible radius in metres.
var _noise_last_pos: Vector3 = Vector3.ZERO
var _noise_speed: float = 0.0
var _noise_inited: bool = false

const GRENADE_SCENE := "res://scenes/items/Grenade.tscn"

# --- Active power-cache buffs (timed; authority-local) -----------------------
# id -> time_left (seconds). Effects read live via the buff_*_mult() getters + _tick_buffs.
var _buffs: Dictionary = {}
var _overshield: float = 0.0   # remaining absorb pool from the Overshield power


func _enter_tree() -> void:
	# AUTHORITY FROM NAME. The server names each spawned Player str(peer_id) before
	# adding it (see arena._ensure_player_spawned), and the MultiplayerSpawner
	# replicates that name to every client. A server-side set_multiplayer_authority()
	# call is NOT itself replicated, so we re-derive authority from the node name —
	# this runs identically on the server and every client, giving consistent
	# ownership so each peer drives only its own player.
	#
	# This MUST happen in _enter_tree (not _ready): the child MultiplayerSynchronizer
	# resolves its network ID from this node's authority while the spawn is processed,
	# which is before _ready. Setting it here keeps the synchronizer's spawn valid.
	# Offline (no peer) leaves authority at the default, where is_multiplayer_authority
	# is already true.
	if multiplayer.has_multiplayer_peer():
		var owner_id := str(name).to_int()
		if owner_id > 0:
			set_multiplayer_authority(owner_id)


func _ready() -> void:
	add_to_group("players")

	# Health is tuned from the central Settings and wired to the global bus so HUD
	# and match-flow workstreams react without referencing the Player directly.
	# Permanent meta-progression upgrades scale starting health + stamina.
	var _mods: Dictionary = MetaProgression.player_mods()
	health.max_health = Settings.PLAYER_MAX_HEALTH * float(_mods.get("health_mult", 1.0))
	health.current = health.max_health
	health.health_changed.connect(_on_health_changed)
	health.died.connect(_on_died)
	# Power-cache buffs intercept incoming damage (Overshield absorb + Juggernaut armor).
	health.damage_filter = _filter_incoming_damage
	_max_stamina = Settings.MAX_STAMINA * float(_mods.get("stamina_mult", 1.0))
	_stamina = _max_stamina

	# Character look: the AUTHORITY takes its OWN equipped cosmetics from its profile (this
	# replicates to every peer). Remotes start from {} and rebuild when the synced value
	# arrives (see the watcher in _physics_process). Build the procedural body now.
	if is_multiplayer_authority():
		cosmetics = MetaProgression.get_cosmetics()
	_build_player_model()

	# Initialise camera from Settings (fov is settings-driven) so ADS/peek lerps have
	# a known baseline.
	camera.fov = Settings.fov
	# Cache the camera pivot's authored base height (crouch/slide lerp down from this).
	_cam_base_y = camera_pivot.position.y
	# Read player-tunable camera distance/shoulder + the spawn view from Settings.
	_read_camera_settings()
	_first_person = Settings.default_first_person
	spring_arm.spring_length = _third_person_len()
	spring_arm.position.x = _shoulder_sign * Settings.SHOULDER_OFFSET * _cam_shoulder_scale
	# Anti-cheat: the spring arm pulls the camera in against world geometry (layer 1, where
	# buildings live) so you can't see through walls. A small margin avoids clipping thin
	# geometry. NEVER disable this collision.
	spring_arm.collision_mask = spring_arm.collision_mask | 1
	spring_arm.margin = 0.2

	# The weapon controller only reads switch/reload input for the local player.
	if _weapon_controller and _weapon_controller.has_method("set_enabled"):
		_weapon_controller.set_enabled(is_multiplayer_authority())
		# The controller lives under the Camera3D, so its view-model would render
		# right at the lens. Reparent the model holder to a body mount (hand height)
		# so the weapon is HELD by the character in third-person. The controller's
		# cached reference still points at this node, so weapon switches keep working.
		var mh: Node = _weapon_controller.get_node_or_null("ModelHolder")
		var mount := get_node_or_null("WeaponMount")
		if mh and mh is Node3D and mount:
			(mh as Node3D).reparent(mount, false)

	if is_multiplayer_authority():
		apply_loadout()
		camera.current = true
		camera.make_current()
		# Re-assert next frame in case the spawn order left another (or no) camera
		# current — guards against the client "grey screen" (no active camera).
		_ensure_camera_current.call_deferred()
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		Events.item_use_requested.connect(_on_item_use)
		# Re-read camera distance/shoulder when the player changes them in Settings.
		if not Events.camera_settings_changed.is_connected(_read_camera_settings):
			Events.camera_settings_changed.connect(_read_camera_settings)
		# Hide the local body in first-person so the camera isn't inside the mesh.
		_apply_view_visibility()
		Events.local_player_spawned.emit(self)
	else:
		# Remote avatars: their camera/input must never run on this machine.
		camera.current = false
		set_process_unhandled_input(false)


## Deferred safety: the LOCAL player must own the viewport camera. Re-asserts a frame
## after spawn so a late-resolved authority / spawn-order quirk can't leave the screen
## with no current camera (the co-op grey screen).
func _ensure_camera_current() -> void:
	if is_instance_valid(self) and is_multiplayer_authority() and camera:
		camera.make_current()

## Server → owning client: place this player at its spawn marker. A client owns its
## own transform, so it ignores the server's spawn-state position (would start at world
## origin); the server calls this to set it authoritatively on the owner.
@rpc("any_peer", "call_remote", "reliable")
func _net_place(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO


## (Re)build the procedural body from `cosmetics` and re-init the animator. Runs on every
## peer (authority builds from its profile; remotes build from the replicated value).
func _build_player_model() -> void:
	for c in model_root.get_children():
		c.queue_free()
	var model: Node3D = AssetRegistry.get_model("player", cosmetics)
	model_root.add_child(model)
	_built_cos_str = str(cosmetics)
	var anim := get_node_or_null("PlayerAnimator")
	if anim != null and anim.has_method("reinit"):
		anim.reinit()

func _physics_process(delta: float) -> void:
	# Remote peers: rebuild the body when the synced `cosmetics` arrives/changes so this
	# player's customization shows on every machine. Runs BEFORE the authority gate.
	if str(cosmetics) != _built_cos_str:
		_build_player_model()
	if not is_multiplayer_authority():
		return

	# Active power-cache buffs: count down + apply per-frame effects (regen/overshield decay).
	_tick_buffs(delta)

	# DOWNED: crawl-only physics, no combat/stance; bleedout + self-revive handled inside.
	if downed:
		_downed_physics(delta)
		_check_water(delta)
		return

	# Gravity (uses the project's configured gravity vector).
	if not is_on_floor():
		velocity += get_gravity() * delta

	var _jump_edge: bool
	if AgentBridge.active:
		var _jn := AgentBridge.held("jump")
		_jump_edge = _jn and not _agent_jump_prev
		_agent_jump_prev = _jn
	else:
		_jump_edge = Input.is_action_just_pressed("jump")
	if _input_enabled and is_on_floor() and _jump_edge:
		velocity.y = Settings.PLAYER_JUMP_VELOCITY

	# Agent self-play: when the control server is driving, consume its look delta
	# (applied to the camera directly so it works even off-screen/unfocused).
	if AgentBridge.active:
		var lk := AgentBridge.consume_look()
		if lk != Vector2.ZERO:
			rotation.y -= lk.x
			spring_arm.rotation.x = clampf(spring_arm.rotation.x - lk.y,
				Settings.CAMERA_PITCH_MIN, Settings.CAMERA_PITCH_MAX)

	# Camera-relative movement on the horizontal plane, as explicit forward/strafe
	# amounts (+forward = toward the camera's facing, +strafe = right). Agent input
	# or keyboard both feed the same convention.
	var move_dir := Vector3.ZERO
	if _input_enabled:
		var strafe: float
		var fwd_amt: float
		if AgentBridge.active:
			strafe = AgentBridge.move.x
			fwd_amt = AgentBridge.move.y
		else:
			strafe = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
			fwd_amt = Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
		var basis := camera_pivot.global_transform.basis
		var forward := -basis.z
		var right := basis.x
		forward.y = 0.0
		right.y = 0.0
		move_dir = right.normalized() * strafe + forward.normalized() * fwd_amt
		if move_dir.length_squared() > 0.0:
			move_dir = move_dir.normalized()

	var wants_sprint := AgentBridge.sprint if AgentBridge.active else Input.is_action_pressed("sprint")
	var moving := move_dir.length_squared() > 0.01

	# --- Stance: crouch / slide vs stand --------------------------------------
	# A slide locks steering and decays its own velocity, so resolve it first.
	var crouch_held := _input_enabled and _act_held("crouch")
	var sprinting := false
	if stance == Stance.SLIDE:
		sprinting = false
		_update_slide(delta, move_dir, crouch_held)
	else:
		# Enter a slide: TAP crouch while sprint-moving on the floor.
		if _input_enabled and is_on_floor() and moving and wants_sprint \
				and not _sprint_locked and _stamina > 0.0 \
				and Input.is_action_just_pressed("crouch"):
			_begin_slide(move_dir)
			_update_slide(delta, move_dir, crouch_held)
		else:
			# Crouch (hold) while standing on the floor; can't sprint while crouched.
			if crouch_held and is_on_floor():
				stance = Stance.CROUCH
			else:
				stance = Stance.STAND
			var speed := Settings.PLAYER_MOVE_SPEED
			if stance == Stance.CROUCH:
				speed = Settings.PLAYER_CROUCH_SPEED
			else:
				sprinting = _input_enabled and wants_sprint and moving \
					and not _sprint_locked and _stamina > 0.0
				if sprinting:
					speed = Settings.PLAYER_SPRINT_SPEED
			# Wading/swimming slows movement (sluggish in water).
			if _water_state != Water.DRY:
				speed *= WATER_SLOW
			# Carrying a downed buddy is slow + heavy (sidearm only).
			if is_carrying():
				speed *= Settings.CARRY_SPEED_MULT
			# Active power-cache buff (Swift / Frenzy).
			speed *= buff_speed_mult()
			# Enemy-applied chill/slow debuff (cryo-mortar hits), time-boxed.
			if Time.get_ticks_msec() < _slow_until_ms:
				speed *= _slow_mult
			velocity.x = move_dir.x * speed
			velocity.z = move_dir.z * speed

	_update_stamina(delta, sprinting)

	move_and_slide()

	# Cosmetic water submersion state + enter/exit splash & particle FX (LOCAL only).
	_check_water(delta)

	# Over-the-shoulder feel: the body yaw IS the look yaw (applied directly at render
	# rate in _unhandled_input / the agent path), so the camera_pivot carries no yaw —
	# nothing to transfer here. Keep it zeroed as a safety against stray writes.
	camera_pivot.rotation.y = 0.0

	# ADS zoom, shoulder offset, and dynamic peek/lean around walls.
	_update_camera(delta)

	# Co-op: a downed teammate in range takes priority (revive / carry). When none is in
	# range this falls through to the normal loot prompt.
	_update_coop_interaction(delta)
	if _revive_target == null and _carry_target == null:
		# Nearby-loot "[E]" interaction prompt (throttled).
		_interact_timer -= delta
		if _interact_timer <= 0.0:
			_interact_timer = 0.15
			_update_interaction()

	# Held-to-fire (cooldown handled by the weapon/controller). Carrying a buddy locks you
	# to a sidearm and blocks ADS (Lane note: enforced here as a fire block while carrying).
	var firing := AgentBridge.fire if AgentBridge.active else Input.is_action_pressed("fire")
	if _input_enabled and firing and not is_carrying():
		_fire_current()


## Fires the active weapon. Uses the WeaponController once wired (multi-weapon +
## ammo); falls back to the single legacy Weapon until then.
func _fire_current() -> void:
	if _weapon_controller and _weapon_controller.has_method("try_fire"):
		_weapon_controller.try_fire(camera)


## Smoothly drives FOV (ADS zoom), spring length (camera pull-in), the over-the-
## shoulder offset, and an automatic lateral "peek/lean" when a wall hugs the
## shoulder side — so the player can see/aim around building corners.
func _update_camera(delta: float) -> void:
	var want_ads: bool
	if is_carrying():
		want_ads = false   # carrying a buddy can't ADS
	elif AgentBridge.active:
		want_ads = AgentBridge.ads
	elif Settings.ads_toggle:
		want_ads = _ads_toggled
	else:
		want_ads = Input.is_action_pressed("aim")
	if want_ads != _ads:
		_ads = want_ads
		Events.ads_changed.emit(self, _ads)

	var target_fov := (_ads_fov() if _ads else Settings.fov)
	# Spring length: ADS overrides everything; else first-person vs settings-scaled
	# third-person distance.
	var target_len: float
	if _ads:
		target_len = Settings.ADS_SPRING_LENGTH
	elif _first_person:
		target_len = Settings.FP_SPRING_LENGTH
	else:
		target_len = _third_person_len()
	var base_off := _shoulder_sign * Settings.SHOULDER_OFFSET * _cam_shoulder_scale * (0.65 if _ads else 1.0)
	var target_off := base_off + _compute_peek()
	# Base camera height (+ small ADS raise), then drop for crouch / slide.
	var target_y := _cam_base_y + (0.18 if _ads else 0.0)
	if stance == Stance.SLIDE:
		target_y -= Settings.SLIDE_CAMERA_DROP
	elif stance == Stance.CROUCH:
		target_y -= Settings.CROUCH_CAMERA_DROP

	var t := clampf(delta * Settings.AIM_TWEEN_SPEED, 0.0, 1.0)
	camera.fov = lerpf(camera.fov, target_fov, t)
	# Transient FOV punch from CameraFX (explosions / heavy hits) — additive so the
	# ADS lerp above stays the baseline. CameraFX never writes camera.fov itself.
	var _camfx := camera.get_node_or_null("CameraFX")
	if _camfx and _camfx.has_method("fov_offset"):
		camera.fov += _camfx.fov_offset()
	spring_arm.spring_length = lerpf(spring_arm.spring_length, target_len, t)
	spring_arm.position.x = lerpf(spring_arm.position.x, target_off, t)
	# Camera height eases at the dedicated crouch lerp speed (snappier stance feel).
	var ty := clampf(delta * Settings.CROUCH_CAMERA_LERP, 0.0, 1.0)
	camera_pivot.position.y = lerpf(camera_pivot.position.y, target_y, ty)


## Per-weapon ADS FOV once the controller is wired; default until then.
func _ads_fov() -> float:
	if _weapon_controller and _weapon_controller.has_method("current_ads_fov"):
		var f: float = _weapon_controller.current_ads_fov()
		if f > 1.0:
			return f
	return Settings.ADS_FOV


## Lean amount: if a wall is within PEEK_PROBE on the current shoulder side, shift
## the camera toward the OPEN side (proportional to closeness) so the body/corner
## doesn't block the view — the "peek out around the edge" effect.
func _compute_peek() -> float:
	var space := get_world_3d().direct_space_state
	var origin := camera_pivot.global_position
	var right := global_transform.basis.x   # body right == camera right (yaw coupled)
	var to := origin + right * _shoulder_sign * Settings.PEEK_PROBE
	var q := PhysicsRayQueryParameters3D.create(origin, to)
	q.collision_mask = 1   # world only
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit:
		var closeness := 1.0 - clampf(origin.distance_to(hit["position"]) / Settings.PEEK_PROBE, 0.0, 1.0)
		return -_shoulder_sign * Settings.PEEK_SHIFT * closeness
	return 0.0


## STANCE API (FROZEN — read by the combat lane). Returns the spread multiplier for
## the current stance/motion. ADS is NOT applied here (the weapon applies it).
func stance_spread_mult() -> float:
	if stance == Stance.SLIDE:
		return Settings.SPREAD_MULT_SLIDE
	if stance == Stance.CROUCH:
		return Settings.SPREAD_MULT_CROUCH
	var hspeed := Vector2(velocity.x, velocity.z).length()
	# Sprinting is only meaningful while actually moving; gate on horizontal speed too.
	var sprinting := (AgentBridge.sprint if AgentBridge.active else Input.is_action_pressed("sprint"))
	if sprinting and not _sprint_locked and hspeed > 0.3:
		return Settings.SPREAD_MULT_SPRINT
	if hspeed > 0.3:
		return Settings.SPREAD_MULT_MOVE
	return Settings.SPREAD_MULT_STAND


## Begin a slide: lock the entry direction, set velocity to the slide-speed burst.
func _begin_slide(move_dir: Vector3) -> void:
	stance = Stance.SLIDE
	_slide_timer = Settings.SLIDE_TIME
	var d := move_dir
	d.y = 0.0
	if d.length_squared() < 0.0001:
		# Slide straight ahead if there was no input vector (rare).
		d = -global_transform.basis.z
		d.y = 0.0
	_slide_dir = d.normalized()
	velocity.x = _slide_dir.x * Settings.SLIDE_SPEED
	velocity.z = _slide_dir.z * Settings.SLIDE_SPEED


## Advance an in-progress slide: decay velocity toward crouch speed along the locked
## entry direction (reduced steering), resolve to CROUCH/STAND when it ends or stops.
func _update_slide(delta: float, move_dir: Vector3, crouch_held: bool) -> void:
	_slide_timer -= delta
	# Progress 0→1 over the slide; speed eases from SLIDE_SPEED down to crouch speed.
	var frac := clampf(1.0 - (_slide_timer / Settings.SLIDE_TIME), 0.0, 1.0)
	var spd := lerpf(Settings.SLIDE_SPEED, Settings.PLAYER_CROUCH_SPEED, frac)
	# Locked steering: mostly the entry direction, a little late input authority.
	var steer := move_dir
	steer.y = 0.0
	var dir := _slide_dir
	if steer.length_squared() > 0.0001:
		dir = (_slide_dir * 0.85 + steer.normalized() * 0.15)
		if dir.length_squared() > 0.0001:
			dir = dir.normalized()
		else:
			dir = _slide_dir
	if _water_state != Water.DRY:
		spd *= WATER_SLOW
	velocity.x = dir.x * spd
	velocity.z = dir.z * spd
	# End the slide when the timer expires or the player has slowed to a stop / left the
	# floor → resolve to CROUCH (if still held) or STAND.
	if _slide_timer <= 0.0 or not is_on_floor():
		stance = Stance.CROUCH if (crouch_held and is_on_floor()) else Stance.STAND


## Third-person spring length, scaled by the player's camera-distance setting.
func _third_person_len() -> float:
	return Settings.DEFAULT_SPRING_LENGTH * _cam_distance_scale


## Re-read the player-tunable camera distance/shoulder scales from Settings. Connected to
## Events.camera_settings_changed so live edits apply (the lerp in _update_camera eases to
## the new target). Safe to call as a 0-arg signal handler.
func _read_camera_settings() -> void:
	_cam_distance_scale = Settings.camera_distance_scale
	_cam_shoulder_scale = Settings.camera_shoulder_scale


## Show/hide the LOCAL body mesh for first/third-person. Only the authority toggles its own
## visibility — a remote peer's body must stay visible to everyone else.
func _apply_view_visibility() -> void:
	if not is_multiplayer_authority():
		return
	if model_root:
		model_root.visible = not _first_person


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if not _input_enabled:
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		# Aiming lowers sensitivity for precision.
		var sens := Settings.mouse_sensitivity * (Settings.ADS_SENS_SCALE if _ads else 1.0)
		var inv := -1.0 if Settings.invert_y else 1.0
		# Yaw the BODY directly at render rate (mouse events arrive per frame) so the
		# player model rotates smoothly with the camera. Previously yaw accumulated on
		# camera_pivot and was transferred to the body only in _physics_process (60Hz),
		# which made the model stutter relative to the smooth camera.
		rotation.y -= motion.relative.x * sens
		var pitch := spring_arm.rotation.x - motion.relative.y * sens * inv
		spring_arm.rotation.x = clampf(pitch, Settings.CAMERA_PITCH_MIN, Settings.CAMERA_PITCH_MAX)
	elif Settings.ads_toggle and event.is_action_pressed("aim"):
		_ads_toggled = not _ads_toggled
	elif event.is_action_pressed("shoulder_swap"):
		# Instant over-the-shoulder flip to peek the other side (camera only; the
		# converged shot keeps the same impact point).
		_shoulder_sign = -_shoulder_sign
	elif event.is_action_pressed("toggle_view"):
		# Flip between third- and first-person. The spring-length target folds into the
		# ADS lerp in _update_camera; the local body is hidden in first-person.
		_first_person = not _first_person
		_apply_view_visibility()
	elif event.is_action_pressed("heal"):
		# While downed the heal key triggers a SELF-REVIVE (if you brought one); the crawl
		# loop also polls this, so just route there and skip medkit healing.
		if downed:
			_self_revive()
		else:
			_try_heal()
	elif event.is_action_pressed("grenade"):
		if not downed:
			_throw_grenade()


## Consume a medkit to restore HP (instant). Authority-gated by the caller.
func _try_heal() -> void:
	if _medkits <= 0 or health.is_dead or health.current >= health.max_health:
		return
	_medkits -= 1
	health.heal(Settings.HEAL_AMOUNT)
	Events.player_healed.emit(self, Settings.HEAL_AMOUNT)

## Throw a grenade from the chest along the aim direction. Works once fx-dev's
## Grenade.tscn exists (guarded); decrements the carried count.
func _throw_grenade() -> void:
	if _grenades <= 0 or not ResourceLoader.exists(GRENADE_SCENE):
		return
	var packed := load(GRENADE_SCENE) as PackedScene
	if packed == null:
		return
	var nade: Node = packed.instantiate()
	var world := get_tree().current_scene
	if world == null:
		return
	world.add_child(nade)
	var from := global_position + Vector3.UP * 1.4
	var dir := -camera.global_transform.basis.z
	if nade.has_method("throw"):
		nade.throw(from, dir, Settings.GRENADE_THROW_FORCE)
	elif nade is Node3D:
		(nade as Node3D).global_position = from
	_grenades -= 1
	Events.grenade_thrown.emit(self, from, dir)


## Cosmetic water immersion. Reads the water surface Y at the player's XZ (Lane A's
## `ProceduralTerrain.water_surface_at`, with a local river fallback so this works before
## that lands). Classifies DRY / WADING (legs in) / SUBMERGED (camera underwater) and, on
## a transition, emits Events.water_state_changed + drives splash/ripple/bubble FX.
## Authority-only (the caller is already authority-gated in _physics_process).
func _check_water(_delta: float) -> void:
	var surf := _water_surface_at(global_position.x, global_position.z)
	var new_state: int = Water.DRY
	if not is_nan(surf):
		var feet_y := global_position.y
		var cam_y := global_position.y + CAM_HEIGHT
		if cam_y < surf:
			new_state = Water.SUBMERGED
		elif feet_y < surf:
			new_state = Water.WADING

	if new_state == _water_state:
		# Keep submerged bubbles parked at the camera as it moves.
		if _water_state == Water.SUBMERGED and _bubbles != null and is_instance_valid(_bubbles):
			_bubbles.global_position = global_position + Vector3.UP * (CAM_HEIGHT - 0.2)
		return

	var was_wet := _water_state != Water.DRY
	var now_wet := new_state != Water.DRY
	_water_state = new_state
	Events.water_state_changed.emit(new_state, global_position)

	# DRY -> wet is an ENTER: splash sound + droplet burst at the entry point.
	if now_wet and not was_wet:
		var entry := global_position
		if not is_nan(surf):
			entry.y = surf
		AudioManager._play_at("water_splash", self)
		_spawn_splash(entry)

	# Manage the persistent ambient particles for the current state.
	_set_ripple(new_state == Water.WADING)
	_set_bubbles(new_state == Water.SUBMERGED)


## Water surface world-Y at (x,z) over the river, else NAN. Prefers Lane A's frozen
## contract `ProceduralTerrain.water_surface_at`; if that method is absent (Lane A not
## landed) falls back to a local river probe so wading still works for testing.
func _water_surface_at(x: float, z: float) -> float:
	if not _terrain_checked:
		_terrain_checked = true
		if ResourceLoader.exists(_TERRAIN_SCRIPT):
			var res := load(_TERRAIN_SCRIPT)
			if res is GDScript:
				_terrain_gd = res
	if _terrain_gd != null and _terrain_gd.has_method("water_surface_at"):
		var s: float = _terrain_gd.water_surface_at(x, z)
		return s   # NAN when not over water (contract); used as-is.
	return _fallback_surface_at(x, z)


## Local river-surface fallback (used only until Lane A's water_surface_at lands). Returns
## the water surface Y if (x,z) is within the river channel, else NAN. Derived from the
## terrain's PUBLIC river centerline + the bed height so it tracks shallow OR deep rivers.
func _fallback_surface_at(x: float, z: float) -> float:
	if _terrain_gd == null:
		return NAN
	# Distance to the polyline river centerline (replicates the terrain's private probe
	# using its public RIVER_PTS constant).
	var pts: Variant = _terrain_gd.get("RIVER_PTS")
	if not (pts is Array) or (pts as Array).size() < 2:
		return NAN
	var p := Vector2(x, z)
	var best := INF
	var arr := pts as Array
	for i in range(arr.size() - 1):
		var a: Vector2 = arr[i]
		var b: Vector2 = arr[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		var t := 0.0 if len2 < 0.0001 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
		var d := p.distance_to(a + ab * t)
		if d < best:
			best = d
	var halfw: float = float(Settings.RIVER_WIDTH) * 0.5
	if best > halfw:
		return NAN
	# Bed height at this XZ (the terrain mesh's own value) → surface sits just above it.
	# RIVER_DEPTH-relative offset keeps the surface near the visible water ribbon (~-0.12).
	if not _terrain_gd.has_method("height_at"):
		return NAN
	var bed: float = _terrain_gd.height_at(x, z)
	return bed + float(Settings.RIVER_DEPTH) - 0.12


## One-shot droplet burst when entering water (white droplets, gravity down).
func _spawn_splash(at: Vector3) -> void:
	var world := get_tree().current_scene
	if world == null:
		return
	var ps := GPUParticles3D.new()
	ps.amount = 24
	ps.lifetime = 0.7
	ps.one_shot = true
	ps.explosiveness = 0.9
	ps.local_coords = false
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 55.0
	mat.gravity = Vector3(0, -9.8, 0)
	mat.initial_velocity_min = 2.0
	mat.initial_velocity_max = 4.5
	mat.scale_min = 0.4
	mat.scale_max = 1.0
	mat.color = Color(0.75, 0.88, 0.95, 0.9)
	ps.process_material = mat
	ps.draw_pass_1 = _droplet_mesh()
	world.add_child(ps)
	ps.global_position = at
	ps.restart()
	ps.emitting = true
	# Self-free after the burst finishes.
	get_tree().create_timer(1.2).timeout.connect(func() -> void:
		if is_instance_valid(ps):
			ps.queue_free())


## Continuous feet-ripple particles while WADING (small, cheap).
func _set_ripple(on: bool) -> void:
	if on:
		if _ripple == null or not is_instance_valid(_ripple):
			_ripple = GPUParticles3D.new()
			_ripple.amount = 10
			_ripple.lifetime = 0.6
			_ripple.local_coords = false
			var m := ParticleProcessMaterial.new()
			m.direction = Vector3(0, 1, 0)
			m.spread = 40.0
			m.gravity = Vector3(0, -6.0, 0)
			m.initial_velocity_min = 0.6
			m.initial_velocity_max = 1.6
			m.scale_min = 0.2
			m.scale_max = 0.5
			m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			m.emission_sphere_radius = 0.35
			m.color = Color(0.7, 0.85, 0.9, 0.6)
			_ripple.process_material = m
			_ripple.draw_pass_1 = _droplet_mesh()
			add_child(_ripple)
			_ripple.position = Vector3(0, 0.1, 0)
		_ripple.emitting = true
	elif _ripple != null and is_instance_valid(_ripple):
		_ripple.emitting = false


## Rising bubble particles past the camera while SUBMERGED.
func _set_bubbles(on: bool) -> void:
	if on:
		if _bubbles == null or not is_instance_valid(_bubbles):
			_bubbles = GPUParticles3D.new()
			_bubbles.amount = 28
			_bubbles.lifetime = 1.6
			_bubbles.local_coords = false
			var m := ParticleProcessMaterial.new()
			m.direction = Vector3(0, 1, 0)
			m.spread = 20.0
			m.gravity = Vector3(0, 1.2, 0)   # bubbles rise
			m.initial_velocity_min = 0.4
			m.initial_velocity_max = 1.1
			m.scale_min = 0.15
			m.scale_max = 0.5
			m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			m.emission_box_extents = Vector3(0.8, 0.6, 0.8)
			m.color = Color(0.8, 0.92, 1.0, 0.5)
			_bubbles.process_material = m
			_bubbles.draw_pass_1 = _droplet_mesh()
			var world := get_tree().current_scene
			if world != null:
				world.add_child(_bubbles)
			else:
				add_child(_bubbles)
		_bubbles.global_position = global_position + Vector3.UP * (CAM_HEIGHT - 0.2)
		_bubbles.emitting = true
	elif _bubbles != null and is_instance_valid(_bubbles):
		_bubbles.emitting = false


## A tiny shared sphere mesh for water droplets/bubbles.
func _droplet_mesh() -> Mesh:
	var sm := SphereMesh.new()
	sm.radius = 0.05
	sm.height = 0.10
	sm.radial_segments = 6
	sm.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.9, 1.0, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.material = mat
	return sm


## Sprint stamina: drain while sprinting, regen otherwise; lock sprint once empty
## until it recovers past STAMINA_SPRINT_MIN. Broadcasts for the HUD stamina bar.
func _update_stamina(delta: float, sprinting: bool) -> void:
	# Adrenaline buff: stamina never drains (sprint forever).
	if sprinting and not _has_buff("adrenaline"):
		_stamina = maxf(0.0, _stamina - Settings.STAMINA_DRAIN * delta)
		if _stamina <= 0.0:
			_sprint_locked = true
	else:
		_stamina = minf(_max_stamina, _stamina + Settings.STAMINA_REGEN * delta)
		if _sprint_locked and _stamina >= Settings.STAMINA_SPRINT_MIN:
			_sprint_locked = false
	Events.stamina_changed.emit(_stamina, _max_stamina)

## Finds the nearest loot pickup within INTERACT_RANGE and emits the "[E]" prompt
## (or clears it). Loot is picked up with E by loot_pickup; this just informs.
func _update_interaction() -> void:
	# If the pickup we were pointing at got TAKEN (freed), the prompt would otherwise stick:
	# in Godot a freed Object compares == null, so the `best == _interact_target` early-return
	# below would read null == <freed> as true and skip the clear. Normalize the freed/invalid
	# target to null and clear the stale "[E] Pick up" hint first.
	if _interact_target != null and not is_instance_valid(_interact_target):
		_interact_target = null
		Events.interaction_cleared.emit()
	var best: Node = null
	var best_d := Settings.INTERACT_RANGE
	for n in get_tree().get_nodes_in_group("pickups"):
		if n is Node3D and is_instance_valid(n):
			var d := global_position.distance_to((n as Node3D).global_position)
			if d < best_d:
				best_d = d
				best = n
	if best == _interact_target:
		return
	_interact_target = best
	if best:
		var item_id := str(best.get("item_id")) if "item_id" in best else "item"
		if item_id == "power_cache":
			Events.interaction_available.emit(tr("Open Power Cache"), best)
		else:
			var nice := item_id.replace("loot_", "").capitalize()
			Events.interaction_available.emit(tr("Pick up %s") % nice, best)
	else:
		Events.interaction_cleared.emit()

## Inventory UI -> player: use a carried item by id.
func _on_item_use(item_id: String) -> void:
	if not is_multiplayer_authority():
		return
	match item_id:
		"loot_medkit", "medkit":
			_try_heal()
		"loot_grenade", "grenade":
			_throw_grenade()
		Settings.SELF_REVIVE_ITEM, "self_revive":
			if downed:
				_self_revive()

# --- Active power-cache buffs ------------------------------------------------
## Server → opener: roll a power, play the NON-BLOCKING reveal, then apply it AFTER the reveal.
## Runs on the opener's own client (its authority), so it rolls from THAT player's unlocked pool
## and the buff is applied locally (correct in co-op). The game never pauses during the reveal.
@rpc("any_peer", "call_local", "reliable")
func begin_power_open() -> void:
	if not is_multiplayer_authority():
		return
	var pool: Array = MetaProgression.available_powers()
	if pool.is_empty():
		pool = ["berserk"]
	var rolled: String = String(pool[randi() % pool.size()])
	Events.power_reveal_started.emit(rolled)
	# Apply ONLY once the reveal reel has finished (never before the animation).
	var t := get_tree().create_timer(Settings.POWER_REVEAL_TIME)
	t.timeout.connect(func() -> void:
		if is_instance_valid(self):
			apply_power(rolled))

# --- Enemy-applied slow debuff (cryo-mortar) ----------------------------------
# Movement is CLIENT-authoritative, so the server routes the slow to the owning
# peer via rpc_id (same trust pattern as begin_power_open). Time-boxed via ticks —
# no per-frame bookkeeping; re-hits simply extend/refresh the window.
var _slow_until_ms: int = 0
var _slow_mult: float = 1.0

## Server → owner: apply a movement slow of `mult` (e.g. 0.6 = 40% slower) for `dur` s.
@rpc("any_peer", "call_local", "reliable")
func server_apply_slow(mult: float, dur: float) -> void:
	if not is_multiplayer_authority():
		return
	_slow_mult = clampf(mult, 0.2, 1.0)
	_slow_until_ms = Time.get_ticks_msec() + int(maxf(dur, 0.0) * 1000.0)

## Grant a timed buff (called on the owning authority after the cache reveal finishes).
func apply_power(power_id: String) -> void:
	if not is_multiplayer_authority():
		return
	var def: Dictionary = Settings.POWERS.get(power_id, {})
	if def.is_empty():
		return
	var dur: float = float(def.get("dur", 20.0))
	_buffs[power_id] = dur
	if String(def.get("field", "")) == "overshield":
		_overshield = maxf(_overshield, float(def.get("mag", 0.0)))
	Events.buff_applied.emit(self, power_id, dur)

func _has_buff(power_id: String) -> bool:
	return _buffs.has(power_id)

## Sum of magnitudes for every active buff whose POWERS.field matches `field` (+ Frenzy, which
## boosts damage/fire/speed together). Returns the additive bonus (e.g. 0.6 = +60%).
func _buff_sum(field: String) -> float:
	var total: float = 0.0
	for id in _buffs:
		var def: Dictionary = Settings.POWERS.get(id, {})
		var f: String = String(def.get("field", ""))
		if f == field:
			total += float(def.get("mag", 0.0))
		elif f == "frenzy" and (field == "damage" or field == "fire_rate" or field == "speed"):
			total += float(def.get("mag", 0.0))
	return total

func buff_damage_mult() -> float:
	return 1.0 + _buff_sum("damage")

func buff_fire_rate_mult() -> float:
	return 1.0 + _buff_sum("fire_rate")

func buff_speed_mult() -> float:
	return 1.0 + _buff_sum("speed")

## Reload-time multiplier (<1 = faster). Adrenaline speeds reloads.
func buff_reload_mult() -> float:
	var a: float = _buff_sum("adrenaline")
	return 1.0 / (1.0 + a) if a > 0.0 else 1.0

## Fraction of dealt damage returned as healing (Lifesteal).
func buff_lifesteal_frac() -> float:
	return _buff_sum("lifesteal")

## Damage filter set on Health: Juggernaut armor reduces, then Overshield absorbs the rest.
func _filter_incoming_damage(amount: float, _source: Node) -> float:
	var armor: float = clampf(_buff_sum("armor"), 0.0, 0.9)
	amount *= (1.0 - armor)
	if _overshield > 0.0:
		var absorbed: float = minf(_overshield, amount)
		_overshield -= absorbed
		amount -= absorbed
	return amount

## Heal a fraction of damage just dealt to an enemy (Lifesteal). Called from the local weapon.
func on_dealt_damage(amount: float) -> void:
	if not is_multiplayer_authority() or downed or health == null or health.is_dead:
		return
	var frac: float = buff_lifesteal_frac()
	if frac > 0.0 and amount > 0.0:
		health.heal(amount * frac)

## Per-frame: count buffs down, apply regen, expire + revert. Authority-only.
func _tick_buffs(delta: float) -> void:
	if _buffs.is_empty():
		return
	var regen: float = _buff_sum("regen")
	if regen > 0.0 and not downed and health != null and not health.is_dead \
			and health.current < health.max_health:
		health.heal(regen * delta)
	var expired: Array = []
	for id in _buffs:
		_buffs[id] = float(_buffs[id]) - delta
		if float(_buffs[id]) <= 0.0:
			expired.append(id)
	for id in expired:
		_buffs.erase(id)
		if String(Settings.POWERS.get(id, {}).get("field", "")) == "overshield":
			_overshield = 0.0
		Events.buff_expired.emit(self, String(id))

## Snapshot of active buffs for the HUD / harness: [{ id, name, time_left, color }].
func active_buffs() -> Array:
	var out: Array = []
	for id in _buffs:
		var def: Dictionary = Settings.POWERS.get(id, {})
		out.append({ "id": String(id), "name": String(def.get("name", id)),
			"time_left": float(_buffs[id]), "color": def.get("color", Color.WHITE) })
	return out


## This peer's own player configures its STARTING consumables from its OWN profile's
## bring-list (committed from the stash at deploy). Weapons are loaded separately by the
## WeaponController from the same local profile. Authority-only — the counts replicate
## to other peers via the MultiplayerSynchronizer so the server can read them on extract.
func apply_loadout() -> void:
	var brought := MetaProgression.get_bring()
	_medkits = int(brought.get("loot_medkit", 0))
	_grenades = int(brought.get("loot_grenade", 0))
	_self_revives = int(brought.get(Settings.SELF_REVIVE_ITEM, 0))
	_shields = int(brought.get(Settings.KNOCKDOWN_SHIELD_ITEM, 0))

## Surviving brought consumables as stash stacks — added to the extraction deposit so
## unused medkits/grenades come back out with you (and are lost if you die).
func extracted_consumables() -> Array:
	var out: Array = []
	if _medkits > 0:
		out.append({ "id": "loot_medkit", "count": _medkits })
	if _grenades > 0:
		out.append({ "id": "loot_grenade", "count": _grenades })
	return out


var _last_hp: float = -1.0
func _on_health_changed(current: float, max_health: float) -> void:
	# Finish-damage while downed: a drop in HP drains the downed pool / bleedout faster
	# (authority only; the synced `downed` flag is set on the authority).
	if downed and is_multiplayer_authority() and _last_hp >= 0.0 and current < _last_hp:
		_on_downed_damage(_last_hp, current)
	_last_hp = current
	Events.player_health_changed.emit(self, current, max_health)


## Health hit 0. Instead of dying outright we ENTER THE DOWNED state (a teammate can
## revive, or a self-revive item / bleedout resolves it). Only the authority drives this
## for its own player. A second `died` while already downed (the finish-damage path drains
## downed HP and re-triggers `_die`) means true death.
func _on_died(killer: Node) -> void:
	if not is_multiplayer_authority():
		return
	if downed:
		# Already down and Health hit 0 again → finish them (true death).
		_true_death()
		return
	_enter_downed(killer)

## Begin the DOWNED state on the authority: crawl-only, camera dropped, bleedout running.
## Clears Health.is_dead so heal/revive work, and tells the server to own GameState.downed.
func _enter_downed(killer: Node) -> void:
	downed = true
	_downed_resolved = false
	_bleedout = Settings.BLEEDOUT_TIME
	velocity = Vector3.ZERO
	# A brought knockdown shield soaks the first chunk of finish-damage while downed.
	if _shields > 0:
		_shields -= 1
		_shield_charges = Settings.KNOCKDOWN_SHIELD_ABSORB
	else:
		_shield_charges = 0.0
	# Reset Health to a small downed pool so heal()/revive work and finish-damage can drain it.
	health.is_dead = false
	health.current = DOWNED_HEALTH
	health.health_changed.emit(health.current, health.max_health)
	# Stop ADS / firing; the cursor stays captured so you can still crawl + ping.
	_ads = false
	_ads_toggled = false
	# Drop the carrying side if we were carrying someone (can't carry while downed).
	_drop_carry()
	Events.player_downed.emit(self, killer)
	var pid := str(name).to_int()
	if GameState.is_local_authority_server():
		NetworkManager.broadcast_downed(pid, true)
	else:
		_report_downed.rpc_id(1, pid, true)

## Authority → server: my player entered (true) / left downed. The SERVER owns
## GameState.downed + broadcasts it to everyone (drives the loss check + remote HUD/AI).
@rpc("any_peer", "call_remote", "reliable")
func _report_downed(pid: int, value: bool) -> void:
	if GameState.is_local_authority_server():
		NetworkManager.broadcast_downed(pid, value)

## Per-frame bleedout countdown while downed (authority only). At 0 → true death.
func _tick_downed(delta: float) -> void:
	if _downed_resolved:
		return
	_bleedout -= delta
	if _bleedout <= 0.0:
		_bleedout = 0.0
		_true_death()

## Resolve a downed player to TRUE death: emit bleedout, then the original death
## resolution (mark_dead + loss check), and clear the synced downed flag.
func _true_death() -> void:
	if _downed_resolved:
		return
	_downed_resolved = true
	downed = false
	_drop_carry()
	_input_enabled = false
	velocity = Vector3.ZERO
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Events.player_bleedout.emit(self)
	var pid := str(name).to_int()
	if GameState.is_local_authority_server():
		_server_handle_death(pid)
	else:
		_report_death.rpc_id(1, pid)

## SERVER: revive this downed player (called by NetworkManager.request_revive after it
## validates the reviver). Clears downed, heals to a fraction, restores control + camera.
func server_revive(by: Node) -> void:
	if not GameState.is_local_authority_server():
		return
	if not downed:
		return
	_apply_revive()
	GameState.set_downed(str(name).to_int(), false)
	NetworkManager.broadcast_downed(str(name).to_int(), false)
	Events.player_revived.emit(self, by)
	# Tell the OWNING client to come out of its local downed state (input/camera/Health).
	if multiplayer.has_multiplayer_peer() and not NetworkManager.is_offline:
		var owner := str(name).to_int()
		if owner != 1:
			_revived_owner.rpc_id(owner, _peer_of(by))

## Owner-side notification that the SERVER revived this player (the owner restores its
## own local input/camera/Health, which the server can't drive remotely).
@rpc("any_peer", "call_remote", "reliable")
func _revived_owner(by_peer: int) -> void:
	if not is_multiplayer_authority():
		return
	var by: Node = _player_for_peer(by_peer) if by_peer > 0 else self
	_apply_revive()
	Events.player_revived.emit(self, by)

## Shared revive effect (runs on whoever owns the relevant state): clear downed,
## un-flag Health, heal to the configured fraction, restore input.
func _apply_revive() -> void:
	downed = false
	_downed_resolved = false
	_bleedout = 0.0
	_shield_charges = 0.0
	health.is_dead = false
	health.current = maxf(1.0, Settings.REVIVE_HEALTH_FRAC * health.max_health)
	health.health_changed.emit(health.current, health.max_health)
	if is_multiplayer_authority():
		_input_enabled = true
		if AgentBridge.active or Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _peer_of(n: Node) -> int:
	if n == null:
		return 0
	return str(n.name).to_int()

## Local lookup of the player node owned by `peer_id` (the NetworkManager one is private).
func _player_for_peer(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if str(p.name).to_int() == peer_id:
			return p
	return null

# =========================================================== DOWNED finish-damage / movement
## Damage taken WHILE downed drains the downed HP pool faster (and shortens bleedout). A
## knockdown shield soaks the first KNOCKDOWN_SHIELD_ABSORB before the pool is touched.
## Connected to Health.health_changed so we react to any take_damage while down.
func _on_downed_damage(prev: float, now: float) -> void:
	if not downed or _downed_resolved or now >= prev:
		return
	var dmg := prev - now
	if _shield_charges > 0.0:
		var soaked: float = minf(_shield_charges, dmg)
		_shield_charges -= soaked
		dmg -= soaked
		# Refund the soaked portion back into the downed pool so the shield truly absorbs it.
		health.current = minf(DOWNED_HEALTH, health.current + soaked)
	_last_hp = health.current   # re-baseline after any shield refund
	if dmg <= 0.0:
		return
	# Finish damage also bleeds the clock down faster.
	_bleedout = maxf(0.0, _bleedout - dmg * 0.15)
	if health.current <= 0.0 or _bleedout <= 0.0:
		_true_death()

## Crawl movement while downed (authority): slow, no jump/sprint/slide/ADS/fire. Still
## allows the look/yaw from _unhandled_input + ping. Drives the camera down by the drop.
func _downed_physics(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	var move_dir := Vector3.ZERO
	if _input_enabled:
		var strafe: float
		var fwd_amt: float
		if AgentBridge.active:
			strafe = AgentBridge.move.x
			fwd_amt = AgentBridge.move.y
		else:
			strafe = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
			fwd_amt = Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
		var basis := camera_pivot.global_transform.basis
		var forward := -basis.z
		var right := basis.x
		forward.y = 0.0
		right.y = 0.0
		move_dir = right.normalized() * strafe + forward.normalized() * fwd_amt
		if move_dir.length_squared() > 0.0:
			move_dir = move_dir.normalized()
	# A carried downed player follows its carrier's anchor instead of crawling (its OWN
	# authority moves it, so the synced position replicates to everyone).
	if _carried_by_peer > 0 and _carry_anchor != Vector3.INF:
		var to_anchor := _carry_anchor - global_position
		to_anchor.y = 0.0
		velocity.x = to_anchor.x * 8.0
		velocity.z = to_anchor.z * 8.0
	elif _carried_by_peer > 0:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		velocity.x = move_dir.x * Settings.DOWNED_MOVE_SPEED
		velocity.z = move_dir.z * Settings.DOWNED_MOVE_SPEED
	move_and_slide()
	camera_pivot.rotation.y = 0.0
	# Camera lerps down to (base - drop) while downed.
	var target_y := _cam_base_y - Settings.DOWNED_CAMERA_DROP
	var ty := clampf(delta * Settings.CROUCH_CAMERA_LERP, 0.0, 1.0)
	camera_pivot.position.y = lerpf(camera_pivot.position.y, target_y, ty)
	# GIVE UP: hold the give_up key to self-finish and skip the bleedout wait (e.g. solo,
	# with no teammate to revive you). Runs on this player's OWN authority, so it works the
	# same hosting or as a co-op client. Releasing the key resets the hold.
	if _input_enabled and _act_held("give_up"):
		_giveup_held += delta
		if _giveup_held >= Settings.GIVE_UP_HOLD_TIME and not _downed_resolved:
			_bleedout = 0.0
	else:
		_giveup_held = 0.0
	_tick_downed(delta)

## 0..1 progress of the give-up hold (for the HUD ring/bar). 0 when not holding.
func give_up_ratio() -> float:
	if not downed:
		return 0.0
	return clampf(_giveup_held / maxf(Settings.GIVE_UP_HOLD_TIME, 0.001), 0.0, 1.0)

## Extraction saved this downed player: clear the downed state so the bleedout can't
## true-kill them after they reach the evac. Called server-side by ExtractionZone on
## completion; server_revive self-guards to the server and syncs the owning client.
func cancel_downed_for_extract() -> void:
	if downed:
		server_revive(self)

## Consume a SELF_REVIVE_ITEM to revive yourself (solo lifeline). Routes through the server
## so GameState.downed is cleared authoritatively; offline/host applies it directly.
func _self_revive() -> void:
	if _self_revives <= 0 or not downed:
		return
	_self_revives -= 1
	if GameState.is_local_authority_server():
		server_revive(self)
	else:
		# Client self-revive: apply locally for responsiveness + tell the server to clear downed.
		_apply_revive()
		Events.player_revived.emit(self, self)
		_report_downed.rpc_id(1, str(name).to_int(), false)

# =========================================================== REVIVER side (channel) + CARRY
## Authority per-frame: find the nearest DOWNED teammate in range, surface the revive
## prompt, run the hold-E channel, and handle carry (hold F). Loot/extraction prompts
## yield to a downed teammate when one is in range.
func _update_coop_interaction(delta: float) -> void:
	var target := _nearest_downed_teammate()
	# --- Carry (hold F) ---
	if _carry_target != null and (not is_instance_valid(_carry_target) \
			or not _carry_target.get("downed") or not _act_held("carry")):
		_drop_carry()
	if _carry_target == null and target != null and _act_held("carry"):
		_begin_carry(target)
	if _carry_target != null:
		# While carrying, keep the body glued to a point in front of us.
		_update_carry_follow()
		# Carrying suppresses the revive channel + prompt.
		_revive_target = null
		_revive_progress = 0.0
		_set_revive_ui(-1.0)
		Events.interaction_available.emit(tr("Carrying [release F]"), _carry_target)
		_coop_prompt_active = true
		return
	# --- Revive (hold E) ---
	if target == null:
		if _revive_target != null:
			_revive_target = null
			_revive_progress = 0.0
		_set_revive_ui(-1.0)
		# Left the downed teammate — clear the shared "[E]" prompt so the revive/carry hint
		# doesn't stick (the loot update below re-shows a loot prompt if one is in range).
		if _coop_prompt_active:
			_coop_prompt_active = false
			Events.interaction_cleared.emit()
		return
	# A downed teammate takes priority over loot — show the revive prompt.
	Events.interaction_available.emit(tr("Revive / Carry [hold E / F]"), target)
	_coop_prompt_active = true
	if _act_held("interact"):
		if target != _revive_target:
			_revive_target = target
			_revive_progress = 0.0
			_revive_guard_hp = health.current
		# Interrupt the channel if the reviver takes damage (must protect your reviver).
		if _revive_guard_hp >= 0.0 and health.current < _revive_guard_hp - 0.01:
			_revive_target = null
			_revive_progress = 0.0
			_revive_guard_hp = -1.0
			_set_revive_ui(-1.0)
			Events.notify.emit(tr("Revive interrupted"), 2)
			return
		_revive_progress += delta
		# Drive the reviver's HUD progress bar (0..1) so it's clear a revive is in progress.
		_set_revive_ui(clampf(_revive_progress / Settings.REVIVE_CHANNEL_TIME, 0.0, 1.0))
		if _revive_progress >= Settings.REVIVE_CHANNEL_TIME:
			_revive_progress = 0.0
			var tp := str(target.name).to_int()
			NetworkManager.request_revive(tp)
			_revive_target = null
			_set_revive_ui(-1.0)
	else:
		_revive_target = null
		_revive_progress = 0.0
		_set_revive_ui(-1.0)

## Emits the reviver-side revive progress to the HUD. frac 0..1 = channeling (fires every
## frame so the bar fills); frac < 0 = clear (emitted once, then suppressed until active again).
func _set_revive_ui(frac: float) -> void:
	if frac >= 0.0:
		_revive_ui_shown = true
		Events.revive_channel.emit(frac, _revive_target)
	elif _revive_ui_shown:
		_revive_ui_shown = false
		Events.revive_channel.emit(-1.0, null)

## Nearest downed-and-not-yet-revived teammate within INTERACT_RANGE (excludes self).
func _nearest_downed_teammate() -> Node:
	var best: Node = null
	var best_d := Settings.INTERACT_RANGE
	for p in get_tree().get_nodes_in_group("players"):
		if p == self or not (p is Node3D):
			continue
		if not GameState.is_downed(str(p.name).to_int()):
			continue
		var d := global_position.distance_to((p as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = p
	return best

func _begin_carry(target: Node) -> void:
	_carry_target = target
	_tell_carried(target, str(name).to_int())

func _update_carry_follow() -> void:
	if _carry_target == null or not (_carry_target is Node3D):
		return
	# Push a follow point to the carried player's OWNER so ITS authority moves the synced
	# body (a non-authority writing global_position wouldn't replicate). The owner pulls
	# toward this point in its own _downed_physics.
	var ahead := global_position - global_transform.basis.z * 0.9
	ahead.y = global_position.y
	if _carry_target.has_method("set_carry_anchor"):
		_carry_target.set_carry_anchor(ahead)

func _drop_carry() -> void:
	if _carry_target != null and is_instance_valid(_carry_target):
		_tell_carried(_carry_target, 0)
	_carry_target = null

## Tell `target`'s OWNER who is carrying it (so its authority drives the synced follow).
func _tell_carried(target: Node, carrier_peer: int) -> void:
	var owner := str(target.name).to_int()
	if not multiplayer.has_multiplayer_peer() or NetworkManager.is_offline or owner == GameState.local_peer_id():
		target.set_carried_by(carrier_peer)
	else:
		target._set_carried_rpc.rpc_id(owner, carrier_peer)

@rpc("any_peer", "call_remote", "reliable")
func _set_carried_rpc(peer_id: int) -> void:
	set_carried_by(peer_id)

## Set/clear who is carrying THIS player (runs on the carried player's OWNER → the synced
## flag replicates from here).
func set_carried_by(peer_id: int) -> void:
	_carried_by_peer = peer_id
	if peer_id == 0:
		_carry_anchor = Vector3.INF

var _carry_anchor: Vector3 = Vector3.INF
## The carrier feeds a target world point; THIS player's authority eases its body toward it.
func set_carry_anchor(p: Vector3) -> void:
	_carry_anchor = p

## PUBLIC: HUD / other lanes query downed state.
func is_downed() -> bool:
	return downed

## Agent-or-input HELD read: when the harness drives this player, consult
## AgentBridge.held(action); otherwise the real Input. Lets the harness HOLD
## crouch/interact/carry (revive/carry/crouch testing).
func _act_held(action: String) -> bool:
	return AgentBridge.held(action) if AgentBridge.active else Input.is_action_pressed(action)

# --- Audible movement noise (sound stealth) ---------------------------------
## Observe planar speed from the SYNCED position on every peer (runs on server AND
## clients), so the server-side enemy perception can hear a remote client's footsteps
## without syncing velocity. Cheap; lightly smoothed against single-frame jitter.
func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if not _noise_inited:
		_noise_last_pos = global_position
		_noise_inited = true
		return
	var d := global_position - _noise_last_pos
	d.y = 0.0
	var inst := d.length() / delta
	_noise_last_pos = global_position
	_noise_speed = lerpf(_noise_speed, inst, clampf(delta * 10.0, 0.0, 1.0))

## Audible radius (metres) of this player's movement, for the server-side enemy AI.
## Crouch-walking is quiet, sprinting is loud, standing still is a faint hum; a downed
## (crawling) player is nearly silent. Pure read — safe on any peer.
func noise_radius() -> float:
	if downed:
		return Settings.NOISE_IDLE * 0.5
	var spd := _noise_speed
	if spd < 0.4:
		return Settings.NOISE_IDLE
	var loud: float
	if spd >= Settings.PLAYER_MOVE_SPEED + 0.4:
		loud = Settings.NOISE_SPRINT     # running
	else:
		loud = Settings.NOISE_WALK       # walking
	if stance == Stance.CROUCH:
		loud *= Settings.NOISE_CROUCH_MULT
	elif stance == Stance.SLIDE:
		loud = Settings.NOISE_WALK       # a slide scrapes — moderately loud
	return loud

## True if the local player can only use a sidearm / can't ADS (carrying a buddy).
func is_carrying() -> bool:
	return _carry_target != null

## Client -> server: "my player died". Server-only resolution below.
@rpc("any_peer", "call_remote", "reliable")
func _report_death(pid: int) -> void:
	if GameState.is_local_authority_server():
		_server_handle_death(pid)

func _server_handle_death(pid: int) -> void:
	GameState.mark_dead(pid)
	GameState.set_downed(pid, false)
	NetworkManager.broadcast_downed(pid, false)
	# Loss only when NO ONE is still up (alive, not downed, not extracted) — a downed
	# teammate alone is NOT a loss while someone can still revive them.
	if not GameState.any_player_up():
		NetworkManager.broadcast_match_lost()
