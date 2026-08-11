extends Node3D
class_name EnemyHealthBar
## Tiny world-space health bar for enemies. Two billboarded MeshInstance3D quads —
## a dark background and a colored fill scaled by the health ratio. Purely visual,
## runs on server + clients (it reads the replicated Health.current via the
## health_changed signal). Hidden while at full health and after death so the
## arena isn't cluttered; reveals on first damage.
##
## Usage: add as a child of an enemy and call setup(health) once. It auto-tracks
## the Health component and positions itself; the owner sets `bar_height` to sit
## above the model. No collision, no networking of its own.

@export var bar_width: float = 1.1
@export var bar_height: float = 0.14
@export var bar_y: float = 2.0  # local height above the enemy origin

var _bg: MeshInstance3D
var _fill: MeshInstance3D
var _fill_mat: StandardMaterial3D
var _health: Health = null
var _ratio: float = 1.0
var _label: Label3D = null  # M3: elite-modifier tag over the bar (set_label)


## M3: build the elite tag from the raw modifier id list («ARMORED · SWIFT»).
## Owner passes its parsed modifiers; empty list clears the tag.
func set_modifier_label(mods: Array) -> void:
	var tags: Array[String] = []
	for m in mods:
		tags.append(tr(String(m).to_upper()))
	set_label(" · ".join(tags))


## M3 elite readability: show WHY a machine is special («ARMORED · SWIFT») right
## over its health bar. Lazy Label3D; reveals/hides together with the bar.
func set_label(text: String) -> void:
	if text.strip_edges() == "":
		if _label != null:
			_label.visible = false
		return
	if _label == null:
		_label = Label3D.new()
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = false
		_label.font_size = 34
		_label.pixel_size = 0.004
		_label.modulate = Color(0.98, 0.72, 0.25)
		_label.outline_size = 8
		_label.position = Vector3(0, bar_y + 0.24, 0)
		add_child(_label)
	_label.text = text


func _ready() -> void:
	# Build the two quads procedurally so the scene file stays trivial and the
	# size is driven by exports. Both are unshaded + billboarded so they read at
	# any angle and ignore arena lighting.
	_bg = _make_quad(Vector2(bar_width, bar_height), Color(0.06, 0.06, 0.07, 0.85))
	_bg.position = Vector3(0, bar_y, 0)
	add_child(_bg)

	_fill = _make_quad(Vector2(bar_width, bar_height), Color(0.85, 0.2, 0.18, 1.0))
	# Sit the fill a hair in front of the background to avoid z-fighting.
	_fill.position = Vector3(0, bar_y, 0.01)
	_fill_mat = _fill.material_override as StandardMaterial3D
	add_child(_fill)

	visible = false


func _make_quad(size: Vector2, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	mi.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Bind to a Health component; we mirror its ratio and visibility.
func setup(health: Health) -> void:
	_health = health
	if _health == null:
		return
	if not _health.health_changed.is_connected(_on_health_changed):
		_health.health_changed.connect(_on_health_changed)
	if not _health.died.is_connected(_on_died):
		_health.died.connect(_on_died)
	_apply(_health.current, _health.max_health)


func _on_health_changed(current: float, max_health: float) -> void:
	_apply(current, max_health)


func _on_died(_killer: Node) -> void:
	visible = false


func _apply(current: float, max_health: float) -> void:
	if max_health <= 0.0:
		return
	_ratio = clampf(current / max_health, 0.0, 1.0)
	# Reveal once damaged (and not dead); hide again only if somehow refilled.
	visible = _ratio < 0.999 and (_health == null or not _health.is_dead)
	if _fill == null:
		return
	# Scale the fill quad horizontally and shift it left so it shrinks from the
	# right edge instead of the centre.
	_fill.scale = Vector3(maxf(_ratio, 0.0001), 1.0, 1.0)
	_fill.position.x = -bar_width * 0.5 * (1.0 - _ratio)
	if _fill_mat:
		# Green -> yellow -> red as it drops.
		_fill_mat.albedo_color = (
			Color(0.85, 0.85, 0.2).lerp(Color(0.9, 0.2, 0.15), 1.0 - _ratio)
			if _ratio > 0.5
			else Color(0.9, 0.55, 0.15).lerp(Color(0.9, 0.18, 0.15), (0.5 - _ratio) / 0.5)
		)
