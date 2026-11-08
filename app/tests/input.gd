extends RefCounted

const FRAME := 1.0 / 60.0

var runner
var app: Control
var data := ""
var opened: Array = []
var quits := 0


func _init(smoke) -> void:
	runner = smoke
	data = smoke.root_dir + "/input"


func check(ok: bool, what: String) -> void:
	runner.check(ok, what)


func run() -> void:
	_make_data()
	await _open_does_not_repeat()
	await _diagonals()
	await _every_pad()
	await _prompt_ignores_held_direction()
	await _double_tap()
	await _hysteresis()
	_unfocused_setting()
	await _lost_release()
	await _page_repeat()
	await _repeat_survives_other_presses()
	await _menus_return()
	await _hints_follow_state()
	await _scroll_survives_refresh()
	await _preview_follows_refresh()
	await _physical_keys()
	await _display_gaps()
	await _round3_keys()
	await _round3_keyboard()
	await _round3_close()
	await _round3_missing_place()
	app.queue_free()
	await runner.process_frame


func _make_data() -> void:
	for i in 10:
		DirAccess.make_dir_recursive_absolute("%s/many/d%03d" % [data, i])
	for i in 190:
		runner.write("%s/many/f%03d.txt" % [data, i], "x")
	runner.write(data + "/chain/a/b/c/d/e/f/g/h/leaf.txt", "leaf")
	DirAccess.make_dir_recursive_absolute(data + "/empty")


# the app clock moves one 60 fps tick per real frame, so a hold is timed the same on every machine
func step(n := 1) -> void:
	for i in n:
		await runner.process_frame
		app._process(FRAME)


# a new screen ignores every press for a moment, so a deliberate press waits past that
func settle() -> void:
	await step(12)


func fresh(path: String) -> void:
	if app != null:
		app.queue_free()
		await runner.process_frame
	app = load("res://main.tscn").instantiate()
	app.start_path = path
	app.settings_path = data + "/settings.cfg"
	app.places_source = func() -> Array: return [{"label": "Data", "path": data, "kind": "home"}]
	app.opener = func(p: String) -> int:
		opened.append(p)
		return OK
	app.quitter = func() -> void: quits += 1
	runner.root.add_child(app)
	app.set_process(false)
	opened.clear()
	quits = 0
	await step(2)


func btn(index: int, pressed: bool, device := 0) -> void:
	var e := InputEventJoypadButton.new()
	e.device = device
	e.button_index = index
	e.pressed = pressed
	Input.parse_input_event(e)


func axis(which: int, value: float, device := 0) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = device
	e.axis = which
	e.axis_value = value
	Input.parse_input_event(e)


