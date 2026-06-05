extends Node
class_name PlayerAnimator
## Gives the player character visible animation without touching player.gd.
##
## Attach as a child Node named "PlayerAnimator" directly under the Player
## (CharacterBody3D). On ready it defers one frame so player.gd's _ready()
## has finished adding the visual model under ModelRoot.
##
## TWO LAYERS run in parallel and complement each other:
##   1. SKELETAL — drives an AnimationPlayer found in the raider.glb subtree (if
##      any clips are present). Maps clips by keyword, cross-fades, and plays
##      one-shot fire/reload animations on Events signals.
##   2. PROCEDURAL — a pure-math walk-bob + lean applied to the visual model's
##      LOCAL transform each frame. Guaranteed to produce a visible result even
##      when the GLB ships no skeletal clips (which is likely for the Kenney
##      raider mesh). Resets smoothly toward neutral when idle.
##
## Footstep events (Events.footstep) are emitted at each step's low-point when
## the player is moving on the ground, for the audio-dev to consume.

# ── tunables ────────────────────────────────────────────────────────────────

## Vertical bob amplitude at walk speed (metres).
const BOB_AMPLITUDE_WALK: float   = 0.028
## Vertical bob amplitude at full sprint (metres).
const BOB_AMPLITUDE_SPRINT: float = 0.052
## Side-to-side roll amplitude at full sprint (degrees).
const ROLL_AMPLITUDE_DEG: float   = 2.4
## Forward-lean pitch at full sprint (degrees, positive = lean forward).
const PITCH_LEAN_DEG: float       = 1.8
## Walk-cycle phase speed (radians/sec) at walk speed.
const CYCLE_SPEED_WALK: float     = 8.0
## Walk-cycle phase speed at sprint.
const CYCLE_SPEED_SPRINT: float   = 12.5
## How quickly the procedural offset interpolates back toward neutral (s^-1).
const RESET_SPEED: float          = 10.0
## Horizontal speed below which the player is considered "idle".
const IDLE_SPEED_THRESHOLD: float = 0.4
## Recoil: downward translation kick on fire (metres).
const RECOIL_DIP: float           = 0.025
## Recoil: backward translation on fire (metres along local Z).
const RECOIL_KICK: float          = 0.03
## How quickly recoil decays (s^-1).
const RECOIL_DECAY: float         = 14.0
## Landing dip depth (metres).
const LAND_DIP: float             = 0.04
## How quickly the landing dip decays (s^-1).
const LAND_DECAY: float           = 12.0
## Speed threshold (m/s) to consider the player "sprinting" for animation purposes.
const SPRINT_SPEED_THRESHOLD: float = Settings.PLAYER_MOVE_SPEED + 0.5

# ── state ────────────────────────────────────────────────────────────────────

var _parent: CharacterBody3D = null   # the Player node

# ModelRoot's first child — the Node3D wrapper created by AssetRegistry._fit_model.
# This is what we animate; we write ONLY to its local transform.
var _visual_model: Node3D = null

# ── skeletal layer ───────────────────────────────────────────────────────────
var _anim_player: AnimationPlayer = null
var _current_anim: String = ""
var _anim_idle:   String = ""
var _anim_walk:   String = ""
var _anim_run:    String = ""
var _anim_fire:   String = ""
var _anim_reload: String = ""

## Whether the GLB actually had skeletal clips (logged in _ready, reported to lead).
var _has_skeletal_clips: bool = false

# Tracks active one-shot overlay state.
var _reloading: bool = false

# ── procedural layer ─────────────────────────────────────────────────────────
var _bob_phase: float   = 0.0    # accumulated walk-cycle angle (radians)
var _prev_bob_y: float  = 0.0    # previous sine value for footstep detection
var _recoil_t: float    = 0.0   # 0..1; decays to 0
var _land_t: float      = 0.0   # 0..1; decays to 0
var _was_on_floor: bool = false  # for landing detection
var _proc_offset: Vector3  = Vector3.ZERO    # accumulated procedural translation
var _proc_rot_deg: Vector3 = Vector3.ZERO    # accumulated procedural rotation (degrees)

# ── lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_parent = get_parent() as CharacterBody3D
	if _parent == null:
		push_warning("[PlayerAnimator] parent is not CharacterBody3D — disabling.")
		set_process(false)
		return

	# The player model is added in player.gd's _ready(). Deferring one frame
	# ensures ModelRoot already has its child before we look it up.
	call_deferred("_init_deferred")

	# Wire Events signals. All connections are guarded so missing signals (if
	# Events.gd is patched later) don't crash.
	if Events.has_signal("weapon_fired"):
		Events.weapon_fired.connect(_on_weapon_fired)
	if Events.has_signal("reload_started"):
		Events.reload_started.connect(_on_reload_started)
	if Events.has_signal("reload_finished"):
		Events.reload_finished.connect(_on_reload_finished)


