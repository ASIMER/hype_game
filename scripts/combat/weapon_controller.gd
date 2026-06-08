extends Node3D
class_name WeaponController
## The player's weapon arsenal: holds the 5 WeaponData definitions, tracks per-weapon
## ammo + reserve, and handles switching / reloading. Firing is delegated to a child
## Weapon node (weapon.gd) via fire_with(), so all existing VFX/audio hooks keep
## working unchanged.
##
## WIRING (for the player/lead) — place this scene at
##   CameraPivot/SpringArm3D/Camera3D/WeaponController under Player.tscn, then:
##   - call try_fire(camera) when the fire button is pressed/held (returns true if a shot went out)
##   - call set_enabled(true) ONLY for the local authority player (gates input reading)
##   - read current_ads_fov() for the camera zoom and current_weapon_id() for HUD/anims
## The controller reads its OWN input (weapon_1..5 / weapon_next / weapon_prev / reload)
## once enabled, and emits Events.weapon_switched / ammo_changed / reload_* for the HUD.

const WEAPON_PATHS := [
	"res://resources/weapons/rifle.tres",
	"res://resources/weapons/shotgun.tres",
	"res://resources/weapons/smg.tres",
	"res://resources/weapons/pistol.tres",
	"res://resources/weapons/dmr.tres",
]

var _weapons: Array[WeaponData] = []
var _index: int = 0
var _ammo: Dictionary = {}        # weapon id -> current mag count
var _reserve: Dictionary = {}     # weapon id -> spare ammo

var _enabled: bool = false        # input reading gate (local authority only)
var _switch_timer: float = 0.0    # >0 while switching (firing locked out)
var _reloading: bool = false
var _reload_timer: float = 0.0

var _weapon: Weapon               # child hitscan node we delegate fire_with() to
var _model_holder: Node3D         # child that shows the current weapon model
var _cooldown: float = 0.0        # time until the next shot is allowed (1/fire_rate)
var _semi_latched: bool = false   # semi-auto: true once we've fired for the current hold
var _since_fire_call: float = 1.0 # seconds since try_fire() was last called (release detect)
var _tf_calls: int = 0      # DIAG: try_fire() call count
var _tf_fail: String = ""   # DIAG: last try_fire early-return reason

# ADS state of THIS controller's owning player. Tracked off Events.ads_changed
# (only honored for our own player node) so the authoritative shot path and the
# crosshair can both fold the ADS spread multiplier in without reaching into the
# player's private `_ads`. The owning player body is cached lazily.
var _ads: bool = false
var _owner_player: Node = null

func _ready() -> void:
	_weapon = get_node_or_null("Weapon") as Weapon
	_model_holder = get_node_or_null("ModelHolder") as Node3D
	if _model_holder == null:
		_model_holder = Node3D.new()
		_model_holder.name = "ModelHolder"
		add_child(_model_holder)
	if not Events.ads_changed.is_connected(_on_ads_changed):
		Events.ads_changed.connect(_on_ads_changed)
	_load_weapons()
	_refresh_model()
	# Broadcast the starting weapon + ammo so the HUD shows it immediately.
	_emit_switched()

## Tracks the owning player's ADS state. Only the event for OUR player matters
## (co-op: every controller hears every peer's ads_changed) — match by body.
func _on_ads_changed(who: Node, a: bool) -> void:
	if who == _owner_body():
		_ads = bool(a)

## The CharacterBody3D player that owns this controller (cached). Walks up the
## node tree from this controller — the controller lives deep under Player.tscn.
func _owner_body() -> Node:
	if is_instance_valid(_owner_player):
		return _owner_player
	var n := get_parent()
	while n != null:
		if n is CharacterBody3D or n is RigidBody3D:
			_owner_player = n
			return n
		n = n.get_parent()
	return null

## The owning player's stance spread multiplier (crouch/stand/move/sprint/slide),
## or 1.0 if the player doesn't expose the API (Lane A adds it in parallel).
func _stance_mult() -> float:
	var p := _owner_body()
	if p != null and p.has_method("stance_spread_mult"):
		return float(p.stance_spread_mult())
	return 1.0

