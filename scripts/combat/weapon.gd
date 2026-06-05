extends Node3D
class_name Weapon
## Hitscan weapon. Lives under the player's camera/muzzle. Fires a ray from the
## given origin/direction, finds a Hurtbox, and applies damage. Designed so the
## player controller just calls try_fire(camera) each frame the fire button is held.
##
## CONTRACT (depended on by player + combat-feedback workstreams):
##   func try_fire(from_node: Node3D) -> bool          # legacy single-weapon fire
##   func fire_with(from_node, data: WeaponData) -> bool  # data-driven, multi-weapon
##   signal fired(hit_point, hit_node) ; signal hit(target, amount)
##
## Both fire paths emit `fired`/`hit`/`Events.weapon_fired` PER SHOT (per pellet)
## so VFX (muzzle/tracer/impact) and audio keep working unchanged. fire_with()
## additionally emits Events.damage_number when it damages a "enemies" entity.

signal fired(hit_point: Vector3, hit_node: Node)
signal hit(target: Node, amount: float)

@export var weapon_id: String = "rifle"
@export var damage: float = 12.0
@export var fire_rate: float = 8.0          # shots per second
@export var max_range: float = 80.0
@export var auto: bool = true               # held-to-fire
@export var hurtbox_mask: int = 0b1000101   # layers: world(1) + enemy(3) + hurtbox(7)

var _cooldown: float = 0.0

# --- VFX (purely visual/local, never networked) -----------------------------
# Preloaded combat feedback scenes. Spawned from our own `fired` signal so the
# hitscan logic above stays untouched. All spawns are null-safe and cheap.
const _MUZZLE_FLASH_SCENE := "res://scenes/fx/MuzzleFlash.tscn"
const _TRACER_SCENE := "res://scenes/fx/Tracer.tscn"
const _IMPACT_SCENE := "res://scenes/fx/Impact.tscn"

var _muzzle_flash_ps: PackedScene
var _tracer_ps: PackedScene
var _impact_ps: PackedScene

func _ready() -> void:
	if ResourceLoader.exists(_MUZZLE_FLASH_SCENE):
		_muzzle_flash_ps = load(_MUZZLE_FLASH_SCENE)
	if ResourceLoader.exists(_TRACER_SCENE):
		_tracer_ps = load(_TRACER_SCENE)
	if ResourceLoader.exists(_IMPACT_SCENE):
		_impact_ps = load(_IMPACT_SCENE)
	if not fired.is_connected(_on_fired):
		fired.connect(_on_fired)

func _process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta

## Legacy single-weapon fire using this node's exported damage/fire_rate/range.
## from_node supplies the muzzle ray (usually the Camera3D). Returns true if it fired.
func try_fire(from_node: Node3D) -> bool:
	if _cooldown > 0.0:
		return false
	_cooldown = 1.0 / maxf(0.1, fire_rate)
	_shoot(from_node, weapon_id, damage, max_range, 0.0, 1.0, false)
	return true

## Data-driven fire used by WeaponController. Fires `data.pellets` converged rays
## (with per-ray spread), each emitting fired/hit/Events.weapon_fired so VFX and
## audio react per pellet exactly like try_fire. Damage numbers are emitted for
## hits on entities in group "enemies". The caller owns the cooldown/ammo — this
## method does NOT gate on _cooldown so a controller can manage rate-of-fire, but
## it does refresh _cooldown for compatibility with anything polling this node.
func fire_with(from_node: Node3D, data: WeaponData) -> bool:
	if from_node == null or data == null:
		return false
	_cooldown = 1.0 / maxf(0.1, data.fire_rate)
	var pellets: int = maxi(1, data.pellets)
	for i in pellets:
		_shoot(from_node, data.id, data.damage, data.range, data.spread_deg, data.crit_mult, true)
	return true

