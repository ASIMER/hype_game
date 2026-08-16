extends RefCounted
class_name UIGlyphs
## Which button label to print for an action, given the device the player is actually using.
##
## Prompts in this project hard-code their key ("[E] Pick up", the "E" key-cap the interaction
## prompt draws). On a controller that is simply wrong — and wrong in the most confusing way,
## because the player is holding a pad and being told to press a keyboard key.
##
## The label is read from the InputMap rather than from a table, so it follows the Controls-tab
## remap for free: rebind interact to F and the prompt says F; plug in a pad and it says the
## face button that action is actually bound to.
##
## Device tracking is last-event-wins, the convention every console-and-PC game uses: touch the
## mouse and prompts go back to keys, touch the stick and they become glyphs. `note_event` is
## fed from `UIFocusPad._input`, which is the one global listener this project already has.

## Xbox-style face names. Godot's JoyButton enum order is fixed, so the index IS the mapping.
const PAD_NAMES := [
	"A",
	"B",
	"X",
	"Y",
	"BACK",
	"HOME",
	"START",
	"L3",
	"R3",
	"LB",
	"RB",
	"UP",
	"DOWN",
	"LEFT",
	"RIGHT",
]
## Analog axes that read as buttons to the player.
const PAD_AXES := {4: "LT", 5: "RT", 0: "LS", 1: "LS", 2: "RS", 3: "RS"}

static var _pad_active: bool = false


## Feed every input event here; cheap, and the only thing it does is remember the device.
static func note_event(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		_pad_active = true
	elif event is InputEventJoypadMotion:
		# A resting stick still emits motion; only a real push counts as "using the pad".
		if absf((event as InputEventJoypadMotion).axis_value) > 0.5:
			_pad_active = true
	elif event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion:
		_pad_active = false


static func pad_active() -> bool:
	return _pad_active


## Short label for `action` on the CURRENT device — "E" / "F" on a keyboard, "A" / "RT" on a
## pad. Falls back to the action name only when the action has no binding for that device,
## which means an unbound action is visibly unbound rather than silently mislabelled.
static func label_for(action: String) -> String:
	if not InputMap.has_action(action):
		return action
	var want_pad: bool = _pad_active
	for ev in InputMap.action_get_events(action):
		if want_pad:
			if ev is InputEventJoypadButton:
				var idx: int = (ev as InputEventJoypadButton).button_index
				return PAD_NAMES[idx] if idx < PAD_NAMES.size() else "B%d" % idx
			if ev is InputEventJoypadMotion:
				return String(PAD_AXES.get((ev as InputEventJoypadMotion).axis, "STICK"))
		else:
			if ev is InputEventKey:
				var key := ev as InputEventKey
				var code: int = key.physical_keycode if key.physical_keycode != 0 else key.keycode
				return OS.get_keycode_string(code)
			if ev is InputEventMouseButton:
				return "LMB" if (ev as InputEventMouseButton).button_index == 1 else "RMB"
	return action
