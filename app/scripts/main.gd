extends Control

enum Mode { FILES, PLACES, MENU, KEYBOARD, CONFIRM, CONFLICT, JOBS, PROPS, PREVIEW }

const VISIBLE_ROWS := 12
const ROW_HEIGHT := 50
const THUMB_BOX := 42
const TOAST_FONT := 22
const TOAST_MAX_WIDTH := 880.0
const TOAST_LIFT := 84
const REPEAT_DELAY := 0.35
const REPEAT_RATE := 0.06
const PLACES_REFRESH_SECONDS := 3.0
# a clash prompt never cuts into a menu, a keyboard or a confirm that the user is using
const PROMPT_MODES := [Mode.FILES, Mode.PLACES]

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
var last_error := ""
var conflict_panel: JoyConflict
var jobs_panel: JoyJobs
var props_panel: JoyProps
var preview: JoyPreview

var _handlers := {}
var _panels := {}
var _overlay_renderers := {}
var _down := {}
var _held := ""
var _repeat_at := 0.0
var _clock := 0.0
var _on_submit: Callable
var _on_change: Callable
var _on_cancel: Callable
var _on_confirm: Callable
var _toast_until := 0.0
var _places_at := 0.0
var _conflict_job := -1
var _conflict_return := Mode.FILES

var _path_label: Label
var _filter_label: Label
var _sort_label: Label
var _count_label: Label
var _rows: Array[PanelContainer] = []
var _row_parts: Array[Dictionary] = []
var _places_box: VBoxContainer
var _status: Label
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
	JoyInput.install()
	settings = JoySettings.new(settings_path)
	settings.load_file()
	if not opener.is_valid():
		opener = _shell_open
	if not places_source.is_valid():
		places_source = core.places
	if not quitter.is_valid():
		quitter = get_tree().quit
	_build_ui()
	_handlers = {
		Mode.FILES: _files_action,
		Mode.PLACES: _places_action,
		Mode.MENU: _menu_action,
		Mode.KEYBOARD: _keyboard.handle,
		Mode.CONFIRM: _confirm_action,
		Mode.CONFLICT: conflict_panel.handle,
		Mode.JOBS: jobs_panel.handle,
		Mode.PROPS: props_panel.handle,
		Mode.PREVIEW: preview.handle,
	}
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
		Mode.JOBS: func(): jobs_panel.update(jobs),
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
	if mode == Mode.KEYBOARD and event is InputEventKey and event.pressed:
		_keyboard.handle_key(event)
		_render()
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
	if _clock >= _places_at:
		refresh_places()
	if thumbs.poll():
		_render()
	if mode == Mode.PROPS:
		props_panel.poll()
	if _toast_until > 0.0 and _clock > _toast_until:
		_toast_until = 0.0
		_toast_panel.visible = false


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
		"jf_back": _back()
		"jf_left", "jf_pane": _open_places()
		"jf_select": _toggle_select()
		"jf_menu": _open_menu(_file_menu())
		"jf_start": _open_menu(_app_menu())
		"jf_view": _toggle_hidden()
		"jf_search": _ask_filter()
		"jf_jobs": _open_jobs()


func _places_action(action: String) -> void:
	match action:
		"jf_up": place_cursor = posmod(place_cursor - 1, places.size())
		"jf_down": place_cursor = posmod(place_cursor + 1, places.size())
		"jf_accept", "jf_right":
			navigate(places[place_cursor]["path"])
			mode = Mode.FILES
		"jf_back", "jf_pane": mode = Mode.FILES
		"jf_start": _open_menu(_app_menu())
		"jf_jobs": _open_jobs()


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

func _open_places() -> void:
	refresh_places()
	mode = Mode.PLACES


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
	return result["entries"]


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
		for path: String in selected.keys():
			if not present.has(path):
				selected.erase(path)
	_apply_filter(keep)


func go_up() -> void:
	var parent: String = core.parent_dir(cwd)
	if parent == "":
		return
	if not DirAccess.dir_exists_absolute(cwd):
		_leave_missing_folder()
		return
	navigate(parent, cwd.get_file() if cwd.get_file() != "" else cwd)


