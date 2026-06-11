class_name TracerPool
extends Node3D
## Pooled ballistic-arc tracers: ONE MultiMeshInstance3D + ONE shader material for
## every tracer segment in the match (PERF). The old per-segment Tracer nodes spent
## ~32 node instantiations + 32 unique StandardMaterial3Ds PER SHOT on every peer —
## a 4-player firefight churned hundreds of nodes/materials per second. Here a shot
## writes its arc segments into a ring buffer of MultiMesh instances; fading and
## reclaim happen ON THE GPU (the shader collapses expired instances), so the only
## per-frame CPU work is a single `u_now` uniform write.
##
## Instanced once per raid by main.load_arena (non-headless), like RemoteShotFX.
## Purely visual + per-peer local; `static var active` is the call-site handle for
## weapon.gd (local shots) and remote_shot_fx.gd (teammates' shots).

const CAPACITY := 2048  # ring slots; ~17x the worst-case live count (4p sustained fire)
const LIFETIME := 0.09  # must match u_lifetime in shaders/tracer.gdshader

static var active: TracerPool = null

var _mm: MultiMesh
var _mat: ShaderMaterial
var _head: int = 0
var _clock: float = 0.0  # pool-owned fade clock (uniform u_now); pause-safe by design


func _enter_tree() -> void:
	active = self


func _exit_tree() -> void:
	if active == self:
		active = null


func _ready() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.022
	cyl.bottom_radius = 0.022
	cyl.height = 1.0
	cyl.radial_segments = 6
	cyl.rings = 0
	_mm.mesh = cyl
	_mm.instance_count = CAPACITY
	# Park every slot as a degenerate transform far below the world until used.
	var parked := Transform3D(Basis().scaled(Vector3(0.001, 0.001, 0.001)), Vector3(0, -500, 0))
	for i in range(CAPACITY):
		_mm.set_instance_transform(i, parked)
		_mm.set_instance_custom_data(i, Color(-1000.0, 0, 0, 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# CRITICAL: a fixed world-sized AABB — instances scatter across the whole map and
	# per-write AABB recomputation (or a stale tight AABB) would cost CPU / cull wrong.
	mmi.custom_aabb = AABB(
		Vector3(WorldBounds.X_MIN - 10.0, -510.0, WorldBounds.Z_MIN - 10.0),
		Vector3(WorldBounds.SPAN + 20.0, 600.0, WorldBounds.SPAN + 20.0)
	)
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/tracer.gdshader")
	mmi.material_override = _mat
	add_child(mmi)


func _process(delta: float) -> void:
	_clock += delta
	_mat.set_shader_parameter("u_now", _clock)


## Write one shot's arc into the ring: one stretched-cylinder instance per segment.
## `points[0]` is replaced by `muzzle` so the streak leaves the actual barrel —
## exactly the anchoring the per-node path used. Same orthonormal-basis math as the
## legacy Tracer._rebuild (basis +Y along the segment, scaled to its length).
func spawn_arc(points: PackedVector3Array, muzzle: Vector3) -> void:
	if points.size() < 2:
		return
	for i in range(points.size() - 1):
		var a: Vector3 = muzzle if i == 0 else points[i]
		var b: Vector3 = points[i + 1]
		var dir := b - a
		var dist := dir.length()
		if dist < 0.0001:
			continue
		var up := dir / dist
		var arbitrary := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD
		var x := arbitrary.cross(up).normalized()
		var z := x.cross(up).normalized()
		var basis := Basis(x, up, z).scaled(Vector3(1.0, dist, 1.0))
		_mm.set_instance_transform(_head, Transform3D(basis, (a + b) * 0.5))
		_mm.set_instance_custom_data(_head, Color(_clock, 0, 0, 0))
		_head = (_head + 1) % CAPACITY
