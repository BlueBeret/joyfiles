class_name JoySettings
extends RefCounted

const SECTION := "view"
# each key holds its label, its ascending phrase and its descending phrase
const SORTS := {
	"name": ["Name", "A to Z", "Z to A"],
	"size": ["Size", "smallest first", "largest first"],
	"modified": ["Modified", "oldest first", "newest first"],
	"type": ["Type", "A to Z", "Z to A"],
}

var path: String
var show_hidden := false
var sort_key := "name"
var sort_desc := false


func _init(file_path := "user://settings.cfg") -> void:
	path = file_path


static func order_text(key: String, desc: bool) -> String:
	return SORTS[key][2 if desc else 1]


func load_file() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	show_hidden = bool(cfg.get_value(SECTION, "show_hidden", false))
	var key := str(cfg.get_value(SECTION, "sort_key", "name"))
	sort_key = key if SORTS.has(key) else "name"
	sort_desc = bool(cfg.get_value(SECTION, "sort_desc", false))


func save() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "show_hidden", show_hidden)
	cfg.set_value(SECTION, "sort_key", sort_key)
	cfg.set_value(SECTION, "sort_desc", sort_desc)
	return cfg.save(path)
