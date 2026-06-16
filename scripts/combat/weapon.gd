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
## Emitted alongside `fired` carrying the ballistic arc points (muzzle → hit) so
## the VFX can draw a tracer that FOLLOWS the curve instead of a straight line.
signal fired_arc(arc_points: PackedVector3Array, hit_node: Node)

# Hard cap on ballistic raycast segments so a long-range shot stays cheap.
const _MAX_BALLISTIC_SEGMENTS := 40

@export var weapon_id: String = "rifle"
@export var damage: float = 12.0
@export var fire_rate: float = 8.0  # shots per second
@export var max_range: float = 80.0
@export var auto: bool = true  # held-to-fire
@export var hurtbox_mask: int = 0b1000101  # layers: world(1) + enemy(3) + hurtbox(7)

var _cooldown: float = 0.0
# Surface normal of the most recent resolved hit (Vector3.ZERO = none). Set in
# _shoot right before `fired` is emitted; read synchronously in _on_fired to
# orient the impact burst to the surface. Per-pellet, single-threaded — safe.
var _last_hit_normal: Vector3 = Vector3.ZERO

# --- VFX (purely visual/local, never networked) -----------------------------
# Preloaded combat feedback scenes. Spawned from our own `fired` signal so the
# hitscan logic above stays untouched. All spawns are null-safe and cheap.
const _MUZZLE_FLASH_SCENE := "res://scenes/fx/MuzzleFlash.tscn"
const _TRACER_SCENE := "res://scenes/fx/Tracer.tscn"
const _IMPACT_SCENE := "res://scenes/fx/Impact.tscn"
const _MUZZLE_SMOKE_SCRIPT := "res://scripts/fx/muzzle_smoke.gd"
const _SHELL_CASINGS_SCRIPT := "res://scripts/fx/shell_casings.gd"

var _muzzle_flash_ps: PackedScene
var _tracer_ps: PackedScene
var _impact_ps: PackedScene
var _muzzle_smoke_script: GDScript
var _shell_script: GDScript
## Last WeaponData fired through fire_with — drives the per-class muzzle FX scale / shell count.
var _last_data: WeaponData = null


func _ready() -> void:
	if ResourceLoader.exists(_MUZZLE_FLASH_SCENE):
		_muzzle_flash_ps = load(_MUZZLE_FLASH_SCENE)
	if ResourceLoader.exists(_TRACER_SCENE):
		_tracer_ps = load(_TRACER_SCENE)
	if ResourceLoader.exists(_IMPACT_SCENE):
		_impact_ps = load(_IMPACT_SCENE)
	if ResourceLoader.exists(_MUZZLE_SMOKE_SCRIPT):
		_muzzle_smoke_script = load(_MUZZLE_SMOKE_SCRIPT)
	if ResourceLoader.exists(_SHELL_CASINGS_SCRIPT):
		_shell_script = load(_SHELL_CASINGS_SCRIPT)
	if not fired.is_connected(_on_fired):
		fired.connect(_on_fired)
	if not fired_arc.is_connected(_on_fired_arc):
		fired_arc.connect(_on_fired_arc)


func _process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta


## Legacy single-weapon fire using this node's exported damage/fire_rate/range.
## from_node supplies the muzzle ray (usually the Camera3D). Returns true if it fired.
func try_fire(from_node: Node3D) -> bool:
	if _cooldown > 0.0:
		return false
	_cooldown = 1.0 / maxf(0.1, fire_rate)
	_shoot(from_node, weapon_id, damage, max_range, 0.0, 1.0, false, 0.0)
	return true


