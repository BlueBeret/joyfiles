extends Control

enum Mode { FILES, PLACES, MENU, KEYBOARD, CONFIRM, CONFLICT, JOBS, PROPS, PREVIEW }

const INITIAL_ROWS := 12
const MIN_ROWS := 6
const MAX_ROWS := 40
const ROW_HEIGHT := 50
const ROW_GAP := 2
const SIDE_WIDTH := 280
const CONFIRM_WIDTH := 640
const THUMB_BOX := 42
const THUMB_MIN_SIDE := 3.0
const MARK_WIDTH := 30
const FILTER_MAX_WIDTH := 380.0
const TOAST_FONT := 22
const TOAST_MAX_WIDTH := 880.0
const TOAST_LIFT := 20
const TOAST_QUEUE_MAX := 4
const QUEUED_TOAST_SECONDS := 2.5
const PLACES_REFRESH_SECONDS := 3.0
# a clash prompt never cuts into a menu, a keyboard or a confirm that the user is using
const PROMPT_MODES := [Mode.FILES, Mode.PLACES]
# a press this soon after a screen change was aimed at the old screen, and only time tells a double tap apart
const GUARD_SECONDS := 0.15
# on the keyboard, these keys end or undo the work, so the guard holds them back while a letter still types
const GUARDED_KEYS := [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE, KEY_BACKSPACE]
# these panels draw their own hint row, so the footer does not repeat it
const PANEL_HINT_MODES := [Mode.KEYBOARD, Mode.CONFIRM, Mode.CONFLICT, Mode.JOBS, Mode.PROPS, Mode.PREVIEW]

var start_path := ""
var settings_path := "user://settings.cfg"
var opener := Callable()
var places_source := Callable()
var quitter := Callable()
var core := JoyCore.new()
var settings: JoySettings
var thumbs := JoyThumbs.new()
var mode := Mode.FILES
var cwd := ""
var all_entries: Array = []
var entries: Array = []
var filter := ""
var cursor := 0
var top := 0
var visible_rows := INITIAL_ROWS
var selected := {}
var clipboard := {"move": false, "paths": PackedStringArray()}
var places: Array = []
var place_cursor := 0
var menu_items: Array = []
var menu_cursor := 0
var jobs := {}
# one entry per ended operation that left failed items, kept until the user dismisses it
var reports := {}
var last_error := ""
# the start folder and the home folder both failed to list, so the screen names home and says so
var _unreadable := false
var conflict_panel: JoyConflict
var jobs_panel: JoyJobs
var props_panel: JoyProps
var preview: JoyPreview
var pad := JoyInput.new()

var _handlers := {}
# one command table per mode, read by both the handler and the hints, so the two cannot drift
var _commands := {}
var _panels := {}
var _overlay_renderers := {}
var _clock := 0.0
var _guard_until := 0.0
# the mode that each open modal returns to when it closes
var _return := {}
var _keyboard_title: Callable
var _only_hidden := false
var _on_submit: Callable
var _on_change: Callable
var _on_cancel: Callable
var _on_confirm: Callable
var _toast_until := 0.0
var _toast_error := false
var _toast_replay := false
# the toasts that came while a dialog was open, as [text, is_error], plus true for a toast that shows again
var _toast_queue: Array = []
var _places_shown: Array = []
var _places_at := 0.0
var _conflict_job := -1
var _report_seq := 0

var _path_label: JoyFitLabel
var _filter_label: JoyFitLabel
var _sort_label: Label
var _count_label: Label
var _rows: Array[PanelContainer] = []
var _row_parts: Array[Dictionary] = []
var _stage: Control
var _shell: VBoxContainer
var _list_host: Control
var _rows_box: VBoxContainer
var _places_scroll: JoyScrollBox
var _places_box: VBoxContainer
var _status: JoyFitLabel
var _status_tail: Label
var _toast_panel: PanelContainer
var _toast_label: Label
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
	theme = Theme_.theme()
	JoyInput.install()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	settings = JoySettings.new(settings_path)
	settings.load_file()
	if not opener.is_valid():
		opener = _shell_open
	if not places_source.is_valid():
		places_source = core.places
	if not quitter.is_valid():
		quitter = get_tree().quit
	_commands = _main_commands()
	_build_ui()
	_handlers = {
		Mode.KEYBOARD: _keyboard.handle,
		Mode.CONFLICT: conflict_panel.handle,
		Mode.JOBS: jobs_panel.handle,
		Mode.PROPS: props_panel.handle,
		Mode.PREVIEW: preview.handle,
	}
	for own_mode: int in _commands:
		var table: Array = _commands[own_mode]
		_handlers[own_mode] = func(action: String) -> void: JoyCommands.run(action, table)
	_commands.merge({
		Mode.KEYBOARD: _keyboard.commands,
		Mode.CONFLICT: conflict_panel.commands,
		Mode.JOBS: jobs_panel.commands,
		Mode.PROPS: props_panel.commands,
		Mode.PREVIEW: preview.commands,
	})
	_panels = {
		Mode.MENU: _menu_panel,
		Mode.CONFIRM: _confirm_panel,
		Mode.KEYBOARD: _keyboard,
		Mode.CONFLICT: conflict_panel,
		Mode.JOBS: jobs_panel,
		Mode.PROPS: props_panel,
		Mode.PREVIEW: preview,
	}
	_overlay_renderers = {
		Mode.MENU: _render_menu,
		Mode.JOBS: func(): jobs_panel.update(jobs, reports),
		Mode.PREVIEW: preview.refresh,
	}
	places = places_source.call()
	var no_places := places.is_empty()
	if no_places:
		places = [{"label": "Root", "path": "C:/" if OS.get_name() == "Windows" else "/", "kind": "folder"}]
	var arg_path := _arg_path()
	var home: String = places[0]["path"]
	if not navigate(arg_path if arg_path != "" else (start_path if start_path != "" else home)) and not navigate(home):
		cwd = home
		_unreadable = true
	_render()
	if no_places:
		toast("No home folder was found. Showing the root folder.", true)


