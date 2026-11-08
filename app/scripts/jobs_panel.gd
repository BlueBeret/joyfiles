class_name JoyJobs
extends PanelContainer

signal closed
signal cancel_requested(id: int)
signal answer_requested(id: int)
signal dismissed(id: int)

const DETAIL_ROWS := 4
const DETAIL_ROW_HEIGHT := 88

var cursor := 0
var ids: Array = []
var report_ids: Array = []
# the report whose failure list is open, or -1 while the job list shows
var viewing := -1
var failure_cursor := 0
var failure_top := 0
# one text per failed item of the open report, so the labels and the tests read the same data
var failure_texts: Array = []
var _reports := {}
var _list: VBoxContainer
var _report_list: VBoxContainer
var _empty: Label
var _detail: VBoxContainer
var _detail_title: Label
var _detail_count: Label
var _detail_rows: Array[Dictionary] = []
var _hints_box: VBoxContainer
var _hints_key := ""
var _rows := {}
var _report_rows := {}


func _init() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size.x = 760
	add_child(box)
	box.add_child(Theme_.label("Jobs", Theme_.TEXT, 28))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	box.add_child(_list)
	_report_list = VBoxContainer.new()
	_report_list.add_theme_constant_override("separation", 8)
	box.add_child(_report_list)
	_empty = Theme_.label("No jobs are running.", Theme_.MUTED, 22)
	box.add_child(_empty)
	_build_detail(box)
	_hints_box = VBoxContainer.new()
	box.add_child(_hints_box)
	add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 24))


func _build_detail(box: VBoxContainer) -> void:
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 6)
	_detail.visible = false
	box.add_child(_detail)
	var head := HBoxContainer.new()
	_detail.add_child(head)
	_detail_title = Theme_.label("", Theme_.DANGER, 24, true)
	_detail_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_detail_title)
	_detail_count = Theme_.label("", Theme_.MUTED, 20)
	head.add_child(_detail_count)
	for i in DETAIL_ROWS:
		var row := PanelContainer.new()
		row.custom_minimum_size.y = DETAIL_ROW_HEIGHT
		var lines := VBoxContainer.new()
		row.add_child(lines)
		var message := Theme_.label("", Theme_.TEXT, 21)
		message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		message.max_lines_visible = 2
		lines.add_child(message)
		var where := Theme_.label("", Theme_.MUTED, 18, true)
		lines.add_child(where)
		_detail.add_child(row)
		_detail_rows.append({"row": row, "message": message, "path": where})


func focused_id() -> int:
	return ids[cursor] if cursor < ids.size() else -1


func focused_report() -> int:
	var at := cursor - ids.size()
	return report_ids[at] if cursor >= ids.size() and at < report_ids.size() else -1


func progress_of(id: int) -> float:
	return _rows[id]["bar"].value if _rows.has(id) else -1.0


func is_waiting(id: int, jobs: Dictionary) -> bool:
	return id in jobs and not jobs[id].get("conflict", {}).is_empty()


func handle(action: String) -> void:
	if viewing >= 0:
		_handle_detail(action)
		return
	var total := ids.size() + report_ids.size()
	match action:
		"jf_up": cursor = maxi(cursor - 1, 0)
		"jf_down": cursor = mini(cursor + 1, maxi(total - 1, 0))
		"jf_menu":
			if focused_id() >= 0:
				cancel_requested.emit(focused_id())
			elif focused_report() >= 0:
				dismissed.emit(focused_report())
		"jf_accept":
			if focused_id() >= 0:
				answer_requested.emit(focused_id())
			elif focused_report() >= 0:
				viewing = focused_report()
				failure_cursor = 0
				failure_top = 0
		"jf_back", "jf_jobs": closed.emit()


func _handle_detail(action: String) -> void:
	var last := failure_texts.size() - 1
	match action:
		"jf_up": failure_cursor = maxi(failure_cursor - 1, 0)
		"jf_down": failure_cursor = clampi(failure_cursor + 1, 0, maxi(last, 0))
		"jf_page_up": failure_cursor = maxi(failure_cursor - DETAIL_ROWS, 0)
		"jf_page_down": failure_cursor = clampi(failure_cursor + DETAIL_ROWS, 0, maxi(last, 0))
		"jf_menu":
			var id := viewing
			viewing = -1
			dismissed.emit(id)
		"jf_back": viewing = -1
		"jf_jobs":
			viewing = -1
			closed.emit()


func update(jobs: Dictionary, reports := {}) -> void:
	ids = jobs.keys()
	ids.sort()
	report_ids = reports.keys()
	report_ids.sort()
	_reports = reports
	cursor = clampi(cursor, 0, maxi(ids.size() + report_ids.size() - 1, 0))
	if not reports.has(viewing):
		viewing = -1
	_drop_gone(_rows, jobs)
	_drop_gone(_report_rows, reports)
	for i in ids.size():
		var id: int = ids[i]
		if not _rows.has(id):
			_rows[id] = _make_row()
			_list.add_child(_rows[id]["row"])
		_fill_row(_rows[id], jobs[id], i == cursor)
	for i in report_ids.size():
		var id: int = report_ids[i]
		if not _report_rows.has(id):
			_report_rows[id] = _make_report_row()
			_report_list.add_child(_report_rows[id]["row"])
		_fill_report_row(_report_rows[id], reports[id], ids.size() + i == cursor)
	_render_detail()
	_list.visible = viewing < 0
	_report_list.visible = viewing < 0
	_empty.visible = viewing < 0 and ids.is_empty() and report_ids.is_empty()
	_set_hints(jobs)