## Data-driven fire used by WeaponController. Fires `data.pellets` converged rays
## (with per-ray spread), each emitting fired/hit/Events.weapon_fired so VFX and
## audio react per pellet exactly like try_fire. Damage numbers are emitted for
## hits on entities in group "enemies". The caller owns the cooldown/ammo — this
## method does NOT gate on _cooldown so a controller can manage rate-of-fire, but
## it does refresh _cooldown for compatibility with anything polling this node.
## `eff_spread` (degrees, < 0 = "use the weapon's own spread_deg") is the
## controller-computed effective cone (base × stance/movement × ADS). It is applied
## HERE, on the authoritative shot-resolution path inside _shoot, so co-op clients
## can't bypass stance/ADS spread. The shotgun pellet loop uses the SAME eff_spread
## per pellet.
func fire_with(from_node: Node3D, data: WeaponData, eff_spread: float = -1.0) -> bool:
	if from_node == null or data == null:
		return false
	_last_data = data
	_cooldown = 1.0 / maxf(0.1, data.fire_rate)
	var pellets: int = maxi(1, data.pellets)
	# Optional per-weapon muzzle velocity override (flatter trajectory for rifles,
	# droopier for slow projectile weapons). 0 / absent -> Settings default.
	var muzzle_v: float = 0.0
	if "muzzle_velocity" in data:
		muzzle_v = float(data.muzzle_velocity)
	var spread: float = data.spread_deg if eff_spread < 0.0 else eff_spread
	for i in pellets:
		_shoot(from_node, data.id, data.damage, data.range, spread, data.crit_mult, true, muzzle_v)
	# Report gunfire noise ONCE per shot (not per pellet) so the AI hears it.
	# report_noise routes to the server on clients, so no is_server guard needed.
	var nm: float = data.noise_mult if "noise_mult" in data else 1.0
	NetworkManager.report_noise(_muzzle_position(), Settings.NOISE_GUNFIRE * nm, 1)
	return true


## One converged hitscan ray (chest-origin toward the crosshair aim point) with
## optional spread. Applies damage to any Hurtbox hit and emits the per-shot
## signals. `emit_numbers` gates the floating damage number (legacy path off).
func _shoot(
	from_node: Node3D,
	wid: String,
	dmg: float,
	rng: float,
	spread_deg: float,
	crit_mult: float,
	emit_numbers: bool,
	data_muzzle_velocity: float
) -> void:
	var space := from_node.get_world_3d().direct_space_state
	var shooter := _find_owner_body()

	# Exclude the shooter AND its own Hurtbox from every query — the camera sits
	# behind the player, so the player's body/hurtbox is between muzzle and target.
	var exclude: Array[RID] = []
	if shooter:
		exclude.append(shooter.get_rid())
		var own_hb := shooter.get_node_or_null(Groups.NODE_HURTBOX)
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

	# Stepped BALLISTIC raycast: instead of one straight instant ray, march a
	# projectile from `origin` along `dir` at muzzle velocity `v`, with gravity
	# pulling -Y. Each BULLET_STEP-long segment is a short intersect_ray along the
	# curved path; the first segment that hits resolves the hurtbox/world exactly
	# like a hitscan did. Damage stays applied right here (server-authoritative).
	var v: float = _muzzle_velocity(data_muzzle_velocity)
	var grav := Vector3(0.0, -Settings.BULLET_GRAVITY, 0.0)
	var vel := dir * v
	var pos := origin

	# Build the arc points as we go so the tracer can follow the curve. Always
	# starts at the muzzle origin; subsequent points are the marched positions.
	var arc := PackedVector3Array()
	arc.append(origin)

	# Cap the number of segments for performance; the arc length is bounded by rng.
	var seg_count: int = clampi(
		int(ceil(rng / maxf(0.1, Settings.BULLET_STEP))), 1, _MAX_BALLISTIC_SEGMENTS
	)
	var dt: float = Settings.BULLET_STEP / maxf(0.1, v)  # time per segment at muzzle speed

	var hit_point := origin
	var hit_node: Node = null
	var resolved := false
	var travelled := 0.0
	_last_hit_normal = Vector3.ZERO

	for i in seg_count:
		# Advance the projectile one ballistic segment (simple Euler integration).
		var next_vel := vel + grav * dt
		var next_pos := pos + vel * dt
		var seg := next_pos - pos
		var seg_len := seg.length()
		if seg_len < 0.0001:
			break
		# Don't overshoot the weapon's max range on the final partial segment.
		if travelled + seg_len > rng:
			var allow := rng - travelled
			next_pos = pos + seg.normalized() * allow
			seg = next_pos - pos
			seg_len = allow

		var params := PhysicsRayQueryParameters3D.create(pos, next_pos)
		params.collision_mask = hurtbox_mask
		params.collide_with_areas = true
		params.collide_with_bodies = true
		params.exclude = exclude
		var result := space.intersect_ray(params)
		if result:
			hit_point = result["position"]
			hit_node = result["collider"]
			_last_hit_normal = result.get("normal", Vector3.ZERO)
			arc.append(hit_point)
			resolved = true
			break

		pos = next_pos
		vel = next_vel
		travelled += seg_len
		arc.append(pos)
		if travelled >= rng:
			break

	if not resolved:
		hit_point = arc[arc.size() - 1]

	if hit_node != null:
		var hb := _resolve_hurtbox(hit_node)
		if hb:
			# A weak-point hurtbox carries damage_multiplier > 1 (e.g. headshot).
			var is_crit := hb.damage_multiplier > 1.0 and crit_mult > 1.0
			var dealt := dmg
			if is_crit:
				dealt *= crit_mult
			# Active power-cache damage buff (Berserk / Frenzy) on the firing player.
			if shooter != null and shooter.has_method("buff_damage_mult"):
				dealt *= float(shooter.buff_damage_mult())
			# Mutant-Harvest limb DAMAGE passive (melee/ranged limbs + set bonus) on the shooter.
			if shooter != null:
				var sk: Node = shooter.get_node_or_null("Skills")
				if sk != null and sk.has_method("passive_damage_mult"):
					dealt *= float(sk.passive_damage_mult())
			# Server-authoritative damage: the host applies directly; a CLIENT routes
			# the hit to the server (its local apply_hit would only damage its OWN copy
			# of the enemy, never the authoritative one → the enemy never dies in co-op).
			if GameState.is_local_authority_server():
				hb.apply_hit(dealt, shooter)
			else:
				NetworkManager.request_hit(hb.get_path(), dealt, _shooter_peer(shooter))
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
			# Lifesteal buff: heal the shooter for a fraction of damage dealt to an enemy.
			if shooter != null and shooter.has_method("on_dealt_damage") and _is_enemy(hit_node):
				shooter.on_dealt_damage(dealt * hb.damage_multiplier)
		elif hit_node is BreakableGlass:
			# Window pane: the bullet correctly STOPS on this (breaking) shot — the
			# impact FX already targets the pane point; the server shatters + replicates.
			NetworkManager.request_break_glass((hit_node as BreakableGlass).index)
	fired_arc.emit(arc, hit_node)
	fired.emit(hit_point, hit_node)
	Events.weapon_fired.emit(shooter, wid)
	# Co-op: let teammates SEE this shot. Our own FX already spawned via the `fired`
	# signal above; broadcast the shot so the OTHER peers spawn the tracer/impact too.
	NetworkManager.broadcast_shot(
		_muzzle_position(), hit_point, arc, _is_enemy(hit_node), _last_hit_normal
	)


