extends SceneTree

var app: Control
var failures := 0
var root_dir := ""
var settings_file := ""


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


func frames(n := 2) -> void:
	for i in n:
		await process_frame


func until(cond: Callable, what: String, max_frames := 400) -> void:
	for i in max_frames:
		if cond.call():
			break
		await process_frame
	check(cond.call(), what)


func press(action: String) -> void:
	app.fire(action)


func choose(prefix: String) -> void:
	var idx := -1
	for i in app.menu_items.size():
		if String(app.menu_items[i][0]).begins_with(prefix):
			idx = i
	check(idx >= 0, "menu has '%s'" % prefix)
	if idx < 0:
		press("jf_back")
		return
	for i in idx:
		press("jf_down")
	press("jf_accept")


func pick(prefix: String) -> void:
	press("jf_menu")
	choose(prefix)


func pick_start(prefix: String) -> void:
	press("jf_start")
	choose(prefix)


func cursor_to(name: String) -> void:
	for i in app.entries.size():
		if app.entries[i]["name"] == name:
			app.cursor = i


func write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func write_size(path: String, n: int) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(_bytes(n))
	f.close()


func text_of(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func names() -> Array:
	return app.entries.map(func(e): return e["name"])


func show(path: String) -> void:
	app.navigate(path)
	app._render()


func jobs_done() -> bool:
	return app.jobs.is_empty()


func start_app(path: String) -> Control:
	var scene: PackedScene = load("res://main.tscn")
	var instance: Control = scene.instantiate()
	instance.start_path = path
	instance.settings_path = settings_file
	root.add_child(instance)
	return instance


func _run() -> void:
	root_dir = OS.get_environment("JF_TEST_DIR")
	settings_file = root_dir.get_base_dir() + "/jf_smoke_settings.cfg"
	DirAccess.remove_absolute(settings_file)
	DirAccess.make_dir_recursive_absolute(root_dir + "/beta")
	FileAccess.open(root_dir + "/alpha.txt", FileAccess.WRITE).store_string("hello")
	var big := FileAccess.open(root_dir + "/gamma.bin", FileAccess.WRITE)
	big.store_buffer(_bytes(3 * 1024 * 1024))
	big.close()

	app = start_app(root_dir)
	await frames()

	var listed: Array = names()
	check(listed == ["beta", "alpha.txt", "gamma.bin"], "lists folders first: %s" % [listed])

	var a := InputEventJoypadButton.new()
	a.button_index = JOY_BUTTON_A
	check(InputMap.event_is_action(a, "jf_accept"), "A button maps to accept")
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_Y
	stick.axis_value = 1.0
	check(InputMap.event_is_action(stick, "jf_down"), "left stick down maps to down")

	var dpad := InputEventJoypadButton.new()
	dpad.button_index = JOY_BUTTON_DPAD_DOWN
	dpad.pressed = true
	Input.parse_input_event(dpad)
	await frames()
	var release: InputEventJoypadButton = dpad.duplicate()
	release.pressed = false
	Input.parse_input_event(release)
	await frames()
	check(app.cursor == 1, "real D-pad event moves the cursor once (cursor=%d)" % app.cursor)

	press("jf_select")
	press("jf_select")
	check(app.selected.size() == 2, "Y selects two files")
	pick("Copy")
	check(app.clipboard["paths"].size() == 2, "copy puts two paths on the clipboard")

	cursor_to("beta")
	press("jf_accept")
	check(app.cwd.ends_with("beta"), "A opens the folder")
	pick("Paste")
	for i in 300:
		await frames(1)
		if app.jobs.is_empty():
			break
	check(FileAccess.file_exists(root_dir + "/beta/gamma.bin"), "paste copies the big file")
	check(FileAccess.get_file_as_string(root_dir + "/beta/alpha.txt") == "hello", "paste copies file content")
	check(app.entries.size() == 2, "folder refreshes after the job")

	cursor_to("alpha.txt")
	pick("Rename")
	check(app.mode == app.Mode.KEYBOARD, "rename opens the on-screen keyboard")
	for i in "alpha.txt".length():
		press("jf_back")
	press("jf_accept")
	press("jf_select")
	press("jf_accept")
	press("jf_start")
	check(FileAccess.file_exists(root_dir + "/beta/qQ"), "keyboard rename writes qQ")

	pick("New folder")
	press("jf_right")
	press("jf_accept")
	press("jf_start")
	check(DirAccess.dir_exists_absolute(root_dir + "/beta/w"), "new folder w exists")

	cursor_to("gamma.bin")
	pick("Move to trash")
	check(app.mode == app.Mode.CONFIRM, "trash asks for confirmation")
	press("jf_back")
	check(FileAccess.file_exists(root_dir + "/beta/gamma.bin"), "B cancels the trash")
	pick("Move to trash")
	press("jf_accept")
	check(not FileAccess.file_exists(root_dir + "/beta/gamma.bin"), "A moves the file to the trash")

	press("jf_back")
	check(app.cwd == root_dir, "B goes up to the parent")
	check(app.entries[app.cursor]["name"] == "beta", "cursor returns to the folder we left")

	press("jf_pane")
	check(app.mode == app.Mode.PLACES, "LB focuses places")
	press("jf_accept")
	check(app.cwd == app.places[0]["path"], "A opens the Home place")

	await _conflicts()
	await _jobs_panel()
	await _properties()
	await _sorting()
	await _filtering()
	await _images()
	await _preview_replay()
	await _opening()
	_glyphs()
	_keyboard_fallback()

	DirAccess.remove_absolute(settings_file)
	print("RESULT %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(failures)


func _conflicts() -> void:
	var base := root_dir + "/clash"
	for n in ["a.txt", "b.txt", "c.txt", "d.txt"]:
		write("%s/src/%s" % [base, n], "new-" + n)
	for n in ["a.txt", "b.txt", "c.txt"]:
		write("%s/dst/%s" % [base, n], "old-" + n)
		write("%s/dst2/%s" % [base, n], "old-" + n)
	write(base + "/dst3/a.txt", "old-a.txt")

	app.navigate(base + "/src")
	pick("Select all")
	pick("Copy")
	app.navigate(base + "/dst")
	pick("Paste")
	await until(func(): return app.mode == app.Mode.CONFLICT, "a clashing paste opens the prompt")
	check(app.conflict_panel.conflict["name"] == "a.txt", "the prompt names the first clash")
	check(app.conflict_panel.cursor == 1, "the prompt starts on Keep both, the safe choice")
	check(text_of(base + "/dst/a.txt") == "old-a.txt", "the job waits and leaves the old file alone")
	press("jf_up")
	press("jf_accept")
	check(app.mode == app.Mode.FILES, "answering closes the prompt")
	await until(func(): return app.mode == app.Mode.CONFLICT and app.conflict_panel.conflict["name"] == "b.txt", "the next clash gets its own prompt")
	press("jf_accept")
	await until(func(): return app.mode == app.Mode.CONFLICT and app.conflict_panel.conflict["name"] == "c.txt", "the third clash gets a prompt")
	press("jf_down")
	press("jf_accept")
	await until(jobs_done, "the job finishes after the last answer")
	check(text_of(base + "/dst/a.txt") == "new-a.txt", "Replace overwrites the old file")
	check(text_of(base + "/dst/b.txt") == "old-b.txt" and text_of(base + "/dst/b (2).txt") == "new-b.txt", "Keep both adds a numbered copy")
	check(text_of(base + "/dst/c.txt") == "old-c.txt" and not FileAccess.file_exists(base + "/dst/c (2).txt"), "Skip leaves the old file and adds nothing")
	check(text_of(base + "/dst/d.txt") == "new-d.txt", "a name without a clash copies as usual")

	app.navigate(base + "/dst2")
	pick("Paste")
	await until(func(): return app.mode == app.Mode.CONFLICT, "the second paste prompts again")
	press("jf_select")
	check(app.conflict_panel.apply_all, "Y turns on apply to all")
	press("jf_up")
	press("jf_accept")
	var asked_again := false
	for i in 400:
		await process_frame
		asked_again = asked_again or app.mode == app.Mode.CONFLICT
		if app.jobs.is_empty():
			break
	check(not asked_again, "apply to all asks only once")
	check(text_of(base + "/dst2/a.txt") == "new-a.txt" and text_of(base + "/dst2/c.txt") == "new-c.txt", "apply to all replaced every clash")

	app.navigate(base + "/dst3")
	pick("Paste")
	await until(func(): return app.mode == app.Mode.CONFLICT, "the third paste prompts")
	press("jf_back")
	check(app.mode == app.Mode.FILES, "B on the prompt closes it")
	await until(jobs_done, "B on the prompt cancels the job")
	check(text_of(base + "/dst3/a.txt") == "old-a.txt", "a cancelled job leaves the old file alone")


func _jobs_panel() -> void:
	var base := root_dir + "/jobs"
	write_size(base + "/src/aa_big.bin", 2 * 1024 * 1024)
	write(base + "/src/zz.txt", "new")
	write(base + "/dst/zz.txt", "old")
	app.navigate(base + "/src")
	pick("Select all")
	pick("Copy")
	app.navigate(base + "/dst")
	pick("Paste")
	pick_start("Jobs")
	check(app.mode == app.Mode.JOBS, "the Start menu opens the jobs panel")
	await until(func(): return app.jobs.size() == 1 and not app.jobs.values()[0].get("conflict", {}).is_empty(), "the job reports its clash")
	var id: int = app.jobs.keys()[0]
	check(app.mode == app.Mode.JOBS, "no prompt cuts into the jobs panel")
	check(app.jobs_panel.ids == [id], "the panel lists the running job")
	check(app.jobs_panel.progress_of(id) > 0.9, "the progress bar shows the bytes done so far (%.3f)" % app.jobs_panel.progress_of(id))
	press("jf_menu")
	await until(jobs_done, "X on the panel cancels the focused job")
	check(app.mode == app.Mode.JOBS, "the panel stays open after a cancel")
	check(text_of(base + "/dst/zz.txt") == "old", "the cancelled job left the old file alone")
	check(app.jobs_panel.ids.is_empty(), "the panel shows no jobs after the cancel")
	press("jf_back")
	check(app.mode == app.Mode.FILES, "B closes the jobs panel")

	pick("Paste")
	press("jf_jobs")
	check(app.mode == app.Mode.JOBS, "the jobs button opens the panel")
	await until(func(): return not app.jobs.is_empty() and app.jobs_panel.is_waiting(app.jobs.keys()[0], app.jobs), "the second job waits for an answer")
	press("jf_accept")
	check(app.mode == app.Mode.CONFLICT, "A on a waiting job opens its prompt")
	press("jf_select")
	press("jf_down")
	press("jf_accept")
	check(app.mode == app.Mode.JOBS, "answering returns to the jobs panel")
	await until(jobs_done, "the job ends after the answer")
	press("jf_jobs")
	check(app.mode == app.Mode.FILES, "the jobs button closes the panel again")


func _properties() -> void:
	var base := root_dir + "/props"
	write_size(base + "/p1.bin", 1000)
	write_size(base + "/sub/p2.bin", 500)
	app.navigate(base)
	cursor_to("p1.bin")
	pick("Properties")
	check(app.mode == app.Mode.PROPS, "the actions menu opens properties")
	var shown: Dictionary = app.props_panel.shown
	check(shown["Name"] == "p1.bin" and shown["Path"] == base + "/p1.bin", "properties show name and full path: %s" % [shown])
	check(shown["Type"] == "BIN file", "properties show the type")
	check(shown["Size"] == "1,000 B", "properties show the file size (%s)" % shown["Size"])
	check(shown["Modified"].length() == 16, "properties show the modified date (%s)" % shown["Modified"])
	check(shown["Contains"] == "", "a file has no item count")
	press("jf_back")
	check(app.mode == app.Mode.FILES, "B closes properties")

	app.navigate(root_dir)
	cursor_to("props")
	pick("Properties")
	check(shown["Type"] == "Folder" and shown["Contains"] == "2 items", "a folder shows its item count (%s)" % shown["Contains"])
	await until(func(): return app.props_panel.scan_done, "the folder size scan finishes")
	check(shown["Size"] == "1.5 KB (2 files, 1 folder)", "the scan totals every file below (%s)" % shown["Size"])
	press("jf_back")


func _sorting() -> void:
	var base := root_dir + "/sorting"
	DirAccess.make_dir_recursive_absolute(base + "/dir1")
	write(base + "/b.txt", "0123456789")
	write_size(base + "/a.png", 300)
	write_size(base + "/c.log", 5000)
	write(base + "/.hidden", "x")
	app.navigate(base)
	check(names() == ["dir1", "a.png", "b.txt", "c.log"], "the default order is by name: %s" % [names()])

	pick_start("Sort")
	choose("Size")
	check(names() == ["dir1", "b.txt", "a.png", "c.log"], "sort by size, smallest first: %s" % [names()])
	pick_start("Sort")
	choose("Order")
	check(names() == ["dir1", "c.log", "a.png", "b.txt"], "the order item flips to largest first: %s" % [names()])
	var cfg := ConfigFile.new()
	check(cfg.load(settings_file) == OK, "sorting writes the settings file")
	check(cfg.get_value("view", "sort_key") == "size" and cfg.get_value("view", "sort_desc") == true, "the file holds the sort choice")

	pick_start("Sort")
	choose("Type")
	check(names() == ["dir1", "b.txt", "a.png", "c.log"], "sort by type, descending: %s" % [names()])
	pick_start("Sort")
	choose("Modified")
	check(names()[0] == "dir1" and names().size() == 4, "sort by modified keeps folders first")

	press("jf_view")
	check(".hidden" in names(), "the view button shows hidden files")
	check(cfg.load(settings_file) == OK and cfg.get_value("view", "show_hidden") == true, "the hidden choice is saved")

	var second := start_app(base)
	await frames()
	check(second.settings.sort_key == "modified" and second.settings.sort_desc and second.settings.show_hidden, "a new session reads the saved settings")
	check(second.entries.size() == 5 and second.entries[0]["name"] == "dir1", "a new session lists with the saved sort and hidden choice")
	second.queue_free()
	await frames()

	app.settings.sort_key = "name"
	app.settings.sort_desc = false
	app.settings.show_hidden = false
	app.refresh()


func _filtering() -> void:
	var base := root_dir + "/finding"
	for n in ["apple.txt", "banana.txt", "cherry.txt", "apricot.txt", "Zebra.txt"]:
		write("%s/%s" % [base, n], "x")
	app.navigate(base)
	press("jf_search")
	check(app.mode == app.Mode.KEYBOARD, "the search button opens the on-screen keyboard")
	press("jf_down")
	press("jf_accept")
	check(app.filter == "a" and app.entries.size() == 4, "typing a filters live, case blind: %s" % [names()])
	press("jf_up")
	press("jf_left")
	press("jf_accept")
	check(names() == ["apple.txt", "apricot.txt"], "typing ap narrows the list: %s" % [names()])
	press("jf_start")
	check(app.mode == app.Mode.FILES and app.filter == "ap", "Done keeps the filter on")
	check(app.all_entries.size() == 5, "the folder listing is still complete")
	press("jf_back")
	check(app.filter == "" and app.entries.size() == 5 and app.cwd == base, "B clears the filter and stays in the folder")
	press("jf_back")
	check(app.cwd == root_dir, "a second B goes up")

	app.navigate(base)
	press("jf_search")
	press("jf_down")
	press("jf_down")
	press("jf_accept")
	check(names() == ["Zebra.txt"], "a lowercase z finds Zebra: %s" % [names()])
	press("jf_view")
	check(app.mode == app.Mode.FILES and app.filter == "" and app.entries.size() == 5, "cancelling the keyboard restores the old filter")

	app.navigate(base)
	pick_start("Filter")
	check(app.mode == app.Mode.KEYBOARD, "the Start menu offers the filter")
	press("jf_view")
	app.navigate(base)
	press("jf_search")
	press("jf_down")
	press("jf_accept")
	press("jf_start")
	check(app.filter == "a", "the filter stays set after Done")
	app.navigate(root_dir)
	check(app.filter == "", "opening another folder drops the filter")


func _png(path: String, w: int, h: int, color: Color) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	img.fill(color)
	match path.get_extension():
		"png": img.save_png(path)
		"jpg": img.save_jpg(path, 0.9)
		"webp": img.save_webp(path)


func _images() -> void:
	var base := root_dir + "/pics"
	_png(base + "/one.png", 64, 48, Color.RED)
	_png(base + "/two.jpg", 80, 40, Color.GREEN)
	_png(base + "/three.webp", 32, 32, Color.BLUE)
	write(base + "/note.txt", "text")
	write(base + "/bad.png", "this is not an image")
	show(base)
	var side := JoyThumbs.THUMB_SIDE
	var wanted := ["one.png", "two.jpg", "three.webp"]
	await until(func(): return wanted.all(func(n): return app.thumbs.entry("%s/%s" % [base, n], side).has("tex")), "png, jpg and webp thumbnails load")
	check(app.thumbs.entry(base + "/one.png", side)["size"] == Vector2i(64, 48), "the thumbnail keeps the original size for the info line")
	await until(func(): return app.thumbs.cache.has(JoyThumbs.key_of(base + "/bad.png", side)), "a broken image is tried once")
	check(app.thumbs.entry(base + "/bad.png", side).is_empty(), "a broken image gives no texture and no crash")
	var row := names().find("one.png")
	check(app._row_parts[row]["thumb"].visible, "the list row shows the thumbnail")
	check(not app._row_parts[names().find("note.txt")]["thumb"].visible, "a text file row shows no thumbnail")

	var many := root_dir + "/many"
	for i in 40:
		_png("%s/img_%02d.png" % [many, i], 8, 8, Color.WHITE)
	var cached_before: int = app.thumbs.cache.size()
	show(many)
	await until(func(): return app.thumbs.cache.size() >= cached_before + app.VISIBLE_ROWS, "thumbnails of the first rows load")
	await frames(30)
	check(app.thumbs.cache.size() == cached_before + app.VISIBLE_ROWS, "a folder of 40 images decodes one screenful (%d new)" % (app.thumbs.cache.size() - cached_before))
	check(not app.thumbs.cache.has(JoyThumbs.key_of(many + "/img_39.png", side)), "rows below the screen are not decoded yet")
	press("jf_page_down")
	press("jf_page_down")
	var far: String = app.entries[app.cursor]["path"]
	await until(func(): return app.thumbs.entry(far, side).has("tex"), "scrolling loads the new rows")

	show(base)
	cursor_to("one.png")
	press("jf_accept")
	check(app.mode == app.Mode.PREVIEW and app.preview.current()["name"] == "one.png", "A on an image opens the preview")
	await until(func(): return app.preview.showing_full, "the large image loads")
	press("jf_right")
	check(app.preview.current()["name"] == "three.webp", "right shows the next image and skips text files: %s" % app.preview.current()["name"])
	press("jf_right")
	press("jf_right")
	check(app.preview.current()["name"] == "two.jpg", "right stops at the last image")
	press("jf_left")
	press("jf_back")
	check(app.mode == app.Mode.FILES and app.entries[app.cursor]["name"] == "three.webp", "B closes the preview on the image we reached")


func _preview_replay() -> void:
	var base := root_dir + "/replay"
	_png(base + "/dest/b.png", 16, 16, Color.RED)
	_png(base + "/dest/c.png", 16, 16, Color.BLUE)
	write_size(base + "/src/a.bin", 8 * 1024 * 1024)
	app.navigate(base + "/src")
	pick("Select all")
	pick("Copy")
	show(base + "/dest")
	cursor_to("c.png")
	pick("Paste")
	press("jf_accept")
	check(app.mode == app.Mode.PREVIEW and app.preview.current()["name"] == "c.png", "A opens the preview on c.png while the paste runs")
	check(not app.jobs.is_empty() and names() == ["b.png", "c.png"], "the folder has not refreshed when the preview opens")
	await until(jobs_done, "the paste ends while the preview is open")
	check(names() == ["a.bin", "b.png", "c.png"], "the refresh adds a.bin in front: %s" % [names()])
	press("jf_back")
	check(app.mode == app.Mode.FILES and app.entries[app.cursor]["name"] == "c.png", "B closes the preview on c.png after a refresh moved it (cursor on %s)" % app.entries[app.cursor]["name"])


func _opening() -> void:
	var path := root_dir + "/pics/note.txt"
	var opened: Array = []
	show(root_dir + "/pics")
	cursor_to("note.txt")
	app.opener = func(p: String) -> int:
		opened.append(p)
		return ERR_UNAVAILABLE
	press("jf_accept")
	check(opened == [path], "A on a file asks the system to open it")
	check(app.last_error.begins_with("Could not open note.txt"), "a failed open shows an error toast: %s" % app.last_error)
	app.opener = func(p: String) -> int:
		return OK
	press("jf_accept")
	check(app.last_error == "" and app._toast_label.text.begins_with("Asked the system to open note.txt"), "a good open shows a plain toast: %s" % app._toast_label.text)


func glyph_actions(node: Node) -> Array:
	var found: Array = []
	for child in node.get_children():
		if child is JoyGlyph:
			found.append(child.action)
		found.append_array(glyph_actions(child))
	return found


func _glyphs() -> void:
	var unglyphed := JoyInput.ACTIONS.keys().filter(func(a): return not JoyGlyph.SPECS.has(a))
	check(unglyphed.is_empty(), "every input action has a glyph: %s" % [unglyphed])
	var unbound := JoyGlyph.SPECS.keys().filter(func(a): return not JoyInput.ACTIONS.has(a))
	check(unbound.is_empty(), "every glyph names a real action: %s" % [unbound])
	var unknown: Array = []
	for mode: int in app.HINTS:
		for pair: Array in app.HINTS[mode]:
			if not JoyGlyph.SPECS.has(pair[0]):
				unknown.append(pair[0])
	check(unknown.is_empty(), "every hint table entry is keyed by an action: %s" % [unknown])

	app.navigate(root_dir)
	app.mode = app.Mode.FILES
	app._render()
	var expected := ["jf_accept", "jf_back", "jf_menu", "jf_select", "jf_pane", "jf_start"]
	check(glyph_actions(app._hints) == expected, "the footer draws one glyph per hint: %s" % [glyph_actions(app._hints)])
	check(app._hints_for_mode().has(["jf_back", "Up"]), "back reads Up without a filter")
	app._set_filter("ap")
	check(app._hints_for_mode().has(["jf_back", "Clear filter"]), "back reads Clear filter while a filter is on")
	app._set_filter("")
	check(not app._hints_for_mode().any(func(p): return p[0] == "jf_jobs"), "no jobs hint while no job runs")
	app.jobs[99] = {"dest": ""}
	check(app._hints_for_mode().has(["jf_jobs", "Jobs"]), "the jobs hint shows while a job runs")
	app.jobs.erase(99)
	for panel in [app.conflict_panel, app.jobs_panel, app.props_panel, app.preview, app._keyboard]:
		check(not glyph_actions(panel).is_empty(), "%s draws glyph hints" % panel.get_script().get_global_name())


func _keyboard_fallback() -> void:
	var enter := InputEventKey.new()
	enter.physical_keycode = KEY_ENTER
	check(InputMap.event_is_action(enter, "jf_accept"), "the Enter key still maps to accept")
	var no_key := JoyInput.ACTIONS.keys().filter(func(a): return not JoyInput.ACTIONS[a].any(func(b): return b[0] == JoyInput.KEY))
	check(no_key.is_empty(), "every action keeps a keyboard key: %s" % [no_key])
	app.navigate(root_dir)
	app.mode = app.Mode.FILES
	press("jf_search")
	var typed := InputEventKey.new()
	typed.pressed = true
	typed.keycode = KEY_Q
	typed.unicode = 113
	app._unhandled_input(typed)
	check(app.mode == app.Mode.KEYBOARD and app.filter == "q", "a physical key types into the on-screen keyboard (filter=%s)" % app.filter)
	var done := InputEventKey.new()
	done.pressed = true
	done.keycode = KEY_ENTER
	app._unhandled_input(done)
	check(app.mode == app.Mode.FILES, "the Enter key finishes the on-screen keyboard")
	app._set_filter("")


func _bytes(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	b.fill(7)
	return b
