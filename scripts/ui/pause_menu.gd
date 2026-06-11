extends Control
## Pause overlay: Resume / Settings / Quit to Menu. Runs while the tree is paused
## (process_mode = WHEN_PAUSED, set in the scene) so its buttons stay clickable. The
## lead owns get_tree().paused and the ESC binding — this node only shows/hides and
## emits intent signals.

signal resume_pressed
signal quit_to_menu_pressed

@onready var _panel: PanelContainer = $Panel
@onready var _settings_menu := $SettingsMenu


func _ready() -> void:
	$Panel/VBox/ResumeBtn.pressed.connect(_on_resume)
	$Panel/VBox/SettingsBtn.pressed.connect(_on_settings)
	$Panel/VBox/QuitBtn.pressed.connect(_on_quit_to_menu)
	_settings_menu.closed.connect(_on_settings_closed)
	_settings_menu.visible = false
	# Style the scene-side title with Russo One header face.
	UIStyle.make_header($Panel/VBox/Title, UIStyle.AMBER, 36)
	# Hover-lift on the three action buttons.
	UIStyle.hover_lift($Panel/VBox/ResumeBtn)
	UIStyle.hover_lift($Panel/VBox/SettingsBtn)
	UIStyle.hover_lift($Panel/VBox/QuitBtn)
	# Frosted-glass backdrop behind the panel.
	var bg := GlassBackdrop.new()
	add_child(bg)
	move_child(bg, 0)
	hide()


# ---------------------------------------------------------------- public API
func show_pause() -> void:
	_settings_menu.hide()
	_panel.show()
	show()
	UIStyle.pop_in(_panel)


func hide_pause() -> void:
	_settings_menu.hide()
	hide()


# ---------------------------------------------------------------- buttons
func _on_resume() -> void:
	resume_pressed.emit()


func _on_settings() -> void:
	_panel.hide()
	_settings_menu.open()


func _on_settings_closed() -> void:
	_panel.show()


func _on_quit_to_menu() -> void:
	quit_to_menu_pressed.emit()