# a deleted folder or a removed card leaves a stale list, so move to the nearest folder that still lists
func _leave_missing_folder() -> void:
	var gone := cwd
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
			toast("The folder %s is not available. Opened %s." % [gone.get_file(), _pretty_path(candidate)])
			return
	toast("The folder %s is not available." % gone.get_file(), true)


func _pretty_path(path: String) -> String:
	var home: String = places[0]["path"]
	return ("~" + path.trim_prefix(home)) if path.begins_with(home) else path


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
			if entries[i]["name"] == focus_name:
				cursor = i
				break
	top = 0
	_clamp_view()


func _set_filter(text: String) -> void:
	filter = text
	_apply_filter()
	if mode == Mode.KEYBOARD:
		_keyboard.set_title(_filter_title())


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
	return not e["is_dir"] and JoyThumbs.is_image(e["name"]) and e["size"] <= JoyThumbs.MAX_FILE_BYTES


func _open_current() -> void:
	if entries.is_empty():
		return
	var e: Dictionary = entries[cursor]
	if e["is_dir"]:
		navigate(e["path"])
	elif _previewable(e):
		preview.open(thumbs, entries, cursor)
		mode = Mode.PREVIEW
	else:
		_open_file(e)


# a good result is no proof, because Game Mode can accept the call and show nothing
func _open_file(e: Dictionary) -> void:
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
	if _visible_selection().is_empty():
		items.append(["Select all", select_all])
	else:
		items.append(["Clear selection", func(): selected.clear()])
	return items


func select_all() -> void:
	for e: Dictionary in entries:
		selected[e["path"]] = true


func _app_menu() -> Array:
	return [
		["Jobs (%d)" % jobs.size() if not jobs.is_empty() else "Jobs", _open_jobs],
		["Filter this folder", _ask_filter],
		["Sort...", _open_sort_menu],
		["Hide hidden files" if settings.show_hidden else "Show hidden files", _toggle_hidden],
		["Refresh", refresh],
		["Quit Joyfiles", _ask_quit],
	]


func _ask_quit() -> void:
	if jobs.is_empty():
		quitter.call()
		return
	var what := "A job is still running." if jobs.size() == 1 else "%d jobs are still running." % jobs.size()
	_confirm_label.text = what + " Quit anyway?"
	_on_confirm = quitter
	mode = Mode.CONFIRM


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
	mode = Mode.MENU


func _set_clipboard(paths: PackedStringArray, is_move: bool) -> void:
	clipboard = {"move": is_move, "paths": paths}
	selected.clear()
	toast("%d item(s) ready to %s. Open a folder and pick Paste." % [paths.size(), "move" if is_move else "copy"])


func paste() -> void:
	var id: int = core.start_job(clipboard["move"], clipboard["paths"], cwd)
	var watch := [cwd]
	if clipboard["move"]:
		for path: String in clipboard["paths"]:
			var parent: String = core.parent_dir(path)
			if parent not in watch:
				watch.append(parent)
		clipboard = {"move": false, "paths": PackedStringArray()}
	jobs[id] = {"watch": watch}


