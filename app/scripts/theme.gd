class_name Theme_
extends RefCounted

const BG := Color("#14161b")
const PANEL := Color("#1d2028")
const SIDE := Color("#191b22")
const ROW_SEL := Color("#2d3a52")
# the cursor fill is dark so every ink reads on it, and the ring makes the cursor stand out
const CURSOR := Color("#1a3490")
const RING := Color("#6f95ff")
const RING_WIDTH := 3
# the progress bar fill, a mark and never a text color
const ACCENT := Color("#4f7cff")
const TEXT := Color("#eef0f6")
const MUTED := Color("#b3bad0")
const FOLDER := Color("#ffc857")
const DANGER := Color("#ff9a9a")
const WARN := Color("#ffc857")
const MIN_TEXT_CONTRAST := 4.5
const MIN_MARK_CONTRAST := 3.0
# every surface that carries text, and every ink that the UI draws as text on any of them
const SURFACES := {"BG": BG, "PANEL": PANEL, "SIDE": SIDE, "SELECTED": ROW_SEL, "CURSOR": CURSOR}
const INKS := {"TEXT": TEXT, "MUTED": MUTED, "FOLDER": FOLDER, "WARN": WARN, "DANGER": DANGER}
# a mark is a line or a fill without text, as [mark, surface, name], and it needs the lower WCAG ratio
const MARKS := [
	[RING, BG, "RING on BG"], [RING, PANEL, "RING on PANEL"], [RING, SIDE, "RING on SIDE"],
	[ACCENT, BG, "ACCENT on BG"], [MUTED, PANEL, "MUTED glyph on PANEL"], [TEXT, PANEL, "TEXT glyph on PANEL"],
]
const SIZE_SMALL := 20
const SIZE_BODY := 22
const SIZE_LIST := 24
const SIZE_TITLE := 26
const SIZE_HEAD := 28
const FONT_DIR := "res://fonts/"
# the first font covers Latin, Greek and Cyrillic, the others cover scripts and symbols that a device can lack
const FONT_FILES := ["NotoSans", "NotoSansThai", "NotoSansArabic", "NotoSansHebrew", "NotoSansSymbols2-Subset"]
const BASE_SIZE := 22

static var _theme: Theme


# one theme for the whole window, so every label gets the bundled font and the same default size
static func theme() -> Theme:
	if _theme == null:
		var faces: Array[Font] = []
		for stem: String in FONT_FILES:
			faces.append(load("%s%s.ttf" % [FONT_DIR, stem]))
		var font := FontVariation.new()
		font.base_font = faces[0]
		font.fallbacks = faces.slice(1)
		_theme = Theme.new()
		_theme.default_font = font
		_theme.default_font_size = BASE_SIZE
		_theme.set_color("font_color", "Label", TEXT)
	return _theme


static func luminance(c: Color) -> float:
	var parts: Array[float] = []
	for channel: float in [c.r, c.g, c.b]:
		parts.append(channel / 12.92 if channel <= 0.04045 else pow((channel + 0.055) / 1.055, 2.4))
	return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]


# the WCAG 2 contrast ratio, from 1 to 21
static func contrast(a: Color, b: Color) -> float:
	var la := luminance(a)
	var lb := luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


# one row per pair that the UI draws, as [name, ratio, minimum], so the test and the report read the same table
static func contrast_rows() -> Array:
	var rows: Array = []
	for ink: String in INKS:
		for surface: String in SURFACES:
			rows.append(["%s on %s" % [ink, surface], contrast(INKS[ink], SURFACES[surface]), MIN_TEXT_CONTRAST])
	for mark: Array in MARKS:
		rows.append([mark[2], contrast(mark[0], mark[1]), MIN_MARK_CONTRAST])
	return rows


static func box(color: Color, radius := 0, margin := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(margin)
	return s


static func box_xy(color: Color, radius: int, margin_x: int, margin_y: int) -> StyleBoxFlat:
	var s := box(color, radius, margin_x)
	s.content_margin_top = margin_y
	s.content_margin_bottom = margin_y
	return s


# the one look of the cursor in every list, menu and keyboard, and the plain fill for a row that has none
static func focus_box(focused: bool, plain := Color.TRANSPARENT, radius := 8, margin_x := 10, margin_y := 10) -> StyleBoxFlat:
	var s := box_xy(CURSOR if focused else plain, radius, margin_x, margin_y)
	if focused:
		s.set_border_width_all(RING_WIDTH)
		s.border_color = RING
	return s


static func text_width(text: String, size: int) -> float:
	return theme().default_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


static func progress(ratio: float) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.max_value = 1.0
	bar.value = ratio
	bar.custom_minimum_size.y = 14
	bar.add_theme_stylebox_override("background", box(BG, 7, 0))
	bar.add_theme_stylebox_override("fill", box(ACCENT, 7, 0))
	return bar


static func label(text: String, color := TEXT, size := SIZE_LIST, clip := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	if clip:
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


static func hints(pairs: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	for pair: Array in pairs:
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 10)
		item.add_child(JoyGlyph.of(pair[0]))
		item.add_child(label(pair[1], MUTED, SIZE_BODY))
		row.add_child(item)
	return row


static func update_hints(holder: Container, pairs: Array) -> void:
	var key := str(pairs)
	if holder.get_meta("pairs", "") == key:
		return
	holder.set_meta("pairs", key)
	for child in holder.get_children():
		child.queue_free()
	holder.add_child(hints(pairs))


static func human_size(bytes: int) -> String:
	var units := ["B", "KB", "MB", "GB", "TB"]
	var value := float(bytes)
	var i := 0
	while value >= 1024.0 and i < units.size() - 1:
		value /= 1024.0
		i += 1
	return ("%d %s" % [value, units[i]]) if i == 0 else ("%.1f %s" % [value, units[i]])


static func with_commas(n: int) -> String:
	var digits := str(absi(n))
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return ("-" if n < 0 else "") + out


static func count(n: int, noun: String) -> String:
	return "%s %s%s" % [with_commas(n), noun, "" if n == 1 else "s"]


static func human_date(unix: int) -> String:
	if unix <= 0:
		return "Unknown"
	var local := unix + int(Time.get_time_zone_from_system()["bias"]) * 60
	var d := Time.get_datetime_dict_from_unix_time(local)
	return "%04d-%02d-%02d %02d:%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"]]
