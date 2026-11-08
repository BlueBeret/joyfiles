class_name JoyFitLabel
extends Label

# which part of a text stays when it is too wide: the start of the text, its end, or both ends with the middle cut
enum Cut { END, START, MIDDLE }

const ELLIPSIS := "…"
const SLACK := 2.0
const TAIL_CHARS := 6
const EXTENSION_CHARS := 8
const EXTENSION_KEEP := 3

var cut := Cut.END
# with a start cut, the text keeps whole parts after one of these characters, like "/"
var boundary := ""
var full := ""


func _init() -> void:
	clip_text = true
	text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	resized.connect(_fit)


func set_full(value: String) -> void:
	full = JoyPathText.printable(value)
	_fit()


func _fit() -> void:
	var room := size.x - get_theme_stylebox("normal").get_minimum_size().x - SLACK
	# before the first layout a label has no width, so it keeps the whole text until it gets one
	if room <= 0.0 or not is_inside_tree():
		text = full
		return
	var shown := cut_text(full, get_theme_font("font"), get_theme_font_size("font_size"), room, cut, boundary)
	if shown != text:
		text = shown


static func cut_text(value: String, font: Font, font_size: int, room: float, how: int, parts := "") -> String:
	if _width(value, font, font_size) <= room:
		return value
	match how:
		Cut.START:
			return _cut_start(value, font, font_size, room, parts)
		Cut.MIDDLE:
			return _cut_middle(value, font, font_size, room)
	return _cut_end(value, font, font_size, room)


static func _width(value: String, font: Font, font_size: int) -> float:
	return font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


# the most characters in 0..count that still fit, found by bisection because a wider cut never fits better
static func _most_that_fit(count: int, fits: Callable) -> int:
	var low := 0
	var high := count
	while low < high:
		var mid := (low + high + 1) >> 1
		if fits.call(mid):
			low = mid
		else:
			high = mid - 1
	return low


static func _cut_end(value: String, font: Font, font_size: int, room: float) -> String:
	var kept := _most_that_fit(value.length(), func(n: int) -> bool: return _width(value.left(n) + ELLIPSIS, font, font_size) <= room)
	return value.left(kept) + ELLIPSIS


static func _cut_start(value: String, font: Font, font_size: int, room: float, parts: String) -> String:
	var kept := _most_that_fit(value.length(), func(n: int) -> bool: return _width(ELLIPSIS + value.right(n), font, font_size) <= room)
	var from := value.length() - kept
	if parts != "":
		for i in range(maxi(from, 1), value.length()):
			if parts.contains(value[i]):
				return ELLIPSIS + value.substr(i)
	return ELLIPSIS + value.substr(from)


# keeps the extension and a few characters before it, so two long names that differ at the start stay apart
static func _cut_middle(value: String, font: Font, font_size: int, room: float) -> String:
	var tail_length := mini(TAIL_CHARS, value.length() - 1)
	var dot := value.rfind(".")
	if dot > 0 and value.length() - dot <= EXTENSION_CHARS and not value.substr(dot).contains(" "):
		tail_length = mini(value.length() - dot + EXTENSION_KEEP, value.length() - 1)
	var tail := value.right(tail_length)
	var head := value.left(value.length() - tail_length)
	var kept := _most_that_fit(head.length(), func(n: int) -> bool: return _width(head.left(n) + ELLIPSIS + tail, font, font_size) <= room)
	if kept == 0 and _width(ELLIPSIS + tail, font, font_size) > room:
		return _cut_end(value, font, font_size, room)
	return head.left(kept) + ELLIPSIS + tail
