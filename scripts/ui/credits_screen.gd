extends CanvasLayer
## CREDITS / licenses overlay (main menu) — the in-product attribution the shipped
## builds legally need: the game-icons.net UI icons are CC BY 3.0 (attribution
## required), fonts are SIL OFL, plugins MIT, everything else CC0/own work. The full
## machine-readable catalog stays in docs/ASSETS.md; this screen is the player-facing
## summary. Built in code (glass theme), opened by the menu's CREDITS button; node
## name "CreditsScreen" + open()/close() keep it drivable by the harness `ui` verb.
## A CanvasLayer (layer 60): the MainMenu root Control has ZERO size, so a child
## Control full-rect collapses to the origin (the skill-hotbar lesson) — CanvasLayer
## children anchor against the VIEWPORT instead, and the layer draws above the menu.

# Section header (tr-key) → untranslated attribution lines (names/licenses/URLs).
const _SECTIONS: Array = [
	["ENGINE", ["Godot Engine 4.6 — MIT — godotengine.org"]],
	[
		"PLUGINS & TECHNIQUES (MIT)",
		[
			"Sky3D — Cory Petkovsek & contributors, J. Cuéllar",
			"GodotGrass grass technique — Ethan Truong (2Retr0)",
		]
	],
	[
		"MODELS & TEXTURES (CC0)",
		[
			"Quaternius (Tomás Laulhé) — nature & weapon models — quaternius.com",
			"Kenney (Kenney Vleugels) — blaster kit, props — kenney.nl",
			"ambientCG (Lennart Demes) — PBR ground textures — ambientcg.com",
		]
	],
	[
		"AUDIO",
		[
			"Gunshot Sounds (OpenGameArt) — recorded firearms — CC0",
			"qubodup — ambience & music loops — CC0",
			"All remaining SFX — generated in-house (gen_audio.py) — CC0",
		]
	],
	[
		"UI ICONS (CC BY 3.0 — attribution required)",
		[
			"Icons by Lorc, Delapouite and Sbed — game-icons.net",
			"creativecommons.org/licenses/by/3.0",
		]
	],
	["FONTS (SIL OFL 1.1)", ["Oswald · Russo One — Google Fonts"]],
]

var _backdrop: Control = null
var _panel: PanelContainer = null


func _ready() -> void:
	name = "CreditsScreen"
	layer = 60
	visible = false
	_backdrop = GlassBackdrop.new()
	add_child(_backdrop)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP  # block menu clicks behind
	_build_panel()


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.AMBER))
	# Explicit centered box: 540 wide, 88% of the viewport tall — fits the 640×360
	# agent window AND fullscreen alike (a fixed 480 px height overflowed 360p).
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.offset_left = -270.0
	_panel.offset_right = 270.0
	_panel.anchor_top = 0.06
	_panel.anchor_bottom = 0.94
	_panel.offset_top = 0.0
	_panel.offset_bottom = 0.0
	add_child(_panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)
	var title := Label.new()
	title.text = "CREDITS"
	UIStyle.make_header(title, UIStyle.WHITE, 26, 4)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	for section: Array in _SECTIONS:
		list.add_child(UIStyle.micro_header(String(section[0])))
		for line: String in section[1]:
			var lab := Label.new()
			lab.text = line
			lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lab.add_theme_font_size_override("font_size", 14)
			list.add_child(lab)
		list.add_child(HSeparator.new())
	var close := Button.new()
	close.text = "CLOSE"
	close.custom_minimum_size = Vector2(160, 40)
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close.pressed.connect(close_screen)
	UIStyle.hover_lift(close)
	vbox.add_child(close)


func open() -> void:
	visible = true
	if _panel != null:
		UIStyle.pop_in(_panel)


func close_screen() -> void:
	visible = false


## Harness-friendly alias (the `ui` verb calls open()/close()).
func close() -> void:
	close_screen()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_screen()
		get_viewport().set_input_as_handled()
