extends CanvasLayer
## The cold-cinematic colour grade (Marathon / Arc Raiders signature look the user chose) —
## a full-screen post pass that re-grades the rendered world: teal-steel shadows, warm
## highlights, crushed blacks, industrial desaturation. The decisive "intentionally graded"
## lever the subtle WorldEnvironment adjustment couldn't deliver. Mirrors raid_vignette.gd:
## a CanvasLayer + ColorRect(ShaderMaterial), shown only DURING a raid, gated by
## Settings.ui_fx_enabled. layer=0 → grades the 3D world (its screen texture is the rendered
## 3D) but sits BELOW the HUD (a CanvasLayer at the default layer 1) so UI text stays crisp.
## Render-only; no netcode. Instanced by main.gd.

const GRADE_SHADER := "res://shaders/cold_grade.gdshader"

var _rect: ColorRect = null
var _in_match: bool = false
var _paused: bool = false


func _ready() -> void:
	layer = 0  # grades the rendered 3D; the HUD (default layer 1) draws on top, ungraded
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(GRADE_SHADER):
		var mat := ShaderMaterial.new()
		mat.shader = load(GRADE_SHADER)
		_rect.material = mat
	add_child(_rect)
	Events.match_started.connect(_on_started)
	Events.match_won.connect(_on_ended)
	Events.match_lost.connect(_on_ended)
	Events.game_paused.connect(_on_paused)
	Events.ui_fx_changed.connect(_on_fx)
	_refresh()


func _on_started() -> void:
	_in_match = true
	_refresh()


func _on_ended() -> void:
	_in_match = false
	_refresh()


func _on_paused(p: bool) -> void:
	_paused = p
	_refresh()


func _on_fx(_enabled: bool) -> void:
	_refresh()


func _refresh() -> void:
	visible = _in_match and not _paused and Settings.ui_fx_enabled