func key(code: int, pressed: bool, unicode := 0, echo := false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.unicode = unicode
	e.pressed = pressed
	e.echo = echo
	Input.parse_input_event(e)


func tap(index: int, device := 0) -> void:
	btn(index, true, device)
	await step(2)
	btn(index, false, device)
	await step(2)


func type_key(code: int, unicode := 0) -> void:
	key(code, true, unicode)
	await step()
	key(code, false)
	await step()


func center() -> void:
	axis(JOY_AXIS_LEFT_X, 0.0)
	axis(JOY_AXIS_LEFT_Y, 0.0)
	await step(3)


func png(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create_empty(16, 16, false, Image.FORMAT_RGB8)
	img.fill(Color.WHITE)
	img.save_png(path)


func clash(tag: String) -> String:
	var base := "%s/clash_%s" % [data, tag]
	for i in 4:
		runner.write("%s/src/c%d.txt" % [base, i], "new")
		runner.write("%s/dst/c%d.txt" % [base, i], "old")
	return base


func copy_into_dst(base: String) -> void:
	app.navigate(base + "/src")
	app.select_all()
	app._set_clipboard(app.targets(), false)
	app.navigate(base + "/dst")


func until_prompt() -> bool:
	for i in 600:
		if app.mode == app.Mode.CONFLICT:
			return true
		await step()
	return false


func finish_jobs() -> void:
	for id: int in app.jobs:
		app.core.cancel_job(id)
	for i in 600:
		if app.jobs.is_empty():
			return
		await step()


func menu_index(prefix: String) -> int:
	for i in app.menu_items.size():
		if String(app.menu_items[i][0]).begins_with(prefix):
			return i
	return -1


func hinted(pairs: Array, action: String) -> bool:
	return pairs.any(func(p: Array) -> bool: return p[0] == action)


# the hint pairs that a node really draws, read from its glyphs and labels
func drawn(node: Node) -> Array:
	var pairs: Array = []
	for child in node.get_children():
		if child.is_queued_for_deletion():
			continue
		if child.get_child_count() == 2 and child.get_child(0) is JoyGlyph:
			pairs.append([child.get_child(0).action, child.get_child(1).text])
		else:
			pairs.append_array(drawn(child))
	return pairs


func _open_does_not_repeat() -> void:
	var chain := data + "/chain"
	await fresh(chain)
	btn(JOY_BUTTON_DPAD_RIGHT, true)
	await step(60)
	btn(JOY_BUTTON_DPAD_RIGHT, false)
	await step(2)
	check(app.cwd == chain + "/a", "holding D-pad Right for a second enters one folder (%s)" % app.cwd.trim_prefix(chain))
	await fresh(chain)
	axis(JOY_AXIS_LEFT_X, 1.0)
	await step(120)
	axis(JOY_AXIS_LEFT_X, 0.0)
	await step(2)
	check(app.cwd == chain + "/a", "holding the stick right for two seconds enters one folder (%s)" % app.cwd.trim_prefix(chain))
	await fresh(chain + "/a/b/c/d/e/f/g/h")
	btn(JOY_BUTTON_DPAD_RIGHT, true)
	await step(60)
	btn(JOY_BUTTON_DPAD_RIGHT, false)
	await step(2)
	check(opened.is_empty(), "holding Right on a file does not launch it (%d opens)" % opened.size())
	opened.clear()
	btn(JOY_BUTTON_A, true)
	await step(60)
	btn(JOY_BUTTON_A, false)
	await step(2)
	check(opened.size() == 1, "holding A on a file opens it once (%d opens)" % opened.size())
	await fresh(chain)
	await tap(JOY_BUTTON_LEFT_SHOULDER)
	await settle()
	btn(JOY_BUTTON_DPAD_RIGHT, true)
	await step(60)
	btn(JOY_BUTTON_DPAD_RIGHT, false)
	await step(2)
	check(app.mode == app.Mode.FILES and app.cwd == data, "holding Right in Places opens the place once (%s)" % app.cwd.trim_prefix(data))


func _diagonals() -> void:
	var many := data + "/many"
	await fresh(many)
	axis(JOY_AXIS_LEFT_Y, 0.8)
	axis(JOY_AXIS_LEFT_X, 0.6)
	await step(3)
	check(app.cwd == many and app.cursor == 1, "a stick push down and right gives one step down (cursor %d, %s)" % [app.cursor, app.cwd.trim_prefix(data)])
	await center()
	axis(JOY_AXIS_LEFT_X, -0.6)
	axis(JOY_AXIS_LEFT_Y, 0.8)
	await step(3)
	check(app.mode == app.Mode.FILES and app.cursor == 2, "a stick push down and left gives one step down and keeps Places closed (mode %d)" % app.mode)
	await center()
	axis(JOY_AXIS_LEFT_X, 0.52)
	axis(JOY_AXIS_LEFT_Y, 0.9)
	await step(3)
	check(app.cwd == many and app.cursor == 3, "a push 30 degrees off vertical stays one step down (%s)" % app.cwd.trim_prefix(data))
	await center()
	btn(JOY_BUTTON_DPAD_DOWN, true)
	btn(JOY_BUTTON_DPAD_RIGHT, true)
	await step(3)
	btn(JOY_BUTTON_DPAD_DOWN, false)
	btn(JOY_BUTTON_DPAD_RIGHT, false)
	await step(2)
	check(app.cwd == many and app.cursor == 4, "D-pad Down and Right together give one step down (%s)" % app.cwd.trim_prefix(data))


func _every_pad() -> void:
	await fresh(data + "/many")
	for device: int in [1, 3]:
		var before: int = app.cursor
		await tap(JOY_BUTTON_DPAD_DOWN, device)
		axis(JOY_AXIS_LEFT_Y, 1.0, device)
		await step(2)
		axis(JOY_AXIS_LEFT_Y, 0.0, device)
		await step(2)
		check(app.cursor == before + 2, "pad %d moves the cursor with its D-pad and its stick (%d to %d)" % [device, before, app.cursor])
	var chain := data + "/chain"
	await fresh(chain)
	await tap(JOY_BUTTON_A, 1)
	check(app.cwd == chain + "/a", "A on pad 1 opens a folder (%s)" % app.cwd.trim_prefix(chain))
	await fresh(chain)
	btn(JOY_BUTTON_A, true, 0)
	btn(JOY_BUTTON_A, true, 1)
	await step(3)
	btn(JOY_BUTTON_A, false, 0)
	btn(JOY_BUTTON_A, false, 1)
	await step(2)
	check(app.cwd == chain + "/a", "two pads pressing A together open one folder (%s)" % app.cwd.trim_prefix(chain))


func _prompt_ignores_held_direction() -> void:
	var base := clash("held")
	await fresh(data)
	copy_into_dst(base)
	btn(JOY_BUTTON_DPAD_DOWN, true)
	app.paste()
	var seen: Array = []
	if await until_prompt():
		for i in 40:
			seen.append(app.conflict_panel.cursor)
			await step()
	check(seen.size() == 40 and seen.all(func(c: int) -> bool: return c == 1), "D-pad Down held while the clash prompt opens leaves the choice on Keep both: %s" % [seen])
	btn(JOY_BUTTON_DPAD_DOWN, false)
	await step(2)
	await tap(JOY_BUTTON_DPAD_DOWN)
	check(app.conflict_panel.cursor == 2, "a new press after the release moves the choice (%d)" % app.conflict_panel.cursor)
	await finish_jobs()

	var base2 := clash("stick")
	await fresh(data)
	copy_into_dst(base2)
	axis(JOY_AXIS_LEFT_Y, -1.0)
	app.paste()
	await until_prompt()
	await step(25)
	check(app.mode == app.Mode.CONFLICT and app.conflict_panel.cursor == 1, "the stick held up while the prompt opens leaves the choice on Keep both (%d)" % app.conflict_panel.cursor)
	await center()
	await finish_jobs()

	var base3 := clash("late")
	await fresh(data)
	copy_into_dst(base3)
	app.paste()
	await until_prompt()
	btn(JOY_BUTTON_DPAD_DOWN, true)
	await step(40)
	check(app.conflict_panel.cursor == 1, "D-pad Down pressed just after the prompt opens and held leaves the choice on Keep both (%d)" % app.conflict_panel.cursor)
	btn(JOY_BUTTON_DPAD_DOWN, false)
	await step(2)
	await finish_jobs()


func double_tap_a() -> void:
	for i in 2:
		btn(JOY_BUTTON_A, true)
		await step(2)
		btn(JOY_BUTTON_A, false)
		await step(2)


func _double_tap() -> void:
	var base := data + "/dbl"
	for i in 5:
		runner.write("%s/f%d.txt" % [base, i], "x")
	await fresh(base)
	app.cursor = 2
	var target: String = app.entries[2]["path"]
	await tap(JOY_BUTTON_X)
	await settle()
	for i in menu_index("Move to trash"):
		await tap(JOY_BUTTON_DPAD_DOWN)
	await double_tap_a()
	check(FileAccess.file_exists(target) and app.mode == app.Mode.CONFIRM, "a fast double tap of A on Move to trash stops at the question (mode %d)" % app.mode)
	await settle()
	await tap(JOY_BUTTON_B)
	check(app.mode == app.Mode.FILES and FileAccess.file_exists(target), "B on the question keeps the file")

	await fresh(data + "/many")
	app.jobs[999] = {"watch": [], "state": "running"}
	await tap(JOY_BUTTON_START)
	await settle()
	for i in menu_index("Quit"):
		await tap(JOY_BUTTON_DPAD_DOWN)
	await double_tap_a()
	check(quits == 0 and app.mode == app.Mode.CONFIRM, "a fast double tap of A on Quit stops at the question about the running job (quits %d)" % quits)
	await settle()
	await tap(JOY_BUTTON_A)
	check(quits == 1, "a deliberate A a moment later answers the question (quits %d)" % quits)
	app.jobs.clear()


func _hysteresis() -> void:
	await fresh(data + "/many")
	for i in 120:
		axis(JOY_AXIS_LEFT_Y, 0.55 if i % 2 == 0 else 0.45)
		await step()
	check(app.cursor <= 1, "the stick flapping between 0.45 and 0.55 for two seconds moves at most one row (%d)" % app.cursor)
	await center()
	app.cursor = 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 120:
		axis(JOY_AXIS_LEFT_Y, 0.5 + rng.randf_range(-0.04, 0.04))
		await step()
	check(app.cursor <= 1, "stick noise around 0.5 for two seconds moves at most one row (%d)" % app.cursor)
	await center()
	app.cursor = 0
	for i in 60:
		axis(JOY_AXIS_TRIGGER_RIGHT, 0.55 if i % 2 == 0 else 0.45)
		await step()
	axis(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	await step(2)
	check(app.cursor <= app.visible_rows, "a trigger flapping around 0.5 for a second pages at most once (%d)" % app.cursor)
	app.cursor = 20
	app._clamp_view()
	axis(JOY_AXIS_LEFT_Y, 1.0)
	await step(3)
	axis(JOY_AXIS_LEFT_Y, -0.6)
	await step(2)
	axis(JOY_AXIS_LEFT_Y, 0.0)
	await step(3)
	check(app.cursor == 21, "a flick down that springs back past the center moves one row down (%d)" % app.cursor)
	var before: int = app.cursor
	axis(JOY_AXIS_LEFT_Y, 0.7)
	await step(10)
	axis(JOY_AXIS_LEFT_Y, 0.0)
	await step(2)
	check(app.cursor == before + 1, "a clear push still moves one row (%d to %d)" % [before, app.cursor])


func _unfocused_setting() -> void:
	var ignores: bool = ProjectSettings.get_setting("input_devices/joypads/ignore_joypad_on_unfocused_application", false)
	check(ignores, "the app ignores gamepads while another window has the focus")


func held_down_survives(lose: Callable, what: String) -> void:
	app.cursor = 0
	app._clamp_view()
	btn(JOY_BUTTON_DPAD_DOWN, true)
	await step(30)
	lose.call()
	var at: int = app.cursor
	await step(60)
	check(app.cursor == at, "%s while Down is held stops the repeat (%d then %d)" % [what, at, app.cursor])
	btn(JOY_BUTTON_DPAD_DOWN, false)
	await step(2)
	await tap(JOY_BUTTON_DPAD_DOWN)
	check(app.cursor == at + 1, "a new press works after %s (%d)" % [what, app.cursor])


func _lost_release() -> void:
	await fresh(data + "/many")
	await held_down_survives(func() -> void: runner.root.propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT), "losing the application focus")
	await held_down_survives(func() -> void: runner.root.propagate_notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT), "losing the window focus")
	await held_down_survives(func() -> void: Input.joy_connection_changed.emit(0, false), "a pad disconnect")


func _page_repeat() -> void:
	await fresh(data + "/many")
	axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	await step(30)
	var page_from: int = app.cursor
	await step(30)
	var pages: float = (app.cursor - page_from) * 2.0 / app.visible_rows
	axis(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	await step(2)
	app.cursor = 0
	app._clamp_view()
	btn(JOY_BUTTON_DPAD_DOWN, true)
	await step(30)
	var row_from: int = app.cursor
	await step(30)
	var rows: float = (app.cursor - row_from) * 2.0
	btn(JOY_BUTTON_DPAD_DOWN, false)
	await step(2)
	check(pages <= 5.0 and pages < rows, "a held trigger repeats slower than a held direction (%.1f pages and %.1f rows per second)" % [pages, rows])


func _repeat_survives_other_presses() -> void:
	await fresh(data + "/many")
	btn(JOY_BUTTON_DPAD_DOWN, true)
	await step(60)
	await tap(JOY_BUTTON_Y)
	var after_tap: int = app.cursor
	await step(60)
	check(app.cursor > after_tap + 5, "D-pad Down keeps repeating after a tap of Y (%d to %d)" % [after_tap, app.cursor])
	btn(JOY_BUTTON_DPAD_DOWN, false)
	await step(2)
	app.cursor = 0
	app._clamp_view()
	axis(JOY_AXIS_LEFT_Y, 1.0)
	await step(60)
	axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	await step(10)
	axis(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	var after_page: int = app.cursor
	await step(60)
	check(app.cursor > after_page + 5, "the stick held down keeps repeating after a trigger tap (%d to %d)" % [after_page, app.cursor])
	await center()
	app.cursor = 100
	app._clamp_view()
	btn(JOY_BUTTON_DPAD_DOWN, true)
	await step(10)
	btn(JOY_BUTTON_DPAD_UP, true)
	await step(10)
	btn(JOY_BUTTON_DPAD_UP, false)
	var after_up: int = app.cursor
	await step(60)
	check(app.cursor > after_up + 5, "D-pad Down keeps repeating after Up is pressed and let go (%d to %d)" % [after_up, app.cursor])
	btn(JOY_BUTTON_DPAD_DOWN, false)
	await step(2)
	app.cursor = 100
	app._clamp_view()
	key(KEY_DOWN, true)
	await step(10)
	key(KEY_UP, true)
	await step(10)
	key(KEY_UP, false)
	var after_key: int = app.cursor
	await step(60)
	check(app.cursor > after_key + 5, "the Down key repeats again after the Up key is let go (%d to %d)" % [after_key, app.cursor])
	key(KEY_DOWN, false)
	await step(2)


func _menus_return() -> void:
	await fresh(data + "/many")
	await tap(JOY_BUTTON_LEFT_SHOULDER)
	await settle()
	await tap(JOY_BUTTON_START)
	await settle()
	await tap(JOY_BUTTON_B)
	check(app.mode == app.Mode.PLACES, "closing the Start menu returns to Places (mode %d)" % app.mode)
	await settle()
	await tap(JOY_BUTTON_LEFT_STICK)
	await settle()
	await tap(JOY_BUTTON_B)
	check(app.mode == app.Mode.PLACES, "closing Jobs returns to Places (mode %d)" % app.mode)


func _hints_follow_state() -> void:
	await fresh("/")
	check(app.cwd == "/" and not hinted(app._hints_for_mode(), "jf_back"), "the footer offers no Up at the filesystem root: %s" % [app._hints_for_mode()])

	await fresh(data + "/empty")
	var hints: Array = app._hints_for_mode()
	check(not hinted(hints, "jf_accept") and not hinted(hints, "jf_select"), "the footer offers no Open and no Select in an empty folder: %s" % [hints])
	await tap(JOY_BUTTON_X)
	check(menu_index("Select all") < 0, "the Actions menu of an empty folder has no Select all")
	await settle()
	await tap(JOY_BUTTON_B)

	await fresh(data + "/many")
	app._set_filter("zzz")
	await step()
	hints = app._hints_for_mode()
	check(not hinted(hints, "jf_accept") and not hinted(hints, "jf_select"), "the footer offers no Open and no Select when the filter hides every item: %s" % [hints])
	await tap(JOY_BUTTON_X)
	check(menu_index("Select all") < 0, "the Actions menu has no Select all when the filter hides every item")
	await settle()
	await tap(JOY_BUTTON_B)

	var base := clash("hints")
	await fresh(data)
	copy_into_dst(base)
	app.paste()
	await until_prompt()
	await step(2)
	check(drawn(app.conflict_panel) == app._hints_for_mode() and drawn(app._hints).is_empty(), "the clash prompt draws the hints of its table and the footer draws none: %s and %s" % [drawn(app.conflict_panel), drawn(app._hints)])
	await finish_jobs()

	var pics := data + "/pics"
	for n in ["p1.png", "p2.png"]:
		png(pics + "/" + n)
	await fresh(pics)
	await tap(JOY_BUTTON_A)
	await step(2)
	check(app.mode == app.Mode.PREVIEW and drawn(app.preview) == app._hints_for_mode() and drawn(app._hints).is_empty(), "the preview draws the hints of its table and the footer draws none: %s and %s" % [drawn(app.preview), drawn(app._hints)])
	check(not hinted(app._hints_for_mode(), "jf_left"), "the first image offers no Previous: %s" % [app._hints_for_mode()])


func _scroll_survives_refresh() -> void:
	await fresh(data + "/many")
	app.cursor = 25
	app.top = 19
	app._render()
	app.refresh()
	check(app.cursor == 25 and app.top == 19, "a refresh keeps the cursor on its screen row (top %d)" % app.top)
	await tap(JOY_BUTTON_BACK)
	check(app.cursor == 25 and app.top == 19, "the View button keeps the scroll position (top %d)" % app.top)
	await tap(JOY_BUTTON_BACK)


func _preview_follows_refresh() -> void:
	var base := data + "/prev"
	for n in ["i1.png", "i2.png", "i3.png"]:
		png(base + "/" + n)
	await fresh(base)
	await tap(JOY_BUTTON_A)
	await settle()
	DirAccess.remove_absolute(base + "/i2.png")
	png(base + "/i0.png")
	app.refresh()
	await step()
	await tap(JOY_BUTTON_DPAD_RIGHT)
	check(app.preview.current()["name"] == "i3.png", "after a refresh, Right in the preview skips the removed image (%s)" % app.preview.current()["name"])
	await tap(JOY_BUTTON_DPAD_LEFT)
	await tap(JOY_BUTTON_DPAD_LEFT)
	check(app.preview.current()["name"] == "i0.png", "Left reaches the image that the refresh added (%s)" % app.preview.current()["name"])


func _physical_keys() -> void:
	await fresh(data + "/many")
	key(KEY_F, true, 102)
	await step(2)
	for i in 5:
		key(KEY_F, true, 102, true)
		await step()
	key(KEY_F, false)
	await step(2)
	check(app.mode == app.Mode.KEYBOARD and app.filter == "", "holding F opens the filter keyboard and types nothing (%s)" % app.filter)
	await type_key(KEY_F, 102)
	check(app.filter == "f", "a new press of F types f (%s)" % app.filter)
	for u: int in [127, 128, 159, 0x200B, 0x200F, 0x202E]:
		await type_key(KEY_UNKNOWN, u)
	var codes: Array = []
	for ch in app._keyboard.text:
		codes.append(ch.unicode_at(0))
	check(app._keyboard.text == "f", "control and format characters type nothing: %s" % [codes])
	await settle()
	await tap(JOY_BUTTON_Y)
	await type_key(KEY_A, 97)
	await tap(JOY_BUTTON_A)
	check(app._keyboard.text == "faq", "a typed letter uses up the on-screen Shift (%s)" % app._keyboard.text)
	await type_key(KEY_ESCAPE, 27)

	await fresh(data + "/many")
	app.cursor = 12
	app._ask_rename(app.entries[12]["path"])
	await step(2)
	key(KEY_ENTER, true, 13, true)
	await step(2)
	key(KEY_ENTER, false)
	await step(2)
	check(app.mode == app.Mode.KEYBOARD, "an Enter repeat from before the rename keyboard opened does not submit it (mode %d)" % app.mode)
	await type_key(KEY_ESCAPE, 27)

	await fresh(data + "/many")
	var alt_tab := InputEventKey.new()
	alt_tab.keycode = KEY_TAB
	alt_tab.physical_keycode = KEY_TAB
	alt_tab.alt_pressed = true
	alt_tab.pressed = true
	Input.parse_input_event(alt_tab)
	await step(2)
	var up: InputEventKey = alt_tab.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	await step(2)
	check(app.mode == app.Mode.FILES, "Alt+Tab does not open Places (mode %d)" % app.mode)
	await type_key(KEY_TAB)
	check(app.mode == app.Mode.PLACES, "Tab alone still opens Places (mode %d)" % app.mode)


func _display_gaps() -> void:
	var many := data + "/many"
	await fresh(many)
	await tap(JOY_BUTTON_RIGHT_STICK)
	await settle()
	await tap(JOY_BUTTON_A)
	runner.write(many + "/q_new.txt", "x")
	app.refresh()
	await step()
	check(app._keyboard._title.text == "Filter this folder (1 of 201)", "the filter keyboard counts again after a refresh: %s" % app._keyboard._title.text)
	await type_key(KEY_ESCAPE, 27)
	DirAccess.remove_absolute(many + "/q_new.txt")

	runner.write(data + "/onlyhidden/.secret", "x")
	await fresh(data + "/onlyhidden")
	app.settings.show_hidden = false
	app.refresh()
	app._render()
	check(app._row_parts[0]["name"].text != "This folder is empty.", "a folder with only hidden items does not say it is empty (%s)" % app._row_parts[0]["name"].text)

	var sel := data + "/sel"
	for n in [".dot1", ".dot2", "plain.txt"]:
		runner.write("%s/%s" % [sel, n], "x")
	await fresh(sel)
	app.settings.show_hidden = true
	app.refresh()
	app.select_all()
	await tap(JOY_BUTTON_BACK)
	check(not app.settings.show_hidden and app.selected.size() == 3, "hiding hidden files keeps them selected (%d)" % app.selected.size())
	check(app.targets().size() == 1, "actions skip the selected items that are hidden (%d)" % app.targets().size())
	await tap(JOY_BUTTON_BACK)
	check(app.targets().size() == 3, "showing hidden files brings the whole selection back (%d)" % app.targets().size())
	app.settings.show_hidden = false
	app._save_settings()


func chord(code: int, mods: Dictionary) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		e.shift_pressed = mods.get("shift", false)
		e.ctrl_pressed = mods.get("ctrl", false)
		e.alt_pressed = mods.get("alt", false)
		e.meta_pressed = mods.get("meta", false)
		Input.parse_input_event(e)
		await step()


func _round3_keys() -> void:
	var many := data + "/many"
	await fresh(many)
	await type_key(KEY_KP_ENTER)
	check(app.cwd == many + "/d000", "numpad Enter opens the folder like Enter (%s)" % app.cwd.trim_prefix(data))
	await fresh(many)
	for mods: Dictionary in [{"shift": true}, {"ctrl": true}, {"alt": true}, {"meta": true}]:
		var before: int = app.cursor
		await chord(KEY_DOWN, mods)
		check(app.cursor == before + 1, "Down with %s held still moves the cursor (%d to %d)" % [mods.keys()[0], before, app.cursor])
	await chord(KEY_TAB, {"shift": true})
	check(app.mode == app.Mode.PLACES, "Shift+Tab opens Places (mode %d)" % app.mode)


func _round3_keyboard() -> void:
	var many := data + "/many"
	await fresh(many)
	app._ask_rename(app.entries[12]["path"])
	await step(2)
	await type_key(KEY_ENTER, 13)
	check(app.mode == app.Mode.KEYBOARD, "a physical Enter right after the keyboard opens does not submit it (mode %d)" % app.mode)
	await type_key(KEY_Q, 113)
	check(app._keyboard.text.ends_with("q"), "a letter typed right after the keyboard opens still types (%s)" % app._keyboard.text)
	await settle()
	await type_key(KEY_DOWN)
	check(app._keyboard.row == 2, "physical Down moves the key cursor (row %d)" % app._keyboard.row)
	await type_key(KEY_RIGHT)
	check(app._keyboard.col == 1, "physical Right moves the key cursor (col %d)" % app._keyboard.col)
	await type_key(KEY_LEFT)
	await type_key(KEY_UP)
	check(app._keyboard.row == 1 and app._keyboard.col == 0, "physical Left and Up move it back (%d, %d)" % [app._keyboard.row, app._keyboard.col])
	var kb: JoyKeyboard = app._keyboard
	kb.row = 3
	kb.col = 8
	kb._across = 0.85
	kb.handle("jf_down")
	check(kb.row == 4 and kb.col == 4, "Down from the dot lands on the key under it (col %d)" % kb.col)
	kb.handle("jf_up")
	check(kb.row == 3 and kb.col == 8, "Up returns to the same column (col %d)" % kb.col)
	kb.col = 0
	kb._across = 0.05
	kb.handle("jf_down")
	check(kb.col == 0, "Down from the first column stays in the first column (col %d)" % kb.col)
	await type_key(KEY_ESCAPE, 27)


func _round3_close() -> void:
	var many := data + "/many"
	await fresh(many)
	check(ProjectSettings.get_setting("application/config/auto_accept_quit", true) == false, "the app handles a window close itself")
	app.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(quits == 1, "a window close with no job quits at once (quits %d)" % quits)
	await fresh(many)
	app.jobs[999] = {"watch": [], "state": "running"}
	app.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(quits == 0 and app.mode == app.Mode.CONFIRM, "a window close with a running job asks first (quits %d, mode %d)" % [quits, app.mode])
	await settle()
	await tap(JOY_BUTTON_B)
	check(quits == 0 and app.mode == app.Mode.FILES, "B on the quit question keeps the app open (mode %d)" % app.mode)
	app.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await settle()
	await tap(JOY_BUTTON_A)
	check(quits == 1, "A on the quit question quits (quits %d)" % quits)
	await fresh(many)
	app.jobs[999] = {"watch": [], "state": "running"}
	app._ask_trash(PackedStringArray([app.entries[3]["path"]]))
	app.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await settle()
	await tap(JOY_BUTTON_B)
	check(app.mode == app.Mode.FILES and quits == 0, "a window close over another question does not trap the screen (mode %d)" % app.mode)
	app.jobs.clear()


func _round3_missing_place() -> void:
	await fresh(data + "/many")
	var gone := [{"label": "Data", "path": data, "kind": "home"}, {"label": "Gone", "path": data + "/gone", "kind": "folder"}]
	app.places_source = func() -> Array: return gone
	app.places = gone
	await tap(JOY_BUTTON_LEFT_SHOULDER)
	await settle()
	await tap(JOY_BUTTON_DPAD_DOWN)
	await tap(JOY_BUTTON_A)
	check(app.mode == app.Mode.PLACES and app.cwd == data + "/many", "A on a place that is gone stays in Places (mode %d, %s)" % [app.mode, app.cwd.trim_prefix(data)])