## Muzzle velocity for the ballistic march: a weapon may override the Settings
## default by exposing a positive `muzzle_velocity` on its WeaponData.
func _muzzle_velocity(override_v: float) -> float:
	if override_v > 0.0:
		return override_v
	return Settings.BULLET_MUZZLE_VELOCITY


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
	var mscale: float = float(_last_data.muzzle_scale) if _last_data != null else 1.0

	# All per-shot FX go through the FXPool when one exists (PERF: zero node/material
	# churn under fire); the legacy instantiate path stays as the fallback.
	var mf := FXPool.acquire_or_new("muzzle_flash", _muzzle_flash_ps, host)
	if mf != null:
		if mf is Node3D:
			(mf as Node3D).global_position = muzzle
		if mf.has_method("set_intensity"):
			mf.call("set_intensity", mscale)
		if mf.has_method("fire"):
			mf.call("fire")

	# Muzzle smoke puff drifting up off the barrel (builds a light haze on sustained fire).
	var sm := FXPool.acquire_or_new("muzzle_smoke", _muzzle_smoke_script, host)
	if sm != null:
		if sm is Node3D:
			(sm as Node3D).global_position = muzzle
		if sm.has_method("set_scale_mult"):
			sm.call("set_scale_mult", mscale)
		if sm.has_method("fire"):
			sm.call("fire")

	# Shell casing ejection from the side port (skip the tube-fed shotgun's per-shot brass).
	if _last_data == null or _last_data.id != "shotgun":
		var sc := FXPool.acquire_or_new("shells", _shell_script, host)
		if sc != null:
			if sc is Node3D:
				(sc as Node3D).global_transform = _eject_transform()
			if sc.has_method("fire"):
				sc.call("fire")

	# Tracer is drawn by _on_fired_arc (which follows the ballistic curve). We only
	# spawn the impact burst here. (fired_arc always fires alongside fired.)

	var im := FXPool.acquire_or_new("impact", _impact_ps, host)
	if im != null:
		if im is Impact:
			(im as Impact).set_enemy_hit(_is_enemy(hit_node))
			# Orient the burst to the surface normal if we can resolve one.
			(im as Impact).set_surface_normal(_last_hit_normal)
		if im is Node3D:
			(im as Node3D).global_position = hit_point
		if im.has_method("fire"):
			im.call("fire")


