class_name JoyCommands
extends RefCounted

# a command is [action, label, run] or [action, label, run, when], and a label is text or a Callable that returns it


static func run(action: String, commands: Array) -> bool:
	for command: Array in commands:
		if command[0] == action and _enabled(command):
			command[2].call()
			return true
	return false


static func hints(commands: Array) -> Array:
	var pairs: Array = []
	for command: Array in commands:
		var label: String = command[1].call() if command[1] is Callable else command[1]
		if label != "" and _enabled(command):
			pairs.append([command[0], label])
	return pairs


static func _enabled(command: Array) -> bool:
	return command.size() < 4 or command[3].call()
