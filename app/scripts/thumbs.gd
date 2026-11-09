class_name JoyThumbs
extends RefCounted

const EXTS := ["png", "jpg", "jpeg", "webp"]
const THUMB_SIDE := 96
const PREVIEW_SIDE := 1280
const MAX_FILE_BYTES := 48 * 1024 * 1024
# a file that compresses well can still unpack to a huge image, so the header size is capped as well
const MAX_PIXELS := 64_000_000
const HEADER_BYTES := 262144
const MAX_ACTIVE := 2
const CACHE_LIMIT := 192
const CACHE_BYTES := 128 * 1024 * 1024

# each key holds a texture, its bytes, the original size and the stamp of the decoded file, or only the stamp when the file cannot be decoded
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
	return "%d|%d" % [e["modified_ns"], e["size"]]


# one rule for the preview and for the decode, so a folder or a file over the cap is never decoded
static func previewable(e: Dictionary) -> bool:
	return not e["is_dir"] and is_image(e["name"]) and e["size"] <= MAX_FILE_BYTES


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
			cache[key] = {"tex": ImageTexture.create_from_image(image), "bytes": result["bytes"], "size": result["size"], "stamp": result["stamp"]}
		_trim()
	_start_more()
	return not batch.is_empty()


func _start_more() -> void:
	while _active.size() < MAX_ACTIVE and not _queue.is_empty():
		var job: Array = _queue.pop_front()
		if _active.has(job[0]):
			continue
		_active[job[0]] = {"task": WorkerThreadPool.add_task(_decode.bind(job[0], job[1], job[2], job[3])), "stamp": job[3]}


func cache_bytes() -> int:
	var total := 0
	for item: Dictionary in cache.values():
		total += item.get("bytes", 0)
	return total


# the oldest entry leaves first, and the newest stays even when it alone is over the byte limit
func _trim() -> void:
	var bytes := cache_bytes()
	while cache.size() > 1 and (cache.size() > CACHE_LIMIT or bytes > CACHE_BYTES):
		var oldest: Variant = cache.keys()[0]
		bytes -= cache[oldest].get("bytes", 0)
		cache.erase(oldest)


# the width and height that a file header states, or Vector2i.ZERO when the header is not readable
static func header_size(head: PackedByteArray, ext: String) -> Vector2i:
	match ext:
		"png": return _png_size(head)
		"jpg", "jpeg": return _jpeg_size(head)
		"webp": return _webp_size(head)
	return Vector2i.ZERO


static func too_many_pixels(size: Vector2i) -> bool:
	return int(size.x) * int(size.y) > MAX_PIXELS


static func _be(head: PackedByteArray, at: int, count: int) -> int:
	var value := 0
	for i in count:
		value = (value << 8) | head[at + i]
	return value


static func _le(head: PackedByteArray, at: int, count: int) -> int:
	var value := 0
	for i in count:
		value |= head[at + i] << (8 * i)
	return value


static func _png_size(head: PackedByteArray) -> Vector2i:
	if head.size() < 24 or head.slice(0, 8) != PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) or head.slice(12, 16).get_string_from_ascii() != "IHDR":
		return Vector2i.ZERO
	return Vector2i(_be(head, 16, 4), _be(head, 20, 4))


# walks the marker segments up to the first frame header
static func _jpeg_size(head: PackedByteArray) -> Vector2i:
	if head.size() < 4 or head[0] != 0xFF or head[1] != 0xD8:
		return Vector2i.ZERO
	var at := 2
	while at + 4 <= head.size():
		if head[at] != 0xFF:
			return Vector2i.ZERO
		var marker := head[at + 1]
		if marker == 0xFF:
			at += 1
		elif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8):
			at += 2
		elif marker == 0xD9 or marker == 0xDA:
			return Vector2i.ZERO
		elif marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC:
			return Vector2i(_be(head, at + 7, 2), _be(head, at + 5, 2)) if at + 9 <= head.size() else Vector2i.ZERO
		else:
			at += 2 + _be(head, at + 2, 2)
	return Vector2i.ZERO


static func _webp_size(head: PackedByteArray) -> Vector2i:
	if head.size() < 30 or head.slice(0, 4).get_string_from_ascii() != "RIFF" or head.slice(8, 12).get_string_from_ascii() != "WEBP":
		return Vector2i.ZERO
	match head.slice(12, 16).get_string_from_ascii():
		"VP8 ":
			return Vector2i(_le(head, 26, 2) & 0x3FFF, _le(head, 28, 2) & 0x3FFF)
		"VP8L":
			var bits := _le(head, 21, 4)
			return Vector2i((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
		"VP8X":
			return Vector2i(_le(head, 24, 3) + 1, _le(head, 27, 3) + 1)
	return Vector2i.ZERO


# true when the header of the file states more pixels than the cap, read before any decode
static func over_pixel_cap(path: String) -> bool:
	var head := PackedByteArray()
	if JoyPathText.is_opaque(path):
		head = JoyFiles.read_bytes(path, MAX_FILE_BYTES)
	else:
		var file := FileAccess.open(JoyPathText.native(path), FileAccess.READ)
		if file != null:
			head = file.get_buffer(HEADER_BYTES)
	return too_many_pixels(header_size(head, path.get_extension().to_lower()))


# a name that is not valid text reaches Godot only as bytes, so the core reads it and Godot decodes the buffer
static func _load(path: String) -> Image:
	if over_pixel_cap(path):
		return null
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
	var bytes := 0
	if image != null and not image.is_empty():
		original = image.get_size()
		var longest := maxi(original.x, original.y)
		if longest > side:
			var scale := float(side) / longest
			image.resize(maxi(1, roundi(original.x * scale)), maxi(1, roundi(original.y * scale)), Image.INTERPOLATE_BILINEAR)
		bytes = image.get_data().size()
	else:
		image = null
	_lock.lock()
	_results.append({"key": key, "image": image, "bytes": bytes, "size": original, "stamp": stamp})
	_lock.unlock()