func _arg_path() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--path="):
			return arg.trim_prefix("--path=")
	return ""


func _shell_open(path: String) -> int:
	return OS.shell_open(path)


# input

func _unhandled_input(event: InputEvent) -> void:
	if mode == Mode.KEYBOARD and event is InputEventKey:
		if event.pressed and _clock < _guard_until and JoyInput.key_of(event) in GUARDED_KEYS:
			get_viewport().set_input_as_handled()
			return
		if pad.typed(event):
			_keyboard.handle_key(event)
			_render()
		get_viewport().set_input_as_handled()
		return
	var action := pad.press(event)
	if action != "":
		get_viewport().set_input_as_handled()
		_on_press(action)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		pad.release_all()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		_ask_quit()
		_render()


func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	pad.release_all()


func _process(delta: float) -> void:
	_clock += delta
	pad.tick(_clock, _on_press)
	_poll_jobs()
	if _clock >= _places_at:
		refresh_places()
	if thumbs.poll():
		_render()
	if mode == Mode.PROPS:
		props_panel.poll()
	_sync_toast()


func _on_press(action: String) -> void:
	if _clock < _guard_until:
		pad.block()
		return
	fire(action)


# every screen change drops the held controls, so a press meant for the old screen cannot act on the new one
func _set_mode(next: int) -> void:
	if next == mode:
		return
	mode = next
	pad.block()
	_guard_until = _clock + GUARD_SECONDS


func _open(modal: int) -> void:
	_return[modal] = mode
	_set_mode(modal)


func _close() -> void:
	_set_mode(_return.get(mode, Mode.FILES))


func fire(action: String) -> void:
	_handlers[mode].call(action)
	_render()


# mode handlers

func _main_commands() -> Dictionary:
	var app_menu := func() -> void: _open_menu(_app_menu())
	var to_files := _set_mode.bind(Mode.FILES)
	return {
		Mode.FILES: [
			["jf_accept", "Open", _open_current, _has_entries],
			["jf_back", _back_label, _back, _can_back],
			["jf_menu", "Actions", func() -> void: _open_menu(_file_menu())],
			["jf_select", "Select", _toggle_select, _has_entries],
			["jf_pane", "Places", _open_places],
			["jf_start", "Menu", app_menu],
			["jf_jobs", _jobs_hint, _open_jobs],
			["jf_up", "", _move.bind(-1)],
			["jf_down", "", _move.bind(1)],
			["jf_page_up", "", func() -> void: _move(-visible_rows)],
			["jf_page_down", "", func() -> void: _move(visible_rows)],
			["jf_right", "", _open_current, _on_folder],
			["jf_left", "", _open_places],
			["jf_view", "", _toggle_hidden],
			["jf_search", "", _ask_filter],
		],
		Mode.PLACES: [
			["jf_accept", "Go", _go_place],
			["jf_back", "Back", to_files],
			["jf_start", "Menu", app_menu],
			["jf_jobs", _jobs_hint, _open_jobs],
			["jf_up", "", func() -> void: place_cursor = posmod(place_cursor - 1, places.size())],
			["jf_down", "", func() -> void: place_cursor = posmod(place_cursor + 1, places.size())],
			["jf_right", "", _go_place],
			["jf_pane", "", to_files],
		],
		Mode.MENU: [
			["jf_accept", "Choose", _choose_menu_item],
			["jf_back", "Close", _close],
			["jf_up", "", func() -> void: menu_cursor = posmod(menu_cursor - 1, menu_items.size())],
			["jf_down", "", func() -> void: menu_cursor = posmod(menu_cursor + 1, menu_items.size())],
			["jf_menu", "", _close],
			["jf_start", "", _close],
		],
		Mode.CONFIRM: [
			["jf_accept", "Yes", _confirm],
			["jf_back", "No", _close],
		],
	}


func _has_entries() -> bool:
	return not entries.is_empty()


# Right goes into folders only, so a push of the stick never launches an app
func _on_folder() -> bool:
	return _has_entries() and entries[cursor]["is_dir"]


func _back_label() -> String:
	return "Clear filter" if filter != "" else "Up"


func _can_back() -> bool:
	return filter != "" or core.parent_dir(cwd) != ""


func _jobs_hint() -> String:
	return "" if jobs.is_empty() and reports.is_empty() else "Jobs"


func _go_place() -> void:
	if navigate(places[place_cursor]["path"]):
		_set_mode(Mode.FILES)


func _choose_menu_item() -> void:
	var item: Callable = menu_items[menu_cursor][1]
	_close()
	item.call()


func _confirm() -> void:
	_close()
	_on_confirm.call()


# navigation

func _open_places() -> void:
	refresh_places()
	_set_mode(Mode.PLACES)


# a card can be mounted or removed at any time, so the list is read again on a timer
func refresh_places() -> void:
	_places_at = _clock + PLACES_REFRESH_SECONDS
	var fresh: Array = places_source.call()
	if fresh.is_empty() or fresh == places:
		return
	var focused: String = places[place_cursor]["path"] if place_cursor < places.size() else ""
	places = fresh
	place_cursor = 0
	for i in places.size():
		if places[i]["path"] == focused:
			place_cursor = i
	_render_places()


