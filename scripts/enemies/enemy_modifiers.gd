## Elite ENEMY MODIFIERS (rare prefixes rolled by the wave manager) — the parser +
## stat/visual appliers behind RobotEnemy's modifier hooks, kept here as statics so
## robot_enemy.gd stays thin. Server applies stats; EVERY peer parses the name + builds
## the visuals (the name is replicated via the auto-spawn, so clients see the same elite).
##
## Wire (the wave manager NAME-ENCODES rolled prefixes BEFORE add_child):
##   enemy.name = "%s_mod%s" % [base, flags]   flags ⊆ {A,S,V,R}  e.g. "RobotHeavy_modAV"
##   add_child(..., true) may APPEND collision digits ("_modAV2", "_modA3") — tolerated.
##
## Letter map: A→armored  S→swift  V→volatile  R→regenerating  (unknown letters ignored).
## Stats/colors come from Settings.ELITE_MOD_STATS + Settings.ELITE_MOD_COLORS.
class_name EnemyModifiers

const _FLAG_TO_MOD := {
	"A": "armored",
	"S": "swift",
	"V": "volatile",
	"R": "regenerating",
}


## Parse the modifier list out of a node name. Finds the LAST "_mod" token, then reads
## letters after it until a digit or the end (the auto-spawn de-dupe digits stop us), maps
## each known letter to its modifier, and dedupes while preserving order. Tolerant of:
##   - no "_mod" token at all (plain enemy) → []
##   - trailing collision digits ("_modAV2") → digits end the scan
##   - unknown letters → silently skipped
## Returns an Array[String] of full modifier names (e.g. ["armored", "volatile"]).
static func parse_from_name(node_name: String) -> Array[String]:
	var mods: Array[String] = []
	var idx := node_name.rfind("_mod")
	if idx < 0:
		return mods
	var i := idx + 4  # past "_mod"
	while i < node_name.length():
		var ch := node_name[i]
		if ch >= "0" and ch <= "9":
			break  # de-dupe digit terminates the flag run
		if _FLAG_TO_MOD.has(ch):
			var mod: String = _FLAG_TO_MOD[ch]
			if not mods.has(mod):
				mods.append(mod)
		i += 1
	return mods


## Look up one modifier's stat dict from Settings (empty if unknown).
static func stats_for(mod: String) -> Dictionary:
	return Settings.ELITE_MOD_STATS.get(mod, {})


## Accent color for the PRIMARY modifier (drives the tint + glow ring). White if none.
static func primary_color(mods: Array[String]) -> Color:
	if mods.is_empty():
		return Color.WHITE
	return Settings.ELITE_MOD_COLORS.get(mods[0], Color.WHITE)


## Tint a list of (already per-instance duplicated) StandardMaterial3D toward `tint` so the
## elite reads as colored while the archetype silhouette/shading stays recognizable. Lerp on
## albedo only (emission is owned by the hit-flash / idle pulse, so we never fight them).
## `amount` ~0.45 keeps the base material visible. Caller guards headless.
static func tint_materials(mats: Array[StandardMaterial3D], tint: Color, amount: float) -> void:
	for m in mats:
		if m == null:
			continue
		m.albedo_color = m.albedo_color.lerp(tint, amount)


## Build the under-foot glow ring (a flat unshaded additive cylinder) in the elite color so
## the modifier is legible from across the map. Parented under `model_root`; render-only.
## Caller guards headless. Returns the MeshInstance3D (or null on a bad root).
static func build_glow_ring(model_root: Node3D, color: Color) -> MeshInstance3D:
	if model_root == null:
		return null
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.05
	mesh.bottom_radius = 1.05
	mesh.height = 0.04
	mesh.radial_segments = 24
	mesh.rings = 0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.5)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# Lie flat at the feet, ignore lighting/shadows, never cull early.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0.0, 0.04, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model_root.add_child(mi)
	return mi
