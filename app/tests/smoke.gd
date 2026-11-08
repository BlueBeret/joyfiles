extends SceneTree

class ErrorCounter extends Logger:
	var count := 0

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		count += 1


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
	instance.opener = func(_path: String) -> int: return OK
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
	_filter_selection()
	await _images()
	await _preview_replay()
	await _move_refreshes_source()
	await _unknown_job()
	await _places_refresh()
	await _quit_with_job()
	_missing_folder()
	await _opening()
	await _job_failures()
	await _finish_toasts()
	await _trash_partial()
	_props_unknown()
	await _opaque_paths()
	_part_files()
	_glyphs()
	_keyboard_fallback()
	_settings_types()

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

	press("jf_accept")
	DirAccess.remove_absolute(base + "/dest/c.png")
	app.refresh()
	press("jf_back")
	check(app.mode == app.Mode.FILES and app.cursor < app.entries.size(), "B closes the preview of a file that vanished (cursor %d of %d)" % [app.cursor, app.entries.size()])


func _move_refreshes_source() -> void:
	var base := root_dir + "/moving"
	write(base + "/src/x.txt", "new")
	write(base + "/dst/x.txt", "old")
	app.navigate(base + "/src")
	pick("Select all")
	pick("Cut")
	app.navigate(base + "/dst")
	pick("Paste")
	app.navigate(base + "/src")
	check(names() == ["x.txt"], "the source lists its file while the move waits on a clash: %s" % [names()])
	await until(func(): return app.mode == app.Mode.CONFLICT, "the move asks about the clash")
	press("jf_up")
	press("jf_accept")
	await until(jobs_done, "the move ends")
	check(text_of(base + "/dst/x.txt") == "new" and not FileAccess.file_exists(base + "/src/x.txt"), "the move replaced the file and emptied the source")
	check(names().is_empty(), "the source folder refreshes when a move ends (%s)" % [names()])
	check(app._row_parts[0]["name"].text == "This folder is empty.", "the rows show the emptied source (%s)" % app._row_parts[0]["name"].text)


func _unknown_job() -> void:
	var base := root_dir + "/stray"
	write(base + "/in/s.txt", "x")
	DirAccess.make_dir_recursive_absolute(base + "/out")
	var counter := ErrorCounter.new()
	OS.add_logger(counter)
	app.jobs[99] = {"dest": ""}
	var stray: int = app.core.start_job(false, PackedStringArray([base + "/in/s.txt"]), base + "/out")
	await until(func(): return FileAccess.file_exists(base + "/out/s.txt"), "a job that the app never tracked still runs")
	await frames(10)
	check(not app.jobs.has(stray), "the app ignores a job it does not track")
	check(counter.count == 0, "polling an unknown job id raises no script error (%d)" % counter.count)
	app.jobs.erase(99)
	OS.remove_logger(counter)


func place_labels() -> Array:
	return app.places.map(func(p): return p["label"])


func _places_refresh() -> void:
	var home: Dictionary = app.places[0]
	var card := {"label": "SD CARD", "path": root_dir, "kind": "drive"}
	var drives: Array = [home]
	app.places_source = func() -> Array: return drives.duplicate(true)
	app.mode = app.Mode.FILES
	drives.append(card)
	press("jf_pane")
	check(place_labels() == [home["label"], "SD CARD"], "opening the places pane lists a card that was inserted: %s" % [place_labels()])
	press("jf_down")
	check(app.mode == app.Mode.PLACES and app.place_cursor == 1, "the cursor can rest on the new card")
	drives.pop_back()
	app._clock += 60.0
	await until(func(): return place_labels() == [home["label"]], "a timer drops a card that was removed")
	check(app.mode == app.Mode.PLACES and app.place_cursor == 0, "the cursor falls back to the last place that exists (%d)" % app.place_cursor)
	drives.append(card)
	app._clock += 60.0
	await until(func(): return place_labels() == [home["label"], "SD CARD"], "a timer lists a card that was inserted")
	app.mode = app.Mode.FILES
	app.places_source = app.core.places
	app.places = app.places_source.call()


