extends Control
class_name InteractionPrompt
## Lower-centre "[E]  <prompt>" hint for nearby interactables (loot / extraction).
## Shows on Events.interaction_available, hides on interaction_cleared. Pure HUD —
## an amber key-cap drawn in code plus a dim label. Dark sci-fi theme.
## While holding E to revive a downed teammate it morphs into a teal REVIVING… bar
## (Events.revive_channel, fired on the local reviver) so the progress is unmistakable.

const KEY_COL := Color(0.91, 0.64, 0.24, 1.0)  # amber #e8a33d
const TEXT_COL := Color(0.847, 0.871, 0.894, 1.0)  # dim #d8dee4
const PANEL_BG := Color(0.03, 0.05, 0.07, 0.78)
const REVIVE_COL := Color(0.30, 0.85, 0.62, 1.0)  # teal-green revive accent
const PANEL_W := 320.0
const PANEL_H := 38.0
# Phase 2 (ARC pattern): the prompt sits just BELOW the crosshair, not 300 px away at
# the screen bottom — the player's eye never leaves the aim point.
const CROSSHAIR_GAP := 46.0
const CAP := 26.0  # key-cap size

var _prompt: String = ""
var _shown: bool = false
var _revive_frac: float = -1.0  # >= 0 while channeling a teammate revive; -1 = not reviving


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Crosshair-adjacent fixed box (screen centre + a small gap), any resolution.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -PANEL_W * 0.5
	offset_right = PANEL_W * 0.5
	offset_top = CROSSHAIR_GAP
	offset_bottom = CROSSHAIR_GAP + PANEL_H
	visible = false
	Events.interaction_available.connect(_on_available)
	Events.interaction_cleared.connect(_on_cleared)
	Events.revive_channel.connect(_on_revive_channel)


func _on_available(prompt: String, _target: Node) -> void:
	_prompt = prompt
	_shown = true
	visible = true
	queue_redraw()


func _on_cleared() -> void:
	_shown = false
	_revive_frac = -1.0
	visible = false


## Reviver-side hold-to-revive progress. frac 0..1 while channeling; < 0 = ended.
func _on_revive_channel(frac: float, _target: Node) -> void:
	_revive_frac = frac
	if frac >= 0.0:
		_shown = true
		visible = true
	queue_redraw()


func _draw() -> void:
	if not _shown:
		return
	var font := ThemeDB.fallback_font
	# Backing panel (accent turns teal while reviving).
	var accent: Color = REVIVE_COL if _revive_frac >= 0.0 else KEY_COL
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, PANEL_H)), PANEL_BG, true)
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, PANEL_H)), Color(accent, 0.5), false, 1.0)
	# Key-cap — filled brighter while the key is held for a revive. The label comes from the
	# InputMap for the CURRENT device, so it follows a Controls-tab remap and turns into the
	# pad's face button when the player is on a controller (it used to be a hard-coded "E",
	# which told a pad user to press a key they do not have).
	var cap_pos := Vector2(8.0, (PANEL_H - CAP) * 0.5)
	var cap_rect := Rect2(cap_pos, Vector2(CAP, CAP))
	draw_rect(cap_rect, Color(accent, 0.30 if _revive_frac >= 0.0 else 0.16), true)
	draw_rect(cap_rect, accent, false, 1.5)
	# Sampled at draw time, and this Control only redraws when the prompt changes — so
	# swapping mouse for pad WHILE a prompt is up leaves the old glyph until the next one.
	# A prompt lives a second or two, so the alternative (polling the device every frame on
	# a HUD element) costs more than the staleness does.
	var cap_label: String = UIGlyphs.label_for("interact")
	var cap_size: int = 16 if cap_label.length() <= 1 else 11
	draw_string(
		font,
		cap_pos + Vector2(CAP * 0.5 - 2.8 * cap_label.length(), CAP * 0.5 + 6.0),
		cap_label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		cap_size,
		accent
	)

	var text_x := cap_pos.x + CAP + 12.0
	if _revive_frac < 0.0:
		# Normal prompt text.
		draw_string(
			font,
			Vector2(text_x, PANEL_H * 0.5 + 6.0),
			_prompt,
			HORIZONTAL_ALIGNMENT_LEFT,
			PANEL_W - CAP - 30.0,
			16,
			TEXT_COL
		)
		return

	# --- Reviving: label + filling progress bar + percent ---
	draw_string(
		font,
		Vector2(text_x, 15.0),
		tr("REVIVING…"),
		HORIZONTAL_ALIGNMENT_LEFT,
		PANEL_W - text_x - 12.0,
		13,
		REVIVE_COL
	)
	var bar_x := text_x
	var bar_w := PANEL_W - bar_x - 12.0
	var bar_y := PANEL_H - 12.0
	var bar_h := 6.0
	draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.0, 0.0, 0.0, 0.55), true)
	draw_rect(Rect2(bar_x, bar_y, bar_w * clampf(_revive_frac, 0.0, 1.0), bar_h), REVIVE_COL, true)
	draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(REVIVE_COL, 0.7), false, 1.0)
	var pct := str(int(round(clampf(_revive_frac, 0.0, 1.0) * 100.0))) + "%"
	draw_string(font, Vector2(bar_x, 15.0), pct, HORIZONTAL_ALIGNMENT_RIGHT, bar_w, 13, REVIVE_COL)