## Draws the tracer as a chain of short straight Tracer segments through the arc
## points so the visible streak follows the ballistic curve. Reuses the existing
## Tracer scene (one per segment) — kept cheap by the capped segment count. The
## first arc point is the muzzle, so the segment chain starts exactly at the barrel.
func _on_fired_arc(arc_points: PackedVector3Array, _hit_node: Node) -> void:
	if arc_points.size() < 2:
		return
	# PERF: the pooled MultiMesh draws the whole arc with ONE material and zero node
	# churn (the old path made ~32 nodes + 32 unique materials per shot).
	if TracerPool.active != null:
		TracerPool.active.spawn_arc(arc_points, _muzzle_position())
		return
	if _tracer_ps == null:
		return
	var host := _fx_host()
	if host == null:
		return
	# Anchor the first segment at the real muzzle so the streak leaves the barrel.
	var muzzle := _muzzle_position()
	for i in range(arc_points.size() - 1):
		var a: Vector3 = muzzle if i == 0 else arc_points[i]
		var b: Vector3 = arc_points[i + 1]
		var tr := _tracer_ps.instantiate()
		if tr is Tracer:
			(tr as Tracer).setup(a, b)
		host.add_child(tr)


## World-space muzzle point. PREFER the held view-model's "Muzzle" marker (so flash/smoke/
## tracer leave the actual gun barrel in 3rd person), then the camera-anchored "Muzzle"
## Marker3D, then the weapon node itself.
func _muzzle_position() -> Vector3:
	var vm := _view_marker("Muzzle")
	if vm != null:
		return vm.global_position
	var marker := get_node_or_null("Muzzle")
	if marker is Node3D:
		return (marker as Node3D).global_position
	return global_position


## World transform of the shell ejection port (view-model "Eject" marker), else a muzzle-
## offset fallback. Used to orient the brass casings flying out the side.
func _eject_transform() -> Transform3D:
	var ej := _view_marker("Eject")
	if ej != null and ej.is_inside_tree():
		return ej.global_transform
	return Transform3D(Basis.IDENTITY, _muzzle_position())


## The held view-model's "Muzzle"/"Eject" marker, via the owning WeaponController (which holds
## the authoritative model-holder reference, surviving the reparent to WeaponMount). Null →
## the caller uses the camera-anchored fallback.
func _view_marker(mark_name: String) -> Node3D:
	var ctrl := get_parent()
	if ctrl == null:
		return null
	if mark_name == "Muzzle" and ctrl.has_method("muzzle_node"):
		return ctrl.muzzle_node()
	if mark_name == "Eject" and ctrl.has_method("eject_node"):
		return ctrl.eject_node()
	return null


## Where to parent FX so they live in the world, not under the moving camera.
func _fx_host() -> Node:
	var tree := get_tree()
	if tree and tree.current_scene:
		return tree.current_scene
	return get_parent()


func _is_enemy(node: Node) -> bool:
	var n := node
	while n != null:
		if n.is_in_group(Groups.ENEMIES):
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
		var child := node.get_node_or_null(Groups.NODE_HURTBOX)
		if child is Hurtbox:
			return child
	return null


## Peer id that owns the shooter body (the player node is named str(peer_id)).
func _shooter_peer(shooter: Node) -> int:
	if shooter == null:
		return 1
	var pid := str(shooter.name).to_int()
	return pid if pid > 0 else 1


func _find_owner_body() -> Node3D:
	var n := get_parent()
	while n != null:
		if n is CharacterBody3D or n is RigidBody3D:
			return n
		n = n.get_parent()
	return null