func rm_tree(path: String) -> void:
	if not path.begins_with(root_dir + "/"):
		return
	for d in DirAccess.get_directories_at(path):
		rm_tree(path + "/" + d)
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path + "/" + f)
	DirAccess.remove_absolute(path)


func _missing_folder() -> void:
	var base := root_dir + "/vanish"
	write(base + "/top/mid/f.txt", "x")
	write(base + "/keep.txt", "x")
	app.navigate(base + "/top/mid")
	rm_tree(base + "/top")
	app.refresh()
	check(app.cwd == base, "refresh leaves a deleted folder for the nearest one that exists (%s)" % app.cwd)
	check(names() == ["keep.txt"], "the nearest folder lists its own entries: %s" % [names()])
	check(app._toast_label.text.begins_with("The folder mid is not available."), "a toast says that the folder is not available: %s" % app._toast_label.text)

	write(base + "/top/mid/f.txt", "x")
	app.navigate(base + "/top/mid")
	rm_tree(base + "/top")
	press("jf_back")
	check(app.cwd == base, "B on a deleted folder also lands on the nearest one that exists (%s)" % app.cwd)

	app.cwd = "Z:\\gone"
	app.refresh()
	check(app.cwd == app.places[0]["path"], "a folder with no ancestor that exists falls back to home (%s)" % app.cwd)


func _quit_with_job() -> void:
	var base := root_dir + "/leaving"
	var quits: Array = []
	app.quitter = func(): quits.append(1)
	app.mode = app.Mode.FILES
	pick_start("Quit")
	check(quits.size() == 1 and app.mode == app.Mode.FILES, "Quit leaves at once while no job runs")

	write_size(base + "/src/big.bin", 8 * 1024 * 1024)
	DirAccess.make_dir_recursive_absolute(base + "/dst")
	app.navigate(base + "/src")
	pick("Select all")
	pick("Copy")
	app.navigate(base + "/dst")
	pick("Paste")
	pick_start("Quit")
	check(app.mode == app.Mode.CONFIRM and quits.size() == 1, "Quit asks first while a job runs")
	check(app._confirm_label.text == "A job is still running. Quit and cancel it?", "the question says that quitting cancels the job: %s" % app._confirm_label.text)
	press("jf_back")
	check(app.mode == app.Mode.FILES and quits.size() == 1, "B keeps the app open")
	pick_start("Quit")
	press("jf_accept")
	check(quits.size() == 2 and app.mode == app.Mode.FILES, "A on the question quits")
	await until(jobs_done, "the job ends")
	app.quitter = app.get_tree().quit


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


func _load_settings(text: String) -> JoySettings:
	var path := root_dir.get_base_dir() + "/jf_smoke_types.cfg"
	write(path, text)
	var loaded := JoySettings.new(path)
	loaded.load_file()
	DirAccess.remove_absolute(path)
	return loaded


func _settings_types() -> void:
	var mixed := _load_settings('[view]\nsort_key="size"\nshow_hidden="false"\nsort_desc=true\n')
	check(mixed.sort_key == "size" and mixed.sort_desc and not mixed.show_hidden, "a string where a bool belongs keeps the other settings (%s, %s, %s)" % [mixed.sort_key, mixed.sort_desc, mixed.show_hidden])
	var listy := _load_settings('[view]\nsort_key="modified"\nshow_hidden=[1, 2]\nsort_desc=true\n')
	check(listy.sort_key == "modified" and listy.sort_desc and not listy.show_hidden, "a list where a bool belongs keeps the other settings")
	var numeric := _load_settings('[view]\nsort_key=5\nshow_hidden=true\nsort_desc=3\n')
	check(numeric.sort_key == "name" and numeric.show_hidden and not numeric.sort_desc, "a number where a string or bool belongs falls back for that key only")
	var unknown := _load_settings('[view]\nsort_key="colour"\nshow_hidden=true\n')
	check(unknown.sort_key == "name" and unknown.show_hidden, "an unknown sort key falls back to name")
	var good := _load_settings('[view]\nsort_key="type"\nshow_hidden=true\nsort_desc=true\n')
	check(good.sort_key == "type" and good.show_hidden and good.sort_desc, "a well formed file still loads whole")


