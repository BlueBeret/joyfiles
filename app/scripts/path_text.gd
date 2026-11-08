class_name JoyPathText
extends RefCounted

# marks that follow one base character, and the rest of a longer run collapses into one count
const MAX_MARKS := 3

# the core carries a byte that is not valid text as U+F700 plus the byte, and a real U+F7xx as the escaped bytes of its UTF-8 form
static var _escapes := RegEx.create_from_string("[\\x{F700}-\\x{F7FF}]")
static var _runs := RegEx.create_from_string("[\\x{F700}-\\x{F7FF}]+")
# control, format and filler characters, which no row may draw because some reorder the text and some draw nothing
static var _hidden := RegEx.create_from_string("[\\x{0}-\\x{1F}\\x{7F}-\\x{9F}\\x{AD}\\x{34F}\\x{600}-\\x{605}\\x{61C}\\x{6DD}\\x{70F}\\x{115F}\\x{1160}\\x{17B4}\\x{17B5}\\x{180E}\\x{200B}\\x{200E}\\x{200F}\\x{2028}-\\x{202E}\\x{2060}-\\x{206F}\\x{2800}\\x{3164}\\x{FEFF}\\x{FFA0}\\x{FFF9}-\\x{FFFB}\\x{E0001}-\\x{E007F}]")
# a text of only spaces and invisible joiners or selectors, which draws as nothing
static var _blank := RegEx.create_from_string("^[\\s\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{202F}\\x{205F}\\x{3000}\\x{180B}-\\x{180D}\\x{200C}\\x{200D}\\x{FE00}-\\x{FE0F}\\x{E0100}-\\x{E01EF}]*$")
static var _marks := RegEx.create_from_string("\\p{M}+")
static var _mark := RegEx.create_from_string("^\\p{M}$")


# such a path names a file only to the core, so it never goes to FileAccess, DirAccess or Image
static func is_opaque(path: String) -> bool:
	if _escapes.search(path) == null:
		return false
	for run in _runs.search_all(path):
		if _decode(run.get_string()) == null:
			return true
	return false


# the path that Godot can open, where an escaped real character is the character itself, and a path that is opaque stays as it is
static func native(path: String) -> String:
	if _escapes.search(path) == null:
		return path
	var out := ""
	var at := 0
	for run in _runs.search_all(path):
		var decoded: Variant = _decode(run.get_string())
		if decoded == null:
			return path
		out += path.substr(at, run.get_start() - at) + decoded
		at = run.get_end()
	return out + path.substr(at)


# the text of a run of escapes when its bytes are valid UTF-8, or null when one of them is a byte that is not valid text
static func _decode(run: String) -> Variant:
	var bytes := PackedByteArray()
	for ch in run:
		bytes.append(ch.unicode_at(0) - 0xF700)
	var decoded := bytes.get_string_from_utf8()
	return decoded if decoded.to_utf8_buffer() == bytes else null


# a text that is safe to draw, with every hidden character shown as <U+XXXX>, a blank name made visible and long mark runs cut
static func printable(text: String) -> String:
	return scan(text)["shown"]


# the drawn text plus its tokens as [start, end, original text], so an edit of the drawn text can give the hidden parts back
static func scan(text: String) -> Dictionary:
	if _escapes.search(text) == null and _hidden.search(text) == null and _marks.search(text) == null and (text == "" or _blank.search(text) == null):
		return {"shown": text, "tokens": []}
	var blank := text != "" and _blank.search(text) != null
	# each piece is [drawn text, original text], and the original is "" for a character that draws as itself
	var pieces: Array = []
	var runs := _runs.search_all(text)
	var next_run := 0
	var i := 0
	while i < text.length():
		if next_run < runs.size() and runs[next_run].get_start() == i:
			pieces.append_array(_escape_pieces(runs[next_run].get_string()))
			i = runs[next_run].get_end()
			next_run += 1
			continue
		var ch := text[i]
		pieces.append([_spell(ch), ch] if blank or _hidden.search(ch) != null else [ch, ""])
		i += 1
	return _assemble(_cap_marks(pieces))


# a real character shows as its mark, and a byte that is not valid text shows as one replacement character
static func _escape_pieces(run: String) -> Array:
	var decoded: Variant = _decode(run)
	var out: Array = []
	if decoded == null:
		for ch in run:
			out.append(["�", ch])
		return out
	var at := 0
	for ch: String in decoded:
		var length := ch.to_utf8_buffer().size()
		out.append([_spell(ch), run.substr(at, length)])
		at += length
	return out


static func _assemble(pieces: Array) -> Dictionary:
	var shown := ""
	var tokens: Array = []
	for piece: Array in pieces:
		if piece[1] != "":
			tokens.append([shown.length(), shown.length() + piece[0].length(), piece[1]])
		shown += piece[0]
	return {"shown": shown, "tokens": tokens}


# the name that an edit means, or null when it cut into a token, and kept counts the leading characters that no edit ever touched
static func restore(first: Dictionary, edited: String, kept: int) -> Variant:
	kept = mini(kept, shared_start(first["shown"], edited))
	var out := ""
	var at := 0
	for token: Array in first["tokens"]:
		if token[0] >= kept:
			break
		if token[1] > kept:
			return null
		out += edited.substr(at, token[0] - at) + token[2]
		at = token[1]
	return out + edited.substr(at)


# how many leading characters two texts share
static func shared_start(a: String, b: String) -> int:
	var n := 0
	var most := mini(a.length(), b.length())
	while n < most and a.unicode_at(n) == b.unicode_at(n):
		n += 1
	return n


static func _spell(text: String) -> String:
	var out := ""
	for ch in text:
		out += "<U+%04X>" % ch.unicode_at(0)
	return out


# a run of marks keeps its first few and says how many it dropped, so a stack cannot push the letters out of a row
static func _cap_marks(pieces: Array) -> Array:
	var out: Array = []
	var run := 0
	var dropped := ""
	for piece: Array in pieces:
		var is_mark: bool = piece[1] == "" and _mark.search(piece[0]) != null
		if is_mark:
			run += 1
			if run > MAX_MARKS:
				dropped += piece[0]
				continue
		else:
			_flush_marks(out, dropped)
			dropped = ""
			run = 0
		out.append(piece)
	_flush_marks(out, dropped)
	return out


static func _flush_marks(out: Array, dropped: String) -> void:
	if dropped != "":
		out.append(["<+%d marks>" % dropped.length(), dropped])