func _load_weapons() -> void:
	_weapons.clear()
	# Resolve which weapons to bring: the meta-progression loadout (ids) if any
	# resolve to real resources, else fall back to the full default arsenal.
	var paths := _loadout_paths()
	# Combined stat multipliers: permanent upgrades (damage/reload) + difficulty's
	# player_damage handicap/assist. Resources are DUPLICATED before mutation so the
	# shared cached .tres is never corrupted.
	var mods: Dictionary = MetaProgression.player_mods()
	var dmg_mult: float = float(mods.get("damage_mult", 1.0)) * float(Settings.difficulty_mods().get("player_damage", 1.0))
	var reload_mult: float = float(mods.get("reload_mult", 1.0))
	for p in paths:
		if ResourceLoader.exists(p):
			var res := load(p)
			if res is WeaponData:
				var w := (res as WeaponData).duplicate() as WeaponData
				w.damage *= dmg_mult
				w.reload_time = maxf(0.1, w.reload_time * reload_mult)
				_apply_perks(w)         # permanent per-weapon perks (never lost)
				_apply_attachments(w)   # at-risk equipped attachments (lost on death)
				_apply_mastery(w)       # passive "veteran" ramp from weapon mastery level
				_weapons.append(w)
	# Initialise ammo/reserve for every loaded weapon (full mag + full reserve).
	for w in _weapons:
		_ammo[w.id] = w.mag_size
		_reserve[w.id] = w.reserve_max
	if _index >= _weapons.size():
		_index = 0

## Apply this weapon's PERMANENT perks (Gunsmith-bought, never lost) to the dup'd data.
func _apply_perks(w: WeaponData) -> void:
	var perks: Dictionary = MetaProgression.weapon_perks.get(w.id, {})
	for key in perks:
		var info: Dictionary = MetaProgression.WEAPON_PERKS.get(key, {})
		if info.is_empty():
			continue
		var lvl: int = int(perks[key])
		var eff: float = float(info.get("effect", 0.0)) * lvl
		match String(info.get("field", "")):
			"damage": w.damage *= (1.0 + eff)
			"recoil": w.recoil = maxf(0.0, w.recoil * (1.0 - eff))
			"reload": w.reload_time = maxf(0.1, w.reload_time * (1.0 - eff))
			"mag":    w.mag_size = maxi(1, w.mag_size + int(eff))

## Apply the per-weapon MASTERY ramp (per-peer LOCAL): the more you use a gun, the better
## it handles — a small recoil/spread/reload reduction scaling with its mastery level. This
## is the passive counterpart to the bought perks (damage/mag). Multiplicative on the dup.
func _apply_mastery(w: WeaponData) -> void:
	var lvl: int = MetaProgression.weapon_mastery_level(w.id)
	if lvl <= 0:
		return
	w.recoil = maxf(0.0, w.recoil * (1.0 - Settings.WEAPON_MASTERY_RECOIL_PER * lvl))
	w.spread_deg = maxf(0.0, w.spread_deg * (1.0 - Settings.WEAPON_MASTERY_SPREAD_PER * lvl))
	w.reload_time = maxf(0.1, w.reload_time * (1.0 - Settings.WEAPON_MASTERY_RELOAD_PER * lvl))

## Apply this weapon's equipped AT-RISK attachments (committed from the stash at deploy)
## to the dup'd data. AttachmentData extends ItemData and lives in ItemCatalog.
func _apply_attachments(w: WeaponData) -> void:
	var slots: Dictionary = MetaProgression.get_equipped(w.id)
	for s in slots:
		var att := ItemCatalog.get_item(String(slots[s]))
		if att is AttachmentData:
			(att as AttachmentData).apply_to(w)

## Maps the MetaProgression loadout (weapon ids) to resource paths, keeping order.
## Falls back to the full WEAPON_PATHS arsenal when nothing resolves (offline tools,
## empty profile, or ids without a .tres).
func _loadout_paths() -> Array:
	var ids: Array = MetaProgression.get_loadout()
	var out: Array = []
	for id in ids:
		var p := "res://resources/weapons/%s.tres" % String(id)
		if ResourceLoader.exists(p):
			out.append(p)
	if out.is_empty():
		return WEAPON_PATHS.duplicate()
	return out

# --- Public API (used by the player/lead) -----------------------------------

## Enables/disables OWN input reading. Call set_enabled(true) for the local
## authority player only. When disabled the controller never switches/reloads
## from input; the player can still call try_fire() explicitly.
func set_enabled(b: bool) -> void:
	_enabled = b
	set_process_unhandled_input(b)