## One converged hitscan ray (chest-origin toward the crosshair aim point) with
## optional spread. Applies damage to any Hurtbox hit and emits the per-shot
## signals. `emit_numbers` gates the floating damage number (legacy path off).
func _shoot(from_node: Node3D, wid: String, dmg: float, rng: float, spread_deg: float, crit_mult: float, emit_numbers: bool) -> void:
	var space := from_node.get_world_3d().direct_space_state
	var shooter := _find_owner_body()

	# Exclude the shooter AND its own Hurtbox from every query — the camera sits
	# behind the player, so the player's body/hurtbox is between muzzle and target.
	var exclude: Array[RID] = []
	if shooter:
		exclude.append(shooter.get_rid())
		var own_hb := shooter.get_node_or_null("Hurtbox")
		if own_hb is CollisionObject3D:
			exclude.append((own_hb as CollisionObject3D).get_rid())

	# Step 1 — crosshair raycast from the CAMERA to find exactly what the player is
	# looking at (the aim point under the screen-center crosshair).
	var cam_origin := from_node.global_position
	var cam_dir := -from_node.global_transform.basis.z
	var aim_q := PhysicsRayQueryParameters3D.create(cam_origin, cam_origin + cam_dir * rng)
	aim_q.collision_mask = hurtbox_mask
	aim_q.collide_with_areas = true
	aim_q.collide_with_bodies = true
	aim_q.exclude = exclude
	var aim := space.intersect_ray(aim_q)
	var aim_point: Vector3 = aim["position"] if aim else cam_origin + cam_dir * rng

	# Step 2 — fire from the shooter's chest TOWARD that aim point, so bullets and
	# crosshair converge (chest origin avoids the spring-arm camera shooting the floor).
	var origin := cam_origin
	if shooter:
		origin = shooter.global_position + Vector3.UP * 1.4
	var dir := (aim_point - origin).normalized()
	if spread_deg > 0.0:
		dir = _apply_spread(dir, spread_deg)
	var params := PhysicsRayQueryParameters3D.create(origin, origin + dir * rng)
	params.collision_mask = hurtbox_mask
	params.collide_with_areas = true
	params.collide_with_bodies = true
	params.exclude = exclude
	var result := space.intersect_ray(params)

	var hit_point := origin + dir * rng
	var hit_node: Node = null
	if result:
		hit_point = result["position"]
		hit_node = result["collider"]
		var hb := _resolve_hurtbox(hit_node)
		if hb:
			# A weak-point hurtbox carries damage_multiplier > 1 (e.g. headshot).
			var is_crit := hb.damage_multiplier > 1.0 and crit_mult > 1.0
			var dealt := dmg
			if is_crit:
				dealt *= crit_mult
			hb.apply_hit(dealt, shooter)
			hit.emit(hb.get_parent(), dealt)
			# Crit juice: a punch of camera shake everywhere, plus a brief hit-stop in
			# single-player only (hit-stop scales Engine.time_scale, which would desync
			# the shared co-op simulation — gate it to offline).
			if is_crit:
				Events.screen_shake.emit(0.28)
				if NetworkManager.is_offline:
					Events.hit_stop.emit(0.05)
			if emit_numbers and _is_enemy(hit_node):
				# Report the damage actually applied (incl. the hurtbox's own multiplier).
				Events.damage_number.emit(hit_point, dealt * hb.damage_multiplier, is_crit)
	fired.emit(hit_point, hit_node)
	Events.weapon_fired.emit(shooter, wid)

## Rotates `dir` by a random offset within a cone of half-angle `spread_deg`.
func _apply_spread(dir: Vector3, spread_deg: float) -> Vector3:
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var right := dir.cross(up).normalized()
	up = right.cross(dir).normalized()
	var ang := deg_to_rad(spread_deg)
	var yaw := randf_range(-ang, ang)
	var pitch := randf_range(-ang, ang)
	return (dir + right * tan(yaw) + up * tan(pitch)).normalized()

# --- VFX spawning -----------------------------------------------------------

## Reacts to our own `fired` signal: muzzle flash at the barrel, a tracer from the
## muzzle to the hit point, and an impact burst at the hit point (sparks for
## enemies, dust for the world). Everything is best-effort and never blocks fire.
func _on_fired(hit_point: Vector3, hit_node: Node) -> void:
	var host := _fx_host()
	if host == null:
		return
	var muzzle := _muzzle_position()

	if _muzzle_flash_ps:
		var mf := _muzzle_flash_ps.instantiate()
		host.add_child(mf)
		if mf is Node3D:
			(mf as Node3D).global_position = muzzle

	if _tracer_ps:
		var tr := _tracer_ps.instantiate()
		if tr is Tracer:
			(tr as Tracer).setup(muzzle, hit_point)
		host.add_child(tr)

	if _impact_ps:
		var im := _impact_ps.instantiate()
		if im is Impact:
			(im as Impact).set_enemy_hit(_is_enemy(hit_node))
		host.add_child(im)
		if im is Node3D:
			(im as Node3D).global_position = hit_point

## World-space muzzle point. Prefer a sibling "Muzzle" Marker3D if the scene
## provides one; otherwise use the weapon node itself (sits on the camera).
func _muzzle_position() -> Vector3:
	var marker := get_node_or_null("Muzzle")
	if marker is Node3D:
		return (marker as Node3D).global_position
	return global_position

## Where to parent FX so they live in the world, not under the moving camera.
func _fx_host() -> Node:
	var tree := get_tree()
	if tree and tree.current_scene:
		return tree.current_scene
	return get_parent()

func _is_enemy(node: Node) -> bool:
	var n := node
	while n != null:
		if n.is_in_group("enemies"):
			return true
		n = n.get_parent()
	return false

func _resolve_hurtbox(node: Node) -> Hurtbox:
	# The collider may BE the hurtbox (area hit) or the body that OWNS it (the
	# hurtbox is a child of the enemy CharacterBody3D). Check self, ancestors, then
	# the body's "Hurtbox" child.
	var n := node
	while n != null:
		if n is Hurtbox:
			return n
		n = n.get_parent()
	if node:
		var child := node.get_node_or_null("Hurtbox")
		if child is Hurtbox:
			return child
	return null

func _find_owner_body() -> Node3D:
	var n := get_parent()
	while n != null:
		if n is CharacterBody3D or n is RigidBody3D:
			return n
		n = n.get_parent()
	return null
