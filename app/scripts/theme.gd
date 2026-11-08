class_name Theme_
extends RefCounted

const BG := Color("#14161b")
const PANEL := Color("#1d2028")
const ROW_SEL := Color("#2d3a52")
const ACCENT := Color("#4f7cff")
const TEXT := Color("#e8eaf0")
const MUTED := Color("#8a90a0")
const FOLDER := Color("#ffc857")
const DANGER := Color("#ff5d5d")
const WARN := Color("#ffc857")


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


static func progress(ratio: float) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.max_value = 1.0
	bar.value = ratio
	bar.custom_minimum_size.y = 14
	bar.add_theme_stylebox_override("background", box(BG, 7, 0))
	bar.add_theme_stylebox_override("fill", box(ACCENT, 7, 0))
	return bar


static func label(text: String, color := TEXT, size := 24, clip := false) -> Label:
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
		item.add_child(label(pair[1], MUTED, 20))
		row.add_child(item)
	return row


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
