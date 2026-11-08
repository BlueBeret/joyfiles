extends SceneTree

var app: Control
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


func frames(n := 2) -> void:
	for i in n:
		await process_frame


func press(action: String) -> void:
	app.fire(action)


func pick(prefix: String) -> void:
	press("jf_menu")
	var idx := -1
	for i in app.menu_items.size():
		if String(app.menu_items[i][0]).begins_with(prefix):
			idx = i
	check(idx >= 0, "menu has '%s'" % prefix)
	for i in idx:
		press("jf_down")
	press("jf_accept")


func cursor_to(name: String) -> void:
	for i in app.entries.size():
		if app.entries[i]["name"] == name:
			app.cursor = i


func _run() -> void:
	var root_dir := OS.get_environment("JF_TEST_DIR")
	DirAccess.make_dir_recursive_absolute(root_dir + "/beta")
	FileAccess.open(root_dir + "/alpha.txt", FileAccess.WRITE).store_string("hello")
	var big := FileAccess.open(root_dir + "/gamma.bin", FileAccess.WRITE)
	big.store_buffer(_bytes(3 * 1024 * 1024))
	big.close()

	var scene: PackedScene = load("res://main.tscn")
	app = scene.instantiate()
	app.start_path = root_dir
	root.add_child(app)
	await frames()

	var names: Array = app.entries.map(func(e): return e["name"])
	check(names == ["beta", "alpha.txt", "gamma.bin"], "lists folders first: %s" % [names])

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

	print("RESULT %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(failures)


func _bytes(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	b.fill(7)
	return b
