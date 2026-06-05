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
	spring_arm.spring_length = Settings.DEFAULT_SPRING_LENGTH
	spring_arm.position.x = Settings.SHOULDER_OFFSET

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
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		Events.item_use_requested.connect(_on_item_use)
		Events.local_player_spawned.emit(self)
	else:
		# Remote avatars: their camera/input must never run on this machine.
		camera.current = false
		set_process_unhandled_input(false)


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

	var speed := Settings.PLAYER_MOVE_SPEED
	var wants_sprint := AgentBridge.sprint if AgentBridge.active else Input.is_action_pressed("sprint")
	var moving := move_dir.length_squared() > 0.01
	var sprinting := _input_enabled and wants_sprint and moving and not _sprint_locked and _stamina > 0.0
	if sprinting:
		speed = Settings.PLAYER_SPRINT_SPEED
	_update_stamina(delta, sprinting)

	velocity.x = move_dir.x * speed
	velocity.z = move_dir.z * speed

	move_and_slide()

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
	var target_len := (Settings.ADS_SPRING_LENGTH if _ads else Settings.DEFAULT_SPRING_LENGTH)
	var base_off := _shoulder_sign * Settings.SHOULDER_OFFSET * (0.65 if _ads else 1.0)
	var target_off := base_off + _compute_peek()
	var target_y := 1.5 + (0.18 if _ads else 0.0)

	var t := clampf(delta * Settings.AIM_TWEEN_SPEED, 0.0, 1.0)
	camera.fov = lerpf(camera.fov, target_fov, t)
	# Transient FOV punch from CameraFX (explosions / heavy hits) — additive so the
	# ADS lerp above stays the baseline. CameraFX never writes camera.fov itself.
	var _camfx := camera.get_node_or_null("CameraFX")
	if _camfx and _camfx.has_method("fov_offset"):
		camera.fov += _camfx.fov_offset()
	spring_arm.spring_length = lerpf(spring_arm.spring_length, target_len, t)
	spring_arm.position.x = lerpf(spring_arm.position.x, target_off, t)
	camera_pivot.position.y = lerpf(camera_pivot.position.y, target_y, t)


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
