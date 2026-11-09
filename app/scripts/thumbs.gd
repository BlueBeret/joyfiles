class_name JoyThumbs
extends RefCounted

const EXTS := ["png", "jpg", "jpeg", "webp"]
const THUMB_SIDE := 96
const PREVIEW_SIDE := 1280
const MAX_FILE_BYTES := 48 * 1024 * 1024
const MAX_ACTIVE := 2
const CACHE_LIMIT := 192

# each key holds a texture, the original size and the stamp of the decoded file, or only the stamp when the file cannot be decoded
var cache := {}
var _queue: Array = []
var _active := {}
var _lock := Mutex.new()
var _results: Array = []


static func is_image(file_name: String) -> bool:
	return file_name.get_extension().to_lower() in EXTS


static func key_of(path: String, side: int) -> String:
	return "%d|%s" % [side, path]


# the file as the list shows it, so a replaced or finished file gets a new stamp
static func stamp_of(e: Dictionary) -> String:
	return "%d|%d" % [e["modified"], e["size"]]


func entry(path: String, side: int) -> Dictionary:
	return cache.get(key_of(path, side), {})


func texture(path: String, side: int) -> Texture2D:
	return entry(path, side).get("tex")


# the newest wish replaces the old queue, so a fast scroll never decodes rows that left the screen
func want(items: Array, side: int) -> void:
	_queue.clear()
	for item: Dictionary in items:
		var key := key_of(item["path"], side)
		var stamp := stamp_of(item)
		if cache.get(key, {}).get("stamp", "") != stamp and _active.get(key, {}).get("stamp", "") != stamp:
			_queue.append([key, item["path"], side, stamp])
	_start_more()


func poll() -> bool:
	_lock.lock()
	var batch := _results
	_results = []
	_lock.unlock()
	for result: Dictionary in batch:
		var key: String = result["key"]
		var task: int = _active.get(key, {}).get("task", -1)
		if task >= 0:
			WorkerThreadPool.wait_for_task_completion(task)
		_active.erase(key)
		var image: Image = result["image"]
		cache.erase(key)
		if image == null:
			cache[key] = {"stamp": result["stamp"]}
		else:
			cache[key] = {"tex": ImageTexture.create_from_image(image), "size": result["size"], "stamp": result["stamp"]}
		_trim()
	_start_more()
	return not batch.is_empty()


func _start_more() -> void:
	while _active.size() < MAX_ACTIVE and not _queue.is_empty():
		var job: Array = _queue.pop_front()
		if _active.has(job[0]):
			continue
		_active[job[0]] = {"task": WorkerThreadPool.add_task(_decode.bind(job[0], job[1], job[2], job[3])), "stamp": job[3]}


func _trim() -> void:
	while cache.size() > CACHE_LIMIT:
		cache.erase(cache.keys()[0])


# a name that is not valid text reaches Godot only as bytes, so the core reads it and Godot decodes the buffer
static func _load(path: String) -> Image:
	if not JoyPathText.is_opaque(path):
		return Image.load_from_file(JoyPathText.native(path))
	var bytes := JoyFiles.read_bytes(path, MAX_FILE_BYTES)
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match path.get_extension().to_lower():
		"png": err = image.load_png_from_buffer(bytes)
		"jpg", "jpeg": err = image.load_jpg_from_buffer(bytes)
		"webp": err = image.load_webp_from_buffer(bytes)
	return image if err == OK else null


# runs on a worker thread, so it touches only its own locals and the locked result list
func _decode(key: String, path: String, side: int, stamp: String) -> void:
	var image := _load(path)
	var original := Vector2i.ZERO
	if image != null and not image.is_empty():
		original = image.get_size()
		var longest := maxi(original.x, original.y)
		if longest > side:
			var scale := float(side) / longest
			image.resize(maxi(1, roundi(original.x * scale)), maxi(1, roundi(original.y * scale)), Image.INTERPOLATE_BILINEAR)
	else:
		image = null
	_lock.lock()
	_results.append({"key": key, "image": image, "size": original, "stamp": stamp})
	_lock.unlock()
