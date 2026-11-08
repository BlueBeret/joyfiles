class_name JoyPathText
extends RefCounted

# marks that follow one base character, and the rest of a longer run collapses into one count
const MAX_MARKS := 3

# the core carries a byte that is not valid text as U+F700 plus the byte
static var _escapes := RegEx.create_from_string("[\\x{F700}-\\x{F7FF}]")
# control, format and filler characters, which no row may draw because some reorder the text and some draw nothing
static var _hidden := RegEx.create_from_string("[\\x{0}-\\x{1F}\\x{7F}-\\x{9F}\\x{AD}\\x{34F}\\x{600}-\\x{605}\\x{61C}\\x{6DD}\\x{70F}\\x{115F}\\x{1160}\\x{17B4}\\x{17B5}\\x{180E}\\x{200B}\\x{200E}\\x{200F}\\x{2028}-\\x{202E}\\x{2060}-\\x{206F}\\x{2800}\\x{3164}\\x{FEFF}\\x{FFA0}\\x{FFF9}-\\x{FFFB}\\x{E0001}-\\x{E007F}]")
# a text of only spaces, which draws as nothing
static var _blank := RegEx.create_from_string("^[\\s\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{202F}\\x{205F}\\x{3000}]*$")
static var _marks := RegEx.create_from_string("\\p{M}+")


# such a path names a file only to the core, so it never goes to FileAccess, DirAccess or Image
static func is_opaque(path: String) -> bool:
	return _escapes.search(path) != null


# a text that is safe to draw, with every hidden character shown as <U+XXXX>, a blank name made visible and long mark runs cut
static func printable(text: String) -> String:
	var shown := _escapes.sub(text, "�", true)
	if shown != "" and _blank.search(shown) != null:
		return _spell(shown)
	if _hidden.search(shown) != null:
		var out := ""
		for ch in shown:
			out += _spell(ch) if _hidden.search(ch) != null else ch
		shown = out
	return _cap_marks(shown)


static func _spell(text: String) -> String:
	var out := ""
	for ch in text:
		out += "<U+%04X>" % ch.unicode_at(0)
	return out


# a run of marks keeps its first few and says how many it dropped, so a stack cannot push the letters out of a row
static func _cap_marks(text: String) -> String:
	var out := ""
	var at := 0
	for run in _marks.search_all(text):
		var length: int = run.get_end() - run.get_start()
		if length <= MAX_MARKS:
			continue
		out += text.substr(at, run.get_start() + MAX_MARKS - at) + "<+%d marks>" % (length - MAX_MARKS)
		at = run.get_end()
	return text if at == 0 else out + text.substr(at)
