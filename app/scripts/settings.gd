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
	show_hidden = _typed(cfg, "show_hidden", TYPE_BOOL, false)
	var key: String = _typed(cfg, "sort_key", TYPE_STRING, "name")
	sort_key = key if SORTS.has(key) else "name"
	sort_desc = _typed(cfg, "sort_desc", TYPE_BOOL, false)


func _typed(cfg: ConfigFile, key: String, type: int, fallback: Variant) -> Variant:
	var value: Variant = cfg.get_value(SECTION, key, fallback)
	return value if typeof(value) == type else fallback


func save() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "show_hidden", show_hidden)
	cfg.set_value(SECTION, "sort_key", sort_key)
	cfg.set_value(SECTION, "sort_desc", sort_desc)
	return cfg.save(path)