func _list(path: String, quiet := false) -> Variant:
	var result: Dictionary = core.list_dir(path, settings.show_hidden, settings.sort_key, settings.sort_desc)
	if not result["ok"]:
		if not quiet:
			toast(result["error"], true)
		return null
	var listed: Array = result["entries"]
	for e: Dictionary in listed:
		e["name"] = JoyPathText.file_name(e["path"])
	_only_hidden = listed.is_empty() and not settings.show_hidden and not core.list_dir(path, true, "name", false)["entries"].is_empty()
	return listed


func navigate(path: String, focus_name := "") -> bool:
	var listed: Variant = _list(path)
	if listed == null:
		return false
	_enter(path, listed, focus_name)
	return true


func _enter(path: String, listed: Array, focus_name := "") -> void:
	cwd = path
	_unreadable = false
	all_entries = listed
	filter = ""
	selected.clear()
	top = 0
	_apply_filter(focus_name)


func refresh(focus_name := "") -> void:
	var keep := focus_name if focus_name != "" else _cursor_name()
	var listed: Variant = _list(cwd, true)
	if listed == null:
		_leave_missing_folder()
		return
	all_entries = listed
	_unreadable = false
	if not selected.is_empty():
		var present := {}
		for e: Dictionary in all_entries:
			present[e["path"]] = true
		# an item that the hidden setting takes out of view stays selected while it exists, like a filtered one
		for path: String in selected.keys():
			if not present.has(path) and not core.props(path)["ok"]:
				selected.erase(path)
	_apply_filter(keep)


func go_up() -> void:
	var parent: String = core.parent_dir(cwd)
	if parent == "":
		return
	if not _dir_exists(cwd):
		_leave_missing_folder()
		return
	navigate(parent, _focus_of(cwd))


# the core answers for every path, but Godot cannot open a path that is not valid text
func _dir_exists(path: String) -> bool:
	var info: Dictionary = core.props(path)
	return info["ok"] and info["is_dir"]


# the list names a folder by its text, but a path that is not valid text only matches as a whole
func _focus_of(path: String) -> String:
	return path if JoyPathText.is_opaque(path) or path.get_file() == "" else path.get_file()


# the text of a name that the screen may draw
func _name_of(path: String) -> String:
	for e: Dictionary in all_entries:
		if e["path"] == path:
			return JoyPathText.printable(e["name"])
	return JoyPathText.printable(JoyPathText.file_name(path))


func _label_of(paths: PackedStringArray) -> String:
	return _name_of(paths[0]) if paths.size() == 1 else Theme_.count(paths.size(), "item")


# a deleted folder or a removed card leaves a stale list, so move to the nearest folder that still lists
func _leave_missing_folder() -> void:
	var gone := JoyPathText.printable(cwd.get_file() if cwd.get_file() != "" else cwd)
	var candidates: Array = []
	var path: String = core.parent_dir(cwd)
	while path != "":
		candidates.append(path)
		path = core.parent_dir(path)
	candidates.append(places[0]["path"])
	for candidate: String in candidates:
		var listed: Variant = _list(candidate, true)
		if listed != null:
			_enter(candidate, listed)
			toast("The folder %s is not available. Opened %s." % [gone, _pretty_path(candidate)])
			return
	toast("The folder %s is not available." % gone, true)


func _pretty_path(path: String) -> String:
	var home: String = places[0]["path"]
	# a home that ends with a slash is the root, and a "~" there would eat the first slash of the path
	return ("~" + path.trim_prefix(home)) if not home.ends_with("/") and (path == home or path.begins_with(home + "/")) else path


func _back() -> void:
	if filter != "":
		_set_filter("")
	else:
		go_up()


func _cursor_name() -> String:
	return entries[cursor]["name"] if not entries.is_empty() else ""


func _apply_filter(focus_name := "") -> void:
	if filter == "":
		entries = all_entries
	else:
		entries = all_entries.filter(func(e: Dictionary) -> bool: return e["name"].containsn(filter))
	cursor = 0
	if focus_name != "":
		for i in entries.size():
			if entries[i]["name"] == focus_name or entries[i]["path"] == focus_name:
				cursor = i
				break
	# a refresh keeps the scroll position, so the cursor stays on the same screen row
	top = clampi(top, 0, maxi(entries.size() - visible_rows, 0))
	_clamp_view()
	if mode == Mode.PREVIEW and not preview.relist(entries):
		_close()
	if mode == Mode.KEYBOARD:
		_keyboard.set_title(_keyboard_title.call())


func _set_filter(text: String) -> void:
	filter = text
	_apply_filter()


func _filter_title() -> String:
	return "Filter this folder (%s of %s)" % [Theme_.with_commas(entries.size()), Theme_.with_commas(all_entries.size())]


func _move(step: int) -> void:
	if entries.is_empty():
		return
	cursor = clampi(cursor + step, 0, entries.size() - 1)
	_clamp_view()


func _clamp_view() -> void:
	if cursor < top:
		top = cursor
	elif cursor >= top + visible_rows:
		top = cursor - visible_rows + 1
	top = clampi(top, 0, maxi(entries.size() - visible_rows, 0))


func _open_current() -> void:
	if entries.is_empty():
		return
	var e: Dictionary = entries[cursor]
	if e["is_dir"]:
		navigate(e["path"])
	elif JoyThumbs.previewable(e):
		preview.open(thumbs, entries, cursor)
		_open(Mode.PREVIEW)
	else:
		_open_file(e)


