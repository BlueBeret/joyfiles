class_name JoyScrollBox
extends ScrollContainer

# with a cap the box grows with its content up to that height, and without one it fills the room that its parent gives
var max_height := 0.0
var content: Control


func _init(for_content: Control, cap := 0.0) -> void:
	max_height = cap
	content = for_content
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(content)
	if cap > 0.0:
		content.minimum_size_changed.connect(_fit)


func is_scrollable() -> bool:
	return size.y > 0.0 and content.get_combined_minimum_size().y > size.y + 0.5


# waits one frame, because a scroll range only follows the content after the layout has run
func reveal(control: Control) -> void:
	await get_tree().process_frame
	if is_instance_valid(control) and is_ancestor_of(control):
		ensure_control_visible(control)


func _fit() -> void:
	custom_minimum_size.y = minf(content.get_combined_minimum_size().y, max_height)
