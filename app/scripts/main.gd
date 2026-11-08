extends Control

enum Mode { FILES, PLACES, MENU, KEYBOARD, CONFIRM }

const VISIBLE_ROWS := 12
const ROW_HEIGHT := 50
const REPEAT_DELAY := 0.35
const REPEAT_RATE := 0.06

var start_path := ""
var core := JoyCore.new()
var mode := Mode.FILES
var cwd := ""
var entries: Array = []
var cursor := 0
var top := 0
var selected := {}
var clipboard := {"move": false, "paths": PackedStringArray()}
var show_hidden := false
var places: Array = []
var place_cursor := 0
var menu_items: Array = []
var menu_cursor := 0
var jobs := {}
var last_error := ""

var _handlers := {}
var _down := {}
var _held := ""
var _repeat_at := 0.0
var _clock := 0.0
var _on_submit: Callable
var _on_confirm: Callable
var _toast_until := 0.0

var _path_label: Label
var _count_label: Label
var _rows: Array[PanelContainer] = []
var _places_box: VBoxContainer
var _status: Label
var _hints: Control
var _footer: HBoxContainer
var _overlay: CenterContainer
var _dim: ColorRect
var _menu_panel: PanelContainer
var _menu_box: VBoxContainer
var _confirm_panel: PanelContainer
var _confirm_label: Label
var _keyboard: JoyKeyboard


func _ready() -> void:
	JoyInput.install()
	_build_ui()
	_handlers = {
		Mode.FILES: _files_action,
		Mode.PLACES: _places_action,
		Mode.MENU: _menu_action,
		Mode.KEYBOARD: _keyboard.handle,
		Mode.CONFIRM: _confirm_action,
	}
	places = core.places()
	var arg_path := _arg_path()
	navigate(arg_path if arg_path != "" else (start_path if start_path != "" else places[0]["path"]))
	_render()


func _arg_path() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--path="):
			return arg.trim_prefix("--path=")
	return ""


# input

func _unhandled_input(event: InputEvent) -> void:
	if mode == Mode.KEYBOARD and event is InputEventKey and event.pressed:
		_keyboard.handle_key(event)
		get_viewport().set_input_as_handled()
		return
	for action: String in JoyInput.ACTIONS:
		if event.is_action_pressed(action) and not _down.has(action):
			_down[action] = true
			_held = action if action in JoyInput.REPEATING else ""
			_repeat_at = _clock + REPEAT_DELAY
			fire(action)
			get_viewport().set_input_as_handled()
			return


func _process(delta: float) -> void:
	_clock += delta
	for action: String in _down.keys():
		if not Input.is_action_pressed(action):
			_down.erase(action)
	if _held != "" and _down.has(_held) and _clock >= _repeat_at:
		_repeat_at = _clock + REPEAT_RATE
		fire(_held)
	_poll_jobs()
	if _toast_until > 0.0 and _clock > _toast_until:
		_toast_until = 0.0
		_render_status()


func fire(action: String) -> void:
	_handlers[mode].call(action)
	_render()


# mode handlers

func _files_action(action: String) -> void:
	match action:
		"jf_up": _move(-1)
		"jf_down": _move(1)
		"jf_page_up": _move(-VISIBLE_ROWS)
		"jf_page_down": _move(VISIBLE_ROWS)
		"jf_accept", "jf_right": _open_current()
		"jf_back": go_up()
		"jf_left", "jf_pane": mode = Mode.PLACES
		"jf_select": _toggle_select()
		"jf_menu": _open_menu(_file_menu())
		"jf_start": _open_menu(_app_menu())
		"jf_view": _toggle_hidden()


func _places_action(action: String) -> void:
	match action:
		"jf_up": place_cursor = posmod(place_cursor - 1, places.size())
		"jf_down": place_cursor = posmod(place_cursor + 1, places.size())
		"jf_accept", "jf_right":
			navigate(places[place_cursor]["path"])
			mode = Mode.FILES
		"jf_back", "jf_pane": mode = Mode.FILES
		"jf_start": _open_menu(_app_menu())


func _menu_action(action: String) -> void:
	match action:
		"jf_up": menu_cursor = posmod(menu_cursor - 1, menu_items.size())
		"jf_down": menu_cursor = posmod(menu_cursor + 1, menu_items.size())
		"jf_back", "jf_menu", "jf_start": mode = Mode.FILES
		"jf_accept":
			mode = Mode.FILES
			menu_items[menu_cursor][1].call()


