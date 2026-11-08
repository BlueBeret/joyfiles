class_name JoyPathText
extends RefCounted

# the core carries a byte that is not valid text as U+F700 plus the byte
static var _escapes := RegEx.create_from_string("[\\x{F700}-\\x{F7FF}]")


# such a path names a file only to the core, so it never goes to FileAccess, DirAccess or Image
static func is_opaque(path: String) -> bool:
	return _escapes.search(path) != null


static func printable(text: String) -> String:
	return _escapes.sub(text, "�", true)
