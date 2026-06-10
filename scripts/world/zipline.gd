extends Node3D
## Zipline — a single traversable cable between two world-space anchors.
##
## Built procedurally in `setup()` (a stretched cable mesh, two end poles, and one
## mount Area3D per end). A LOCAL player overlapping an end gets a "Ride zipline [E]"
## interaction; pressing "interact" hands control to the player via the contract
## `player.begin_zipline(self, from, to)` and we drive the rider along the cable in
## `_physics_process`.
##
## Authority model: only the rider whose `is_multiplayer_authority()` is true is moved
## here (its `:position` replicates to other peers). We set both `global_position`
## (the ride path) and `velocity` (feeds the animator/noise) each physics frame.
##
## Collision: each end Area3D is layer 0 / mask 2 (player). NO layer-1 anywhere, so
## ziplines never affect the navmesh bake or the golden world checksum.

const LAYER_PLAYER := 1 << 1  # 3d_physics layer_2 "player"

## Cable endpoints in world space (set in `setup`).
var _a: Vector3 = Vector3.ZERO
var _b: Vector3 = Vector3.ZERO
var _length: float = 0.0

## Per-end mount areas, in {a, b} order, so we know which end a player entered at.
var _area_a: Area3D = null
var _area_b: Area3D = null

## Local players currently overlapping each end (kept per-end so the ride direction
## starts from the end they are standing at).
var _at_a: Array[Node] = []
var _at_b: Array[Node] = []

## Active ride state.
var _rider: Node = null
var _ride_from: Vector3 = Vector3.ZERO
var _ride_to: Vector3 = Vector3.ZERO
var _t: float = 0.0
var _prev_jump_held: bool = false  # edge-detect the harness "jump" hold


## Builds the cable + poles + mount areas between two world-space anchors.
## Called by zipline_network.gd right after instancing.
func setup(a: Vector3, b: Vector3) -> void:
	_a = a
	_b = b
	_length = a.distance_to(b)
	if _length < 0.001:
		return

	_build_cable()
	_build_pole(_a)
	_build_pole(_b)
	_area_a = _build_end_area(_a)
	_area_b = _build_end_area(_b)


# ─── procedural visuals ───────────────────────────────────────────────────────


func _build_cable() -> void:
	# A thin box stretched from a to b. BoxMesh's local axis is arbitrary, so we orient
	# its local +Y down the cable and size Y to the cable length.
	var cable := MeshInstance3D.new()
	cable.name = "Cable"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.06, _length, 0.06)
	cable.mesh = mesh
	cable.material_override = _dark_mat()

	var mid: Vector3 = (_a + _b) * 0.5
	# Orient local +Y (the long axis) toward b. look_at points -Z at the target, so we
	# rotate the basis a quarter-turn so +Y ends up along the cable direction. LOCAL
	# transform on purpose: the node isn't in the tree yet (global_* would error), and
	# this Zipline root sits at the origin so local == world here.
	var dir: Vector3 = (_b - _a).normalized()
	var up: Vector3 = Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.RIGHT  # avoid a degenerate basis on a vertical cable
	var basis := Basis.looking_at(dir, up)
	cable.transform = Transform3D(basis * Basis(Vector3.RIGHT, PI * 0.5), mid)
	add_child(cable)


func _build_pole(at: Vector3) -> void:
	var pole := MeshInstance3D.new()
	pole.name = "Pole"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.18
	mesh.bottom_radius = 0.26
	mesh.height = 3.0
	mesh.radial_segments = 10
	pole.mesh = mesh
	pole.material_override = _dark_mat()
	# Drop the pole so its top sits roughly at the anchor (the cable attach point).
	# LOCAL position (pre-tree; this root sits at the origin so local == world).
	pole.position = at - Vector3.UP * 1.5
	add_child(pole)


func _build_end_area(at: Vector3) -> Area3D:
	var area := Area3D.new()
	area.name = "End"
	area.collision_layer = 0
	area.collision_mask = LAYER_PLAYER
	area.monitoring = true
	area.position = at  # LOCAL (pre-tree; root at origin so local == world)

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = Settings.ZIPLINE_END_RADIUS
	shape.shape = sphere
	area.add_child(shape)
	add_child(area)

	area.body_entered.connect(_on_end_entered.bind(area))
	area.body_exited.connect(_on_end_exited.bind(area))
	return area


func _dark_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.06, 0.06, 0.07)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


# ─── interaction tracking ─────────────────────────────────────────────────────


