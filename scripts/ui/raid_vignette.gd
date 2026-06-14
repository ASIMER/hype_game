extends CanvasLayer
## A subtle cinematic vignette (dark, slightly-cool edges) shown ONLY during a live raid — the
## "intentional colour grade" cue the WorldEnvironment can't give (the critic panel flagged the
## absence of any vignette/grade as the "engine-default" tell). The opposite gating to
## fx_overlay (which veils SHELL UI and hides in raid). Gated by Settings.ui_fx_enabled.
## Persistent CanvasLayer instanced by main.gd. Render-only; no netcode.

const VIGNETTE_SHADER := "res://shaders/raid_vignette.gdshader"

var _rect: ColorRect = null
var _in_match: bool = false
var _paused: bool = false


func _ready() -> void:
	layer = 2  # above the 3D world, below the HUD veil (fx_overlay sits at 90)
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(VIGNETTE_SHADER):
		var mat := ShaderMaterial.new()
		mat.shader = load(VIGNETTE_SHADER)
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
