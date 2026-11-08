class_name JoyProps
extends PanelContainer

signal closed

const FIELDS := ["Name", "Path", "Type", "Size", "Modified", "Contains"]

# one text per field, so the labels and the tests read the same data
var shown := {}
var scan_done := true
var _core: JoyCore
var _scan := -1
var _labels := {}
var _grid: GridContainer
var _title: Label


func _init() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	add_child(box)
	_title = Theme_.label("Properties", Theme_.TEXT, 28)
	box.add_child(_title)
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 24)
	_grid.add_theme_constant_override("v_separation", 10)
	box.add_child(_grid)
	for field: String in FIELDS:
		_grid.add_child(Theme_.label(field, Theme_.MUTED, 22))
		var value := Theme_.label("", Theme_.TEXT, 22)
		value.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		value.custom_minimum_size.x = 560
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_grid.add_child(value)
		_labels[field] = value
	box.add_child(Theme_.hints([["B", "Close"]]))
	add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 24))


func open(core: JoyCore, path: String) -> void:
	close()
	_core = core
	shown.clear()
	var info: Dictionary = core.props(path)
	if not info["ok"]:
		_put("Name", path.get_file())
		_put("Path", path)
		_put("Type", "Unknown")
		_put("Size", info["error"])
		_put("Modified", "")
		_put("Contains", "")
		return
	_put("Name", info["name"])
	_put("Path", info["path"])
	_put("Type", info["type"] + (" (link)" if info["is_symlink"] else ""))
	_put("Modified", Theme_.human_date(info["modified"]))
	if info["is_dir"]:
		_put("Contains", Theme_.count(info["items"], "item"))
		_put("Size", "Calculating...")
		scan_done = false
		_scan = core.start_size_scan(path)
	else:
		_put("Contains", "")
		_put("Size", _exact_size(info["size"]))
	_show_rows()


func handle(action: String) -> void:
	match action:
		"jf_back", "jf_accept", "jf_menu": closed.emit()


func poll() -> void:
	if _scan < 0:
		return
	var s: Dictionary = _core.poll_size_scan(_scan)
	var text := "%s (%s, %s)" % [Theme_.human_size(s["bytes"]), Theme_.count(s["files"], "file"), Theme_.count(s["folders"], "folder")]
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


func _exact_size(bytes: int) -> String:
	if bytes < 1024:
		return "%s B" % Theme_.with_commas(bytes)
	return "%s (%s bytes)" % [Theme_.human_size(bytes), Theme_.with_commas(bytes)]


func _put(field: String, text: String) -> void:
	shown[field] = text
	_labels[field].text = text
	_show_rows()


func _show_rows() -> void:
	var folder_fields: bool = shown.get("Contains", "") != ""
	_labels["Contains"].visible = folder_fields
	_grid.get_child(FIELDS.find("Contains") * 2).visible = folder_fields
