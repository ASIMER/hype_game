extends StaticBody3D
class_name BreakableChunk
## A breakable building wall SEGMENT (built by ProceduralBuildings._solid(breakable=true) for
## window piers/sills/headers + blank-wall bodies). Solid on layer 1 until its HP is shot away,
## then it CRUMBLES locally — collision off, the intact box hidden, a rubble pile + dust burst
## left in its place. The wall LOOKS identical until you destroy it (no voxelization; the authored
## triplanar box is untouched). Mirrors BreakableGlass's INDEX-keyed replication: wall roots are
## anonymous (paths differ per peer), so each chunk carries a deterministic `index`
## (ProceduralBuildings._chunk_seq, reset by arena before each build) + a static registry. A shot
## routes server HP through NetworkManager.request_damage_chunk(index, dmg); the SERVER tracks HP
## and broadcasts the crumble → every peer crumbles the same segment. Per-build only (a restart
## rebuilds all walls intact). HP lives ONLY on the server's node (clients just crumble on the
## broadcast) → server-authoritative. Render/runtime only → golden byte-identical.

const NOISE_LOUDNESS := 14.0

var index: int = -1
var broken: bool = false
var hp: float = 120.0  # server-authoritative; set from Settings.CHUNK_HP by the builder
var chunk_size: Vector3 = Vector3.ONE  # the segment box size (rubble scales to it)
var chunk_color: Color = Color(0.5, 0.5, 0.5)  # the wall material colour (rubble tint)

static var _registry: Dictionary = {}


func _ready() -> void:
	add_to_group(Groups.BREAKABLE_CHUNK)
	_registry[index] = self


func _exit_tree() -> void:
	if _registry.get(index) == self:
		_registry.erase(index)


static func by_index(idx: int) -> BreakableChunk:
	var c: Variant = _registry.get(idx)
	return c if (c is BreakableChunk and is_instance_valid(c)) else null


## SERVER-side: subtract `dmg` from HP; returns true when this shot DEPLETES it (the caller
## then broadcasts the crumble). No-op once broken.
func server_take_damage(dmg: float) -> bool:
	if broken:
		return false
	hp -= dmg
	return hp <= 0.0


## SERVER-side helper: crumble every unbroken chunk within `radius` of `center` (grenade blasts
## route here with lethal damage so the segment goes down in one blast).
static func break_in_radius(center: Vector3, radius: float) -> void:
	for c in _registry.values():
		if c is BreakableChunk and is_instance_valid(c) and not c.broken:
			if c.global_position.distance_to(center) <= radius:
				NetworkManager.request_damage_chunk(c.index, 1e9)


## Runs on EVERY peer (post-replication). Idempotent: collision off (deferred — may land
## mid-physics-step), the intact box hidden, FALLING physics debris + a dust burst left behind.
## `hit_normal` points OUT of the broken face toward the shooter so the shards spray the right way
## (Vector3.ZERO = a radial grenade blast). The debris is local/visual only — never networked.
func crumble(hit_normal: Vector3 = Vector3.ZERO) -> void:
	if broken:
		return
	broken = true
	var col := get_node_or_null("CollisionShape3D")
	if col != null:
		col.set_deferred("disabled", true)
	var mesh := get_node_or_null("Mesh")
	if mesh != null:
		(mesh as MeshInstance3D).visible = false
	# Falling rigid-body shards (the "обломки падают" fix) + a dust puff at the broken cell.
	ChunkDebris.burst(self, global_position, chunk_color, chunk_size, hit_normal, index)
	_spawn_dust()
	Events.chunk_broken.emit(self)


## A dust burst at the broken cell (the fallen debris is now real falling RigidBody shards via
## ChunkDebris). Render-only; skipped on headless. Deterministic enough — purely cosmetic.
func _spawn_dust() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var pile := Node3D.new()
	pile.name = "Dust"
	add_child(pile)
	var w: float = maxf(0.3, chunk_size.x)
	var d: float = maxf(0.3, chunk_size.z)
	var p := GPUParticles3D.new()
	p.amount = 20
	p.lifetime = 1.0
	p.one_shot = true
	p.explosiveness = 0.8
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(w * 0.5, chunk_size.y * 0.4, d * 0.5)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 60.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 2.5
	pm.gravity = Vector3(0, -2.0, 0)
	pm.scale_min = 0.3
	pm.scale_max = 0.8
	pm.color = chunk_color.lightened(0.1)
	p.process_material = pm
	var dmesh := BoxMesh.new()
	dmesh.size = Vector3(0.12, 0.12, 0.12)
	var dmat := StandardMaterial3D.new()
	dmat.albedo_color = chunk_color
	dmesh.material = dmat
	p.draw_pass_1 = dmesh
	pile.add_child(p)
	p.emitting = true


## QA summary (kept here so any harness verb stays thin under AgentBridge's line ceiling).
static func debug_summary() -> Dictionary:
	var total: int = 0
	var broken_n: int = 0
	for c in _registry.values():
		if c is BreakableChunk and is_instance_valid(c):
			total += 1
			if c.broken:
				broken_n += 1
	return {"ok": true, "total": total, "broken": broken_n}


## QA helper: nearest unbroken chunk index to `pos`, or -1.
static func nearest_unbroken(pos: Vector3) -> int:
	var best: int = -1
	var best_d: float = 1e9
	for c in _registry.values():
		if c is BreakableChunk and is_instance_valid(c) and not c.broken:
			var dd: float = c.global_position.distance_to(pos)
			if dd < best_d:
				best_d = dd
				best = c.index
	return best