func shell(script: String, dir: String) -> void:
	var output: Array = []
	OS.set_environment("JF_DIR", dir)
	var code := OS.execute("bash", ["-c", script], output, true)
	check(code == 0, "shell step ran (exit %d): %s" % [code, output])


func open_jobs_report() -> int:
	press("jf_jobs")
	check(app.mode == app.Mode.JOBS, "the jobs button opens the panel")
	var id: int = app.jobs_panel.focused_report()
	check(id >= 0, "the panel focuses a failure report")
	return id


func _job_failures() -> void:
	var base := root_dir + "/failing"
	DirAccess.make_dir_recursive_absolute(base + "/dst")
	var probe: int = app.core.start_job(false, PackedStringArray([base + "/nothing.txt"]), base + "/dst")
	var ended: Array = []
	for i in 400:
		ended = app.core.poll_jobs().filter(func(j: Dictionary) -> bool: return j["id"] == probe and j["state"] != "running")
		if not ended.is_empty():
			break
		await process_frame
	check(not ended.is_empty() and ended[0]["state"] == "failed", "a job with a failed item ends failed")
	var item: Dictionary = ended[0]["failures"][0] if not ended.is_empty() and not ended[0]["failures"].is_empty() else {}
	check(item.keys() == ["path", "name", "error"] and item["name"] == "nothing.txt", "poll_jobs lists each failure with path, name and error: %s" % [item])

	for n in ["a.txt", "b.txt", "c.txt"]:
		write("%s/src/%s" % [base, n], "x")
	app.navigate(base + "/src")
	pick("Select all")
	pick("Copy")
	DirAccess.remove_absolute(base + "/src/b.txt")
	DirAccess.remove_absolute(base + "/src/c.txt")
	app.navigate(base + "/dst")
	pick("Paste")
	await until(jobs_done, "a paste with two vanished sources ends")
	check(FileAccess.file_exists(base + "/dst/a.txt"), "the item that exists was copied")
	check(app.reports.size() == 1, "the ended job leaves one report (%d)" % app.reports.size())
	var report: Dictionary = app.reports.values()[0]
	var failed_names: Array = report["failures"].map(func(f: Dictionary) -> String: return f["name"])
	check(failed_names == ["b.txt", "c.txt"], "the report holds every failed item: %s" % [failed_names])
	check(app.last_error == "2 items could not be copied. Open Jobs to see them.", "the toast counts the failures and says where to look: %s" % app.last_error)
	check(app._status.text == "2 items failed. Open Jobs to see why.", "the footer keeps the failure in view after the toast: %s" % app._status.text)
	check(app._hints_for_mode().has(["jf_jobs", "Jobs"]), "the jobs hint stays while a report waits")
	check(app._jobs_label() == "Jobs (1 failed)", "the Start menu counts the report: %s" % app._jobs_label())

	var id := open_jobs_report()
	press("jf_accept")
	check(app.jobs_panel.viewing == id and app.jobs_panel.failure_texts.size() == 2, "A opens the failure list")
	check(app.jobs_panel.failure_texts[0].contains("b.txt") and app.jobs_panel.failure_texts[1].contains("c.txt"), "the list names each failed item: %s" % [app.jobs_panel.failure_texts])
	check(app._hints_for_mode() == [["jf_menu", "Dismiss"], ["jf_back", "Back"]], "the footer hints match the failure list: %s" % [app._hints_for_mode()])
	check(app.jobs_panel._detail_rows[1]["path"].text.ends_with("/src/c.txt"), "each row shows where the item is")
	press("jf_back")
	check(app.mode == app.Mode.JOBS and app.jobs_panel.viewing == -1, "B leaves the list and keeps the panel open")
	press("jf_back")
	check(app.mode == app.Mode.FILES and app.reports.size() == 1, "closing the panel keeps the report")
	open_jobs_report()
	press("jf_menu")
	check(app.reports.is_empty() and app.jobs_panel.report_ids.is_empty(), "X dismisses the report")
	check(app._status.text == "" and not app._hints_for_mode().any(func(p: Array) -> bool: return p[0] == "jf_jobs"), "a dismissed report leaves no trace in the footer")
	press("jf_back")

	for i in 12:
		write("%s/many/src/f%02d.txt" % [base, i], "x")
	DirAccess.make_dir_recursive_absolute(base + "/many/dst")
	app.navigate(base + "/many/src")
	pick("Select all")
	pick("Copy")
	for i in range(1, 12):
		DirAccess.remove_absolute("%s/many/src/f%02d.txt" % [base, i])
	app.navigate(base + "/many/dst")
	pick("Paste")
	await until(jobs_done, "the paste with eleven vanished sources ends")
	open_jobs_report()
	press("jf_accept")
	check(app.jobs_panel.failure_texts.size() == 11, "the list holds all eleven failures (%d)" % app.jobs_panel.failure_texts.size())
	for i in 3:
		press("jf_page_down")
	var last_row: Dictionary = app.jobs_panel._detail_rows[app.jobs_panel.DETAIL_ROWS - 1]
	check(app.jobs_panel.failure_cursor == 10 and last_row["message"].text == app.jobs_panel.failure_texts[10], "paging reaches the last failure (cursor %d)" % app.jobs_panel.failure_cursor)
	press("jf_menu")
	check(app.mode == app.Mode.JOBS and app.jobs_panel.viewing == -1 and app.reports.is_empty(), "X inside the list dismisses the report and shows the jobs")
	press("jf_back")


