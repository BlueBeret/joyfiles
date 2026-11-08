class_name JoyKeyboard
extends PanelContainer

signal submitted(text: String)
signal changed(text: String)
signal cancelled

const ROWS := [
	["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
	["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
	["a", "s", "d", "f", "g", "h", "j", "k", "l", "-"],
	["z", "x", "c", "v", "b", "n", "m", "_", ".", ","],
	["{shift}", "{space}", "{del}", "{cancel}", "{done}"],
]
const LABELS := {"{shift}": "Shift", "{space}": "Space", "{del}": "Delete", "{cancel}": "Cancel", "{done}": "Done"}
# control and format characters, which a name must not carry because some of them, like U+202E, disguise it
const UNTYPABLE := [
	[0x00, 0x1F], [0x7F, 0x9F], [0xAD, 0xAD], [0x0600, 0x0605], [0x061C, 0x061C], [0x06DD, 0x06DD],
	[0x070F, 0x070F], [0x180E, 0x180E], [0x200B, 0x200F], [0x2028, 0x202E], [0x2060, 0x206F],
	[0xFEFF, 0xFEFF], [0xFFF9, 0xFFFB], [0xE0001, 0xE007F],
]
# the panel keeps this width, and the text field shows the end of a long text
const WIDTH := 780

var text := ""
var shift := false
var row := 1
var col := 0
var commands: Array = []
var _title: Label
var _field: JoyFitLabel
var _grid: VBoxContainer


func _init() -> void:
	commands = [
		["jf_accept", "Type", func() -> void: _press(ROWS[row][_col()])],
		["jf_back", "Delete", _press.bind("{del}")],
		["jf_select", "Shift", _press.bind("{shift}")],
		["jf_menu", "Space", _press.bind("{space}")],
		["jf_start", "Done", _press.bind("{done}")],
		["jf_view", "Cancel", _press.bind("{cancel}")],
		["jf_up", "", func() -> void: row = posmod(row - 1, ROWS.size())],
		["jf_down", "", func() -> void: row = posmod(row + 1, ROWS.size())],
		["jf_left", "", func() -> void: col -= 1],
		["jf_right", "", func() -> void: col += 1],
	]
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.custom_minimum_size.x = WIDTH
	add_child(box)
	_title = Theme_.label("", Theme_.TEXT, Theme_.SIZE_TITLE)
	box.add_child(_title)
	_field = Theme_.fit("", Theme_.TEXT, Theme_.SIZE_FIELD, JoyFitLabel.Cut.START)
	_field.add_theme_stylebox_override("normal", Theme_.box(Theme_.BG, 8))
	box.add_child(_field)
	_grid = VBoxContainer.new()
	box.add_child(_grid)
	box.add_child(Theme_.hints(JoyCommands.hints(commands)))
	add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 24))


func open(title: String, initial: String) -> void:
	_title.text = title
	text = initial
	shift = false
	row = 1
	col = 0
	_render()


func set_title(title: String) -> void:
	_title.text = title


func handle(action: String) -> void:
	JoyCommands.run(action, commands)
	col = posmod(col, ROWS[row].size())
	_render()


func handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER: _press("{done}")
		KEY_ESCAPE: _press("{cancel}")
		KEY_BACKSPACE: _press("{del}")
		_:
			if typable(event.unicode):
				text += char(event.unicode)
				shift = false
				changed.emit(text)
	_render()


static func typable(code: int) -> bool:
	return code > 0 and not UNTYPABLE.any(func(r: Array) -> bool: return code >= r[0] and code <= r[1])


func _col() -> int:
	return clampi(col, 0, ROWS[row].size() - 1)


func _press(key: String) -> void:
	var before := text
	match key:
		"{shift}": shift = not shift
		"{space}": text += " "
		"{del}": text = text.left(-1)
		"{cancel}": cancelled.emit()
		"{done}": submitted.emit(text)
		_:
			text += key.to_upper() if shift else key
			shift = false
	if text != before:
		changed.emit(text)


func _render() -> void:
	_field.set_full(text + "|")
	for child in _grid.get_children():
		child.queue_free()
	for r in ROWS.size():
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		_grid.add_child(line)
		for c in ROWS[r].size():
			var key: String = ROWS[r][c]
			var cap := Label.new()
			cap.text = LABELS.get(key, key.to_upper() if shift else key)
			cap.add_theme_font_size_override("font_size", Theme_.SIZE_LIST)
			cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cap.custom_minimum_size = Vector2(150 if LABELS.has(key) else 64, 56)
			cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			var focused: bool = r == row and c == _col()
			var active: bool = key == "{shift}" and shift
			cap.add_theme_stylebox_override("normal", Theme_.focus_box(focused, Theme_.ROW_SEL if active else Theme_.BG, 8, 8, 8))
			line.add_child(cap)
