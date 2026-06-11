extends Node3D
class_name DamageNumber
## A single floating world-space damage number. Renders a billboarded Label3D
## that rises and fades over LIFETIME then frees itself. Purely visual/local.
## Call setup(amount, is_crit) before or after adding to the tree; position the
## node at the hit point first. White for normal hits, bold yellow for crits.

const LIFETIME := 0.7
const RISE := 1.1  # world units the number floats upward over its life

var _t := 0.0
var _label: Label3D
var _start_y := 0.0
var _amount := 0.0
var _crit := false
var _pending := false  # setup() was called before _ready built the label


## amount is shown rounded; is_crit styles it yellow + larger + bold.
func setup(amount: float, is_crit: bool) -> void:
	_amount = amount
	_crit = is_crit
	if _label:
		_apply()
	else:
		_pending = true


func _ready() -> void:
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.shaded = false
	_label.double_sided = true
	_label.outline_size = 8
	_label.outline_modulate = Color(0, 0, 0, 0.9)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_label)
	_start_y = global_position.y
	_apply()


## Push the current amount/crit styling onto the label.
func _apply() -> void:
	if _label == null:
		return
	var n := int(round(_amount))
	_label.text = str(n)
	if _crit:
		_label.modulate = Color(1.0, 0.85, 0.2)
		_label.font_size = 56
		_label.pixel_size = 0.0014
		_label.outline_size = 12
	else:
		_label.modulate = Color(1.0, 1.0, 1.0)
		_label.font_size = 40
		_label.pixel_size = 0.001
		_label.outline_size = 8
	_pending = false


func _process(delta: float) -> void:
	_t += delta
	var k := clampf(_t / LIFETIME, 0.0, 1.0)
	# Ease-out rise so it pops up then slows.
	var rise_k := 1.0 - (1.0 - k) * (1.0 - k)
	global_position.y = _start_y + RISE * rise_k
	if _label:
		# Hold full opacity for the first third, then fade.
		var a := 1.0 if k < 0.33 else 1.0 - (k - 0.33) / 0.67
		_label.modulate.a = clampf(a, 0.0, 1.0)
		_label.outline_modulate.a = clampf(a, 0.0, 1.0) * 0.9
	if _t >= LIFETIME:
		queue_free()
