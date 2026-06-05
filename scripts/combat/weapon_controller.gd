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

func _ready() -> void:
	_weapon = get_node_or_null("Weapon") as Weapon
	_model_holder = get_node_or_null("ModelHolder") as Node3D
	if _model_holder == null:
		_model_holder = Node3D.new()
		_model_holder.name = "ModelHolder"
		add_child(_model_holder)
	_load_weapons()
	_refresh_model()
	# Broadcast the starting weapon + ammo so the HUD shows it immediately.
	_emit_switched()

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
	if _weapon == null or from_node == null:
		return false
	if _reloading or _switch_timer > 0.0 or _cooldown > 0.0:
		return false
	var data := current_weapon()
	if data == null:
		return false
	# Semi-auto: one shot per press. Stay latched until the trigger is released.
	if not data.auto and _semi_latched:
		return false
	if int(_ammo.get(data.id, 0)) <= 0:
		_begin_reload()
		return false
	if not _weapon.fire_with(from_node, data):
		return false
	_cooldown = 1.0 / maxf(0.1, data.fire_rate)
	_semi_latched = true
	_ammo[data.id] = int(_ammo[data.id]) - 1
	Events.ammo_changed.emit(int(_ammo[data.id]), int(_reserve.get(data.id, 0)))
	if int(_ammo[data.id]) <= 0:
		_begin_reload()
	return true

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
