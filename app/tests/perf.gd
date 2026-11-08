extends SceneTree

const BUDGET_MS := 300.0
const RUNS := 7

var app: Control
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


func median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func span(values: Array) -> String:
	var sorted := values.duplicate()
	sorted.sort()
	return "%.1f to %.1f" % [sorted[0], sorted[-1]]


# the headless display never draws, so it waits for a plain frame
func drawn() -> void:
	if DisplayServer.get_name() == "headless":
		await process_frame
	else:
		await RenderingServer.frame_post_draw


func ms_since(start_usec: int) -> float:
	return (Time.get_ticks_usec() - start_usec) / 1000.0


func _run() -> void:
	var dir := OS.get_environment("JF_PERF_DIR")
	var small := OS.get_environment("JF_PERF_SMALL")
	var expected := int(OS.get_environment("JF_PERF_COUNT"))
	var scene: PackedScene = load("res://main.tscn")
	app = scene.instantiate()
	app.start_path = small
	app.settings_path = small.get_base_dir() + "/jf_perf_settings.cfg"
	root.add_child(app)
	await process_frame
	await drawn()

	var core := JoyCore.new()
	var list_ms: Array = []
	var nav_ms: Array = []
	var render_ms: Array = []
	var frame_ms: Array = []
	var total_ms: Array = []
	var filter_ms: Array = []
	var counts_ok := true
	for i in RUNS + 1:
		var t0 := Time.get_ticks_usec()
		var result: Dictionary = core.list_dir(dir, false, "name", false)
		var t_list := ms_since(t0)
		counts_ok = counts_ok and result["ok"] and result["entries"].size() == expected
		app.navigate(small)
		await process_frame
		var t1 := Time.get_ticks_usec()
		app.navigate(dir)
		var t_nav := ms_since(t1)
		var t2 := Time.get_ticks_usec()
		app._render()
		var t_render := ms_since(t2)
		await drawn()
		var t_total := ms_since(t1)
		counts_ok = counts_ok and app.entries.size() == expected
		var t3 := Time.get_ticks_usec()
		app.filter = "99"
		app._apply_filter()
		var t_filter := ms_since(t3)
		app.filter = ""
		app._apply_filter()
		if i == 0:
			continue
		list_ms.append(t_list)
		nav_ms.append(t_nav)
		render_ms.append(t_render)
		frame_ms.append(t_total - t_nav - t_render)
		total_ms.append(t_total)
		filter_ms.append(t_filter)

	print("PERF entries=%d runs=%d (first run dropped)" % [expected, RUNS])
	print("PERF core.list_dir            median %.1f ms  range %s" % [median(list_ms), span(list_ms)])
	print("PERF navigate (list+filter)   median %.1f ms  range %s" % [median(nav_ms), span(nav_ms)])
	print("PERF _render (12 rows)        median %.1f ms  range %s" % [median(render_ms), span(render_ms)])
	print("PERF layout and draw frame    median %.1f ms  range %s" % [median(frame_ms), span(frame_ms)])
	print("PERF navigate to first frame  median %.1f ms  range %s" % [median(total_ms), span(total_ms)])
	print("PERF live filter pass         median %.1f ms  range %s" % [median(filter_ms), span(filter_ms)])
	check(counts_ok, "every run listed all %d entries" % expected)
	check(median(total_ms) < BUDGET_MS, "navigate to first frame stays under %d ms (%.1f)" % [BUDGET_MS, median(total_ms)])
	DirAccess.remove_absolute(small.get_base_dir() + "/jf_perf_settings.cfg")
	print("RESULT %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(failures)
