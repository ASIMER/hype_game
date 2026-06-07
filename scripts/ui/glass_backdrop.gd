class_name GlassBackdrop
extends Control
## A frosted-glass dim placed BEHIND a shell modal's panel. With Settings.ui_fx_enabled a
## full-rect ColorRect blurs + dims whatever is behind it (shaders/ui_blur.gdshader — the
## 3D world for the in-raid Hub/Pause, or the menu's dark bg); without it, a plain dark
## dim (cheap fallback). Add as the FIRST child of a screen so it draws behind the panel:
##   var bg := GlassBackdrop.new(); add_child(bg); move_child(bg, 0)
## It ignores mouse input so the UI underneath stays clickable.

const BLUR_SHADER := "res://shaders/ui_blur.gdshader"
const DIM := Color(0.03, 0.04, 0.055, 0.72)

var _rect: ColorRect = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)
	Events.ui_fx_changed.connect(_apply)
	_apply(Settings.ui_fx_enabled)

func _apply(enabled: bool) -> void:
	if _rect == null:
		return
	if enabled and ResourceLoader.exists(BLUR_SHADER):
		var mat := ShaderMaterial.new()
		mat.shader = load(BLUR_SHADER)
		_rect.material = mat
		_rect.color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		_rect.material = null
		_rect.color = DIM