# a good result is no proof, because Game Mode can accept the call and show nothing
func _open_file(e: Dictionary) -> void:
	if JoyPathText.is_opaque(e["path"]):
		toast("Could not open %s. Its name is not valid text, so no app can be asked to open it." % e["name"], true)
		return
	var err: int = opener.call(JoyPathText.native(e["path"]))
	if err == OK:
		toast("Asked the system to open %s. If nothing happens, open it in Desktop Mode." % e["name"])
	else:
		toast("Could not open %s. This system has no app for that file type." % e["name"], true)


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
	settings.show_hidden = not settings.show_hidden
	refresh()
	toast("Hidden files are shown." if settings.show_hidden else "Hidden files are not shown.")
	_save_settings()


func _set_sort(key: String, desc: bool) -> void:
	settings.sort_key = key
	settings.sort_desc = desc
	refresh()
	toast("Sorted by %s, %s." % [JoySettings.SORTS[key][0].to_lower(), JoySettings.order_text(key, desc)])
	_save_settings()


func _save_settings() -> void:
	if settings.save() != OK:
		toast("Could not save your settings.", true)


func _visible_selection() -> PackedStringArray:
	var shown := {}
	for e: Dictionary in entries:
		shown[e["path"]] = true
	return PackedStringArray(selected.keys().filter(func(path: String) -> bool: return shown.has(path)))


func targets() -> PackedStringArray:
	var picked := _visible_selection()
	if not picked.is_empty():
		return picked
	if entries.is_empty():
		return PackedStringArray()
	return PackedStringArray([entries[cursor]["path"]])


# menus and operations

func _file_menu() -> Array:
	var t := targets()
	var items: Array = []
	if not t.is_empty():
		items.append(["Copy (%s)" % Theme_.with_commas(t.size()), func(): _set_clipboard(t, false)])
		items.append(["Cut (%s)" % Theme_.with_commas(t.size()), func(): _set_clipboard(t, true)])
	if not clipboard["paths"].is_empty():
		items.append(["Paste %s here" % Theme_.with_commas(clipboard["paths"].size()), paste])
	if t.size() == 1:
		items.append(["Rename", func(): _ask_rename(t[0])])
		items.append(["Properties", func(): _open_props(t[0])])
	items.append(["New folder", _ask_new_folder])
	if not t.is_empty():
		items.append(["Move to trash (%s)" % Theme_.with_commas(t.size()), func(): _ask_trash(t)])
	if not _visible_selection().is_empty():
		items.append(["Clear selection", func(): selected.clear()])
	elif _has_entries():
		items.append(["Select all", select_all])
	return items


func select_all() -> void:
	for e: Dictionary in entries:
		selected[e["path"]] = true


func _app_menu() -> Array:
	return [
		[_jobs_label(), _open_jobs],
		["Filter this folder", _ask_filter],
		["Sort...", _open_sort_menu],
		["Hide hidden files" if settings.show_hidden else "Show hidden files", _toggle_hidden],
		["Refresh", refresh],
		["Quit Joyfiles", _ask_quit],
	]


func _jobs_label() -> String:
	if reports.is_empty():
		return "Jobs (%d)" % jobs.size() if not jobs.is_empty() else "Jobs"
	var running := "%d running, " % jobs.size() if not jobs.is_empty() else ""
	return "Jobs (%s%d failed)" % [running, reports.size()]


func _ask_quit() -> void:
	if jobs.is_empty():
		quitter.call()
		return
	_set_confirm(_quit_text())
	_on_confirm = quitter
	if mode != Mode.CONFIRM:
		_open(Mode.CONFIRM)


# the quit question follows the job count, so it stays true while jobs end
func _quit_text() -> String:
	if jobs.is_empty():
		return "Quit Joyfiles?"
	return "A job is still running. Quit and cancel it?" if jobs.size() == 1 else "%d jobs are still running. Quit and cancel them?" % jobs.size()


func _set_confirm(text: String) -> void:
	_confirm_label.text = JoyPathText.printable(text)


func _open_sort_menu() -> void:
	var items: Array = []
	for key: String in JoySettings.SORTS:
		var mark := " ✓" if key == settings.sort_key else ""
		items.append([JoySettings.SORTS[key][0] + mark, _set_sort.bind(key, settings.sort_desc)])
	var order := JoySettings.order_text(settings.sort_key, settings.sort_desc)
	items.append(["Order: " + order, _set_sort.bind(settings.sort_key, not settings.sort_desc)])
	_open_menu(items)


func _open_menu(items: Array) -> void:
	menu_items = items
	menu_cursor = 0
	_open(Mode.MENU)


func _set_clipboard(paths: PackedStringArray, is_move: bool) -> void:
	clipboard = {"move": is_move, "paths": paths, "label": _label_of(paths)}
	selected.clear()
	toast("%s item(s) ready to %s. Open a folder and pick Paste." % [Theme_.with_commas(paths.size()), "move" if is_move else "copy"])


func paste() -> void:
	var label: String = clipboard.get("label", _label_of(clipboard["paths"]))
	var id: int = core.start_job(clipboard["move"], clipboard["paths"], cwd)
	var watch := [cwd]
	if clipboard["move"]:
		for path: String in clipboard["paths"]:
			var parent: String = core.parent_dir(path)
			if parent not in watch:
				watch.append(parent)
		clipboard = {"move": false, "paths": PackedStringArray()}
	jobs[id] = {"watch": watch, "label": label}


