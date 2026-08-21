extends Node
class_name UIFocusPad
## Makes the UI navigable with a controller, from ONE place.
##
## Godot already moves focus between Controls on `ui_up`/`ui_down`/`ui_left`/`ui_right` and
## activates on `ui_accept` — but only once something HAS focus. Every screen in this project
## is built in code and none of them call `grab_focus()`, so a pad press did nothing at all:
## the stick moved a focus ring that did not exist yet.
##
## The obvious fix is a `grab_focus()` in each screen's open path, which means touching
## main menu, hub, every hub tab, settings, pause, summary, haul, trade and the modals — and
## then remembering it for the next screen someone adds. This does it once instead: watch for
## a pad input arriving while nothing is focused, find the top-most interactive Control that
## is actually on screen, and focus it. Every screen written afterwards inherits the behaviour
## for free, including ones added by other agents.
##
## Deliberately inert for mouse and keyboard: it only reacts to joypad events, so it can never
## steal focus from someone typing in a LineEdit or clicking.

## Controls under a CanvasLayer with a higher layer are on top; ties break on tree order,
## which is also paint order, so the last match wins.
var _last_focus_ms: int = 0
const _REARM_COOLDOWN_MS := 250


func _ready() -> void:
	# Runs while the tree is paused: the pause menu and the raid summary are exactly the
	# screens a controller user needs to reach.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Device tracking must see EVERY event, including the ones the game consumes (firing, moving),
## so it rides `_input` while the focus grab below stays on `_unhandled_input` — grabbing focus
## from here would fight the game for the stick during a raid.
func _input(event: InputEvent) -> void:
	UIGlyphs.note_event(event)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	if event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) < 0.5:
		return
	var vp := get_viewport()
	if vp == null or vp.gui_get_focus_owner() != null:
		return
	# A held stick fires many motion events; without this the search would run every frame
	# while the player pushes a direction against a screen that has nothing to focus.
	var now: int = Time.get_ticks_msec()
	if now - _last_focus_ms < _REARM_COOLDOWN_MS:
		return
	_last_focus_ms = now
	var target := _best_candidate()
	if target != null:
		target.grab_focus()


## The interactive Control the player would most plausibly mean: visible, on screen, able to
## take focus, and as high in the canvas stack as anything gets. Returns null when the frame
## holds no UI at all — the in-raid HUD is all `mouse_filter = IGNORE` labels, which is
## exactly why nothing is focused during play and the pad is left alone there.
func _best_candidate() -> Control:
	var best: Control = null
	var best_layer: int = -0x7fffffff
	for node in _walk(get_tree().root):
		var c := node as Control
		if c == null or not c.is_visible_in_tree() or c.focus_mode != Control.FOCUS_ALL:
			continue
		if c.size.x <= 0.0 or c.size.y <= 0.0:
			continue
		var layer: int = _layer_of(c)
		if layer >= best_layer:
			best_layer = layer
			best = c
	return best


## Canvas depth of a Control: the nearest CanvasLayer ancestor's layer, 0 when it lives
## directly under the root viewport.
func _layer_of(c: Control) -> int:
	var n: Node = c
	while n != null:
		if n is CanvasLayer:
			return (n as CanvasLayer).layer
		n = n.get_parent()
	return 0


func _walk(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		# A hidden branch cannot hold a focusable target, and skipping it keeps this search
		# proportional to what is actually on screen rather than to the whole scene.
		if n is CanvasItem and not (n as CanvasItem).visible:
			continue
		for child in n.get_children():
			stack.append(child)
	return out
