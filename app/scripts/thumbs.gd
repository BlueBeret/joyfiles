class_name JoyThumbs
extends RefCounted

const EXTS := ["png", "jpg", "jpeg", "webp"]
const THUMB_SIDE := 96
const PREVIEW_SIDE := 1280
const MAX_FILE_BYTES := 48 * 1024 * 1024
const MAX_ACTIVE := 2
const CACHE_LIMIT := 192

# each key holds a texture and the original size, or nothing when the file cannot be decoded
var cache := {}
var _queue: Array = []
var _active := {}
var _lock := Mutex.new()
var _results: Array = []


static func is_image(file_name: String) -> bool:
	return file_name.get_extension().to_lower() in EXTS


static func key_of(path: String, side: int) -> String:
	return "%d|%s" % [side, path]


func entry(path: String, side: int) -> Dictionary:
	return cache.get(key_of(path, side), {})


func texture(path: String, side: int) -> Texture2D:
	return entry(path, side).get("tex")


# the newest wish replaces the old queue, so a fast scroll never decodes rows that left the screen
func want(paths: Array, side: int) -> void:
	_queue.clear()
	for path: String in paths:
		if JoyPathText.is_opaque(path):
			continue
		var key := key_of(path, side)
		if not cache.has(key) and not _active.has(key):
			_queue.append([key, path, side])
	_start_more()


func poll() -> bool:
	_lock.lock()
	var batch := _results
	_results = []
	_lock.unlock()
	for result: Dictionary in batch:
		var key: String = result["key"]
		var task: int = _active.get(key, -1)
		if task >= 0:
			WorkerThreadPool.wait_for_task_completion(task)
		_active.erase(key)
		var image: Image = result["image"]
		if image == null:
			cache[key] = {}
		else:
			cache[key] = {"tex": ImageTexture.create_from_image(image), "size": result["size"]}
		_trim()
	_start_more()
	return not batch.is_empty()


func _start_more() -> void:
	while _active.size() < MAX_ACTIVE and not _queue.is_empty():
		var job: Array = _queue.pop_front()
		_active[job[0]] = WorkerThreadPool.add_task(_decode.bind(job[0], job[1], job[2]))


func _trim() -> void:
	while cache.size() > CACHE_LIMIT:
		cache.erase(cache.keys()[0])


# runs on a worker thread, so it touches only its own locals and the locked result list
func _decode(key: String, path: String, side: int) -> void:
	var image := Image.load_from_file(path)
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
	_results.append({"key": key, "image": image, "size": original})
	_lock.unlock()
