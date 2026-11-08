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
const BUTTON_COLORS := {"A": Color("#3fb950"), "B": Color("#f85149"), "X": Color("#4f7cff"), "Y": Color("#e3b341")}


static func box(color: Color, radius := 0, margin := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(margin)
	return s


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
	row.add_theme_constant_override("separation", 20)
	for pair: Array in pairs:
		var chip := Label.new()
		chip.text = pair[0]
		chip.add_theme_font_size_override("font_size", 18)
		chip.add_theme_color_override("font_color", Color.WHITE)
		chip.add_theme_stylebox_override("normal", box(BUTTON_COLORS.get(pair[0], Color("#555b6b")), 14, 6))
		chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(chip)
		row.add_child(label(pair[1], MUTED, 20))
	return row


static func human_size(bytes: int) -> String:
	var units := ["B", "KB", "MB", "GB", "TB"]
	var value := float(bytes)
	var i := 0
	while value >= 1024.0 and i < units.size() - 1:
		value /= 1024.0
		i += 1
	return ("%d %s" % [value, units[i]]) if i == 0 else ("%.1f %s" % [value, units[i]])
