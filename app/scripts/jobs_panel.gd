class_name JoyJobs
extends PanelContainer

signal closed
signal cancel_requested(id: int)
signal answer_requested(id: int)

var cursor := 0
var ids: Array = []
var _list: VBoxContainer
var _empty: Label
var _hints_box: VBoxContainer
var _hints_key := ""
var _rows := {}


func _init() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size.x = 760
	add_child(box)
	box.add_child(Theme_.label("Jobs", Theme_.TEXT, 28))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	box.add_child(_list)
	_empty = Theme_.label("No jobs are running.", Theme_.MUTED, 22)
	box.add_child(_empty)
	_hints_box = VBoxContainer.new()
	box.add_child(_hints_box)
	add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 24))


func focused_id() -> int:
	return ids[cursor] if not ids.is_empty() else -1


func progress_of(id: int) -> float:
	return _rows[id]["bar"].value if _rows.has(id) else -1.0


func is_waiting(id: int, jobs: Dictionary) -> bool:
	return id in jobs and not jobs[id].get("conflict", {}).is_empty()


func handle(action: String) -> void:
	match action:
		"jf_up": cursor = maxi(cursor - 1, 0)
		"jf_down": cursor = mini(cursor + 1, maxi(ids.size() - 1, 0))
		"jf_menu":
			if not ids.is_empty():
				cancel_requested.emit(ids[cursor])
		"jf_accept":
			if not ids.is_empty():
				answer_requested.emit(ids[cursor])
		"jf_back", "jf_jobs": closed.emit()


func update(jobs: Dictionary) -> void:
	ids = jobs.keys()
	ids.sort()
	cursor = clampi(cursor, 0, maxi(ids.size() - 1, 0))
	for id: int in _rows.keys():
		if not jobs.has(id):
			_rows[id]["row"].queue_free()
			_rows.erase(id)
	for i in ids.size():
		var id: int = ids[i]
		if not _rows.has(id):
			_rows[id] = _make_row()
			_list.add_child(_rows[id]["row"])
		_fill_row(_rows[id], jobs[id], i == cursor)
	_empty.visible = ids.is_empty()
	_set_hints(jobs)


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


func _set_hints(jobs: Dictionary) -> void:
	var pairs: Array = []
	if not ids.is_empty():
		pairs.append(["jf_menu", "Cancel job"])
		if is_waiting(focused_id(), jobs):
			pairs.append(["jf_accept", "Answer"])
	pairs.append(["jf_back", "Close"])
	var key := str(pairs)
	if key == _hints_key:
		return
	_hints_key = key
	for child in _hints_box.get_children():
		child.queue_free()
	_hints_box.add_child(Theme_.hints(pairs))
