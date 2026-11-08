extends Control

enum Mode { FILES, PLACES, MENU, KEYBOARD, CONFIRM, CONFLICT, JOBS, PROPS, PREVIEW }

const VISIBLE_ROWS := 12
const ROW_HEIGHT := 50
const THUMB_BOX := 42
const MARK_WIDTH := 30
const FILTER_MAX_WIDTH := 380.0
const TOAST_FONT := 22
const TOAST_MAX_WIDTH := 880.0
const TOAST_LIFT := 84
const PLACES_REFRESH_SECONDS := 3.0
# a clash prompt never cuts into a menu, a keyboard or a confirm that the user is using
const PROMPT_MODES := [Mode.FILES, Mode.PLACES]
# a press this soon after a screen change was aimed at the old screen, and only time tells a double tap apart
const GUARD_SECONDS := 0.15

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
var _places_at := 0.0
var _conflict_job := -1
var _report_seq := 0

var _path_label: JoyFitLabel
var _filter_label: JoyFitLabel
var _sort_label: Label
var _count_label: Label
var _rows: Array[PanelContainer] = []
var _row_parts: Array[Dictionary] = []
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
	var arg_path := _arg_path()
	navigate(arg_path if arg_path != "" else (start_path if start_path != "" else places[0]["path"]))
	_render()


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
	if _toast_until > 0.0 and _clock > _toast_until:
		_toast_until = 0.0
		_toast_panel.visible = false


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
			["jf_page_up", "", _move.bind(-VISIBLE_ROWS)],
			["jf_page_down", "", _move.bind(VISIBLE_ROWS)],
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
	navigate(places[place_cursor]["path"])
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
	_only_hidden = listed.is_empty() and not settings.show_hidden and not core.list_dir(path, true, "name", false)["entries"].is_empty()
	return listed


func navigate(path: String, focus_name := "") -> void:
	var listed: Variant = _list(path)
	if listed == null:
		return
	_enter(path, listed, focus_name)


func _enter(path: String, listed: Array, focus_name := "") -> void:
	cwd = path
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


# a name from the list is already readable, and any other name loses its escape characters
func _name_of(path: String) -> String:
	for e: Dictionary in all_entries:
		if e["path"] == path:
			return e["name"]
	return JoyPathText.printable(path.get_file())


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
	return JoyPathText.printable(("~" + path.trim_prefix(home)) if path.begins_with(home) else path)


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
	top = clampi(top, 0, maxi(entries.size() - VISIBLE_ROWS, 0))
	_clamp_view()
	if mode == Mode.PREVIEW and not preview.relist(entries):
		_close()
	if mode == Mode.KEYBOARD:
		_keyboard.set_title(_keyboard_title.call())


func _set_filter(text: String) -> void:
	filter = text
	_apply_filter()


func _filter_title() -> String:
	return "Filter this folder (%d of %d)" % [entries.size(), all_entries.size()]


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


func _previewable(e: Dictionary) -> bool:
	return not e["is_dir"] and JoyThumbs.is_image(e["name"]) and e["size"] <= JoyThumbs.MAX_FILE_BYTES and not JoyPathText.is_opaque(e["path"])


func _open_current() -> void:
	if entries.is_empty():
		return
	var e: Dictionary = entries[cursor]
	if e["is_dir"]:
		navigate(e["path"])
	elif _previewable(e):
		preview.open(thumbs, entries, cursor)
		_open(Mode.PREVIEW)
	else:
		_open_file(e)


# a good result is no proof, because Game Mode can accept the call and show nothing
func _open_file(e: Dictionary) -> void:
	if JoyPathText.is_opaque(e["path"]):
		toast("Could not open %s. Its name is not valid text, so no app can be asked to open it." % e["name"], true)
		return
	var err: int = opener.call(e["path"])
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
		items.append(["Copy (%d)" % t.size(), func(): _set_clipboard(t, false)])
		items.append(["Cut (%d)" % t.size(), func(): _set_clipboard(t, true)])
	if not clipboard["paths"].is_empty():
		items.append(["Paste %d here" % clipboard["paths"].size(), paste])
	if t.size() == 1:
		items.append(["Rename", func(): _ask_rename(t[0])])
		items.append(["Properties", func(): _open_props(t[0])])
	items.append(["New folder", _ask_new_folder])
	if not t.is_empty():
		items.append(["Move to trash (%d)" % t.size(), func(): _ask_trash(t)])
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
	_confirm_label.text = "A job is still running. Quit and cancel it?" if jobs.size() == 1 else "%d jobs are still running. Quit and cancel them?" % jobs.size()
	_on_confirm = quitter
	_open(Mode.CONFIRM)


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
	toast("%d item(s) ready to %s. Open a folder and pick Paste." % [paths.size(), "move" if is_move else "copy"])


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
	_ask_text("Rename", _name_of(path), func(new_name: String):
		var r: Dictionary = core.rename(path, new_name)
		if r["ok"]:
			refresh(r["path"].get_file())
		else:
			toast(r["error"], true))


