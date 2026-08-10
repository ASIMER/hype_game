extends Node
## DIEGETIC world-event markers (the panels' unanimous #1 readability fix: «босс
## появился, а я не понимаю что это»): every mid-raid world event gets a COLORED
## LIGHT PILLAR at its position — the extraction-beacon language reused for events,
## so "something is happening THERE" reads across the map without any UI text.
## Pure render, per-peer, zero netcode: listens to the Events bus (kind, pos, label)
## and builds/frees local visuals under the current scene. Instanced by main.gd
## next to the other persistent overlays.

# kind → signal color (matches the map/minimap legend hues).
const EVENT_COLORS := {
	0: Color(0.95, 0.75, 0.25),  # supply cache — amber
	1: Color(0.95, 0.30, 0.95),  # mini-boss — magenta
	2: Color(0.30, 0.80, 0.95),  # contested POI — cyan
	3: Color(1.0, 0.45, 0.10),  # surge — orange
	4: Color(1.0, 0.35, 0.35),  # siege — red
}
const PILLAR_H := 34.0
const RING_R := 3.2

var _beacons: Dictionary = {}  # kind -> Node3D


func _ready() -> void:
	Events.world_event_started.connect(_on_started)
	Events.world_event_ended.connect(_on_ended)
	Events.match_started.connect(_clear_all)


func _on_started(kind: int, world_pos: Vector3, _label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	_on_ended(kind, false)  # replace a stale beacon of the same kind
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var col: Color = EVENT_COLORS.get(kind, Color(1.0, 0.8, 0.3))
	var root := Node3D.new()
	root.name = "EventBeacon%d" % kind
	scene.add_child(root)
	root.global_position = world_pos
	_build_pillar(root, col)
	_beacons[kind] = root


func _on_ended(kind: int, _success: bool) -> void:
	var b: Variant = _beacons.get(kind)
	if b is Node3D and is_instance_valid(b):
		(b as Node3D).queue_free()
	_beacons.erase(kind)


func _clear_all() -> void:
	for k in _beacons.keys():
		_on_ended(int(k), false)


## The pillar: a tall additive beam + a slow-pulsing ground ring + an OmniLight —
## the extraction-beacon visual language in the EVENT's color.
func _build_pillar(root: Node3D, col: Color) -> void:
	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.55
	cyl.bottom_radius = 1.1
	cyl.height = PILLAR_H
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	bm.albedo_color = Color(col.r, col.g, col.b, 0.16)
	bm.emission_enabled = true
	bm.emission = col
	bm.emission_energy_multiplier = 1.6
	cyl.material = bm
	beam.mesh = cyl
	beam.position = Vector3(0, PILLAR_H * 0.5, 0)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(beam)

	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = RING_R - 0.25
	tor.outer_radius = RING_R
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	rm.albedo_color = Color(col.r, col.g, col.b, 0.8)
	tor.material = rm
	ring.mesh = tor
	ring.position = Vector3(0, 0.25, 0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	var tw := ring.create_tween().set_loops()
	tw.tween_property(ring, "scale", Vector3(1.35, 1.0, 1.35), 1.1)
	tw.parallel().tween_property(ring, "transparency", 0.75, 1.1)
	tw.tween_property(ring, "scale", Vector3.ONE, 0.0)
	tw.parallel().tween_property(ring, "transparency", 0.0, 0.0)

	var light := OmniLight3D.new()
	light.light_color = col
	light.light_energy = 2.4
	light.omni_range = 14.0
	light.position = Vector3(0, 3.0, 0)
	light.shadow_enabled = false
	root.add_child(light)