func _ask_rename(path: String) -> void:
	var first := JoyPathText.scan(path.get_file())
	var shown: String = first["shown"]
	var kept := [shown.length()]
	_ask_text("Rename", shown, func(new_name: String):
		var real: Variant = JoyPathText.restore(first, new_name, kept[0])
		if real == null:
			toast("Rename refused. The edit cut into a hidden character mark such as <U+202E>. Delete the whole mark or leave it.", true)
			return
		if real == path.get_file():
			return
		var r: Dictionary = core.rename(path, real)
		if r["ok"]:
			_refresh_to_new(r["path"])
		else:
			toast(r["error"], true),
		func(text: String): kept[0] = mini(kept[0], JoyPathText.shared_start(shown, text)),
		Callable(), first["tokens"])


func _ask_new_folder() -> void:
	_ask_text("New folder name", "", func(new_name: String):
		var r: Dictionary = core.make_dir(cwd, new_name)
		if r["ok"]:
			_refresh_to_new(r["path"])
		else:
			toast(r["error"], true))


# a new or renamed item that the hidden setting takes out of view would look like a failure, so say where it went
func _refresh_to_new(path: String) -> void:
	refresh(_focus_of(path))
	if not entries.any(func(e: Dictionary) -> bool: return e["path"] == path) and filter == "":
		toast("%s is hidden, because its name starts with a dot. Show hidden files to see it." % JoyPathText.printable(path.get_file()))


func _ask_filter() -> void:
	var before := filter
	_ask_text(_filter_title, filter, _set_filter, _set_filter, func(): _set_filter(before))


func _ask_trash(paths: PackedStringArray) -> void:
	var what := _label_of(paths)
	_set_confirm("Move %s to the trash?" % what)
	_on_confirm = func():
		_announce_trash(core.trash(paths), what)
		refresh()
	_open(Mode.CONFIRM)


func _announce_trash(r: Dictionary, what: String) -> void:
	var failures: Array = r["failures"]
	if failures.is_empty():
		toast("Moved %s to the trash." % what)
		return
	_add_report("Move to trash: %s failed" % Theme_.count(failures.size(), "item"), failures)
	var head := "Moved %s to the trash." % Theme_.count(r["trashed"], "item") if r["trashed"] > 0 else "Nothing was moved to the trash."
	toast("%s %s could not be moved. %s" % [head, Theme_.count(failures.size(), "item"), _see_jobs(failures.size())], true)


func _add_report(title: String, failures: Array) -> void:
	_report_seq += 1
	reports[_report_seq] = {"title": title, "failures": failures}


func _see_jobs(count: int) -> String:
	return "Open Jobs to see %s." % ("it" if count == 1 else "them")


func _on_report_dismissed(id: int) -> void:
	reports.erase(id)


# the title is text or a Callable, and a Callable title is read again whenever the list changes
func _ask_text(title: Variant, initial: String, on_submit: Callable, on_change := Callable(), on_cancel := Callable(), marks: Array = []) -> void:
	_keyboard_title = title if title is Callable else func() -> String: return title
	_on_submit = on_submit
	_on_change = on_change
	_on_cancel = on_cancel
	_keyboard.open(_keyboard_title.call(), initial, marks)
	_open(Mode.KEYBOARD)


func _on_keyboard_submitted(text: String) -> void:
	_close()
	_on_submit.call(text)
	_render()


func _on_keyboard_changed(text: String) -> void:
	if _on_change.is_valid():
		_on_change.call(text)


func _on_keyboard_cancelled() -> void:
	_close()
	if _on_cancel.is_valid():
		_on_cancel.call()
	_render()


func _open_props(path: String) -> void:
	props_panel.open(core, path, not settings.show_hidden)
	_open(Mode.PROPS)


func _open_jobs() -> void:
	_open(Mode.JOBS)


func _poll_jobs() -> void:
	if jobs.is_empty():
		return
	var ended := false
	var refreshed := false
	for job: Dictionary in core.poll_jobs():
		var id: int = job["id"]
		if not jobs.has(id):
			continue
		jobs[id].merge(job, true)
		if job["state"] != "running":
			_announce_end(jobs[id])
			ended = true
			if cwd in jobs[id].get("watch", []):
				refresh()
				refreshed = true
			jobs.erase(id)
	if refreshed:
		_render()
	_ask_next_conflict()
	if mode == Mode.CONFIRM and _on_confirm == quitter:
		_set_confirm(_quit_text())
	_render_status()
	if mode == Mode.JOBS:
		_render_overlay()
	if ended and not refreshed:
		_render_hints()


func _announce_end(job: Dictionary) -> void:
	var moved: bool = job["kind"] == "move"
	var failures: Array = job["failures"]
	if not failures.is_empty():
		var cancelled: bool = job["state"] == "cancelled"
		var many := Theme_.count(failures.size(), "item")
		_add_report("%s: %s failed%s" % ["Move" if moved else "Copy", many, " (cancelled)" if cancelled else ""], failures)
		var what := "The job was cancelled. %s had failed before that." % many if cancelled else "%s could not be %s." % [many, "moved" if moved else "copied"]
		toast("%s %s" % [what, _see_jobs(failures.size())], true)
		return
	match job["state"]:
		"done":
			toast("%s %s." % ["Moved" if moved else "Copied", job.get("label", JoyPathText.file_name(job["current"]))])
		"failed":
			toast(job["error"], true)
		"cancelled":
			toast("The job was cancelled.")


func _ask_next_conflict() -> void:
	if mode not in PROMPT_MODES:
		return
	for id: int in jobs:
		if not jobs[id].get("conflict", {}).is_empty():
			_open_conflict(id)
			return