## Called one frame after _ready so the model is present under ModelRoot.
func _init_deferred() -> void:
	var model_root: Node3D = _parent.get_node_or_null("ModelRoot") as Node3D
	if model_root == null:
		push_warning("[PlayerAnimator] ModelRoot not found on parent — no animation.")
		return
	if model_root.get_child_count() == 0:
		push_warning("[PlayerAnimator] ModelRoot has no children (model absent) — no animation.")
		return

	# The AssetRegistry wraps every GLB in a plain Node3D (the "fit wrapper").
	# Animate that wrapper so we don't fight any parent-level transform.
	_visual_model = model_root.get_child(0) as Node3D
	if _visual_model == null:
		push_warning("[PlayerAnimator] ModelRoot first child is not Node3D — no animation.")
		return

	# ── skeletal layer setup ──────────────────────────────────────────────────
	_anim_player = _find_animation_player(_visual_model)
	if _anim_player != null:
		var names: PackedStringArray = _anim_player.get_animation_list()
		_anim_idle   = _pick_anim(names, ["Idle",    "idle",    "Stand"])
		_anim_walk   = _pick_anim(names, ["Walking", "Walk",    "walk"])
		_anim_run    = _pick_anim(names, ["Running", "Run",     "run", "Sprint"])
		_anim_fire   = _pick_anim(names, ["Shoot",   "Fire",    "Attack", "Punch"])
		_anim_reload = _pick_anim(names, ["Reload",  "reload"])

		# Make locomotion clips loop (many GLBs ship them as one-shots).
		for loop_anim in [_anim_idle, _anim_walk, _anim_run]:
			if loop_anim != "" and _anim_player.has_animation(loop_anim):
				var a: Animation = _anim_player.get_animation(loop_anim)
				if a:
					a.loop_mode = Animation.LOOP_LINEAR

		_has_skeletal_clips = names.size() > 0
		print("[PlayerAnimator] raider.glb AnimationPlayer found. Clips: %s" % [Array(names)])
		print("[PlayerAnimator]   mapped -> idle:'%s' walk:'%s' run:'%s' fire:'%s' reload:'%s'"
			% [_anim_idle, _anim_walk, _anim_run, _anim_fire, _anim_reload])
	else:
		_has_skeletal_clips = false
		print("[PlayerAnimator] raider.glb has NO AnimationPlayer — procedural layer only.")


func _process(delta: float) -> void:
	if _parent == null or _visual_model == null:
		return
	_update_skeletal()
	_update_procedural(delta)


# ── skeletal layer ────────────────────────────────────────────────────────────

## Drives the AnimationPlayer from the player's runtime state.
## One-shot anims (fire/reload) are handled via signal callbacks to avoid
## interrupting them mid-clip; this function only drives locomotion.
func _update_skeletal() -> void:
	if _anim_player == null:
		return

	# Don't override an active one-shot (reload). Fire is brief enough to let
	# the AnimationPlayer finish naturally; we only gate on reload.
	if _reloading:
		return

	var horiz_speed: float = Vector2(_parent.velocity.x, _parent.velocity.z).length()
	var desired: String = _anim_idle

	if horiz_speed > IDLE_SPEED_THRESHOLD:
		if horiz_speed >= SPRINT_SPEED_THRESHOLD and _anim_run != "":
			desired = _anim_run
		elif _anim_walk != "":
			desired = _anim_walk
		else:
			desired = _anim_run  # fallback to run if walk absent

	# Jump / fall: prefer idle (no jump clip mapped, but skip locomotion noise).
	if not _parent.is_on_floor():
		desired = _anim_idle

	if desired != "" and desired != _current_anim:
		_play_anim(desired)


func _play_anim(anim_name: String) -> void:
	if _anim_player == null or anim_name == "":
		return
	if not _anim_player.has_animation(anim_name):
		return
	_current_anim = anim_name
	_anim_player.play(anim_name, 0.15)  # 0.15 s cross-fade


# ── procedural layer ──────────────────────────────────────────────────────────

