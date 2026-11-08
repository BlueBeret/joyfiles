class_name JoyConflict
extends PanelContainer

signal answered(choice: String, apply_all: bool)
signal cancelled

# label and the answer word that core.answer_conflict expects
const CHOICES := [["Replace", "replace"], ["Keep both", "keep_both"], ["Skip", "skip"]]

var apply_all := false
var cursor := 1
var conflict := {}
var commands: Array = []
var _title: Label
var _existing: Label
var _incoming: Label
var _rows: Array[Label] = []


func _init() -> void:
	commands = [
		["jf_accept", "Choose", _choose],
		["jf_select", "Apply to all", func() -> void: apply_all = not apply_all],
		["jf_back", "Cancel job", func() -> void: cancelled.emit()],
		["jf_up", "", func() -> void: cursor = posmod(cursor - 1, _rows.size())],
		["jf_down", "", func() -> void: cursor = posmod(cursor + 1, _rows.size())],
	]
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size.x = 640
	add_child(box)
	_title = Theme_.label("", Theme_.TEXT, 26)
	_title.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_title)
	_existing = Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	box.add_child(_existing)
	_incoming = Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	box.add_child(_incoming)
	var list := VBoxContainer.new()
	box.add_child(list)
	for i in CHOICES.size() + 1:
		var row := Theme_.label("", Theme_.TEXT, 24)
		list.add_child(row)
		_rows.append(row)
	box.add_child(Theme_.hints(JoyCommands.hints(commands)))
	add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 24))


func open(info: Dictionary) -> void:
	conflict = info
	apply_all = false
	cursor = 1
	_title.text = "\"%s\" already exists here." % info["name"]
	_existing.text = "In this folder: " + _describe(info["dest_is_dir"], info["dest_size"], info["dest_modified"])
	_incoming.text = "Coming in: " + _describe(info["src_is_dir"], info["src_size"], info["src_modified"])
	_render()


func handle(action: String) -> void:
	JoyCommands.run(action, commands)
	_render()


func _choose() -> void:
	if cursor == CHOICES.size():
		apply_all = not apply_all
	else:
		answered.emit(CHOICES[cursor][1], apply_all)


func _describe(is_dir: bool, size: int, modified: int) -> String:
	var what := "Folder" if is_dir else Theme_.human_size(size)
	return "%s, changed %s" % [what, Theme_.human_date(modified)] if modified > 0 else "%s, change date unknown" % what


func _render() -> void:
	for i in _rows.size():
		var text: String = CHOICES[i][0] if i < CHOICES.size() else "[%s] Do this for all other clashes" % ("x" if apply_all else " ")
		_rows[i].text = text
		_rows[i].add_theme_stylebox_override("normal", Theme_.focus_box(i == cursor))
