class_name JoyInput
extends RefCounted

const BTN := 0
const AXIS := 1
const KEY := 2

# one table row per action, so a new binding is one entry and never a new branch
const ACTIONS := {
	"jf_up": [[BTN, JOY_BUTTON_DPAD_UP], [AXIS, JOY_AXIS_LEFT_Y, -1.0], [KEY, KEY_UP]],
	"jf_down": [[BTN, JOY_BUTTON_DPAD_DOWN], [AXIS, JOY_AXIS_LEFT_Y, 1.0], [KEY, KEY_DOWN]],
	"jf_left": [[BTN, JOY_BUTTON_DPAD_LEFT], [AXIS, JOY_AXIS_LEFT_X, -1.0], [KEY, KEY_LEFT]],
	"jf_right": [[BTN, JOY_BUTTON_DPAD_RIGHT], [AXIS, JOY_AXIS_LEFT_X, 1.0], [KEY, KEY_RIGHT]],
	"jf_accept": [[BTN, JOY_BUTTON_A], [KEY, KEY_ENTER]],
	"jf_back": [[BTN, JOY_BUTTON_B], [KEY, KEY_BACKSPACE], [KEY, KEY_ESCAPE]],
	"jf_menu": [[BTN, JOY_BUTTON_X], [KEY, KEY_M]],
	"jf_select": [[BTN, JOY_BUTTON_Y], [KEY, KEY_SPACE]],
	"jf_pane": [[BTN, JOY_BUTTON_LEFT_SHOULDER], [BTN, JOY_BUTTON_RIGHT_SHOULDER], [KEY, KEY_TAB]],
	"jf_page_up": [[AXIS, JOY_AXIS_TRIGGER_LEFT, 1.0], [KEY, KEY_PAGEUP]],
	"jf_page_down": [[AXIS, JOY_AXIS_TRIGGER_RIGHT, 1.0], [KEY, KEY_PAGEDOWN]],
	"jf_start": [[BTN, JOY_BUTTON_START], [KEY, KEY_F10]],
	"jf_view": [[BTN, JOY_BUTTON_BACK], [KEY, KEY_H]],
	"jf_search": [[BTN, JOY_BUTTON_RIGHT_STICK], [KEY, KEY_F]],
	"jf_jobs": [[BTN, JOY_BUTTON_LEFT_STICK], [KEY, KEY_J]],
}

const REPEATING := ["jf_up", "jf_down", "jf_left", "jf_right", "jf_page_up", "jf_page_down"]


static func install() -> void:
	for action: String in ACTIONS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action, 0.5)
		for binding: Array in ACTIONS[action]:
			InputMap.action_add_event(action, _event_for(binding))


static func _event_for(binding: Array) -> InputEvent:
	match binding[0]:
		BTN:
			var b := InputEventJoypadButton.new()
			b.button_index = binding[1]
			return b
		AXIS:
			var m := InputEventJoypadMotion.new()
			m.axis = binding[1]
			m.axis_value = binding[2]
			return m
		_:
			var k := InputEventKey.new()
			k.physical_keycode = binding[1]
			return k
