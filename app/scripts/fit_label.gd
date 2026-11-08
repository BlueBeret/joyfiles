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
# text that stays whole right after the cut text
var suffix := ""
# the tokens of the full text as [start, end, original text], so a cut never splits one
var tokens: Array = []


func _init() -> void:
	clip_text = true
	text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	resized.connect(_fit)


# a raw text gets scanned, and a text that the caller already scanned comes with its tokens
func set_full(value: String, known: Variant = null) -> void:
	if known == null:
		var scanned := JoyPathText.scan(value)
		full = scanned["shown"]
		tokens = scanned["tokens"]
	else:
		full = value
		tokens = known
	_fit()


func _fit() -> void:
	var room := size.x - get_theme_stylebox("normal").get_minimum_size().x - SLACK
	# before the first layout a label has no width, so it keeps the whole text until it gets one
	if room <= 0.0 or not is_inside_tree():
		text = full + suffix
		return
	var font := get_theme_font("font")
	var font_size := get_theme_font_size("font_size")
	var shown := cut_text(full, font, font_size, room - _width(suffix, font, font_size), cut, boundary, tokens) + suffix
	if shown != text:
		text = shown


static func cut_text(value: String, font: Font, font_size: int, room: float, how: int, parts := "", marks: Array = []) -> String:
	if _width(value, font, font_size) <= room:
		return value
	match how:
		Cut.START:
			return _cut_start(value, font, font_size, room, parts, marks)
		Cut.MIDDLE:
			return _cut_middle(value, font, font_size, room, marks)
	return _cut_end(value, font, font_size, room, marks)


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


static func _cut_end(value: String, font: Font, font_size: int, room: float, marks: Array) -> String:
	var kept := _most_that_fit(value.length(), func(n: int) -> bool: return _width(value.left(n) + ELLIPSIS, font, font_size) <= room)
	return value.left(_before_token(kept, marks)) + ELLIPSIS


# a cut inside a token moves to the start of that token, so no half token shows
static func _before_token(at: int, marks: Array) -> int:
	for token: Array in marks:
		if token[0] < at and at < token[1]:
			return token[0]
	return at


# a cut inside a token moves to the end of that token
static func _after_token(at: int, marks: Array) -> int:
	for token: Array in marks:
		if token[0] < at and at < token[1]:
			return token[1]
	return at


static func _cut_start(value: String, font: Font, font_size: int, room: float, parts: String, marks: Array) -> String:
	var kept := _most_that_fit(value.length(), func(n: int) -> bool: return _width(ELLIPSIS + value.right(n), font, font_size) <= room)
	var from := _after_token(value.length() - kept, marks)
	if parts != "":
		for i in range(maxi(from, 1), value.length()):
			if parts.contains(value[i]):
				return ELLIPSIS + value.substr(i)
	return ELLIPSIS + value.substr(from)


# keeps the extension and a few characters before it, so two long names that differ at the start stay apart
static func _cut_middle(value: String, font: Font, font_size: int, room: float, marks: Array) -> String:
	var tail_length := mini(TAIL_CHARS, value.length() - 1)
	var dot := value.rfind(".")
	if dot > 0 and value.length() - dot <= EXTENSION_CHARS and not value.substr(dot).contains(" "):
		tail_length = mini(value.length() - dot + EXTENSION_KEEP, value.length() - 1)
	var tail := value.substr(_after_token(value.length() - tail_length, marks))
	var head := value.left(value.length() - tail_length)
	var kept := _most_that_fit(head.length(), func(n: int) -> bool: return _width(head.left(n) + ELLIPSIS + tail, font, font_size) <= room)
	if kept == 0 and _width(ELLIPSIS + tail, font, font_size) > room:
		return _cut_end(value, font, font_size, room, marks)
	return value.left(_before_token(kept, marks)) + ELLIPSIS + tail
