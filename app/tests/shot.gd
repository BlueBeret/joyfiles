extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := OS.get_environment("JF_SHOT_DIR")
	var app: Control = load("res://main.tscn").instantiate()
	app.start_path = OS.get_environment("JF_TEST_DIR")
	root.add_child(app)
	for step in [[], ["jf_down", "jf_select", "jf_select", "jf_menu"], ["jf_back", "jf_menu", "jf_down", "jf_down", "jf_down", "jf_accept"]]:
		for action: String in step:
			app.fire(action)
		for i in 10:
			await process_frame
		root.get_texture().get_image().save_png("%s/shot_%d.png" % [out, step.size()])
	quit()