func _finish_toasts() -> void:
	var base := root_dir + "/finishing"
	for n in ["f1.txt", "f2.txt", "f3.txt"]:
		write("%s/src/%s" % [base, n], "x")
	DirAccess.make_dir_recursive_absolute(base + "/dst")
	DirAccess.make_dir_recursive_absolute(base + "/dst2")
	app.navigate(base + "/src")
	pick("Select all")
	pick("Copy")
	app.navigate(base + "/dst")
	pick("Paste")
	await until(jobs_done, "the three item paste ends")
	check(app._toast_label.text == "Copied 3 items.", "the toast counts the copied items: %s" % app._toast_label.text)
	app.navigate(base + "/src")
	cursor_to("f1.txt")
	pick("Cut")
	app.navigate(base + "/dst2")
	pick("Paste")
	await until(jobs_done, "the one item move ends")
	check(app._toast_label.text == "Moved f1.txt.", "the toast names a single moved item: %s" % app._toast_label.text)


func _trash_partial() -> void:
	var base := root_dir + "/trashing"
	for n in ["t1.txt", "t2.txt", "t3.txt"]:
		write("%s/%s" % [base, n], "x")
	app.navigate(base)
	pick("Select all")
	DirAccess.remove_absolute(base + "/t2.txt")
	pick("Move to trash")
	press("jf_accept")
	check(not FileAccess.file_exists(base + "/t1.txt") and not FileAccess.file_exists(base + "/t3.txt"), "the two items that exist went to the trash")
	check(app.last_error == "Moved 2 items to the trash. 1 item could not be moved. Open Jobs to see it.", "the toast says how many went to the trash and how many failed: %s" % app.last_error)
	check(app.reports.size() == 1 and app.reports.values()[0]["title"] == "Move to trash: 1 item failed", "the partial result leaves a report")
	open_jobs_report()
	press("jf_accept")
	check(app.jobs_panel.failure_texts.size() == 1 and app.jobs_panel.failure_texts[0].contains("t2.txt"), "the list names what failed: %s" % [app.jobs_panel.failure_texts])
	press("jf_menu")
	press("jf_back")

	write(base + "/u1.txt", "x")
	app.navigate(base)
	DirAccess.remove_absolute(base + "/u1.txt")
	pick("Move to trash")
	press("jf_accept")
	check(app.last_error == "Nothing was moved to the trash. 1 item could not be moved. Open Jobs to see it.", "a trash that moved nothing says so: %s" % app.last_error)
	app.reports.clear()
	app.refresh()


