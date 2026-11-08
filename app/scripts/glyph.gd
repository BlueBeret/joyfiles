class_name JoyGlyph
extends Control

enum Shape { FACE, DPAD, MENU, VIEW, BUMPER, TRIGGER, STICK }

const HEIGHT := 32.0
const CELL := 32.0
const MID := Vector2(CELL, CELL) / 2.0
const LINE := 2.0
const PAIR_GAP := 6.0
# polygon size of one side of a pair, before the outline widens it
const UNITS := {Shape.BUMPER: Vector2(24, 10), Shape.TRIGGER: Vector2(22, 26), Shape.STICK: Vector2(22, 22)}
# one row per logical action: the shape, then the lit part as a direction
const SPECS := {
	"jf_up": [Shape.DPAD, Vector2.UP],
	"jf_down": [Shape.DPAD, Vector2.DOWN],
	"jf_left": [Shape.DPAD, Vector2.LEFT],
	"jf_right": [Shape.DPAD, Vector2.RIGHT],
	"jf_accept": [Shape.FACE, Vector2.DOWN],
	"jf_back": [Shape.FACE, Vector2.RIGHT],
	"jf_menu": [Shape.FACE, Vector2.LEFT],
	"jf_select": [Shape.FACE, Vector2.UP],
	"jf_pane": [Shape.BUMPER, Vector2.LEFT],
	"jf_page_up": [Shape.TRIGGER, Vector2.LEFT],
	"jf_page_down": [Shape.TRIGGER, Vector2.RIGHT],
	"jf_start": [Shape.MENU, Vector2.ZERO],
	"jf_view": [Shape.VIEW, Vector2.ZERO],
	"jf_search": [Shape.STICK, Vector2.RIGHT],
	"jf_jobs": [Shape.STICK, Vector2.LEFT],
}

var action := ""
var _shape: int
var _lit: Vector2


static func of(for_action: String, height := HEIGHT) -> JoyGlyph:
	assert(SPECS.has(for_action), "no glyph for " + for_action)
	var glyph := JoyGlyph.new()
	glyph.action = for_action
	glyph._shape = SPECS[for_action][0]
	glyph._lit = SPECS[for_action][1]
	glyph.custom_minimum_size = glyph._design_size() * (height / CELL)
	glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return glyph


func _design_size() -> Vector2:
	if UNITS.has(_shape):
		return Vector2(UNITS[_shape].x * 2.0 + PAIR_GAP + LINE, CELL)
	return Vector2(CELL, CELL)


func _draw() -> void:
	var design := _design_size()
	var k := minf(size.x / design.x, size.y / design.y)
	draw_set_transform((size - design * k) / 2.0, 0.0, Vector2(k, k))
	match _shape:
		Shape.FACE: _draw_face()
		Shape.DPAD: _draw_dpad()
		Shape.MENU: _draw_menu()
		Shape.VIEW: _draw_view()
		_: _draw_pair()


func _draw_face() -> void:
	for direction: Vector2 in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		_ring(MID + direction * 10.5, 5.5, direction == _lit)


func _draw_dpad() -> void:
	var plus := PackedVector2Array([
		Vector2(11, 1), Vector2(21, 1), Vector2(21, 11), Vector2(31, 11), Vector2(31, 21), Vector2(21, 21),
		Vector2(21, 31), Vector2(11, 31), Vector2(11, 21), Vector2(1, 21), Vector2(1, 11), Vector2(11, 11),
	])
	_outline(plus, Theme_.MUTED)
	var arm := PackedVector2Array()
	for corner: Vector2 in [Vector2(-5, -15), Vector2(5, -15), Vector2(5, -5), Vector2(-5, -5)]:
		arm.append(MID + corner.rotated(_lit.angle() - Vector2.UP.angle()))
	_piece(arm, true)


func _draw_menu() -> void:
	draw_circle(MID, 15.0 - LINE / 2.0, Theme_.MUTED, false, LINE, true)
	for y in [11.5, 16.0, 20.5]:
		draw_line(Vector2(10, y), Vector2(22, y), Theme_.TEXT, LINE, true)


func _draw_view() -> void:
	draw_circle(MID, 15.0 - LINE / 2.0, Theme_.MUTED, false, LINE, true)
	_outline(_rect_points(Rect2(9.5, 10.5, 9, 7)), Theme_.TEXT, 1.5)
	draw_rect(Rect2(13.5, 14.5, 9, 7), Theme_.PANEL)
	_outline(_rect_points(Rect2(13.5, 14.5, 9, 7)), Theme_.TEXT, 1.5)


func _draw_pair() -> void:
	var unit: Vector2 = UNITS[_shape]
	for side: float in [-1.0, 1.0]:
		var x := LINE / 2.0 + (0.0 if side < 0.0 else unit.x + PAIR_GAP)
		var rect := Rect2(x, (CELL - unit.y) / 2.0, unit.x, unit.y)
		var lit := _lit.x == side
		match _shape:
			Shape.BUMPER:
				_piece(_round_rect(rect, 4.0, 4.0, 4.0, 4.0), lit)
			Shape.TRIGGER:
				var outer := 10.0
				var inner := 2.0
				_piece(_round_rect(rect, outer if side < 0.0 else inner, inner if side < 0.0 else outer, inner, inner), lit)
			_:
				_stick(rect.get_center(), unit.x / 2.0, lit)


func _ring(center: Vector2, radius: float, lit: bool) -> void:
	if lit:
		draw_circle(center, radius, Theme_.TEXT, true, -1.0, true)
	else:
		draw_circle(center, radius - LINE / 2.0, Theme_.MUTED, false, LINE, true)


func _stick(center: Vector2, radius: float, lit: bool) -> void:
	_ring(center, radius, lit)
	if lit:
		var chevron := PackedVector2Array([center + Vector2(-4, -2), center + Vector2(0, 2), center + Vector2(4, -2)])
		draw_polyline(chevron, Theme_.PANEL, LINE, true)


func _piece(points: PackedVector2Array, lit: bool) -> void:
	if lit:
		draw_colored_polygon(points, Theme_.TEXT)
	_outline(points, Theme_.TEXT if lit else Theme_.MUTED)


func _outline(points: PackedVector2Array, color: Color, width := LINE) -> void:
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, color, width, true)


func _rect_points(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])


func _round_rect(rect: Rect2, top_left: float, top_right: float, bottom_right: float, bottom_left: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var corners := [
		[rect.position + Vector2(top_left, top_left), PI, top_left],
		[Vector2(rect.end.x - top_right, rect.position.y + top_right), PI * 1.5, top_right],
		[rect.end - Vector2(bottom_right, bottom_right), 0.0, bottom_right],
		[Vector2(rect.position.x + bottom_left, rect.end.y - bottom_left), PI * 0.5, bottom_left],
	]
	for corner: Array in corners:
		for i in 7:
			var angle: float = corner[1] + PI * 0.5 * i / 6.0
			points.append(corner[0] + Vector2(cos(angle), sin(angle)) * corner[2])
	return points