## Fires the current weapon if it has ammo and is not reloading/switching.
## Call this every frame the fire button is HELD — auto vs semi-auto is handled
## here (semi weapons fire once per press; auto weapons fire at fire_rate while
## held). Decrements the mag, auto-reloads when empty, emits ammo_changed.
## Returns true if a shot actually went out.
func try_fire(from_node: Node3D) -> bool:
	# Mark the trigger as held this instant so _process can detect release
	# (see _process: a short gap with no try_fire() call un-latches semi-auto).
	_since_fire_call = 0.0
	_tf_calls += 1
	if _weapon == null or from_node == null:
		_tf_fail = "weapon/from_node null"
		return false
	if _reloading or _switch_timer > 0.0 or _cooldown > 0.0:
		_tf_fail = "reload/switch/cooldown"
		return false
	var data := current_weapon()
	if data == null:
		_tf_fail = "no data"
		return false
	# Semi-auto: one shot per press. Stay latched until the trigger is released.
	if not data.auto and _semi_latched:
		_tf_fail = "semi-latched"
		return false
	if int(_ammo.get(data.id, 0)) <= 0:
		_tf_fail = "no ammo"
		_begin_reload()
		return false
	_tf_fail = "fired"
	# Effective spread folds in the owning player's stance/movement and ADS. Pass it
	# to the weapon (which resolves the shot server-authoritatively, so a co-op client
	# can't bypass it — the spread is applied where the authoritative dir is computed).
	if not _weapon.fire_with(from_node, data, _effective_spread(data)):
		return false
	_cooldown = 1.0 / maxf(0.1, data.fire_rate)
	_semi_latched = true
	_apply_fire_kick(data)   # punch the held view-model back/up (springs back in _process)
	_ammo[data.id] = int(_ammo[data.id]) - 1
	Events.ammo_changed.emit(int(_ammo[data.id]), int(_reserve.get(data.id, 0)))
	if int(_ammo[data.id]) <= 0:
		_begin_reload()
	return true

# --- View-model recoil kick (cosmetic; springs back so aim is unaffected) -----
const KICK_BACK := 0.06        # metres the gun punches toward the player per recoil unit
const KICK_UP := 0.02
const KICK_PITCH := 0.14       # radians the muzzle flips up
const KICK_ROLL := 0.09        # random roll for life
const KICK_SPRING := 15.0      # how fast the kick recovers to rest

var _kick_pos := Vector3.ZERO
var _kick_rot := Vector3.ZERO   # (pitch, 0, roll) offset from the rest pose
var _kick_base_pos := Vector3.ZERO
var _kick_base_rot := Vector3.ZERO
var _kick_have_base := false

## Adds a recoil impulse to the held view-model (scaled by the weapon's kick/recoil).
func _apply_fire_kick(data: WeaponData) -> void:
	if _model_holder == null:
		return
	if not _kick_have_base:
		_kick_base_pos = _model_holder.position
		_kick_base_rot = _model_holder.rotation
		_kick_have_base = true
	var k: float = data.kick_amount() if data != null else 1.0
	_kick_pos.z += KICK_BACK * k
	_kick_pos.y += KICK_UP * k
	_kick_rot.x += KICK_PITCH * k        # +x rotation = muzzle up (model faces -Z)
	_kick_rot.z += randf_range(-KICK_ROLL, KICK_ROLL) * k

## Springs the view-model kick back to rest each frame.
func _process_kick(delta: float) -> void:
	if not _kick_have_base or _model_holder == null:
		return
	var s := clampf(1.0 - KICK_SPRING * delta, 0.0, 1.0)
	_kick_pos *= s
	_kick_rot *= s
	_model_holder.position = _kick_base_pos + _kick_pos
	_model_holder.rotation = _kick_base_rot + _kick_rot

## The held view-model's "Muzzle"/"Eject" markers (under _model_holder, which is reparented to
## the player's WeaponMount but still referenced here). Combat FX read these so flash/smoke/shells
## leave the actual gun barrel. Null until a model with markers exists / is in the tree.
func muzzle_node() -> Node3D:
	if _model_holder != null:
		var m := _model_holder.find_child("Muzzle", true, false)
		if m is Node3D and (m as Node3D).is_inside_tree():
			return m as Node3D
	return null

func eject_node() -> Node3D:
	if _model_holder != null:
		var e := _model_holder.find_child("Eject", true, false)
		if e is Node3D and (e as Node3D).is_inside_tree():
			return e as Node3D
	return null

## Effective fire spread (degrees) for a given weapon, given the owning player's
## current stance/movement and ADS state. base × stance_mult × (ADS ? SPREAD_MULT_ADS : 1).
func _effective_spread(data: WeaponData) -> float:
	if data == null:
		return 0.0
	var s: float = data.spread_deg * _stance_mult()
	if _ads:
		s *= Settings.SPREAD_MULT_ADS
	return maxf(0.0, s)

## Live effective spread (degrees) for the EQUIPPED weapon — base × stance × ADS.
## Read by the dynamic crosshair so the reticle shows the real shot cone. Returns a
## small default when no weapon is loaded so the crosshair never reads garbage.
func current_spread_deg() -> float:
	var d := current_weapon()
	if d == null:
		return 1.0
	return _effective_spread(d)

## Per-weapon zoomed FOV (read by the camera when aiming).
func current_ads_fov() -> float:
	var d := current_weapon()
	return d.ads_fov if d else Settings.ADS_FOV

## Logical id of the equipped weapon ("rifle"/"shotgun"/... ); "" if none loaded.
func current_weapon_id() -> String:
	var d := current_weapon()
	return d.id if d else ""

