extends Control
class_name InteractionPrompt
## Lower-centre "[E]  <prompt>" hint for nearby interactables (loot / extraction).
## Shows on Events.interaction_available, hides on interaction_cleared. Pure HUD —
## an amber key-cap drawn in code plus a dim label. Dark sci-fi theme.

const KEY_COL := Color(0.91, 0.64, 0.24, 1.0)      # amber #e8a33d
const TEXT_COL := Color(0.847, 0.871, 0.894, 1.0)  # dim #d8dee4
const PANEL_BG := Color(0.03, 0.05, 0.07, 0.78)
const PANEL_W := 320.0
const PANEL_H := 38.0
const BOTTOM_GAP := 120.0
const CAP := 26.0  # key-cap size

var _prompt: String = ""
var _shown: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Bottom-centre, fixed box, grow from centre so it stays put at any resolution.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -PANEL_W * 0.5
	offset_right = PANEL_W * 0.5
	offset_top = -BOTTOM_GAP - PANEL_H
	offset_bottom = -BOTTOM_GAP
	visible = false
	Events.interaction_available.connect(_on_available)
	Events.interaction_cleared.connect(_on_cleared)


func _on_available(prompt: String, _target: Node) -> void:
	_prompt = prompt
	_shown = true
	visible = true
	queue_redraw()


func _on_cleared() -> void:
	_shown = false
	visible = false


func _draw() -> void:
	if not _shown:
		return
	var font := ThemeDB.fallback_font
	# Backing panel.
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, PANEL_H)), PANEL_BG, true)
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, PANEL_H)), Color(KEY_COL, 0.5), false, 1.0)
	# Key-cap (amber outlined square with "E").
	var cap_pos := Vector2(8.0, (PANEL_H - CAP) * 0.5)
	var cap_rect := Rect2(cap_pos, Vector2(CAP, CAP))
	draw_rect(cap_rect, Color(KEY_COL, 0.16), true)
	draw_rect(cap_rect, KEY_COL, false, 1.5)
	draw_string(font, cap_pos + Vector2(CAP * 0.5 - 5.0, CAP * 0.5 + 6.0),
		"E", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, KEY_COL)
	# Prompt text.
	draw_string(font, Vector2(cap_pos.x + CAP + 12.0, PANEL_H * 0.5 + 6.0),
		_prompt, HORIZONTAL_ALIGNMENT_LEFT, PANEL_W - CAP - 30.0, 16, TEXT_COL)
