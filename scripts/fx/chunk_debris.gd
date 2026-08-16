extends Node3D
class_name ChunkDebris
## A one-shot FALLING physics burst spawned when a BreakableChunk crumbles. Several RigidBody3D
## shards (in the wall's colour) fly outward — biased toward the shot side + up — then FALL under
## gravity, tumble, settle, fade, and the whole node frees after LIFETIME. This is the fix for the
## "обломки висят и не падают" complaint: the old _spawn_rubble left STATIC boxes hanging; these are
## real rigid bodies that drop to the floor/ground.
##
## Purely LOCAL/VISUAL — never networked. crumble() already runs on every peer (server-authoritative
## index broadcast), so each peer spawns its own shards; they never cross the wire and can't desync.
## Shards are collision_layer = 0 / mask = 1 (collide with WORLD only) so they fall onto floors/ground
## but never shove players/enemies and never sit on the nav-bake layer. A global concurrent cap keeps
## a "снёс полздания" demolition from spawning hundreds of bodies at once.

const _GRAVITY_SCALE := 1.3
const _MASS := 0.5

# Global live-shard counter so map-wide demolition stays bounded (RigidBody is the expensive bit).
static var _active: int = 0

var _t: float = 0.0
var _spawned: int = 0  # shards this node owns (subtracted from _active on free)
var _mats: Array[StandardMaterial3D] = []
# Crush bookkeeping: each enemy takes damage from THIS burst at most once (shards
# bounce and re-contact; one collapse should hurt once, not machine-gun).
var _crushed: Dictionary = {}
var _life_scale: float = 0.0  # 0 = not sampled yet (see _life_mult)


## Spawn a falling-debris burst at `world_pos` under `host`. `color` tints the shards, `cell` is the
## crumbled cell's box size (shards scale to it), `hit_normal` points OUT of the surface toward the
## shooter (Vector3.ZERO = a radial grenade blast). `sid` seeds a little variation. Render-only:
## skipped on headless (a dedicated server has no camera and shouldn't simulate cosmetic bodies).
static func burst(
	host: Node,
	world_pos: Vector3,
	color: Color,
	cell: Vector3,
	hit_normal: Vector3,
	sid: int,
	kind: int = 0
) -> void:
	if host == null or not is_instance_valid(host):
		return
	if not Settings.CHUNK_DEBRIS_ENABLED or DisplayServer.get_name() == "headless":
		return
	var kd: Dictionary = Settings.CHUNK_KIND_DEFS.get(kind, {})
	var want: int = int(round(Settings.CHUNK_DEBRIS_PER_CELL * float(kd.get("debris_mult", 1.0))))
	var room: int = Settings.CHUNK_DEBRIS_CAP - _active
	var n: int = clampi(mini(want, room), 0, want)
	if n <= 0:
		return
	var node := ChunkDebris.new()
	node._spawned = n
	_active += n
	host.add_child(node)
	node.global_position = world_pos
	node._build(n, color, cell, hit_normal, sid, kd)
	# A COLLAPSE deserves a dust column. One cell breaking is a puff and the shards say it;
	# a burst big enough to be a demolition (the cap-limited count is the honest measure of
	# "how much came down") also lifts a slow plume, which is what sells the weight.
	if n >= Settings.CHUNK_DEBRIS_PER_CELL:
		node._add_dust(color, span_of(cell))


## Longest edge of a cell — the burst's rough "size" for scaling the dust column.
static func span_of(cell: Vector3) -> float:
	return clampf(maxf(maxf(cell.x, cell.y), cell.z), 0.4, 3.0)


## A slow, wide, MIX-blended plume that outlives the shards. Not additive: dust lit from
## behind by a bright sky must OCCLUDE, or a collapse reads as a white flash.
func _add_dust(color: Color, span: float) -> void:
	var p := GPUParticles3D.new()
	p.amount = 16
	p.lifetime = 2.6
	p.one_shot = true
	p.explosiveness = 0.75
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = span * 0.6
	pm.direction = Vector3.UP
	pm.spread = 32.0
	pm.initial_velocity_min = 0.4
	pm.initial_velocity_max = 1.6
	pm.gravity = Vector3(0.0, 0.5, 0.0)
	pm.scale_min = span * 0.8
	pm.scale_max = span * 2.1
	pm.color = color.lightened(0.35)
	p.process_material = pm
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.6, 0.6)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	sm.albedo_color = Color(color.lightened(0.35), 0.5)
	mesh.material = sm
	p.draw_pass_1 = mesh
	add_child(p)
	p.emitting = true


