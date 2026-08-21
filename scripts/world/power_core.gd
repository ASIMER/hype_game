class_name PowerCore
extends Node3D
## The Power-Core Beacon's VISUAL (Phase 4) — a glowing reactor core a boss/miniboss drops
## that the squad must physically carry to extract. It is NOT a networked node: the
## PowerCoreDirector owns the authoritative state (active / world position / carrier peer)
## and syncs it on change; EACH peer builds ONE of these LOCALLY and the director positions
## it every frame (on the ground, or following the carrier). Joins Groups.POWER_CORE so the
## map/minimap draw a marker. Render-only, headless-skipped by the director.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

var _pulse: float = 0.0
var _core: MeshInstance3D = null
var _light: OmniLight3D = null


## Build the glowing core (a bright emissive sphere on a small base + an OmniLight). Static
## so the director can `PowerCore.make()` one per peer. No collision (pickup is a server-side
## distance check), no physics — purely cosmetic.
static func make() -> PowerCore:
	var pc := PowerCore.new()
	pc.add_to_group(Groups.POWER_CORE)
	pc._build()
	return pc


func _build() -> void:
	_core = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.32
	mesh.height = 0.64
	mesh.radial_segments = 16
	mesh.rings = 8
	_core.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.62, 0.18)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.12)
	mat.emission_energy_multiplier = 4.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core.material_override = mat
	_core.position = Vector3(0.0, 0.9, 0.0)
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_core)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.6, 0.2)
	_light.omni_range = 6.0
	_light.light_energy = 2.0
	_light.position = Vector3(0.0, 0.9, 0.0)
	add_child(_light)


func _process(delta: float) -> void:
	# Bob + pulse so it reads as a live, valuable thing on the ground.
	_pulse += delta
	if _core != null:
		_core.position.y = 0.9 + sin(_pulse * 2.0) * 0.08
		_core.rotation.y = _pulse * 1.2
	if _light != null:
		_light.light_energy = 1.6 + 0.6 * (0.5 + 0.5 * sin(_pulse * 3.0))