func _open_conflict(id: int) -> void:
	_conflict_job = id
	conflict_panel.open(jobs[id]["conflict"])
	_open(Mode.CONFLICT)
	_render()


func _on_conflict_answered(choice: String, apply_all: bool) -> void:
	core.answer_conflict(_conflict_job, choice, apply_all)
	_close_conflict()


func _on_conflict_cancelled() -> void:
	core.cancel_job(_conflict_job)
	_close_conflict()


func _close_conflict() -> void:
	if jobs.has(_conflict_job):
		jobs[_conflict_job]["conflict"] = {}
	_conflict_job = -1
	_close()


func _on_answer_requested(id: int) -> void:
	if jobs_panel.is_waiting(id, jobs):
		_open_conflict(id)


func _on_preview_closed() -> void:
	var path: String = preview.current()["path"]
	for i in entries.size():
		if entries[i]["path"] == path:
			cursor = i
			break
	cursor = clampi(cursor, 0, maxi(entries.size() - 1, 0))
	_clamp_view()
	_close()


func _on_props_closed() -> void:
	props_panel.close()
	_close()


func toast(raw: String, is_error := false) -> void:
	var text := JoyPathText.printable(raw)
	last_error = text if is_error else ""
	if _toast_blocked():
		_toast_queue.append([text, is_error])
		while _toast_queue.size() > TOAST_QUEUE_MAX:
			_toast_queue.pop_front()
		return
	_show_toast(text, is_error)


func _show_toast(text: String, is_error: bool, replay := false) -> void:
	_toast_replay = replay
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", Theme_.DANGER if is_error else Theme_.TEXT)
	_toast_label.custom_minimum_size.x = minf(Theme_.text_width(text, TOAST_FONT) + 8.0, TOAST_MAX_WIDTH)
	_toast_panel.visible = true
	_toast_error = is_error
	var seconds := QUEUED_TOAST_SECONDS if not _toast_queue.is_empty() else (6.0 if is_error else 4.0)
	_toast_until = _clock + seconds


# a dialog owns the screen, so the toast waits for it
func _toast_blocked() -> bool:
	return _panels.has(mode)


func _sync_toast() -> void:
	if _toast_blocked():
		if _toast_until > 0.0:
			# a toast that already waited once is not queued again, and a full queue keeps its newer toasts
			if not _toast_replay and _toast_queue.size() < TOAST_QUEUE_MAX:
				_toast_queue.push_front([_toast_label.text, _toast_error, true])
			_toast_until = 0.0
			_toast_panel.visible = false
		return
	if _toast_until > 0.0 and _clock > _toast_until:
		_toast_until = 0.0
		_toast_panel.visible = false
	if _toast_until == 0.0 and not _toast_queue.is_empty():
		var next: Array = _toast_queue.pop_front()
		_show_toast(next[0], next[1], next.size() > 2)


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
	# the stage holds the header, the list and every overlay, so the dim never reaches the footer below it
	_stage = Control.new()
	_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_stage)
	_shell = VBoxContainer.new()
	_shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shell.add_theme_constant_override("separation", 0)
	_stage.add_child(_shell)
	_shell.add_child(_build_header())
	_shell.add_child(_build_body())
	root.add_child(_build_footer())
	_build_toast()
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage.add_child(_dim)
	_build_overlay()


func _build_header() -> Control:
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 0, 16))
	var column := JoyColumn.new()
	header.add_child(column)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	column.add_child(row)
	_path_label = Theme_.fit("", Theme_.TEXT, Theme_.SIZE_TITLE, JoyFitLabel.Cut.START, "/")
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_path_label)
	_filter_label = Theme_.fit("", Theme_.WARN, Theme_.SIZE_BODY)
	row.add_child(_filter_label)
	_sort_label = Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	row.add_child(_sort_label)
	_count_label = Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	row.add_child(_count_label)
	return header


func _build_body() -> Control:
	var column := JoyColumn.new()
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var body := HBoxContainer.new()
	column.add_child(body)
	var side := PanelContainer.new()
	side.custom_minimum_size.x = SIDE_WIDTH
	side.add_theme_stylebox_override("panel", Theme_.box(Theme_.SIDE, 0, 8))
	_places_box = VBoxContainer.new()
	_places_scroll = JoyScrollBox.new(_places_box)
	side.add_child(_places_scroll)
	body.add_child(side)
	# the host takes the room that is left and no more, so the rows never push the footer off the screen
	_list_host = Control.new()
	_list_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_host.clip_contents = true
	_list_host.resized.connect(_fit_rows)
	body.add_child(_list_host)
	_rows_box = VBoxContainer.new()
	_rows_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rows_box.add_theme_constant_override("separation", ROW_GAP)
	_list_host.add_child(_rows_box)
	_set_rows(visible_rows)
	return column


func _build_footer() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 0, 12))
	var column := JoyColumn.new()
	panel.add_child(column)
	_footer = HBoxContainer.new()
	_footer.add_theme_constant_override("separation", 16)
	column.add_child(_footer)
	_status = Theme_.fit("", Theme_.TEXT, Theme_.SIZE_BODY, JoyFitLabel.Cut.MIDDLE)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_footer.add_child(_status)
	_status_tail = Theme_.label("", Theme_.TEXT, Theme_.SIZE_BODY)
	_footer.add_child(_status_tail)
	return panel