func _props_unknown() -> void:
	var base := root_dir + "/locked"
	var owner_only := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER
	write(base + "/closed/inside.txt", "x")
	FileAccess.set_unix_permissions(base + "/closed", 0)
	app.navigate(base)
	cursor_to("closed")
	pick("Properties")
	var shown: Dictionary = app.props_panel.shown
	if app.core.props(base + "/closed")["items"] >= 0:
		print("SKIP this account can read a folder without permission")
	else:
		check(shown["Contains"] == "Unknown (permission denied)", "a folder that cannot be read shows Unknown, not -1 items (%s)" % shown["Contains"])
		check(shown["Size"] == "Unknown (permission denied)" and app.props_panel.scan_done, "its size is unknown too, and no scan runs (%s)" % shown["Size"])
	press("jf_back")
	FileAccess.set_unix_permissions(base + "/closed", owner_only)


func _opaque_paths() -> void:
	if OS.get_name() != "Linux":
		return
	var base := root_dir + "/opaque"
	var counter := ErrorCounter.new()
	OS.add_logger(counter)
	_png(base + "/ok.png", 16, 16, Color.RED)
	DirAccess.make_dir_recursive_absolute(base + "/aaa_dir")
	DirAccess.make_dir_recursive_absolute(base + "/out")
	shell("cp \"$JF_DIR/ok.png\" \"$JF_DIR/caf$(printf '\\351').png\"", base)
	shell("printf x > \"$JF_DIR/note$(printf '\\351').txt\"", base)
	shell("mkdir \"$JF_DIR/dir$(printf '\\351')\" && printf x > \"$JF_DIR/dir$(printf '\\351')/inner.txt\"", base)
	check(app.core.join(base, "ok.png") == base + "/ok.png", "core.join builds a child path")
	show(base)
	var odd: Array = app.entries.filter(func(e: Dictionary) -> bool: return JoyPathText.is_opaque(e["path"]))
	check(odd.size() == 3, "three entries carry a name that is not valid text (%d)" % odd.size())
	check(names().has("caf\ufffd.png") and names().has("note\ufffd.txt") and names().has("dir\ufffd"), "the list shows the readable name: %s" % [names()])
	await until(func(): return app.thumbs.entry(base + "/ok.png", JoyThumbs.THUMB_SIDE).has("tex"), "the valid image next to it still gets a thumbnail")
	await frames(30)
	check(not app.thumbs.cache.keys().any(func(k: String) -> bool: return JoyPathText.is_opaque(k)), "no thumbnail is requested for a path that is not valid text")
	check(counter.count == 0, "listing such a folder raises no engine error (%d)" % counter.count)

	var opened: Array = []
	app.opener = func(p: String) -> int:
		opened.append(p)
		return OK
	cursor_to("caf\ufffd.png")
	press("jf_accept")
	check(app.mode == app.Mode.FILES and opened.is_empty(), "A on such an image neither previews nor hands the path to the system")
	check(app.last_error.begins_with("Could not open caf\ufffd.png."), "the toast says why it cannot open: %s" % app.last_error)
	cursor_to("ok.png")
	press("jf_accept")
	check(app.mode == app.Mode.PREVIEW, "the valid image still previews")
	press("jf_right")
	check(app.preview.current()["name"] == "ok.png", "the preview skips an image whose name is not valid text")
	press("jf_back")
	app.opener = func(_path: String) -> int: return OK

	cursor_to("note\ufffd.txt")
	pick("Rename")
	check(app._keyboard.text == "note\ufffd.txt", "rename starts from the readable name (%s)" % app._keyboard.text)
	press("jf_view")
	cursor_to("note\ufffd.txt")
	pick("Properties")
	check(app.props_panel.shown["Name"] == "note\ufffd.txt" and app.props_panel.shown["Path"] == base + "/note\ufffd.txt", "properties show the name field and a path with U+FFFD: %s" % [app.props_panel.shown])
	press("jf_back")
	pick("Copy")
	check(app.clipboard["label"] == "note\ufffd.txt", "the clipboard labels the item with its readable name")
	app.navigate(base + "/out")
	pick("Paste")
	await until(jobs_done, "the copy of such a file ends")
	check(app._toast_label.text == "Copied note\ufffd.txt." and app.reports.is_empty(), "the toast names the copy: %s" % app._toast_label.text)
	check(names() == ["note\ufffd.txt"] and JoyPathText.is_opaque(app.entries[0]["path"]), "the copy kept the exact name: %s" % [names()])

	show(base)
	cursor_to("dir\ufffd")
	press("jf_accept")
	check(names() == ["inner.txt"] and JoyPathText.is_opaque(app.cwd), "A opens a folder whose name is not valid text")
	check(not JoyPathText.is_opaque(app._path_label.text) and app._path_label.text.contains("\ufffd"), "the header shows U+FFFD for the bad byte (%s)" % app._path_label.text)
	press("jf_back")
	check(app.cwd == base and app.entries[app.cursor]["name"] == "dir\ufffd", "B goes up and lands on that folder (cursor on %s)" % app.entries[app.cursor]["name"])
	check(not app._toast_label.text.contains("not available"), "going up from it does not call it a missing folder: %s" % app._toast_label.text)
	cursor_to("dir\ufffd")
	pick("Properties")
	check(app.props_panel.shown["Name"] == "dir\ufffd" and not JoyPathText.is_opaque(app.props_panel.shown["Path"]), "properties of such a folder show a path without escape characters")
	await until(func(): return app.props_panel.scan_done, "the scan of such a folder ends")
	check(app.props_panel.shown["Size"].begins_with("1 B"), "the scan counts the file inside (%s)" % app.props_panel.shown["Size"])
	press("jf_back")
	check(counter.count == 0, "none of this raises an engine error (%d)" % counter.count)
	OS.remove_logger(counter)


