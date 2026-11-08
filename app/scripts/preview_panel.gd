class_name JoyPreview
extends PanelContainer

signal closed

const IMAGE_BOX := Vector2(1080, 520)
const MIN_SIDE := 4.0

var index := 0
var showing_full := false
var commands: Array = []
var _thumbs: JoyThumbs
var _entries: Array = []
var _title: JoyFitLabel
var _image: TextureRect
var _info: Label
var _hints: HBoxContainer


func _init() -> void:
	var close := func() -> void: closed.emit()
	commands = [
		["jf_left", "Previous", _step.bind(-1), _has_step.bind(-1)],
		["jf_right", "Next", _step.bind(1), _has_step.bind(1)],
		["jf_back", "Close", close],
		["jf_up", "", _step.bind(-1), _has_step.bind(-1)],
		["jf_down", "", _step.bind(1), _has_step.bind(1)],
		["jf_accept", "", close],
		["jf_menu", "", close],
	]
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	add_child(box)
	_title = Theme_.fit("", Theme_.TEXT, Theme_.SIZE_TITLE, JoyFitLabel.Cut.MIDDLE)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_title)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", Theme_.box(Theme_.BG, 8, 8))
	box.add_child(frame)
	var area := Control.new()
	area.custom_minimum_size = IMAGE_BOX
	frame.add_child(area)
	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_SCALE
	area.add_child(_image)
	_info = Theme_.label("", Theme_.MUTED, Theme_.SIZE_BODY)
	box.add_child(_info)
	_hints = HBoxContainer.new()
	box.add_child(_hints)
	add_theme_stylebox_override("panel", Theme_.box(Theme_.PANEL, 16, 20))


# the list is the folder view, so a step skips every entry that is not an image
func open(thumbs: JoyThumbs, entries: Array, at: int) -> void:
	_thumbs = thumbs
	_entries = entries
	index = at
	refresh()


# the folder list was read again, so follow the shown image into it, or report that it is gone
func relist(entries: Array) -> bool:
	var path: String = current()["path"]
	for i in entries.size():
		if entries[i]["path"] == path:
			_entries = entries
			index = i
			return true
	return false


func current() -> Dictionary:
	return _entries[index]


func handle(action: String) -> void:
	JoyCommands.run(action, commands)


func refresh() -> void:
	var e := current()
	var path: String = e["path"]
	var full := _thumbs.entry(path, JoyThumbs.PREVIEW_SIDE)
	var small := _thumbs.entry(path, JoyThumbs.THUMB_SIDE)
	showing_full = full.has("tex")
	_image.texture = full["tex"] if showing_full else small.get("tex")
	_place_image()
	_title.set_full(e["name"])
	var parts: Array = ["%s of %s" % [Theme_.with_commas(index + 1), Theme_.with_commas(_entries.size())], Theme_.human_size(e["size"])]
	if full.has("size"):
		parts.append("%d x %d" % [full["size"].x, full["size"].y])
	elif full.is_empty() and _thumbs.cache.has(JoyThumbs.key_of(path, JoyThumbs.PREVIEW_SIDE)):
		parts.append("This image cannot be shown.")
	else:
		parts.append("Loading...")
	_info.text = "  |  ".join(parts)
	_thumbs.want(_wanted_paths(), JoyThumbs.PREVIEW_SIDE)
	Theme_.update_hints(_hints, JoyCommands.hints(commands))


# a small image grows with sharp pixels, and a thin image keeps a visible line
func _place_image() -> void:
	var tex := _image.texture
	_image.visible = tex != null
	if tex == null:
		return
	var rect := Theme_.fit_rect(tex.get_size(), IMAGE_BOX, MIN_SIDE)
	_image.position = rect.position
	_image.size = rect.size
	_image.texture_filter = Theme_.filter_for(tex.get_size(), rect.size) if showing_full else CanvasItem.TEXTURE_FILTER_LINEAR


func _loadable(e: Dictionary) -> bool:
	return JoyThumbs.is_image(e["name"])


func _neighbor(direction: int) -> int:
	var i := index + direction
	while i >= 0 and i < _entries.size():
		if _loadable(_entries[i]):
			return i
		i += direction
	return -1


func _has_step(direction: int) -> bool:
	return _neighbor(direction) >= 0


func _step(direction: int) -> void:
	index = _neighbor(direction)


func _wanted_paths() -> Array:
	var paths: Array = [current()["path"]]
	for direction: int in [1, -1]:
		if _has_step(direction):
			paths.append(_entries[_neighbor(direction)]["path"])
	return paths