# the toast sits under the dim in the draw order, and it waits in a queue while a dialog is open
func _build_toast() -> void:
	var holder := VBoxContainer.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.alignment = BoxContainer.ALIGNMENT_END
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(holder)
	var row := CenterContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(row)
	var gap := Control.new()
	gap.custom_minimum_size.y = TOAST_LIFT
	holder.add_child(gap)
	_toast_panel = PanelContainer.new()
	_toast_panel.add_theme_stylebox_override("panel", Theme_.box(Theme_.ROW_SEL, 12, 16))
	_toast_panel.visible = false
	_toast_label = Theme_.label("", Theme_.TEXT, TOAST_FONT)
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_panel.add_child(_toast_label)
	row.add_child(_toast_panel)


func _build_overlay() -> void:
	_overlay = CenterContainer.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage.add_child(_overlay)
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
	_confirm_label = Theme_.label("", Theme_.TEXT, Theme_.SIZE_TITLE)
	_confirm_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_label.custom_minimum_size.x = CONFIRM_WIDTH
	confirm_box.add_child(_confirm_label)
	confirm_box.add_child(Theme_.hints(JoyCommands.hints(_commands[Mode.CONFIRM])))
	_overlay.add_child(_confirm_panel)
	_keyboard = JoyKeyboard.new()
	_keyboard.submitted.connect(_on_keyboard_submitted)
	_keyboard.changed.connect(_on_keyboard_changed)
	_keyboard.cancelled.connect(_on_keyboard_cancelled)
	_overlay.add_child(_keyboard)
	conflict_panel = JoyConflict.new()
	conflict_panel.answered.connect(_on_conflict_answered)
	conflict_panel.cancelled.connect(_on_conflict_cancelled)
	_overlay.add_child(conflict_panel)
	jobs_panel = JoyJobs.new()
	jobs_panel.closed.connect(_close)
	jobs_panel.cancel_requested.connect(core.cancel_job)
	jobs_panel.answer_requested.connect(_on_answer_requested)
	jobs_panel.dismissed.connect(_on_report_dismissed)
	_overlay.add_child(jobs_panel)
	props_panel = JoyProps.new()
	props_panel.closed.connect(_on_props_closed)
	_overlay.add_child(props_panel)
	preview = JoyPreview.new()
	preview.closed.connect(_on_preview_closed)
	_overlay.add_child(preview)


# the list shows as many rows as the stage can hold, because the logical height depends on the screen
func _fit_rows() -> void:
	var room := _list_host.size.y + ROW_GAP
	var fit := clampi(floori(room / float(ROW_HEIGHT + ROW_GAP)), MIN_ROWS, MAX_ROWS)
	if fit == visible_rows:
		return
	_set_rows(fit)
	_clamp_view()
	_render_rows()


func _set_rows(count: int) -> void:
	while _rows.size() > count:
		var gone: PanelContainer = _rows.pop_back()
		_row_parts.pop_back()
		_rows_box.remove_child(gone)
		gone.queue_free()
	while _rows.size() < count:
		_add_row()
	visible_rows = count


func _add_row() -> void:
	var row := PanelContainer.new()
	row.custom_minimum_size.y = ROW_HEIGHT
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	row.add_child(hb)
	var mark := Theme_.label("", Theme_.TEXT, Theme_.SIZE_BODY)
	mark.custom_minimum_size.x = MARK_WIDTH
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hb.add_child(mark)
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(THUMB_BOX, THUMB_BOX)
	hb.add_child(slot)
	var thumb := TextureRect.new()
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_SCALE
	thumb.visible = false
	slot.add_child(thumb)
	var glyph := Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	slot.add_child(glyph)
	# the name sits in a clipped slot, so tall glyph stacks never make the row taller
	var name_slot := Control.new()
	name_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_slot.clip_contents = true
	hb.add_child(name_slot)
	var name_label := Theme_.fit("", Theme_.TEXT, Theme_.SIZE_LIST, JoyFitLabel.Cut.MIDDLE)
	name_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_slot.add_child(name_label)
	var size_label := Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	hb.add_child(size_label)
	_rows_box.add_child(row)
	_rows.append(row)
	_row_parts.append({"mark": mark, "glyph": glyph, "thumb": thumb, "name": name_label, "size": size_label})


func _render() -> void:
	_path_label.set_full(_pretty_path(cwd))
	_filter_label.visible = filter != ""
	_filter_label.set_full("Filter: " + filter)
	_filter_label.custom_minimum_size.x = minf(Theme_.text_width(_filter_label.full, Theme_.SIZE_BODY) + 4.0, FILTER_MAX_WIDTH)
	_sort_label.text = "%s %s" % [JoySettings.SORTS[settings.sort_key][0], "▼" if settings.sort_desc else "▲"]
	_count_label.text = "%s / %s" % [Theme_.with_commas(cursor + 1 if not entries.is_empty() else 0), Theme_.with_commas(entries.size())]
	_render_rows()
	_render_places()
	_render_overlay()
	_render_hints()
	_render_status()


