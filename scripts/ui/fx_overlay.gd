extends CanvasLayer
## Global "military glass" FX veil: thin scanlines + film grain + a soft edge vignette,
## drawn over the SHELL UI only (main menu / hub / pause / raid summary) — never over live
## aim during a raid. Persistent CanvasLayer instanced by main.gd alongside StatsOverlay /
## LoadingScreen. Gated by Settings.ui_fx_enabled (Interface tab → Events.ui_fx_changed).

const SCANLINE_SHADER := "res://shaders/ui_scanline.gdshader"

var _rect: ColorRect = null
var _in_match: bool = false
var _paused: bool = false


func _ready() -> void:
	layer = 90  # above the menus/HUD; the loading screen sits higher still
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.color = Color(1.0, 1.0, 1.0, 1.0)
	if ResourceLoader.exists(SCANLINE_SHADER):
		var mat := ShaderMaterial.new()
		mat.shader = load(SCANLINE_SHADER)
		_rect.material = mat
	add_child(_rect)
	# Shell vs in-raid tracking: the veil shows on shell UI and while paused.
	Events.match_started.connect(
		func() -> void:
			_in_match = true
			_refresh()
	)
	Events.match_won.connect(
		func() -> void:
			_in_match = false
			_refresh()
	)
	Events.match_lost.connect(
		func() -> void:
			_in_match = false
			_refresh()
	)
	Events.game_paused.connect(
		func(p: bool) -> void:
			_paused = p
			_refresh()
	)
	Events.ui_fx_changed.connect(func(_e: bool) -> void: _refresh())
	_refresh()


func _refresh() -> void:
	var shell: bool = (not _in_match) or _paused
	visible = shell and Settings.ui_fx_enabled
