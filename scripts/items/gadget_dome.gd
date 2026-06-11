extends GadgetBase
class_name GadgetDome
## Shield Dome: a placed bubble that halves damage to players standing inside it. The DAMAGE
## REDUCTION itself is applied by the player's damage filter (it walks Groups.DOMES and reads
## each dome's `global_position` + `radius`, then applies Settings.DOME_DAMAGE_MULT) — this
## script only joins the group, exposes those two fields, and renders the bubble.
##
## Render-only otherwise: a translucent unshaded hemisphere + a faint larger rim shell, gently
## pulsing. No collision at all (it must never affect navmesh or block shots).

# Read DUCK-TYPED by the player damage filter (global_position is inherited from Node3D).
var radius: float = Settings.DOME_RADIUS

const PULSE_SPEED := 2.0
const PULSE_AMP := 0.04  # ± fraction of the dome scale

var _shell: Node3D = null
var _pulse_t: float = 0.0


func _gadget_ready() -> void:
	_gadget_type = "gadget_dome"
	_lifetime = Settings.DOME_DURATION
	add_to_group(Groups.DOMES)
	# The emitter pod at the base (procedural model).
	var pod := ProceduralModels.build("gadget_dome")
	if pod != null:
		pod.name = "ModelRoot"
		add_child(pod)
	_build_bubble()


## Two stacked unshaded hemispheres: a denser inner skin + a fainter, slightly larger rim so
## the edge reads as a soft fresnel shell. Grouped under "Shell" for the pulse.
func _build_bubble() -> void:
	_shell = Node3D.new()
	_shell.name = "Shell"
	add_child(_shell)

	var col := Color(0.4, 0.75, 1.0)
	_add_hemi(_shell, radius, Color(col.r, col.g, col.b, 0.18))
	_add_hemi(_shell, radius * 1.04, Color(col.r, col.g, col.b, 0.08))


func _add_hemi(parent: Node3D, r: float, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = r
	mesh.height = r * 2.0
	mesh.is_hemisphere = true
	mesh.radial_segments = 24
	mesh.rings = 12
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = col
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from inside too
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


func _gadget_tick(delta: float) -> void:
	if _shell == null:
		return
	_pulse_t += delta
	var s := 1.0 + sin(_pulse_t * PULSE_SPEED) * PULSE_AMP
	_shell.scale = Vector3(s, s, s)
