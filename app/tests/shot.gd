extends SceneTree

var app: Control
var out := ""
var base := ""
var count := 0


func _initialize() -> void:
	_run.call_deferred()


func frames(n := 10) -> void:
	for i in n:
		await process_frame


func snap(label: String) -> void:
	await frames()
	count += 1
	root.get_texture().get_image().save_png("%s/%02d_%s.png" % [out, count, label])


func press(actions: Array) -> void:
	for action: String in actions:
		app.fire(action)


func until(cond: Callable, max_frames := 600) -> void:
	for i in max_frames:
		if cond.call():
			return
		await process_frame


func write_size(path: String, n: int) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	var chunk := PackedByteArray()
	chunk.resize(1 << 20)
	for i in n >> 20:
		f.store_buffer(chunk)
	f.store_buffer(chunk.slice(0, n & ((1 << 20) - 1)))
	f.close()


func write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func gradient(path: String, w: int, h: int, a: Color, b: Color) -> void:
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			img.set_pixel(x, y, a.lerp(b, float(x + y) / (w + h)))
	if path.ends_with(".jpg"):
		img.save_jpg(path, 0.9)
	else:
		img.save_png(path)


func make_content() -> void:
	for d in ["Documents", "Games", "Music", "Pictures"]:
		DirAccess.make_dir_recursive_absolute(base + "/" + d)
	write_text(base + "/apple notes.txt", "x")
	write_text(base + "/apricot jam recipe.md", "x")
	write_text(base + "/banana.txt", "x")
	write_text(base + "/Zebra.log", "x")
	write_size(base + "/save_backup.zip", 18 * 1024 * 1024)
	write_size(base + "/movie_clip.mp4", 6 * 1024 * 1024)
	gradient(base + "/sunset.png", 640, 400, Color("#ff7a59"), Color("#5a3fff"))
	gradient(base + "/forest.jpg", 800, 500, Color("#1f8a4c"), Color("#d6f5a3"))
	gradient(base + "/ocean.png", 512, 512, Color("#0a3d62"), Color("#48dbfb"))
	for n in ["clash_src/save_backup.zip", "clash_src/notes.txt", "clash_dst/save_backup.zip", "clash_dst/notes.txt"]:
		write_size("%s/%s" % [base, n], 24 * 1024 * 1024 if n.ends_with("zip") else 400)
	write_size(base + "/clash_src/aa_before.bin", 40 * 1024 * 1024)
	write_size(base + "/clash_src2/disk_image.img", 30 * 1024 * 1024)
	write_size(base + "/clash_dst/disk_image.img", 5 * 1024 * 1024)


func pick(prefix: String, start := false) -> void:
	press(["jf_start" if start else "jf_menu"])
	for i in app.menu_items.size():
		if String(app.menu_items[i][0]).begins_with(prefix):
			for k in i:
				press(["jf_down"])
			press(["jf_accept"])
			return


func cursor_to(name: String) -> void:
	for i in app.entries.size():
		if app.entries[i]["name"] == name:
			app.cursor = i


func rm_tree(path: String) -> void:
	if not path.begins_with(base + "/"):
		return
	for d in DirAccess.get_directories_at(path):
		rm_tree(path + "/" + d)
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path + "/" + f)
	DirAccess.remove_absolute(path)


func copy_all_from(dir: String) -> void:
	app.navigate(dir)
	pick("Select all")
	pick("Copy")


func glyph_sheet(height: float) -> Control:
	var sheet := ColorRect.new()
	sheet.color = Theme_.PANEL
	sheet.set_anchors_preset(Control.PRESET_FULL_RECT)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 48)
	grid.add_theme_constant_override("v_separation", 36)
	grid.position = Vector2(48, 40)
	sheet.add_child(grid)
	for action: String in JoyGlyph.SPECS:
		var cell := VBoxContainer.new()
		cell.add_child(JoyGlyph.of(action, height))
		cell.add_child(Theme_.label(action, Theme_.MUTED, 18))
		grid.add_child(cell)
	return sheet


