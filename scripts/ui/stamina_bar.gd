extends Control
class_name StaminaBar
## Thin sprint-stamina bar, centred just under the crosshair. Fed by
## Events.stamina_changed. Fill is teal, shifts amber→red when low. Auto-hides
## (fades out) when full, fades back in while draining. Dark sci-fi theme.

const BAR_W := 140.0
const BAR_H := 5.0
const BELOW_CENTRE := 34.0     # px below screen centre
const BG := Color(0.03, 0.05, 0.07, 0.7)

const TEAL := Color(0.247, 0.714, 0.788)   # #3fb6c9
const AMBER := Color(0.91, 0.64, 0.24)     # #e8a33d
const RED := Color(0.847, 0.271, 0.251)    # #d84540

var _ratio: float = 1.0
var _alpha: float = 0.0       # current opacity (fades toward _target_alpha)
var _target_alpha: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Centre-anchored fixed box, nudged below the reticle.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -BAR_W * 0.5
	offset_right = BAR_W * 0.5
	offset_top = BELOW_CENTRE
	offset_bottom = BELOW_CENTRE + BAR_H
	Events.stamina_changed.connect(_on_stamina_changed)


func _on_stamina_changed(current: float, max_stamina: float) -> void:
	_ratio = clampf(current / maxf(max_stamina, 0.001), 0.0, 1.0)
	# Visible while not full; hide once topped off.
	_target_alpha = 0.0 if _ratio >= 0.999 else 1.0


func _process(delta: float) -> void:
	if not is_equal_approx(_alpha, _target_alpha):
		_alpha = move_toward(_alpha, _target_alpha, delta * 3.0)
		queue_redraw()


func _draw() -> void:
	if _alpha <= 0.01:
		return
	# Background track.
	draw_rect(Rect2(Vector2.ZERO, Vector2(BAR_W, BAR_H)), Color(BG.r, BG.g, BG.b, BG.a * _alpha), true)
	# Fill colour by remaining stamina.
	var fill_col := TEAL
	if _ratio < 0.25:
		fill_col = RED
	elif _ratio < 0.5:
		fill_col = AMBER
	var w := BAR_W * _ratio
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, BAR_H)),
		Color(fill_col.r, fill_col.g, fill_col.b, _alpha), true)
	# Thin frame.
	draw_rect(Rect2(Vector2.ZERO, Vector2(BAR_W, BAR_H)),
		Color(fill_col.r, fill_col.g, fill_col.b, 0.45 * _alpha), false, 1.0)
