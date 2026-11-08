class_name JoyColumn
extends Container

# on a very wide window the content keeps this width, so a name and its size stay close
const MAX_WIDTH := 1440.0


func _get_minimum_size() -> Vector2:
	var found := Vector2.ZERO
	for child in get_children():
		if child is Control and child.visible:
			found = found.max(child.get_combined_minimum_size())
	return found


func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	var width := minf(size.x, MAX_WIDTH)
	for child in get_children():
		if child is Control and child.visible:
			fit_child_in_rect(child, Rect2((size.x - width) / 2.0, 0.0, width, size.y))