func _drop_gone(rows: Dictionary, data: Dictionary) -> void:
	for id: int in rows.keys():
		if not data.has(id):
			rows[id]["row"].queue_free()
			rows.erase(id)


func _make_row() -> Dictionary:
	var row := PanelContainer.new()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	row.add_child(box)
	var line := HBoxContainer.new()
	box.add_child(line)
	var title := Theme_.label("", Theme_.TEXT, 22, true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(title)
	var info := Theme_.label("", Theme_.MUTED, 20)
	line.add_child(info)
	var bar := Theme_.progress(0.0)
	box.add_child(bar)
	return {"row": row, "title": title, "info": info, "bar": bar}


func _make_report_row() -> Dictionary:
	var row := PanelContainer.new()
	var line := HBoxContainer.new()
	row.add_child(line)
	var title := Theme_.label("", Theme_.DANGER, 22, true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(title)
	var info := Theme_.label("Open the list", Theme_.WARN, 20)
	line.add_child(info)
	return {"row": row, "title": title}


func _fill_row(parts: Dictionary, job: Dictionary, focused: bool) -> void:
	var total: int = job.get("total_bytes", 0)
	var done: int = job.get("done_bytes", 0)
	var ratio := 0.0 if total == 0 else clampf(float(done) / total, 0.0, 1.0)
	var verb := "Moving" if job.get("kind") == "move" else "Copying"
	var waiting: bool = not job.get("conflict", {}).is_empty()
	parts["title"].text = "%s %s" % [verb, job.get("current", "")]
	parts["info"].text = "Needs an answer" if waiting else "%d%%  %s of %s" % [int(ratio * 100.0), Theme_.human_size(done), Theme_.human_size(total)]
	parts["info"].add_theme_color_override("font_color", Theme_.WARN if waiting else Theme_.MUTED)
	parts["bar"].value = ratio
	parts["row"].add_theme_stylebox_override("panel", Theme_.box(Theme_.ROW_SEL if focused else Color.TRANSPARENT, 8, 12))


func _fill_report_row(parts: Dictionary, report: Dictionary, focused: bool) -> void:
	parts["title"].text = report["title"]
	parts["row"].add_theme_stylebox_override("panel", Theme_.box(Theme_.ROW_SEL if focused else Color.TRANSPARENT, 8, 12))


func _render_detail() -> void:
	_detail.visible = viewing >= 0
	failure_texts = []
	if viewing < 0:
		return
	var report: Dictionary = _reports[viewing]
	var failures: Array = report["failures"]
	failure_texts = failures.map(func(f: Dictionary) -> String: return f["error"])
	failure_cursor = clampi(failure_cursor, 0, maxi(failures.size() - 1, 0))
	if failure_cursor < failure_top:
		failure_top = failure_cursor
	elif failure_cursor >= failure_top + DETAIL_ROWS:
		failure_top = failure_cursor - DETAIL_ROWS + 1
	_detail_title.text = report["title"]
	_detail_count.text = "%d of %d" % [failure_cursor + 1, failures.size()]
	for i in DETAIL_ROWS:
		var parts: Dictionary = _detail_rows[i]
		var at := failure_top + i
		parts["row"].visible = at < failures.size()
		if at >= failures.size():
			continue
		parts["message"].text = failures[at]["error"]
		parts["path"].text = JoyPathText.printable(failures[at]["path"])
		parts["row"].add_theme_stylebox_override("panel", Theme_.box(Theme_.ROW_SEL if at == failure_cursor else Color.TRANSPARENT, 8, 10))


func hint_pairs(jobs: Dictionary) -> Array:
	var pairs: Array = []
	if viewing >= 0:
		pairs.append(["jf_menu", "Dismiss"])
		pairs.append(["jf_back", "Back"])
		return pairs
	if focused_id() >= 0:
		pairs.append(["jf_menu", "Cancel job"])
		if is_waiting(focused_id(), jobs):
			pairs.append(["jf_accept", "Answer"])
	elif focused_report() >= 0:
		pairs.append(["jf_accept", "Open list"])
		pairs.append(["jf_menu", "Dismiss"])
	pairs.append(["jf_back", "Close"])
	return pairs


func _set_hints(jobs: Dictionary) -> void:
	var pairs := hint_pairs(jobs)
	var key := str(pairs)
	if key == _hints_key:
		return
	_hints_key = key
	for child in _hints_box.get_children():
		child.queue_free()
	_hints_box.add_child(Theme_.hints(pairs))
