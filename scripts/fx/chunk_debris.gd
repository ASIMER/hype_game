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


func _build(
	n: int, color: Color, cell: Vector3, hit_normal: Vector3, sid: int, kd: Dictionary
) -> void:
	var flat: float = float(kd.get("shard_flat", 0.72))
	var szmul: float = float(kd.get("shard_size", 1.0))
	var span: float = clampf(maxf(maxf(cell.x, cell.y), cell.z), 0.4, 3.0)
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


func _process(delta: float) -> void:
	_t += delta
	var fade: float = Settings.CHUNK_DEBRIS_FADE
	var life: float = Settings.CHUNK_DEBRIS_LIFETIME
	if _t >= fade:
		var a: float = 1.0 - clampf((_t - fade) / maxf(0.1, life - fade), 0.0, 1.0)
		for mat in _mats:
			if mat != null:
				mat.albedo_color.a = a
	if _t >= life:
		queue_free()


func _exit_tree() -> void:
	_active = maxi(0, _active - _spawned)
