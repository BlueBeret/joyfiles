class_name JoyInput
extends RefCounted

const BTN := 0
const KEY := 1

# one table row per action, so a new binding is one entry and never a new branch
const ACTIONS := {
	"jf_up": [[BTN, JOY_BUTTON_DPAD_UP], [KEY, KEY_UP]],
	"jf_down": [[BTN, JOY_BUTTON_DPAD_DOWN], [KEY, KEY_DOWN]],
	"jf_left": [[BTN, JOY_BUTTON_DPAD_LEFT], [KEY, KEY_LEFT]],
	"jf_right": [[BTN, JOY_BUTTON_DPAD_RIGHT], [KEY, KEY_RIGHT]],
	"jf_accept": [[BTN, JOY_BUTTON_A], [KEY, KEY_ENTER]],
	"jf_back": [[BTN, JOY_BUTTON_B], [KEY, KEY_BACKSPACE], [KEY, KEY_ESCAPE]],
	"jf_menu": [[BTN, JOY_BUTTON_X], [KEY, KEY_M]],
	"jf_select": [[BTN, JOY_BUTTON_Y], [KEY, KEY_SPACE]],
	"jf_pane": [[BTN, JOY_BUTTON_LEFT_SHOULDER], [BTN, JOY_BUTTON_RIGHT_SHOULDER], [KEY, KEY_TAB]],
	"jf_page_up": [[KEY, KEY_PAGEUP]],
	"jf_page_down": [[KEY, KEY_PAGEDOWN]],
	"jf_start": [[BTN, JOY_BUTTON_START], [KEY, KEY_F10]],
	"jf_view": [[BTN, JOY_BUTTON_BACK], [KEY, KEY_H]],
	"jf_search": [[BTN, JOY_BUTTON_RIGHT_STICK], [KEY, KEY_F]],
	"jf_jobs": [[BTN, JOY_BUTTON_LEFT_STICK], [KEY, KEY_J]],
}
const DPAD := [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]
const TRIGGERS := {JOY_AXIS_TRIGGER_LEFT: "jf_page_up", JOY_AXIS_TRIGGER_RIGHT: "jf_page_down"}
# an axis engages at ENGAGE and lets go below RELEASE, so noise around one value cannot flap
const ENGAGE := 0.6
const RELEASE := 0.4
# seconds to the first repeat and between repeats, and only list movement repeats
const REPEAT := {
	"jf_up": [0.35, 0.06],
	"jf_down": [0.35, 0.06],
	"jf_page_up": [0.4, 0.2],
	"jf_page_down": [0.4, 0.2],
}

# a source is one physical control that is down, mapped to the action it holds
var _live := {}
# sources that were down when the screen changed, ignored until their release
var _stale := {}
var _dpads := {}
var _axes := {}
# an axis source fires only after it rests near the center, so a spring back cannot fire the other way
var _armed := {}
var _repeat := ""
var _repeat_at := 0.0
var _clock := 0.0


static func install() -> void:
	for action: String in ACTIONS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
		for binding: Array in ACTIONS[action]:
			InputMap.action_add_event(action, _event_for(binding))


static func _event_for(binding: Array) -> InputEvent:
	var e: InputEvent
	if binding[0] == BTN:
		e = InputEventJoypadButton.new()
		e.button_index = binding[1]
	else:
		e = InputEventKey.new()
		e.physical_keycode = binding[1]
	# device -1 matches every pad, so a second pad or a pad that Windows renumbers still works
	e.device = -1
	return e


static func action_of(e: InputEvent) -> String:
	for action: String in ACTIONS:
		if e.is_action(action, true):
			return action
	return ""


# the action that a button or key event starts, or "" when it starts nothing
func press(e: InputEvent) -> String:
	if e is InputEventJoypadMotion:
		var values: Dictionary = _axes.get_or_add(e.device, {})
		values[e.axis] = e.axis_value
		return ""
	if e is InputEventJoypadButton and e.button_index in DPAD:
		return _dpad(e)
	var src := _source_of(e)
	if src == "":
		return ""
	if not e.is_pressed():
		_up(src)
		return ""
	if e.is_echo() or _live.has(src) or _stale.has(src):
		return ""
	return _down(src, action_of(e))


# a control that is down when the screen changes does nothing more until it is released
func block() -> void:
	_stale.merge(_live)
	_live.clear()
	_repeat = ""


# the stick and the triggers are read once per frame, after every axis event of that frame
func tick(now: float, on_press: Callable) -> void:
	_clock = now
	for device: int in _axes:
		var values: Dictionary = _axes[device]
		var x: float = values.get(JOY_AXIS_LEFT_X, 0.0)
		var y: float = values.get(JOY_AXIS_LEFT_Y, 0.0)
		_settle("s%d" % device, {"jf_up": -y, "jf_down": y, "jf_left": -x, "jf_right": x}, on_press)
		for axis: int in TRIGGERS:
			_settle("t%d:%d" % [device, axis], {TRIGGERS[axis]: values.get(axis, 0.0)}, on_press)
	var target := _repeat_target()
	if target != _repeat:
		_repeat = target
		if target != "":
			_repeat_at = now + REPEAT[target][0]
	elif target != "" and now >= _repeat_at:
		_repeat_at = now + REPEAT[target][1]
		on_press.call(target)


func _source_of(e: InputEvent) -> String:
	if e is InputEventJoypadButton:
		return "b%d:%d" % [e.device, e.button_index]
	if e is InputEventKey:
		return "k%d" % (e.physical_keycode if e.physical_keycode != KEY_NONE else e.keycode)
	return ""


# the D-pad starts a direction only from rest, so a diagonal or a rolled thumb gives one press
func _dpad(e: InputEventJoypadButton) -> String:
	var src := "d%d" % e.device
	var down: Dictionary = _dpads.get_or_add(e.device, {})
	var action := action_of(e)
	if not e.pressed:
		down.erase(action)
		if _held(src) == action:
			_up(src)
		return ""
	var from_rest := down.is_empty()
	down[action] = true
	return _down(src, action) if from_rest else ""


# a stick holds its strongest direction until that direction falls below RELEASE
func _settle(src: String, pulls: Dictionary, on_press: Callable) -> void:
	var held := _held(src)
	if held != "":
		if pulls[held] >= RELEASE:
			return
		_up(src)
	var best: String = pulls.keys()[0]
	for action: String in pulls:
		if pulls[action] > pulls[best]:
			best = action
	if pulls[best] < RELEASE:
		_armed[src] = true
	elif pulls[best] >= ENGAGE and _armed.get(src, true):
		_armed[src] = false
		var pressed := _down(src, best)
		if pressed != "":
			on_press.call(pressed)


# an action presses only when its first source goes down, so two pads pressing A open once
func _down(src: String, action: String) -> String:
	var held_elsewhere := action in _live.values()
	_live[src] = action
	if action == "" or held_elsewhere:
		return ""
	if REPEAT.has(action):
		_repeat = action
		_repeat_at = _clock + REPEAT[action][0]
	return action


func _held(src: String) -> String:
	return _live.get(src, _stale.get(src, ""))


func _up(src: String) -> void:
	_live.erase(src)
	_stale.erase(src)


# the newest held direction repeats, so letting go of a second direction hands back to the first
func _repeat_target() -> String:
	var target := ""
	for action: String in _live.values():
		if REPEAT.has(action):
			target = action
	return target
