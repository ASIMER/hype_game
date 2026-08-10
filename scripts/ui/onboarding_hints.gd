extends CanvasLayer
## First-raid ONBOARDING hints — a short queue of contextual tips for a FRESH profile
## (a new player used to drop into the world with zero guidance). Local-only UI,
## instanced once by main.gd (persistent overlay, like reward_popup): each hint shows
## once (timed + event-triggered), then MetaProgression.onboarding_done is stamped so
## the sequence never runs again for this profile. Strings go through tr() — the
## English text IS the locale key (rows in locale/ui.csv).

const HINT_TIME := 6.5
const DONE_AFTER := 40.0  # s into the raid after which the sequence wraps up

# [show-at seconds, locale key] — the always-shown backbone of the sequence.
# gdlint: ignore=max-line-length
const _TIMED: Array = [
	[2.0, "GOAL: scavenge loot, survive the machines, reach an evac zone alive"],
	[11.0, "E — pick up loot · M — tactical map with evac zones and timers"],
	[20.0, "Green beacon = evac OPEN — stand inside the ring to extract"],
]
const _HINT_LOOT := "Loot is only KEPT if you extract — dying drops your haul"
const _HINT_WAVE := "Machine waves escalate — watch the timer, extract before the storm"

var _panel: PanelContainer = null
var _label: Label = null
var _t := 0.0
var _visible_until := 0.0
var _shown: Dictionary = {}
var _queue: Array[String] = []
var _active := false


func _ready() -> void:
	set_process(false)
	if MetaProgression.onboarding_done:
		return
	_build_ui()
	Events.match_started.connect(_on_match_started)
	Events.item_picked_up.connect(_on_pickup)
	Events.wave_started.connect(_on_wave)
	Events.match_won.connect(_finish)
	Events.match_lost.connect(_finish)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.AMBER))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Fixed-box self-positioning (the skill-hotbar lesson: FULL_RECT under a CanvasLayer
	# collapses to zero size): bottom-center, floating above the skill hotbar.
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.offset_bottom = -150.0
	_panel.visible = false
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 15)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 14)
	pad.add_theme_constant_override("margin_right", 14)
	pad.add_theme_constant_override("margin_top", 7)
	pad.add_theme_constant_override("margin_bottom", 7)
	pad.add_child(_label)
	_panel.add_child(pad)
	add_child(_panel)


func _on_match_started() -> void:
	if MetaProgression.onboarding_done or _panel == null:
		return
	_t = 0.0
	_visible_until = 0.0
	_active = true
	set_process(true)


func _process(delta: float) -> void:
	if not _active:
		return
	_t += delta
	for pair: Array in _TIMED:
		if _t >= float(pair[0]):
			_push(String(pair[1]))
	if _visible_until > 0.0:
		if _t >= _visible_until:
			_visible_until = 0.0
			_panel.visible = false
	elif not _queue.is_empty():
		var key: String = _queue.pop_front()
		_label.text = tr(key)
		_panel.visible = true
		UIStyle.pop_in(_panel)
		_visible_until = _t + HINT_TIME
	elif _t > DONE_AFTER and _shown.size() >= _TIMED.size():
		_finish()


func _push(key: String) -> void:
	if _shown.has(key):
		return
	_shown[key] = true
	_queue.append(key)


## Only the LOCAL player's first pickup teaches the at-risk rule.
func _on_pickup(player: Node, _item_id: String, _count: int) -> void:
	if _active and player != null and player.is_multiplayer_authority():
		_push(_HINT_LOOT)


func _on_wave(wave_number: int, _enemy_count: int) -> void:
	if _active and wave_number >= 1:
		_push(_HINT_WAVE)


func _finish() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	if _panel != null:
		_panel.visible = false
	MetaProgression.mark_onboarding_done()
