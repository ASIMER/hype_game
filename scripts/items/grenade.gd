extends RigidBody3D
class_name Grenade
## A thrown fragmentation grenade. A small RigidBody that bounces off the world,
## then after a fuse detonates: spawns an explosion FX (light flash + particles),
## emits Events.grenade_exploded, and — on the authority server only — applies
## radial damage with distance falloff to every node in group "enemies" within
## radius, then frees itself.
##
## SPAWN/THROW API (used by the lead to wire the `grenade` input):
##   var g = load("res://scenes/items/Grenade.tscn").instantiate()
##   world.add_child(g)
##   g.throw(from_world_pos, dir_normalized, Settings.GRENADE_THROW_FORCE)
## throw() positions, launches, and arms with Settings.GRENADE_FUSE. Or call
## arm(thrower, fuse) directly if you place + push the body yourself.
##
## SUBCLASSING: the fuse/arming/bounce logic lives here; the detonation PAYLOAD
## is the virtual `_detonate_effect(pos)` (frag = radial damage + FX + noise).
## Smoke/EMP/decoy override it. By default the grenade frees itself after the
## effect runs; an override that keeps the body alive (decoy beacon) sets
## `_keep_after_detonate = true`.

const _EXPLOSION_SCENE := "res://scenes/fx/Explosion.tscn"

var grenade_type: String = "frag"

var _thrower: Node = null
var _fuse := 1.6
var _armed := false
var _t := 0.0
var _exploded := false
# Subclasses that turn the grenade into a persistent node (decoy) set this so
# _explode skips the trailing queue_free and leaves it running.
var _keep_after_detonate := false


func _ready() -> void:
	# Bounce a little, settle reasonably. Collide with the world only so the
	# grenade doesn't get hung up on players/enemies.
	collision_layer = 0
	collision_mask = 1
	gravity_scale = 1.0
	mass = 0.5
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.35
	pm.friction = 0.8
	physics_material_override = pm
	contact_monitor = false
	can_sleep = true


## Position at `from`, launch along `dir` with `force`, and start the fuse.
## All-in-one entry point for the thrower.
func throw(from: Vector3, dir: Vector3, force: float) -> void:
	global_position = from
	var d := dir.normalized() if dir.length() > 0.0001 else Vector3.FORWARD
	# Add a touch of lift so grenades arc rather than skid along the floor.
	linear_velocity = d * force + Vector3.UP * (force * 0.18)
	angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
	arm(null, Settings.GRENADE_FUSE)


## Start the fuse. After `fuse` seconds the grenade explodes. Safe to call once.
func arm(thrower: Node, fuse: float) -> void:
	_thrower = thrower
	_fuse = maxf(0.05, fuse)
	_armed = true
	_t = 0.0


func _process(delta: float) -> void:
	if not _armed or _exploded:
		return
	_t += delta
	if _t >= _fuse:
		_explode()


func _explode() -> void:
	if _exploded:
		return
	_exploded = true
	var pos := global_position
	_detonate_effect(pos)
	# Most grenades are spent on detonation; a persistent beacon (decoy) keeps
	# itself alive by setting _keep_after_detonate inside _detonate_effect.
	if not _keep_after_detonate:
		queue_free()


## The detonation PAYLOAD — overridden per grenade type. Runs on EVERY peer (the
## grenade is spawned everywhere); split your server-only work behind
## GameState.is_local_authority_server() exactly like the frag default below.
## Frag default: local explosion FX + a broadcast event + server-only radial
## damage and an AI-audible noise report.
func _detonate_effect(pos: Vector3) -> void:
	var host := _fx_host()

	# Visual explosion (local on every peer).
	if host and ResourceLoader.exists(_EXPLOSION_SCENE):
		var fx = load(_EXPLOSION_SCENE).instantiate()
		if fx:
			host.add_child(fx)
			if fx is Node3D:
				(fx as Node3D).global_position = pos

	# Broadcast for audio / screenshake / other listeners.
	Events.grenade_exploded.emit(pos, Settings.GRENADE_DAMAGE, Settings.GRENADE_RADIUS)

	# Authoritative radial damage — server only, so clients don't double-apply.
	if GameState.is_local_authority_server():
		_apply_radial_damage(pos, Settings.GRENADE_DAMAGE, Settings.GRENADE_RADIUS)
		# Grenade explosion is AI-audible; _detonate_effect runs under the
		# server-auth gate here so report_noise emits directly (no RPC needed).
		NetworkManager.report_noise(pos, Settings.NOISE_GRENADE, 2)
		# Blast shatters every window pane + crumbles every wall segment in radius.
		BreakableGlass.break_in_radius(pos, Settings.GRENADE_RADIUS)
		BreakableChunk.break_in_radius(pos, Settings.GRENADE_RADIUS)


## Damage every "enemies" node within `radius`, scaled by distance falloff
## (full at the centre, ~25% at the edge). Best-effort + null-safe.
func _apply_radial_damage(center: Vector3, damage: float, radius: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	for e in tree.get_nodes_in_group(Groups.ENEMIES):
		if e == null or not (e is Node3D):
			continue
		var dist := (e as Node3D).global_position.distance_to(center)
		if dist > radius:
			continue
		var health := e.get_node_or_null(Groups.NODE_HEALTH)
		if health == null or not health.has_method("take_damage"):
			continue
		# Linear falloff from 1.0 at centre to 0.25 at the rim.
		var falloff := lerpf(1.0, 0.25, clampf(dist / radius, 0.0, 1.0))
		var dmg := damage * falloff
		# Machine Nemesis "blast_hard" learned counter shrugs off explosives (duck-typed; a
		# non-nemesis returns dmg unchanged). Source stays _thrower → kill-attribution intact.
		if e.has_method("filter_blast"):
			dmg = e.filter_blast(dmg)
		health.take_damage(dmg, _thrower)


## Where to parent the explosion FX so it lives in the world, not under us
## (we're about to free). Falls back to the current scene.
func _fx_host() -> Node:
	var tree := get_tree()
	if tree and tree.current_scene:
		return tree.current_scene
	return get_parent()