func _confirm_action(action: String) -> void:
	match action:
		"jf_accept":
			mode = Mode.FILES
			_on_confirm.call()
		"jf_back":
			mode = Mode.FILES


# navigation

func navigate(path: String, focus_name := "") -> void:
	var result: Dictionary = core.list_dir(path, show_hidden, "name", false)
	if not result["ok"]:
		toast(result["error"], true)
		return
	cwd = path
	entries = result["entries"]
	selected.clear()
	cursor = 0
	for i in entries.size():
		if entries[i]["name"] == focus_name:
			cursor = i
	top = 0
	_clamp_view()


func refresh() -> void:
	var keep: String = entries[cursor]["name"] if not entries.is_empty() else ""
	var keep_selected := selected.duplicate()
	navigate(cwd, keep)
	for path: String in keep_selected:
		if entries.any(func(e): return e["path"] == path):
			selected[path] = true


func go_up() -> void:
	var parent: String = core.parent_dir(cwd)
	if parent != "":
		navigate(parent, cwd.get_file() if cwd.get_file() != "" else cwd)


func _move(step: int) -> void:
	if entries.is_empty():
		return
	cursor = clampi(cursor + step, 0, entries.size() - 1)
	_clamp_view()


func _clamp_view() -> void:
	if cursor < top:
		top = cursor
	elif cursor >= top + VISIBLE_ROWS:
		top = cursor - VISIBLE_ROWS + 1


func _open_current() -> void:
	if entries.is_empty():
		return
	var e: Dictionary = entries[cursor]
	if e["is_dir"]:
		navigate(e["path"])
	else:
		OS.shell_open(e["path"])
		toast("Opened %s in the default app." % e["name"])


func _toggle_select() -> void:
	if entries.is_empty():
		return
	var path: String = entries[cursor]["path"]
	if selected.has(path):
		selected.erase(path)
	else:
		selected[path] = true
	_move(1)


func _toggle_hidden() -> void:
	show_hidden = not show_hidden
	refresh()
	toast("Hidden files are shown." if show_hidden else "Hidden files are not shown.")


func targets() -> PackedStringArray:
	if not selected.is_empty():
		return PackedStringArray(selected.keys())
	if entries.is_empty():
		return PackedStringArray()
	return PackedStringArray([entries[cursor]["path"]])


# menus and operations

func _file_menu() -> Array:
	var t := targets()
	var items: Array = []
	if not t.is_empty():
		items.append(["Copy (%d)" % t.size(), func(): _set_clipboard(t, false)])
		items.append(["Cut (%d)" % t.size(), func(): _set_clipboard(t, true)])
	if not clipboard["paths"].is_empty():
		items.append(["Paste %d here" % clipboard["paths"].size(), paste])
	if t.size() == 1:
		items.append(["Rename", func(): _ask_rename(t[0])])
	items.append(["New folder", _ask_new_folder])
	if not t.is_empty():
		items.append(["Move to trash (%d)" % t.size(), func(): _ask_trash(t)])
	if selected.is_empty():
		items.append(["Select all", select_all])
	else:
		items.append(["Clear selection", func(): selected.clear()])
	return items


func select_all() -> void:
	for e: Dictionary in entries:
		selected[e["path"]] = true


func _app_menu() -> Array:
	return [
		["Hide hidden files" if show_hidden else "Show hidden files", _toggle_hidden],
		["Refresh", refresh],
		["Quit Joyfiles", func(): get_tree().quit()],
	]


func _open_menu(items: Array) -> void:
	menu_items = items
	menu_cursor = 0
	mode = Mode.MENU


func _set_clipboard(paths: PackedStringArray, is_move: bool) -> void:
	clipboard = {"move": is_move, "paths": paths}
	selected.clear()
	toast("%d item(s) ready to %s. Open a folder and pick Paste." % [paths.size(), "move" if is_move else "copy"])


func paste() -> void:
	var id: int = core.start_job(clipboard["move"], clipboard["paths"], cwd)
	jobs[id] = {"dest": cwd}
	if clipboard["move"]:
		clipboard = {"move": false, "paths": PackedStringArray()}


func _ask_rename(path: String) -> void:
	_ask_text("Rename", path.get_file(), func(new_name: String):
		var r: Dictionary = core.rename(path, new_name)
		if r["ok"]:
			navigate(cwd, r["path"].get_file())
		else:
			toast(r["error"], true))


