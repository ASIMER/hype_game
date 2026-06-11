extends Grenade
class_name GrenadeDecoy
## Noise Decoy — on "detonation" it does NOT explode or free; it switches into a
## blinking beacon that periodically emits loud noise, pulling investigating
## robots toward it and away from the player. After DECOY_DURATION it shuts off
## and frees. The blink is local FX on every peer; the noise pulses are
## server-authoritative (report_noise self-gates, but we keep the whole pulse
## block behind the auth check so only the host drives the AI).

const _BLINK_HZ := 4.0  # visual pulse frequency of the beacon light/glow

var _active := false
var _life := 0.0
var _pulse_t := 0.0
var _light: OmniLight3D
var _glow_mat: StandardMaterial3D


func _init() -> void:
	grenade_type = "decoy"


func _detonate_effect(_pos: Vector3) -> void:
	# Persist as a beacon instead of being consumed.
	_keep_after_detonate = true
	_active = true
	_life = 0.0
	_pulse_t = Settings.DECOY_PULSE  # fire the first pulse immediately
	# Settle the body so the beacon sits still while chirping.
	freeze = true
	_build_beacon()


# A pulsing amber light + an emissive shell so the decoy is visible as a lure.
func _build_beacon() -> void:
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.75, 0.3)
	_light.light_energy = 4.0
	_light.omni_range = 6.0
	_light.shadow_enabled = false
	add_child(_light)

	var halo := SphereMesh.new()
	halo.radius = 0.2
	halo.height = 0.4
	halo.radial_segments = 12
	halo.rings = 6
	var glow := MeshInstance3D.new()
	glow.mesh = halo
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glow_mat = StandardMaterial3D.new()
	_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_glow_mat.albedo_color = Color(1.0, 0.8, 0.4, 0.8)
	glow.material_override = _glow_mat
	add_child(glow)


func _process(delta: float) -> void:
	# Keep the base fuse logic running until detonation flips us to beacon mode.
	if not _active:
		super._process(delta)
		return

	_life += delta
	# Blink the light/glow (render-only, every peer).
	var blink := 0.5 + 0.5 * sin(_life * TAU * _BLINK_HZ)
	if _light:
		_light.light_energy = lerpf(1.0, 5.0, blink)
	if _glow_mat:
		_glow_mat.albedo_color.a = lerpf(0.35, 0.85, blink)

	# Server-only: emit a loud lure pulse on the DECOY_PULSE cadence.
	if GameState.is_local_authority_server():
		_pulse_t += delta
		if _pulse_t >= Settings.DECOY_PULSE:
			_pulse_t -= Settings.DECOY_PULSE
			NetworkManager.report_noise(global_position, Settings.DECOY_LOUDNESS, 3)

	if _life >= Settings.DECOY_DURATION:
		queue_free()