func _ask_rename(path: String) -> void:
	_ask_text("Rename", path.get_file(), func(new_name: String):
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
	_ask_text("Filter this folder", filter, _set_filter, _set_filter, func(): _set_filter(before))
	_keyboard.set_title(_filter_title())


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


func _ask_text(title: String, initial: String, on_submit: Callable, on_change := Callable(), on_cancel := Callable()) -> void:
	_on_submit = on_submit
	_on_change = on_change
	_on_cancel = on_cancel
	_keyboard.open(title, initial)
	mode = Mode.KEYBOARD


func _on_keyboard_submitted(text: String) -> void:
	mode = Mode.FILES
	_on_submit.call(text)
	_render()


func _on_keyboard_changed(text: String) -> void:
	if _on_change.is_valid():
		_on_change.call(text)


func _on_keyboard_cancelled() -> void:
	mode = Mode.FILES
	if _on_cancel.is_valid():
		_on_cancel.call()
	_render()


func _open_props(path: String) -> void:
	props_panel.open(core, path)
	mode = Mode.PROPS


func _open_jobs() -> void:
	mode = Mode.JOBS


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
		match job["state"]:
			"done":
				toast("Finished: %s." % job["current"])
			"failed":
				toast(job["error"], true)
			"cancelled":
				toast("The job was cancelled.")
		if job["state"] != "running":
			ended = true
			if cwd in jobs[id].get("watch", []):
				refresh()
				refreshed = true
			jobs.erase(id)
	if refreshed:
		_render()
	_ask_next_conflict()
	_render_status()
	if ended and not refreshed:
		_render_hints()
	if mode == Mode.JOBS:
		_render_overlay()


func _ask_next_conflict() -> void:
	if mode not in PROMPT_MODES:
		return
	for id: int in jobs:
		if not jobs[id].get("conflict", {}).is_empty():
			_open_conflict(id)
			return


func _open_conflict(id: int) -> void:
	_conflict_job = id
	_conflict_return = mode
	conflict_panel.open(jobs[id]["conflict"])
	mode = Mode.CONFLICT
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
	mode = _conflict_return


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
	mode = Mode.FILES


func _on_props_closed() -> void:
	props_panel.close()
	mode = Mode.FILES


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
	_path_label = Theme_.label("", Theme_.TEXT, 26, true)
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(_path_label)
	_filter_label = Theme_.label("", Theme_.WARN, 22)
	header_row.add_child(_filter_label)
	_sort_label = Theme_.label("", Theme_.MUTED, 22)
	header_row.add_child(_sort_label)
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
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(THUMB_BOX, THUMB_BOX)
		hb.add_child(slot)
		var thumb := TextureRect.new()
		thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.visible = false
		slot.add_child(thumb)
		var glyph := Theme_.label("", Theme_.ACCENT, 22)
		glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot.add_child(glyph)
		var name_label := Theme_.label("", Theme_.TEXT, 24, true)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(name_label)
		var size_label := Theme_.label("", Theme_.MUTED, 20)
		hb.add_child(size_label)
		list.add_child(row)
		_rows.append(row)
		_row_parts.append({"glyph": glyph, "thumb": thumb, "name": name_label, "size": size_label})

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
	confirm_box.add_child(Theme_.hints([["jf_accept", "Yes"], ["jf_back", "No"]]))
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
	jobs_panel.closed.connect(func(): mode = Mode.FILES)
	jobs_panel.cancel_requested.connect(core.cancel_job)
	jobs_panel.answer_requested.connect(_on_answer_requested)
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
	_path_label.text = _pretty_path(cwd)
	_filter_label.visible = filter != ""
	_filter_label.text = "Filter: " + filter
	_sort_label.text = "%s %s" % [JoySettings.SORTS[settings.sort_key][0], "▼" if settings.sort_desc else "▲"]
	_count_label.text = "%d / %d" % [cursor + 1 if not entries.is_empty() else 0, entries.size()]
	_render_rows()
	_render_places()
	_render_overlay()
	_render_hints()


func _render_rows() -> void:
	var wanted: Array = []
	for i in VISIBLE_ROWS:
		var row := _rows[i]
		var part: Dictionary = _row_parts[i]
		var idx := top + i
		part["thumb"].visible = false
		if idx >= entries.size():
			row.add_theme_stylebox_override("panel", Theme_.box_xy(Color.TRANSPARENT, 8, 8, 4))
			part["glyph"].text = ""
			part["name"].text = ""
			part["size"].text = ""
			if idx == 0:
				part["name"].text = "No items match the filter." if filter != "" else "This folder is empty."
				part["name"].add_theme_color_override("font_color", Theme_.MUTED)
			continue
		var e: Dictionary = entries[idx]
		var is_cursor: bool = idx == cursor and mode != Mode.PLACES
		var is_selected: bool = selected.has(e["path"])
		var bg := Theme_.ACCENT if is_cursor else (Theme_.ROW_SEL if is_selected else Color.TRANSPARENT)
		row.add_theme_stylebox_override("panel", Theme_.box_xy(bg, 8, 8, 4))
		var tex: Texture2D = null
		if _previewable(e):
			wanted.append(e["path"])
			tex = thumbs.texture(e["path"], JoyThumbs.THUMB_SIDE)
		part["thumb"].texture = tex
		part["thumb"].visible = tex != null
		part["thumb"].modulate.a = 0.45 if is_selected else 1.0
		var shape := "" if tex != null else ("▰" if e["is_dir"] else "▫")
		part["glyph"].text = ("✓" if is_selected else "") + shape
		part["glyph"].add_theme_color_override("font_color", Theme_.FOLDER if e["is_dir"] else Theme_.MUTED)
		part["name"].text = e["name"]
		part["name"].add_theme_color_override("font_color", Theme_.MUTED if e["hidden"] else Theme_.TEXT)
		part["size"].text = "" if e["is_dir"] else Theme_.human_size(e["size"])
	thumbs.want(wanted, JoyThumbs.THUMB_SIDE)


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
	_dim.visible = _panels.has(mode)
	for panel_mode: int in _panels:
		_panels[panel_mode].visible = panel_mode == mode
	if _overlay_renderers.has(mode):
		_overlay_renderers[mode].call()


func _render_menu() -> void:
	for child in _menu_box.get_children():
		child.queue_free()
	for i in menu_items.size():
		var l := Theme_.label(menu_items[i][0], Theme_.TEXT, 24)
		l.add_theme_stylebox_override("normal", Theme_.box(Theme_.ACCENT if i == menu_cursor else Color.TRANSPARENT, 8, 10))
		_menu_box.add_child(l)


const HINTS := {
	Mode.FILES: [["jf_accept", "Open"], ["jf_back", "Up"], ["jf_menu", "Actions"], ["jf_select", "Select"], ["jf_pane", "Places"], ["jf_start", "Menu"]],
	Mode.PLACES: [["jf_accept", "Go"], ["jf_back", "Back"], ["jf_start", "Menu"]],
	Mode.MENU: [["jf_accept", "Choose"], ["jf_back", "Close"]],
	Mode.KEYBOARD: [],
	Mode.CONFIRM: [["jf_accept", "Yes"], ["jf_back", "No"]],
	Mode.CONFLICT: [["jf_accept", "Choose"], ["jf_select", "All"], ["jf_back", "Cancel job"]],
	Mode.JOBS: [["jf_menu", "Cancel job"], ["jf_back", "Close"]],
	Mode.PROPS: [["jf_back", "Close"]],
	Mode.PREVIEW: [["jf_left", "Previous"], ["jf_right", "Next"], ["jf_back", "Close"]],
}


func _hints_for_mode() -> Array:
	var pairs: Array = HINTS[mode].duplicate()
	if mode in PROMPT_MODES and not jobs.is_empty():
		pairs.append(["jf_jobs", "Jobs"])
	if mode == Mode.FILES and filter != "":
		pairs = pairs.map(func(p: Array) -> Array: return [p[0], "Clear filter"] if p[0] == "jf_back" else p)
	return pairs


func _render_hints() -> void:
	if _hints:
		_hints.queue_free()
	_hints = Theme_.hints(_hints_for_mode())
	_footer.add_child(_hints)


func _render_status() -> void:
	var running := jobs.values().filter(func(j): return j.get("state", "running") == "running")
	if running.is_empty():
		_status.text = ""
		return
	var j: Dictionary = running[0]
	_status.add_theme_color_override("font_color", Theme_.TEXT)
	var verb := "Moving" if j.get("kind") == "move" else "Copying"
	if not j.get("conflict", {}).is_empty():
		_status.text = "%s paused: %s already exists." % [verb, j["conflict"]["name"]]
		return
	var pct: int = 0 if j.get("total_bytes", 0) == 0 else int(100.0 * j["done_bytes"] / j["total_bytes"])
	_status.text = "%s %s  %d%%" % [verb, j.get("current", ""), pct]
