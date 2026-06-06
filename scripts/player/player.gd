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

const GRENADE_SCENE := "res://scenes/items/Grenade.tscn"


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
	_max_stamina = Settings.MAX_STAMINA * float(_mods.get("stamina_mult", 1.0))
	_stamina = _max_stamina

	# Fill the visual model from the registry (CC0 glb if present, else primitive).
	var model: Node3D = AssetRegistry.get_model("player")
	model_root.add_child(model)

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


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	# Gravity (uses the project's configured gravity vector).
	if not is_on_floor():
		velocity += get_gravity() * delta

	if _input_enabled and is_on_floor() and Input.is_action_just_pressed("jump"):
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
	var crouch_held := _input_enabled and Input.is_action_pressed("crouch")
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

	# Nearby-loot "[E]" interaction prompt (throttled).
	_interact_timer -= delta
	if _interact_timer <= 0.0:
		_interact_timer = 0.15
		_update_interaction()

	# Held-to-fire (cooldown handled by the weapon/controller).
	var firing := AgentBridge.fire if AgentBridge.active else Input.is_action_pressed("fire")
	if _input_enabled and firing:
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
	if AgentBridge.active:
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
		_try_heal()
	elif event.is_action_pressed("grenade"):
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
	if sprinting:
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
	var best: Node = null
	var best_d := Settings.INTERACT_RANGE
	for n in get_tree().get_nodes_in_group("pickups"):
		if n is Node3D:
			var d := global_position.distance_to((n as Node3D).global_position)
			if d < best_d:
				best_d = d
				best = n
	if best == _interact_target:
		return
	_interact_target = best
	if best:
		var item_id := str(best.get("item_id")) if "item_id" in best else "item"
		var nice := item_id.replace("loot_", "").capitalize()
		Events.interaction_available.emit("Pick up %s" % nice, best)
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


## This peer's own player configures its STARTING consumables from its OWN profile's
## bring-list (committed from the stash at deploy). Weapons are loaded separately by the
## WeaponController from the same local profile. Authority-only — the counts replicate
## to other peers via the MultiplayerSynchronizer so the server can read them on extract.
func apply_loadout() -> void:
	var brought := MetaProgression.get_bring()
	_medkits = int(brought.get("loot_medkit", 0))
	_grenades = int(brought.get("loot_grenade", 0))

## Surviving brought consumables as stash stacks — added to the extraction deposit so
## unused medkits/grenades come back out with you (and are lost if you die).
func extracted_consumables() -> Array:
	var out: Array = []
	if _medkits > 0:
		out.append({ "id": "loot_medkit", "count": _medkits })
	if _grenades > 0:
		out.append({ "id": "loot_grenade", "count": _grenades })
	return out


func _on_health_changed(current: float, max_health: float) -> void:
	Events.player_health_changed.emit(self, current, max_health)


func _on_died(_killer: Node) -> void:
	# Stop driving the body and report the death to the server, which decides the
	# loss (all players dead) and broadcasts match_lost to every peer.
	_input_enabled = false
	velocity = Vector3.ZERO
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	var pid := str(name).to_int()
	if GameState.is_local_authority_server():
		_server_handle_death(pid)
	else:
		_report_death.rpc_id(1, pid)

## Client -> server: "my player died". Server-only resolution below.
@rpc("any_peer", "call_remote", "reliable")
func _report_death(pid: int) -> void:
	if GameState.is_local_authority_server():
		_server_handle_death(pid)

func _server_handle_death(pid: int) -> void:
	GameState.mark_dead(pid)
	if GameState.all_players_dead():
		NetworkManager.broadcast_match_lost()