func _part_files() -> void:
	var base := root_dir + "/leftovers"
	write(base + "/doc.txt", "x")
	write(base + "/.dotfile", "x")
	write(base + "/.doc.txt.joyfiles-part", "x")
	write(base + "/.doc.txt.2.joyfiles-part", "x")
	app.navigate(base)
	check(names() == ["doc.txt"], "a leftover part file stays out of the list: %s" % [names()])
	app.settings.show_hidden = true
	app.refresh()
	check(names().has(".dotfile") and names().size() == 2, "hidden files show, but a leftover part file still does not: %s" % [names()])
	app.settings.show_hidden = false
	app.refresh()


func menu_labels() -> Array:
	return app.menu_items.map(func(i): return i[0])


func _filter_selection() -> void:
	var base := root_dir + "/hiding"
	for n in ["photo_a.txt", "photo_b.txt", "doc1.txt", "doc2.txt", "doc3.txt", "doc4.txt"]:
		write("%s/%s" % [base, n], "x")
	app.navigate(base)
	pick("Select all")
	check(app.selected.size() == 6, "select all marks the six items")
	app._set_filter("photo")
	check(app.targets().size() == 2, "actions skip the selected items that the filter hides (%d)" % app.targets().size())
	press("jf_menu")
	check("Copy (2)" in menu_labels() and "Move to trash (2)" in menu_labels(), "the file menu counts only the visible selection: %s" % [menu_labels()])
	press("jf_back")
	_trash_text_of_filtered()
	app._set_filter("")
	check(app.targets().size() == 6, "clearing the filter brings the whole selection back (%d)" % app.targets().size())

	app.selected.clear()
	app.selected[base + "/doc1.txt"] = true
	app._set_filter("photo")
	check(app.targets() == PackedStringArray([app.entries[app.cursor]["path"]]), "a selection that the filter hides leaves the cursor item as the target")
	app._set_filter("")
	app.selected.clear()


func _trash_text_of_filtered() -> void:
	pick("Move to trash")
	check(app.mode == app.Mode.CONFIRM and app._confirm_label.text == "Move 2 items to the trash?", "the trash question names the visible items (%s)" % app._confirm_label.text)
	press("jf_back")


func _bytes(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	b.fill(7)
	return b