func current_weapon() -> WeaponData:
	if _index >= 0 and _index < _weapons.size():
		return _weapons[_index]
	return null

## Recoil magnitude of the current weapon (optional read for camera kick).
func current_recoil() -> float:
	var d := current_weapon()
	return d.recoil if d else 0.0

## Tops every loaded weapon back up to a full mag + full reserve. Used by the
## self-play harness ("refill") for sustained playtests; also a clean hook for a
## future ammo-resupply pickup.
func refill_ammo() -> void:
	for w in _weapons:
		_ammo[w.id] = w.mag_size
		_reserve[w.id] = w.reserve_max
	_reloading = false
	_reload_timer = 0.0
	var d := current_weapon()
	if d:
		Events.ammo_changed.emit(int(_ammo.get(d.id, 0)), int(_reserve.get(d.id, 0)))

# --- Input (own, gated by _enabled) -----------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _enabled:
		return
	if event.is_action_pressed("weapon_next"):
		_switch_to(_index + 1)
	elif event.is_action_pressed("weapon_prev"):
		_switch_to(_index - 1)
	elif event.is_action_pressed("reload"):
		_begin_reload()
	else:
		for i in 5:
			if event.is_action_pressed("weapon_%d" % (i + 1)):
				_switch_to(i)
				break

func _process(delta: float) -> void:
	_process_kick(delta)
	if _cooldown > 0.0:
		_cooldown -= delta
	# If try_fire() hasn't been called for a short window, the trigger was released
	# — clear the semi-auto latch so the next press can fire again. The threshold is
	# generous enough to survive a missed frame yet far below any human re-tap.
	_since_fire_call += delta
	if _since_fire_call > 0.08:
		_semi_latched = false
	if _switch_timer > 0.0:
		_switch_timer -= delta
	if _reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()

# --- Switching --------------------------------------------------------------

func _switch_to(new_index: int) -> void:
	if _weapons.is_empty():
		return
	var wrapped := wrapi(new_index, 0, _weapons.size())
	if wrapped == _index:
		return
	_index = wrapped
	_reloading = false           # cancel any in-progress reload on switch
	_reload_timer = 0.0
	_switch_timer = Settings.WEAPON_SWITCH_TIME
	# Don't inherit the previous weapon's fire cooldown / semi latch — a slow weapon
	# (DMR/shotgun) would otherwise gate the new fast weapon's first shot.
	if _weapon and "_cooldown" in _weapon:
		_weapon._cooldown = 0.0
	_semi_latched = false
	_refresh_model()
	_emit_switched()

func _emit_switched() -> void:
	var d := current_weapon()
	if d == null:
		return
	Events.weapon_switched.emit(d.id, int(_ammo.get(d.id, 0)), int(_reserve.get(d.id, 0)))

## Swaps the visible weapon model under ModelHolder via AssetRegistry.
func _refresh_model() -> void:
	if _model_holder == null:
		return
	for c in _model_holder.get_children():
		c.queue_free()
	var d := current_weapon()
	if d == null:
		return
	if AssetRegistry.has_id(d.id):
		var model := AssetRegistry.get_model(d.id)
		if model:
			_model_holder.add_child(model)
	# Guarantee a Muzzle/Eject anchor on the held model so combat FX leave the gun barrel even
	# for non-procedural (.glb) weapons. Procedural builders already add their own (at the real
	# barrel tip); only add defaults when none exist (in the unscaled holder space).
	if _model_holder.find_child("Muzzle", true, false) == null:
		var muz := Marker3D.new()
		muz.name = "Muzzle"
		muz.position = Vector3(0, 0.02, -0.42)
		_model_holder.add_child(muz)
	if _model_holder.find_child("Eject", true, false) == null:
		var ej := Marker3D.new()
		ej.name = "Eject"
		ej.position = Vector3(0.05, 0.05, -0.02)
		_model_holder.add_child(ej)

# --- Reloading --------------------------------------------------------------

func _begin_reload() -> void:
	if _reloading:
		return
	var d := current_weapon()
	if d == null:
		return
	var cur := int(_ammo.get(d.id, 0))
	var spare := int(_reserve.get(d.id, 0))
	if cur >= d.mag_size or spare <= 0:
		return
	_reloading = true
	_reload_timer = d.reload_time
	Events.reload_started.emit(d.id)

func _finish_reload() -> void:
	_reloading = false
	_reload_timer = 0.0
	var d := current_weapon()
	if d == null:
		return
	var cur := int(_ammo.get(d.id, 0))
	var spare := int(_reserve.get(d.id, 0))
	var need := d.mag_size - cur
	var take := mini(need, spare)
	_ammo[d.id] = cur + take
	_reserve[d.id] = spare - take
	Events.reload_finished.emit(d.id)
	Events.ammo_changed.emit(int(_ammo[d.id]), int(_reserve[d.id]))