func _ask_new_folder() -> void:
	_ask_text("New folder name", "", func(new_name: String):
		var r: Dictionary = core.make_dir(cwd, new_name)
		if r["ok"]:
			navigate(cwd, r["path"].get_file())
		else:
			toast(r["error"], true))


func _ask_trash(paths: PackedStringArray) -> void:
	var what: String = paths[0].get_file() if paths.size() == 1 else "%d items" % paths.size()
	_confirm_label.text = "Move %s to the trash?" % what
	_on_confirm = func():
		var r: Dictionary = core.trash(paths)
		if r["ok"]:
			toast("Moved %s to the trash." % what)
		else:
			toast(r["error"], true)
		refresh()
	mode = Mode.CONFIRM


func _ask_text(title: String, initial: String, on_submit: Callable) -> void:
	_on_submit = on_submit
	_keyboard.open(title, initial)
	mode = Mode.KEYBOARD


func _on_keyboard_submitted(text: String) -> void:
	mode = Mode.FILES
	_on_submit.call(text)
	_render()


func _on_keyboard_cancelled() -> void:
	mode = Mode.FILES
	_render()


func _poll_jobs() -> void:
	if jobs.is_empty():
		return
	for job: Dictionary in core.poll_jobs():
		var id: int = job["id"]
		jobs[id].merge(job, true)
		match job["state"]:
			"done":
				toast("Finished: %s." % job["current"])
			"failed":
				toast(job["error"], true)
			"cancelled":
				toast("The job was cancelled.")
		if job["state"] != "running":
			if jobs[id]["dest"] == cwd:
				refresh()
			jobs.erase(id)
	_render_status()


func toast(text: String, is_error := false) -> void:
	last_error = text if is_error else ""
	_status.text = text
	_status.add_theme_color_override("font_color", Theme_.DANGER if is_error else Theme_.TEXT)
	_toast_until = _clock + 4.0


# rendering

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Theme_.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 0, 16))
	var header_row := HBoxContainer.new()
	header.add_child(header_row)
	_path_label = Theme_.label("", Theme_.TEXT, 26, true)
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(_path_label)
	_count_label = Theme_.label("", Theme_.MUTED, 22)
	header_row.add_child(_count_label)
	root.add_child(header)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	var side := PanelContainer.new()
	side.custom_minimum_size.x = 280
	side.add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL.darkened(0.15), 0, 8))
	_places_box = VBoxContainer.new()
	side.add_child(_places_box)
	body.add_child(side)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	body.add_child(list)
	for i in VISIBLE_ROWS:
		var row := PanelContainer.new()
		row.custom_minimum_size.y = ROW_HEIGHT
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 14)
		row.add_child(hb)
		hb.add_child(Theme_.label("", Theme_.ACCENT, 22))
		var name_label := Theme_.label("", Theme_.TEXT, 24, true)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(name_label)
		hb.add_child(Theme_.label("", Theme_.MUTED, 20))
		list.add_child(row)
		_rows.append(row)

	_footer = HBoxContainer.new()
	var footer_panel := PanelContainer.new()
	footer_panel.add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 0, 12))
	footer_panel.add_child(_footer)
	root.add_child(footer_panel)
	_status = Theme_.label("", Theme_.TEXT, 20, true)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_footer.add_child(_status)

	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)
	_overlay = CenterContainer.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	_menu_panel = PanelContainer.new()
	_menu_panel.custom_minimum_size.x = 460
	_menu_panel.add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 16))
	_menu_box = VBoxContainer.new()
	_menu_panel.add_child(_menu_box)
	_overlay.add_child(_menu_panel)
	_confirm_panel = PanelContainer.new()
	_confirm_panel.add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 24))
	var confirm_box := VBoxContainer.new()
	confirm_box.add_theme_constant_override("separation", 20)
	_confirm_panel.add_child(confirm_box)
	_confirm_label = Theme_.label("", Theme_.TEXT, 26)
	confirm_box.add_child(_confirm_label)
	confirm_box.add_child(Theme_.hints([["A", "Yes"], ["B", "No"]]))
	_overlay.add_child(_confirm_panel)
	_keyboard = JoyKeyboard.new()
	_keyboard.submitted.connect(_on_keyboard_submitted)
	_keyboard.cancelled.connect(_on_keyboard_cancelled)
	_overlay.add_child(_keyboard)