func _render_rows() -> void:
	var wanted: Array = []
	for i in _rows.size():
		var row := _rows[i]
		var part: Dictionary = _row_parts[i]
		var idx := top + i
		part["thumb"].visible = false
		if idx >= entries.size():
			row.add_theme_stylebox_override("panel", Theme_.box_xy(Color.TRANSPARENT, 8, 8, 4))
			part["mark"].text = ""
			part["glyph"].text = ""
			part["name"].set_full("")
			part["size"].text = ""
			if idx == 0:
				part["name"].set_full(_empty_text())
				part["name"].add_theme_color_override("font_color", Theme_.MUTED)
			continue
		var e: Dictionary = entries[idx]
		var is_cursor: bool = idx == cursor and mode != Mode.PLACES
		var is_selected: bool = selected.has(e["path"])
		row.add_theme_stylebox_override("panel", Theme_.focus_box(is_cursor, Theme_.ROW_SEL if is_selected else Color.TRANSPARENT, 8, 8, 4))
		var tex: Texture2D = null
		if JoyThumbs.previewable(e):
			wanted.append(e)
			tex = thumbs.texture(e["path"], JoyThumbs.THUMB_SIDE)
		part["thumb"].texture = tex
		part["thumb"].visible = tex != null
		if tex != null:
			var rect := Theme_.fit_rect(tex.get_size(), Vector2(THUMB_BOX, THUMB_BOX), THUMB_MIN_SIDE)
			part["thumb"].position = rect.position
			part["thumb"].size = rect.size
			part["thumb"].texture_filter = Theme_.filter_for(tex.get_size(), rect.size)
		part["mark"].text = "✓" if is_selected else ""
		part["glyph"].text = "" if tex != null else ("▰" if e["is_dir"] else "▫")
		part["glyph"].add_theme_color_override("font_color", Theme_.FOLDER if e["is_dir"] else Theme_.MUTED)
		part["name"].set_full(e["name"])
		part["name"].add_theme_color_override("font_color", Theme_.MUTED if e["hidden"] else Theme_.TEXT)
		part["size"].text = "" if e["is_dir"] else Theme_.human_size(e["size"])
	thumbs.want(wanted, JoyThumbs.THUMB_SIDE)


func _empty_text() -> String:
	if _unreadable:
		return "This folder cannot be read."
	if filter != "":
		return "No items match the filter."
	return "This folder has only hidden items." if _only_hidden else "This folder is empty."


func _render_places() -> void:
	if places != _places_shown:
		_build_places()
	for i in places.size():
		var l: Label = _places_box.get_child(i + 1)
		var focused: bool = mode == Mode.PLACES and i == place_cursor
		var current: bool = cwd == places[i]["path"]
		l.add_theme_stylebox_override("normal", Theme_.focus_box(focused, Theme_.ROW_SEL if current else Color.TRANSPARENT, 8, 8, 8))
	if mode == Mode.PLACES:
		_keep_place_visible()


func _build_places() -> void:
	_places_shown = places.duplicate(true)
	for child in _places_box.get_children():
		_places_box.remove_child(child)
		child.queue_free()
	_places_box.add_child(Theme_.label("PLACES", Theme_.MUTED, Theme_.SIZE_SMALL))
	for p: Dictionary in places:
		var place_label := Theme_.fit(("◉ " if p["kind"] == "drive" else "• ") + p["label"], Theme_.TEXT, Theme_.SIZE_BODY)
		place_label.text_direction = Control.TEXT_DIRECTION_LTR
		_places_box.add_child(place_label)


# the first place scrolls to the top so the title shows too, and any other place scrolls just into view
func _keep_place_visible() -> void:
	if place_cursor == 0:
		_places_scroll.scroll_vertical = 0
	else:
		_places_scroll.reveal(_places_box.get_child(place_cursor + 1))


func _render_overlay() -> void:
	_dim.visible = _panels.has(mode)
	for panel_mode: int in _panels:
		_panels[panel_mode].visible = panel_mode == mode
	if _overlay_renderers.has(mode):
		_overlay_renderers[mode].call()
	_sync_toast()


func _render_menu() -> void:
	for child in _menu_box.get_children():
		child.queue_free()
	for i in menu_items.size():
		var l := Theme_.label(menu_items[i][0], Theme_.TEXT, Theme_.SIZE_LIST)
		l.add_theme_stylebox_override("normal", Theme_.focus_box(i == menu_cursor))
		_menu_box.add_child(l)


func _hints_for_mode() -> Array:
	return JoyCommands.hints(_commands[mode])


func _render_hints() -> void:
	if _hints:
		_hints.queue_free()
	_hints = Theme_.hints([] if mode in PANEL_HINT_MODES else _hints_for_mode())
	_footer.add_child(_hints)


func _render_status() -> void:
	var running := jobs.values().filter(func(j): return j.get("state", "running") == "running")
	if running.is_empty():
		var failed: int = reports.values().reduce(func(n: int, r: Dictionary) -> int: return n + r["failures"].size(), 0)
		_set_status("" if reports.is_empty() else "%s failed. Open Jobs to see why." % Theme_.count(failed, "item"), "", Theme_.DANGER, JoyFitLabel.Cut.END)
		return
	var j: Dictionary = running[0]
	var verb := "Moving" if j.get("kind") == "move" else "Copying"
	if not j.get("conflict", {}).is_empty():
		_set_status("%s paused: %s" % [verb, JoyPathText.file_name(j["conflict"]["path"])], "", Theme_.TEXT, JoyFitLabel.Cut.MIDDLE, " already exists.")
		return
	var pct: int = 0 if j.get("total_bytes", 0) == 0 else int(100.0 * j["done_bytes"] / j["total_bytes"])
	_set_status("%s %s" % [verb, JoyPathText.file_name(j.get("current", ""))], "%d%%" % pct, Theme_.TEXT)


# the tail stays whole, so a long name never hides the percent or the reason
func _set_status(head: String, tail: String, color: Color, how := JoyFitLabel.Cut.MIDDLE, follow := "") -> void:
	_status.cut = how
	_status.suffix = follow
	_status.set_full(head)
	_status_tail.text = tail
	for label: Label in [_status, _status_tail]:
		label.add_theme_color_override("font_color", color)