## Applies a purely mathematical bob + lean + recoil to _visual_model.transform.
## All values are written as local transforms on the visual model wrapper only —
## no other node is touched, so this never conflicts with AssetRegistry offsets
## (those live on the inner GLB node) or ModelRoot (untouched).
func _update_procedural(delta: float) -> void:
	# ── landing dip ──────────────────────────────────────────────────────────
	var on_floor: bool = _parent.is_on_floor()
	if on_floor and not _was_on_floor:
		# Just landed — kick in a small downward dip.
		_land_t = 1.0
	_was_on_floor = on_floor

	_land_t = maxf(0.0, _land_t - delta * LAND_DECAY)

	# ── walk-bob phase ────────────────────────────────────────────────────────
	var horiz_speed: float = Vector2(_parent.velocity.x, _parent.velocity.z).length()
	var moving: bool       = horiz_speed > IDLE_SPEED_THRESHOLD
	var sprinting: bool    = horiz_speed >= SPRINT_SPEED_THRESHOLD

	var t_speed: float = 0.0   # normalized 0..1 between walk and sprint threshold
	if moving:
		t_speed = clampf(
			(horiz_speed - IDLE_SPEED_THRESHOLD) / (SPRINT_SPEED_THRESHOLD - IDLE_SPEED_THRESHOLD),
			0.0, 1.0)

	var cycle_rate: float = lerpf(CYCLE_SPEED_WALK, CYCLE_SPEED_SPRINT, t_speed)

	var prev_phase: float = _bob_phase
	if moving and on_floor:
		_bob_phase += cycle_rate * delta

	# ── footstep emission ─────────────────────────────────────────────────────
	# Emit at each "down beat" of the bob (sine crosses from positive to negative,
	# i.e. foot hits the ground). Two footsteps per full cycle (left + right).
	if moving and on_floor:
		var cur_sin: float  = sin(_bob_phase)
		var prev_sin: float = sin(prev_phase)
		# Detect a downward zero-crossing (positive -> negative).
		if prev_sin >= 0.0 and cur_sin < 0.0:
			if Events.has_signal("footstep"):
				Events.footstep.emit(_parent, sprinting)

	# ── compute bob amounts ───────────────────────────────────────────────────
	var bob_amp: float = lerpf(BOB_AMPLITUDE_WALK, BOB_AMPLITUDE_SPRINT, t_speed)
	# Vertical: sine of the phase (2x frequency for a proper step cycle feel).
	var bob_y: float   = sin(_bob_phase * 2.0) * bob_amp * (1.0 if moving else 0.0)
	# Decay landing dip into the vertical offset.
	bob_y -= _land_t * LAND_DIP

	# Roll (local Z rotation): sways left/right with the step.
	var roll_deg: float  = cos(_bob_phase) * ROLL_AMPLITUDE_DEG * t_speed

	# Pitch (local X rotation): lean forward when sprinting.
	var pitch_deg: float = t_speed * PITCH_LEAN_DEG

	# ── recoil ────────────────────────────────────────────────────────────────
	_recoil_t = maxf(0.0, _recoil_t - delta * RECOIL_DECAY)
	var recoil_y: float = _recoil_t * RECOIL_DIP
	var recoil_z: float = _recoil_t * RECOIL_KICK

	# ── target offsets ────────────────────────────────────────────────────────
	var target_offset := Vector3(0.0, bob_y - recoil_y, recoil_z)
	var target_rot    := Vector3(deg_to_rad(pitch_deg), 0.0, deg_to_rad(roll_deg))

	# Smoothly reset toward neutral when idle (avoids snapping).
	var reset_t: float = clampf(delta * RESET_SPEED, 0.0, 1.0)
	_proc_offset  = _proc_offset.lerp(target_offset, reset_t if moving else reset_t)
	_proc_rot_deg = _proc_rot_deg.lerp(Vector3(target_rot.x, 0.0, target_rot.z), reset_t)

	# ── write to visual model's local transform ───────────────────────────────
	# We compose a fresh transform from the bob offset + rotation so we always
	# start from identity and avoid accumulated drift. The AssetRegistry fit
	# (scale, rot, offset) lives on the inner GLB child, not the wrapper root —
	# so writing wrapper.position/rotation_degrees is safe and non-conflicting.
	_visual_model.position           = _proc_offset
	_visual_model.rotation           = Vector3(_proc_rot_deg.x, 0.0, _proc_rot_deg.z)


# ── Events callbacks ──────────────────────────────────────────────────────────

## weapon_fired(shooter, weapon_id): only react when it's our player.
func _on_weapon_fired(shooter: Node, _weapon_id: String) -> void:
	if shooter != _parent:
		return
	# Procedural recoil kick.
	_recoil_t = 1.0
	# One-shot skeletal fire animation (if mapped).
	if _anim_player != null and _anim_fire != "" and not _reloading:
		_play_anim(_anim_fire)
		_current_anim = ""    # allow locomotion to re-assert after it finishes


## reload_started(weapon_id): lock locomotion animation while reloading.
func _on_reload_started(_weapon_id: String) -> void:
	_reloading = true
	if _anim_player != null and _anim_reload != "":
		_play_anim(_anim_reload)


## reload_finished(weapon_id): resume locomotion-driven animation.
func _on_reload_finished(_weapon_id: String) -> void:
	_reloading = false
	_current_anim = ""    # force locomotion to re-evaluate next frame


# ── helpers (mirrored from robot_enemy.gd) ────────────────────────────────────

## Depth-first search for the first AnimationPlayer in the subtree of `root`.
func _find_animation_player(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	for child in root.get_children():
		if child is AnimationPlayer:
			return child as AnimationPlayer
		var found: AnimationPlayer = _find_animation_player(child)
		if found:
			return found
	return null


## Returns the first entry in `candidates` that matches any name in `names`
## (exact first, then case-insensitive). Returns "" if none match.
func _pick_anim(names: PackedStringArray, candidates: Array) -> String:
	# Exact pass.
	for cand in candidates:
		for n in names:
			if n == cand:
				return n
	# Case-insensitive pass.
	for cand in candidates:
		var lc: String = String(cand).to_lower()
		for n in names:
			if String(n).to_lower() == lc:
				return n
	return ""