func _ask_new_folder() -> void:
	_ask_text("New folder name", "", func(new_name: String):
		var r: Dictionary = core.make_dir(cwd, new_name)
		if r["ok"]:
			refresh(r["path"].get_file())
		else:
			toast(r["error"], true))


func _ask_filter() -> void:
	var before := filter
	_ask_text(_filter_title, filter, _set_filter, _set_filter, func(): _set_filter(before))


func _ask_trash(paths: PackedStringArray) -> void:
	var what := _label_of(paths)
	_confirm_label.text = "Move %s to the trash?" % what
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
func _ask_text(title: Variant, initial: String, on_submit: Callable, on_change := Callable(), on_cancel := Callable()) -> void:
	_keyboard_title = title if title is Callable else func() -> String: return title
	_on_submit = on_submit
	_on_change = on_change
	_on_cancel = on_cancel
	_keyboard.open(_keyboard_title.call(), initial)
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
	props_panel.open(core, path)
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
			toast("%s %s." % ["Moved" if moved else "Copied", job.get("label", job["current"])])
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


func toast(text: String, is_error := false) -> void:
	last_error = text if is_error else ""
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", Theme_.DANGER if is_error else Theme_.TEXT)
	var width := _toast_label.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TOAST_FONT).x
	_toast_label.custom_minimum_size.x = minf(width + 8.0, TOAST_MAX_WIDTH)
	_toast_panel.visible = true
	_toast_until = _clock + (6.0 if is_error else 4.0)


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
	header_row.add_theme_constant_override("separation", 20)
	header.add_child(header_row)
	_path_label = Theme_.fit("", Theme_.TEXT, Theme_.SIZE_TITLE, JoyFitLabel.Cut.START, "/")
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(_path_label)
	_filter_label = Theme_.fit("", Theme_.WARN, Theme_.SIZE_BODY)
	header_row.add_child(_filter_label)
	_sort_label = Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	header_row.add_child(_sort_label)
	_count_label = Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	header_row.add_child(_count_label)
	root.add_child(header)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	var side := PanelContainer.new()
	side.custom_minimum_size.x = 280
	side.add_theme_stylebox_override("panel", Theme_.box(Theme_.SIDE, 0, 8))
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
		var mark := Theme_.label("", Theme_.TEXT, Theme_.SIZE_BODY)
		mark.custom_minimum_size.x = MARK_WIDTH
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hb.add_child(mark)
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(THUMB_BOX, THUMB_BOX)
		hb.add_child(slot)
		var thumb := TextureRect.new()
		thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.visible = false
		slot.add_child(thumb)
		var glyph := Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
		glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot.add_child(glyph)
		var name_label := Theme_.fit("", Theme_.TEXT, Theme_.SIZE_LIST, JoyFitLabel.Cut.MIDDLE)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(name_label)
		var size_label := Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
		hb.add_child(size_label)
		list.add_child(row)
		_rows.append(row)
		_row_parts.append({"mark": mark, "glyph": glyph, "thumb": thumb, "name": name_label, "size": size_label})

	_footer = HBoxContainer.new()
	_footer.add_theme_constant_override("separation", 16)
	var footer_panel := PanelContainer.new()
	footer_panel.add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 0, 12))
	footer_panel.add_child(_footer)
	root.add_child(footer_panel)
	_status = Theme_.fit("", Theme_.TEXT, Theme_.SIZE_BODY, JoyFitLabel.Cut.MIDDLE)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_footer.add_child(_status)
	_status_tail = Theme_.label("", Theme_.TEXT, Theme_.SIZE_BODY)
	_footer.add_child(_status_tail)

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
	var toast_holder := VBoxContainer.new()
	toast_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	toast_holder.alignment = BoxContainer.ALIGNMENT_END
	toast_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast_holder)
	var toast_row := CenterContainer.new()
	toast_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_holder.add_child(toast_row)
	var toast_gap := Control.new()
	toast_gap.custom_minimum_size.y = TOAST_LIFT
	toast_holder.add_child(toast_gap)
	_toast_panel = PanelContainer.new()
	_toast_panel.add_theme_stylebox_override("panel", Theme_.box(Theme_.ROW_SEL, 12, 16))
	_toast_panel.visible = false
	_toast_label = Theme_.label("", Theme_.TEXT, TOAST_FONT)
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_panel.add_child(_toast_label)
	toast_row.add_child(_toast_panel)


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
	for i in VISIBLE_ROWS:
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
		if _previewable(e):
			wanted.append(e["path"])
			tex = thumbs.texture(e["path"], JoyThumbs.THUMB_SIDE)
		part["thumb"].texture = tex
		part["thumb"].visible = tex != null
		part["mark"].text = "✓" if is_selected else ""
		part["glyph"].text = "" if tex != null else ("▰" if e["is_dir"] else "▫")
		part["glyph"].add_theme_color_override("font_color", Theme_.FOLDER if e["is_dir"] else Theme_.MUTED)
		part["name"].set_full(e["name"])
		part["name"].add_theme_color_override("font_color", Theme_.MUTED if e["hidden"] else Theme_.TEXT)
		part["size"].text = "" if e["is_dir"] else Theme_.human_size(e["size"])
	thumbs.want(wanted, JoyThumbs.THUMB_SIDE)