func _render() -> void:
	var home: String = places[0]["path"]
	_path_label.text = ("~" + cwd.trim_prefix(home)) if cwd.begins_with(home) else cwd
	_count_label.text = "%d / %d" % [cursor + 1 if not entries.is_empty() else 0, entries.size()]
	for i in VISIBLE_ROWS:
		var row := _rows[i]
		var idx := top + i
		var labels := row.get_child(0).get_children()
		if idx >= entries.size():
			row.add_theme_stylebox_override("panel", Theme_.box(Color.TRANSPARENT, 0, 8))
			for l: Label in labels:
				l.text = ""
			if idx == 0:
				labels[1].text = "This folder is empty."
				labels[1].add_theme_color_override("font_color", Theme_.MUTED)
			continue
		var e: Dictionary = entries[idx]
		var is_cursor: bool = idx == cursor and mode != Mode.PLACES
		var is_selected: bool = selected.has(e["path"])
		var bg := Theme_.ACCENT if is_cursor else (Theme_.ROW_SEL if is_selected else Color.TRANSPARENT)
		row.add_theme_stylebox_override("panel", Theme_.box(bg, 8, 8))
		labels[0].text = ("✓" if is_selected else "") + ("▰" if e["is_dir"] else "▫")
		labels[0].add_theme_color_override("font_color", Theme_.FOLDER if e["is_dir"] else Theme_.MUTED)
		labels[1].text = e["name"]
		labels[1].add_theme_color_override("font_color", Theme_.MUTED if e["hidden"] else Theme_.TEXT)
		labels[2].text = "" if e["is_dir"] else Theme_.human_size(e["size"])
	_render_places()
	_render_overlay()
	_render_hints()


func _render_places() -> void:
	for child in _places_box.get_children():
		child.queue_free()
	_places_box.add_child(Theme_.label("PLACES", Theme_.MUTED, 18))
	for i in places.size():
		var p: Dictionary = places[i]
		var l := Theme_.label(("◉ " if p["kind"] == "drive" else "• ") + p["label"], Theme_.TEXT, 22, true)
		var focused: bool = mode == Mode.PLACES and i == place_cursor
		var current: bool = cwd == p["path"]
		l.add_theme_stylebox_override("normal", Theme_.box(Theme_.ACCENT if focused else (Theme_.ROW_SEL if current else Color.TRANSPARENT), 8, 8))
		_places_box.add_child(l)


func _render_overlay() -> void:
	_dim.visible = mode in [Mode.MENU, Mode.CONFIRM, Mode.KEYBOARD]
	_menu_panel.visible = mode == Mode.MENU
	_confirm_panel.visible = mode == Mode.CONFIRM
	_keyboard.visible = mode == Mode.KEYBOARD
	if mode != Mode.MENU:
		return
	for child in _menu_box.get_children():
		child.queue_free()
	for i in menu_items.size():
		var l := Theme_.label(menu_items[i][0], Theme_.TEXT, 24)
		l.add_theme_stylebox_override("normal", Theme_.box(Theme_.ACCENT if i == menu_cursor else Color.TRANSPARENT, 8, 10))
		_menu_box.add_child(l)


const HINTS := {
	Mode.FILES: [["A", "Open"], ["B", "Up"], ["X", "Actions"], ["Y", "Select"], ["LB", "Places"], ["Start", "Menu"]],
	Mode.PLACES: [["A", "Go"], ["B", "Back"], ["Start", "Menu"]],
	Mode.MENU: [["A", "Choose"], ["B", "Close"]],
	Mode.KEYBOARD: [],
	Mode.CONFIRM: [["A", "Yes"], ["B", "No"]],
}


func _render_hints() -> void:
	if _hints:
		_hints.queue_free()
	_hints = Theme_.hints(HINTS[mode])
	_footer.add_child(_hints)


func _render_status() -> void:
	if _toast_until > 0.0:
		return
	var running := jobs.values().filter(func(j): return j.get("state", "running") == "running")
	if running.is_empty():
		_status.text = ""
		return
	var j: Dictionary = running[0]
	var pct: int = 0 if j.get("total_bytes", 0) == 0 else int(100.0 * j["done_bytes"] / j["total_bytes"])
	_status.add_theme_color_override("font_color", Theme_.TEXT)
	_status.text = "%s %s  %d%%" % ["Moving" if j.get("kind") == "move" else "Copying", j.get("current", ""), pct]
