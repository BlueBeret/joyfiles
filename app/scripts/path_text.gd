class_name JoyPathText
extends RefCounted

# the core carries a byte that is not valid text as U+F700 plus the byte
static var _escapes := RegEx.create_from_string("[\\x{F700}-\\x{F7FF}]")
# control and format characters, which no row may draw because some of them, like U+202E, reorder the text
static var _hidden := RegEx.create_from_string("[\\x{0}-\\x{1F}\\x{7F}-\\x{9F}\\x{AD}\\x{600}-\\x{605}\\x{61C}\\x{6DD}\\x{70F}\\x{180E}\\x{200B}\\x{200E}\\x{200F}\\x{2028}-\\x{202E}\\x{2060}-\\x{206F}\\x{FEFF}\\x{FFF9}-\\x{FFFB}\\x{E0001}-\\x{E007F}]")


# such a path names a file only to the core, so it never goes to FileAccess, DirAccess or Image
static func is_opaque(path: String) -> bool:
	return _escapes.search(path) != null


# a text that is safe to draw, with every hidden character shown as <U+XXXX> and a blank name made visible
static func printable(text: String) -> String:
	var shown := _escapes.sub(text, "�", true)
	if _hidden.search(shown) == null and shown.strip_edges() != "":
		return shown
	var out := ""
	for ch in shown:
		out += "<U+%04X>" % ch.unicode_at(0) if _hidden.search(ch) != null else ch
	if out != "" and out.strip_edges() == "":
		return out.replace(" ", "<U+0020>")
	return out
