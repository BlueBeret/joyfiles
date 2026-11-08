class_name JoyPreview
extends PanelContainer

signal closed

var index := 0
var showing_full := false
var _thumbs: JoyThumbs
var _entries: Array = []
var _title: Label
var _image: TextureRect
var _info: Label


func _init() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	add_child(box)
	_title = Theme_.label("", Theme_.TEXT, 26, true)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_title)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", Theme_.box(Theme_.BG, 8, 8))
	box.add_child(frame)
	_image = TextureRect.new()
	_image.custom_minimum_size = Vector2(1080, 520)
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.add_child(_image)
	_info = Theme_.label("", Theme_.MUTED, 20)
	box.add_child(_info)
	box.add_child(Theme_.hints([["Left", "Previous"], ["Right", "Next"], ["B", "Close"]]))
	add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 20))


# the list is the folder view, so a step skips every entry that is not an image
func open(thumbs: JoyThumbs, entries: Array, at: int) -> void:
	_thumbs = thumbs
	_entries = entries
	index = at
	refresh()


func current() -> Dictionary:
	return _entries[index]


func handle(action: String) -> void:
	match action:
		"jf_left", "jf_up": _step(-1)
		"jf_right", "jf_down": _step(1)
		"jf_back", "jf_accept", "jf_menu": closed.emit()


func refresh() -> void:
	var e := current()
	var path: String = e["path"]
	var full := _thumbs.entry(path, JoyThumbs.PREVIEW_SIDE)
	var small := _thumbs.entry(path, JoyThumbs.THUMB_SIDE)
	showing_full = full.has("tex")
	_image.texture = full["tex"] if showing_full else small.get("tex")
	_title.text = e["name"]
	var parts: Array = ["%d of %d" % [index + 1, _entries.size()], Theme_.human_size(e["size"])]
	if full.has("size"):
		parts.append("%d x %d" % [full["size"].x, full["size"].y])
	elif full.is_empty() and _thumbs.cache.has(JoyThumbs.key_of(path, JoyThumbs.PREVIEW_SIDE)):
		parts.append("This image cannot be shown.")
	else:
		parts.append("Loading...")
	_info.text = "  |  ".join(parts)
	_thumbs.want(_wanted_paths(), JoyThumbs.PREVIEW_SIDE)


func _step(direction: int) -> void:
	var i := index + direction
	while i >= 0 and i < _entries.size():
		if JoyThumbs.is_image(_entries[i]["name"]):
			index = i
			return
		i += direction


func _wanted_paths() -> Array:
	var paths: Array = [current()["path"]]
	for direction: int in [1, -1]:
		var i := index + direction
		while i >= 0 and i < _entries.size():
			if JoyThumbs.is_image(_entries[i]["name"]):
				paths.append(_entries[i]["path"])
				break
			i += direction
	return paths
