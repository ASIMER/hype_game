extends Node3D
class_name Explosion
## A one-shot grenade explosion: a bright OmniLight3D flash, an expanding
## additive shockwave ring, a fireball spark burst and a lingering smoke puff.
## Auto-frees after LIFETIME. Purely visual/local — never networked (each peer
## spawns its own on Events.grenade_exploded / the grenade detonating locally).

const LIFETIME := 1.4
const FLASH_TIME := 0.18
const SHOCK_TIME := 0.4
const SHOCK_MAX_SCALE := 6.0

var _t := 0.0
var _light: OmniLight3D
var _shock: MeshInstance3D
var _shock_mat: StandardMaterial3D


func _ready() -> void:
	# Big bright flash.
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.7, 0.35)
	_light.light_energy = 12.0
	_light.omni_range = 12.0
	_light.shadow_enabled = false
	add_child(_light)

	# Expanding additive shockwave — a billboarded ring/disc that scales out.
	var disc := QuadMesh.new()
	disc.size = Vector2(1.0, 1.0)
	_shock = MeshInstance3D.new()
	_shock.mesh = disc
	_shock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shock_mat = StandardMaterial3D.new()
	_shock_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shock_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shock_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_shock_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_shock_mat.albedo_color = Color(1.0, 0.75, 0.4, 1.0)
	_shock.material_override = _shock_mat
	add_child(_shock)

	_spawn_fireball()
	_spawn_smoke()


func _spawn_fireball() -> void:
	var p := GPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 40
	p.lifetime = 0.5
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 12.0
	pm.gravity = Vector3(0, -8.0, 0)
	pm.scale_min = 0.6
	pm.scale_max = 1.6
	pm.color = Color(1.0, 0.6, 0.2)
	p.process_material = pm
	var dot := SphereMesh.new()
	dot.radius = 0.06
	dot.height = 0.12
	dot.radial_segments = 6
	dot.rings = 3
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.albedo_color = Color(1.0, 0.6, 0.2)
	dot.material = dm
	p.draw_pass_1 = dot
	add_child(p)
	p.emitting = true


func _spawn_smoke() -> void:
	var p := GPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.6
	p.amount = 24
	p.lifetime = 1.2
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 90.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.0
	pm.gravity = Vector3(0, 1.0, 0)
	pm.scale_min = 2.0
	pm.scale_max = 4.5
	pm.color = Color(0.12, 0.11, 0.1, 0.7)
	p.process_material = pm
	var puff := SphereMesh.new()
	puff.radius = 0.1
	puff.height = 0.2
	puff.radial_segments = 6
	puff.rings = 3
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.albedo_color = Color(0.12, 0.11, 0.1, 0.7)
	puff.material = puff_mat
	p.draw_pass_1 = puff
	add_child(p)
	p.emitting = true


func _process(delta: float) -> void:
	_t += delta
	# Flash decays fast.
	if _light:
		var lk := clampf(_t / FLASH_TIME, 0.0, 1.0)
		_light.light_energy = lerpf(12.0, 0.0, lk)
	# Shockwave expands and fades over SHOCK_TIME.
	if _shock and _shock_mat:
		var sk := clampf(_t / SHOCK_TIME, 0.0, 1.0)
		var s := lerpf(0.5, SHOCK_MAX_SCALE, sk)
		_shock.scale = Vector3(s, s, s)
		_shock_mat.albedo_color.a = 1.0 - sk
		if sk >= 1.0:
			_shock.visible = false
	if _t >= LIFETIME:
		queue_free()