func _empty_text() -> String:
	if filter != "":
		return "No items match the filter."
	return "This folder has only hidden items." if _only_hidden else "This folder is empty."


func _render_places() -> void:
	for child in _places_box.get_children():
		child.queue_free()
	_places_box.add_child(Theme_.label("PLACES", Theme_.MUTED, Theme_.SIZE_SMALL))
	for i in places.size():
		var p: Dictionary = places[i]
		var l := Theme_.label(("◉ " if p["kind"] == "drive" else "• ") + p["label"], Theme_.TEXT, Theme_.SIZE_BODY, true)
		var focused: bool = mode == Mode.PLACES and i == place_cursor
		var current: bool = cwd == p["path"]
		l.add_theme_stylebox_override("normal", Theme_.focus_box(focused, Theme_.ROW_SEL if current else Color.TRANSPARENT, 8, 8, 8))
		_places_box.add_child(l)


func _render_overlay() -> void:
	_dim.visible = _panels.has(mode)
	for panel_mode: int in _panels:
		_panels[panel_mode].visible = panel_mode == mode
	if _overlay_renderers.has(mode):
		_overlay_renderers[mode].call()


func _render_menu() -> void:
	for child in _menu_box.get_children():
		child.queue_free()
	for i in menu_items.size():
		var l := Theme_.label(menu_items[i][0], Theme_.TEXT, Theme_.SIZE_LIST)
		l.add_theme_stylebox_override("normal", Theme_.focus_box(i == menu_cursor))
		_menu_box.add_child(l)


# the keyboard draws its own hint row next to the keys
func _hints_for_mode() -> Array:
	return [] if mode == Mode.KEYBOARD else JoyCommands.hints(_commands[mode])


func _render_hints() -> void:
	if _hints:
		_hints.queue_free()
	_hints = Theme_.hints(_hints_for_mode())
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
		_set_status("%s paused: %s" % [verb, j["conflict"]["name"]], "already exists.", Theme_.TEXT)
		return
	var pct: int = 0 if j.get("total_bytes", 0) == 0 else int(100.0 * j["done_bytes"] / j["total_bytes"])
	_set_status("%s %s" % [verb, j.get("current", "")], "%d%%" % pct, Theme_.TEXT)


# the tail stays whole, so a long name never hides the percent or the reason
func _set_status(head: String, tail: String, color: Color, how := JoyFitLabel.Cut.MIDDLE) -> void:
	_status.cut = how
	_status.set_full(head)
	_status_tail.text = tail
	for label: Label in [_status, _status_tail]:
		label.add_theme_color_override("font_color", color)