func _on_end_entered(body: Node, area: Area3D) -> void:
	if body == null or not body.is_in_group(Groups.PLAYERS):
		return
	if not _is_local(body):
		return
	var bucket: Array[Node] = _bucket_for(area)
	if not bucket.has(body):
		bucket.append(body)
	Events.interaction_available.emit(tr("Ride zipline [E]"), self)


func _on_end_exited(body: Node, area: Area3D) -> void:
	if body == null:
		return
	_bucket_for(area).erase(body)
	if _at_a.is_empty() and _at_b.is_empty():
		Events.interaction_cleared.emit()


func _bucket_for(area: Area3D) -> Array[Node]:
	return _at_a if area == _area_a else _at_b


func _is_local(body: Node) -> bool:
	# Local in single-player (no peer) or when this peer owns the player.
	if not multiplayer.has_multiplayer_peer():
		return true
	return body.get_multiplayer_authority() == multiplayer.get_unique_id()


# ─── mount on interact ────────────────────────────────────────────────────────


func _unhandled_input(event: InputEvent) -> void:
	if _rider != null:
		return
	if not event.is_action_pressed("interact"):
		return
	_mount_nearest_local()


## Harness path: AgentBridge `hold interact` can't synthesize an InputEvent (the same
## limitation the loot `pickup` cmd works around), so poll its held flag with an edge.
## The singleton is resolved defensively — during scene teardown autoloads die before
## world nodes, and a direct `AgentBridge.x` access then spams Nil errors every frame.
var _prev_interact_held: bool = false


func _poll_harness_mount() -> void:
	if _rider != null:
		return
	var bridge: Node = get_node_or_null("/root/AgentBridge")
	if bridge == null or not bool(bridge.get("active")):
		return
	var held: bool = bool(bridge.call("held", "interact"))
	var edge: bool = held and not _prev_interact_held
	_prev_interact_held = held
	if edge:
		_mount_nearest_local()


## Prefer whichever end a local player is standing at; ride toward the far end.
func _mount_nearest_local() -> void:
	var at_a_player: Node = _first_local(_at_a)
	if at_a_player != null:
		_try_mount(at_a_player, _a, _b)
		return
	var at_b_player: Node = _first_local(_at_b)
	if at_b_player != null:
		_try_mount(at_b_player, _b, _a)


func _first_local(bucket: Array[Node]) -> Node:
	for p in bucket:
		if is_instance_valid(p) and _is_local(p):
			return p
	return null


func _try_mount(player: Node, from_pos: Vector3, to_pos: Vector3) -> void:
	if not player.has_method("begin_zipline"):
		return
	var ok: bool = player.begin_zipline(self, from_pos, to_pos)
	if not ok:
		return
	_rider = player
	_ride_from = from_pos
	_ride_to = to_pos
	_t = 0.0
	_prev_jump_held = false
	Events.interaction_cleared.emit()
	Events.zipline_ride_started.emit(player, self)


# ─── ride update ──────────────────────────────────────────────────────────────


func _physics_process(delta: float) -> void:
	if _rider == null:
		_poll_harness_mount()
		return
	# Release safely if the rider vanished or went down mid-ride.
	if not is_instance_valid(_rider) or _is_rider_downed():
		_release(false)
		return
	# Only the authority drives the body; its :position replicates to other peers.
	if not _rider.is_multiplayer_authority():
		return

	var span: float = maxf(_length, 0.001)
	_t += (Settings.ZIPLINE_SPEED / span) * delta

	var dir: Vector3 = (_ride_to - _ride_from).normalized()
	if _rider is Node3D:
		var pos: Vector3 = _ride_from.lerp(_ride_to, clampf(_t, 0.0, 1.0))
		(_rider as Node3D).global_position = pos - Vector3.UP * Settings.ZIPLINE_HANG
	if _rider.get("velocity") != null:
		_rider.set("velocity", dir * Settings.ZIPLINE_SPEED)

	if _t >= 1.0:
		_release(false)
		return
	if _jump_pressed_edge():
		_release(true)


## Edge-detects a jump from either the real Input action or the harness hold flag.
func _jump_pressed_edge() -> bool:
	if Input.is_action_just_pressed("jump"):
		_prev_jump_held = true  # keep the harness edge in sync so it doesn't double-fire
		return true
	var harness_held: bool = AgentBridge.active and AgentBridge.held("jump")
	var edge: bool = harness_held and not _prev_jump_held
	_prev_jump_held = harness_held
	return edge


func _is_rider_downed() -> bool:
	return _rider.has_method("is_downed") and _rider.is_downed()


func _release(jump: bool) -> void:
	var rider: Node = _rider
	_rider = null
	_t = 0.0
	if rider != null and is_instance_valid(rider) and rider.has_method("end_zipline"):
		rider.end_zipline(jump)
