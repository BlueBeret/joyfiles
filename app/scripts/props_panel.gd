class_name JoyProps
extends PanelContainer

signal closed

const FIELDS := ["Name", "Path", "Type", "Size", "Modified", "Contains", "Error"]
# the values scroll past this height, so the title and the hints always fit in an 800 pixel window
const SCROLL_MAX_HEIGHT := 500.0
const SCROLL_STEP := 72

# one text per field, so the labels and the tests read the same data
var shown := {}
var scan_done := true
var commands: Array = []
var _core: JoyCore
var _scan := -1
var _labels := {}
var _grid: GridContainer
var _scroll: JoyScrollBox
var _title: Label
var _hints_box: VBoxContainer


func _init() -> void:
	var close := func() -> void: closed.emit()
	var overflows := func() -> bool: return _scroll.is_scrollable()
	commands = [
		["jf_up", "Scroll", func() -> void: _scroll.scroll_vertical -= SCROLL_STEP, overflows],
		["jf_down", "", func() -> void: _scroll.scroll_vertical += SCROLL_STEP, overflows],
		["jf_page_up", "", func() -> void: _scroll.scroll_vertical -= int(_scroll.size.y), overflows],
		["jf_page_down", "", func() -> void: _scroll.scroll_vertical += int(_scroll.size.y), overflows],
		["jf_back", "Close", close],
		["jf_accept", "", close],
		["jf_menu", "", close],
	]
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	add_child(box)
	_title = Theme_.label("Properties", Theme_.TEXT, Theme_.SIZE_HEAD)
	box.add_child(_title)
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 24)
	_grid.add_theme_constant_override("v_separation", 10)
	_scroll = JoyScrollBox.new(_grid, SCROLL_MAX_HEIGHT)
	box.add_child(_scroll)
	for field: String in FIELDS:
		_grid.add_child(Theme_.label(field, Theme_.MUTED, Theme_.SIZE_BODY))
		var value := Theme_.label("", Theme_.TEXT, Theme_.SIZE_BODY)
		value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		value.custom_minimum_size.x = 560
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_grid.add_child(value)
		_labels[field] = value
	_hints_box = VBoxContainer.new()
	box.add_child(_hints_box)
	add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 24))
	_set_hints()


# hidden_note tells the user that the count includes the items that the list hides
func open(core: JoyCore, path: String, hidden_note := false) -> void:
	close()
	_core = core
	shown.clear()
	_scroll.scroll_vertical = 0
	var info: Dictionary = core.props(path)
	if not info["ok"]:
		_put("Name", JoyPathText.printable(path.get_file()))
		_put("Path", JoyPathText.printable(path))
		_put("Type", "Unknown")
		_put("Error", info["error"])
		return
	_put("Name", JoyPathText.printable(info["name"]))
	_put("Path", JoyPathText.printable(info["path"]))
	_put("Type", info["type"] + (" (link)" if info["is_symlink"] else ""))
	_put("Modified", Theme_.human_date(info["modified"]))
	if info["is_dir"] and info["items"] < 0:
		var unknown := _unknown(info["items_error"])
		_put("Contains", unknown)
		_put("Size", unknown)
	elif info["is_dir"]:
		_put("Contains", Theme_.count(info["items"], "item") + (" (hidden items included)" if hidden_note else ""))
		_put("Size", "Calculating...")
		scan_done = false
		_scan = core.start_size_scan(path)
	else:
		_put("Contains", "")
		_put("Size", _exact_size(info["size"]))
	_show_rows()


func handle(action: String) -> void:
	JoyCommands.run(action, commands)


func _set_hints() -> void:
	Theme_.update_hints(_hints_box, JoyCommands.hints(commands))


func poll() -> void:
	_set_hints()
	if _scan < 0:
		return
	var s: Dictionary = _core.poll_size_scan(_scan)
	var text := "%s (%s, %s)" % [Theme_.human_size(s["bytes"]), Theme_.count(s["files"], "file"), Theme_.count(s["folders"], "folder")]
	if s.get("skipped", 0) > 0:
		text += ", %s could not be read" % Theme_.count(s["skipped"], "item")
	if s["done"]:
		_scan = -1
		scan_done = true
		_put("Size", text)
	else:
		_put("Size", "Calculating... " + text)


func close() -> void:
	if _scan >= 0:
		_core.cancel_size_scan(_scan)
		_scan = -1
	scan_done = true


func _unknown(reason: String) -> String:
	return "Unknown (%s)" % reason if reason != "" else "Unknown"


func _exact_size(bytes: int) -> String:
	if bytes < 1024:
		return "%s B" % Theme_.with_commas(bytes)
	return "%s (%s bytes)" % [Theme_.human_size(bytes), Theme_.with_commas(bytes)]


func _put(field: String, text: String) -> void:
	shown[field] = JoyPathText.printable(text)
	_labels[field].text = shown[field]
	_show_rows()


func _show_rows() -> void:
	for field: String in FIELDS:
		var filled: bool = shown.get(field, "") != ""
		_labels[field].visible = filled
		_grid.get_child(FIELDS.find(field) * 2).visible = filled