func _build(
	n: int, color: Color, cell: Vector3, hit_normal: Vector3, sid: int, kd: Dictionary
) -> void:
	var flat: float = float(kd.get("shard_flat", 0.72))
	var szmul: float = float(kd.get("shard_size", 1.0))
	var span: float = span_of(cell)
	# Burst axis: away from the surface (toward the shooter) + a strong upward bias so shards arc up
	# then fall. A zero normal (grenade) just bursts straight up and scatters radially.
	var up := Vector3.UP
	var out: Vector3 = (hit_normal + up * 1.2) if hit_normal != Vector3.ZERO else up
	out = out.normalized()
	for i in n:
		var s: int = absi(sid) * 131 + i * 17 + 7
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var rx: float = float(s % 1000) / 1000.0
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var ry: float = float(s % 1000) / 1000.0
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var rz: float = float(s % 1000) / 1000.0
		s = (s * 1103515245 + 12345) & 0x7fffffff
		var rsz: float = float(s % 1000) / 1000.0
		var sx: float = (0.18 + rsz * 0.34) * clampf(span * 0.6, 0.5, 1.6) * szmul
		var body := RigidBody3D.new()
		body.gravity_scale = _GRAVITY_SCALE
		body.mass = _MASS
		body.can_sleep = true
		body.continuous_cd = false
		body.collision_layer = 0  # nothing collides INTO the shards
		body.collision_mask = 1  # shards collide with WORLD only (floors/ground/walls)
		# CRUSH ("разрушение-как-оружие"): on the SERVER, shards also collide with
		# enemy bodies (layer 4) and report contacts — a wall dropped on a machine
		# hurts it. Clients keep world-only shards (damage is server-authoritative).
		if Settings.DEBRIS_CRUSH_ENABLED and GameState.is_local_authority_server():
			body.collision_mask = 1 | 4
			body.contact_monitor = true
			body.max_contacts_reported = 3
			body.body_entered.connect(_on_shard_contact.bind(body))
		var box := BoxMesh.new()
		box.size = Vector3(sx, sx * flat, sx)  # metal = flat panels, stone = chunky, concrete = mid
		var mat := StandardMaterial3D.new()
		# Lighten (not darken) so shards read against the dark cinematic grade; faint emission helps.
		mat.albedo_color = color.lightened(float(kd.get("tint_lighten", 0.15)))
		mat.metallic = float(kd.get("metallic", 0.2))
		mat.roughness = float(kd.get("roughness", 0.92))
		mat.emission_enabled = true
		mat.emission = color.lightened(0.3)
		mat.emission_energy_multiplier = 0.35
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		box.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(mi)
		var shape := BoxShape3D.new()
		shape.size = box.size
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		# Scatter the start point across the broken cell face so the burst reads as the whole cell.
		body.position = Vector3((rx - 0.5) * cell.x, (ry - 0.3) * cell.y, (rz - 0.5) * cell.z)
		add_child(body)
		# Fling along the burst axis with per-shard jitter, then real gravity drops them.
		var jitter := Vector3(rx - 0.5, ry * 0.5, rz - 0.5)
		var dir: Vector3 = (out + jitter * 0.9).normalized()
		var power: float = 2.2 + rsz * 3.4
		body.apply_impulse(dir * power)
		body.angular_velocity = Vector3(rx - 0.5, ry - 0.5, rz - 0.5) * 14.0
		_mats.append(mat)


## SERVER: a shard slammed into something — enemies get crush damage scaled by
## impact speed, once per enemy per burst (Hurtbox.apply_hit, the shot-damage site).
func _on_shard_contact(other: Node, body: RigidBody3D) -> void:
	if other == null or not is_instance_valid(body):
		return
	if not other.is_in_group(Groups.ENEMIES):
		return
	var eid: int = other.get_instance_id()
	if _crushed.has(eid):
		return
	var speed: float = body.linear_velocity.length()
	if speed < 2.0:
		return
	_crushed[eid] = true
	var dmg: float = clampf(speed * 2.5, 3.0, Settings.DEBRIS_CRUSH_DMG_MAX)
	var hb := other.get_node_or_null(Groups.NODE_HURTBOX)
	if hb != null and hb.has_method("apply_hit"):
		hb.apply_hit(dmg, body)


## D4.6: debris LIVES LONGER UP CLOSE. One global lifetime has to be short enough for the
## worst case (a whole facade coming down across the map), which means the rubble at your
## feet — the only rubble you actually look at — evaporates while you are still standing in
## it. Distance decides instead: near bursts get the full dwell, far ones clear fast. The
## multiplier is sampled ONCE, so a burst never changes its mind halfway through fading.
const _NEAR_LIFE_DIST := 22.0
const _NEAR_LIFE_MULT := 2.4


func _life_mult() -> float:
	if _life_scale > 0.0:
		return _life_scale
	_life_scale = 1.0
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		var d: float = cam.global_position.distance_to(global_position)
		_life_scale = lerpf(_NEAR_LIFE_MULT, 1.0, clampf(d / _NEAR_LIFE_DIST, 0.0, 1.0))
	return _life_scale


func _process(delta: float) -> void:
	_t += delta
	var k: float = _life_mult()
	var fade: float = Settings.CHUNK_DEBRIS_FADE * k
	var life: float = Settings.CHUNK_DEBRIS_LIFETIME * k
	if _t >= fade:
		var a: float = 1.0 - clampf((_t - fade) / maxf(0.1, life - fade), 0.0, 1.0)
		for mat in _mats:
			if mat != null:
				mat.albedo_color.a = a
	if _t >= life:
		queue_free()


func _exit_tree() -> void:
	_active = maxi(0, _active - _spawned)