func _run() -> void:
	out = OS.get_environment("JF_SHOT_DIR")
	base = OS.get_environment("JF_TEST_DIR")
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1280, 800)
	await frames(5)
	make_content()
	app = load("res://main.tscn").instantiate()
	app.start_path = base
	app.opener = func(_path: String) -> int: return OK
	app.settings_path = base.get_base_dir() + "/jf_shot_settings.cfg"
	root.add_child(app)
	await until(func(): return app.thumbs.cache.size() >= 3, 120)
	await snap("files_with_thumbnails")

	var sheet := glyph_sheet(96.0)
	root.add_child(sheet)
	await snap("glyph_sheet_large")
	sheet.queue_free()
	sheet = glyph_sheet(JoyGlyph.HEIGHT)
	root.add_child(sheet)
	await snap("glyph_sheet_actual")
	sheet.queue_free()

	press(["jf_menu"])
	await snap("file_menu")
	press(["jf_back"])
	pick("Sort...", true)
	await snap("sort_menu")
	press(["jf_down", "jf_accept"])
	await snap("sorted_by_size")
	app.settings.sort_key = "name"
	app.settings.sort_desc = false
	app.refresh()

	app._open_props(base + "/Pictures")
	app._render()
	await snap("properties_folder")
	press(["jf_back"])
	app._open_props(base + "/save_backup.zip")
	app._render()
	await snap("properties_file")
	press(["jf_back"])
	app._open_props(base)
	app._render()
	await until(func(): return app.props_panel.scan_done, 300)
	await snap("properties_folder_with_size")
	press(["jf_back"])

	press(["jf_search", "jf_down", "jf_accept", "jf_up", "jf_left", "jf_accept"])
	await snap("filter_keyboard")
	press(["jf_start"])
	await snap("filter_applied")
	press(["jf_back"])

	cursor_to("sunset.png")
	press(["jf_accept"])
	await until(func(): return app.preview.showing_full, 200)
	await snap("image_preview")
	press(["jf_back"])

	app.opener = func(p: String) -> int: return ERR_UNAVAILABLE
	cursor_to("banana.txt")
	press(["jf_accept"])
	await snap("open_failed_toast")

	copy_all_from(base + "/clash_src")
	app.navigate(base + "/clash_dst")
	pick("Paste")
	await until(func(): return app.mode == app.Mode.CONFLICT, 300)
	await snap("conflict_prompt")
	press(["jf_down", "jf_down", "jf_accept"])
	await snap("conflict_apply_all_on")
	press(["jf_up", "jf_up", "jf_up", "jf_accept"])
	await until(func(): return app.jobs.is_empty(), 300)

	copy_all_from(base + "/clash_src2")
	app.navigate(base + "/clash_dst")
	pick("Paste")
	press(["jf_jobs"])
	await until(func(): return not app.jobs.is_empty() and app.jobs.values().all(func(j): return not j.get("conflict", {}).is_empty()), 300)
	await snap("jobs_panel")
	press(["jf_back"])
	await snap("files_after_closing_jobs")
	press(["jf_back"])
	await until(func(): return app.jobs.is_empty(), 300)

	for n in ["photo_a.txt", "photo_b.txt", "doc1.txt", "doc2.txt", "doc3.txt", "doc4.txt"]:
		write_text("%s/hiding/%s" % [base, n], "x")
	app.navigate(base + "/hiding")
	pick("Select all")
	app._set_filter("photo")
	press(["jf_menu"])
	await snap("filter_hides_selection")
	press(["jf_back"])
	app._set_filter("")
	app.selected.clear()

	var home: Dictionary = app.places[0]
	app.places_source = func() -> Array: return [home, {"label": "SD CARD", "path": base, "kind": "drive"}]
	press(["jf_pane"])
	await snap("places_new_card")
	press(["jf_back"])
	app.places_source = app.core.places
	app.refresh_places()

	write_text(base + "/gone/inner/f.txt", "x")
	app.navigate(base + "/gone/inner")
	rm_tree(base + "/gone")
	pick("Refresh", true)
	await snap("folder_gone")

	copy_all_from(base + "/clash_src2")
	app.navigate(base + "/clash_dst")
	pick("Paste")
	pick("Quit", true)
	await snap("quit_while_job_runs")
	press(["jf_back"])
	await until(func(): return app.mode == app.Mode.CONFLICT, 300)
	press(["jf_back"])
	await until(func(): return app.jobs.is_empty(), 300)
	quit()
