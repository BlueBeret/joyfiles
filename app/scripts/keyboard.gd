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

var text := ""
var shift := false
var row := 1
var col := 0
var _title: Label
var _field: Label
var _grid: VBoxContainer


func _init() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	add_child(box)
	_title = Label.new()
	box.add_child(_title)
	_field = Label.new()
	_field.add_theme_font_size_override("font_size", 32)
	_field.add_theme_stylebox_override("normal", Theme_.box(Theme_.BG, 8))
	box.add_child(_field)
	_grid = VBoxContainer.new()
	box.add_child(_grid)
	box.add_child(Theme_.hints([["jf_accept", "Type"], ["jf_back", "Delete"], ["jf_select", "Shift"], ["jf_menu", "Space"], ["jf_start", "Done"], ["jf_view", "Cancel"]]))
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
	match action:
		"jf_up": row = posmod(row - 1, ROWS.size())
		"jf_down": row = posmod(row + 1, ROWS.size())
		"jf_left": col -= 1
		"jf_right": col += 1
		"jf_accept": _press(ROWS[row][_col()])
		"jf_back": _press("{del}")
		"jf_select": _press("{shift}")
		"jf_menu": _press("{space}")
		"jf_start": _press("{done}")
		"jf_view": _press("{cancel}")
	col = posmod(col, ROWS[row].size())
	_render()


func handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER: _press("{done}")
		KEY_ESCAPE: _press("{cancel}")
		KEY_BACKSPACE: _press("{del}")
		_:
			if event.unicode >= 32:
				text += char(event.unicode)
				changed.emit(text)
	_render()


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
	_field.text = text + "|"
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
			cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cap.custom_minimum_size = Vector2(150 if LABELS.has(key) else 64, 56)
			cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			var focused: bool = r == row and c == _col()
			var active: bool = key == "{shift}" and shift
			cap.add_theme_stylebox_override("normal", Theme_.box(Theme_.ACCENT if focused else (Theme_.ROW_SEL if active else Theme_.BG), 8))
			line.add_child(cap)
