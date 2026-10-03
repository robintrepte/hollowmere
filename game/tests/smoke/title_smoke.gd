extends Node
## Cycles the title screen through every backdrop and screenshots each with its ambience running.
##   godot --path game res://tests/smoke/title_smoke.tscn -- --out=/abs/dir

var out_dir := "user://shots"
var failures := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var main: Node = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.5)
	var title: TitleScreen = main.title
	_check(title != null, "title screen is up")
	_check(title._splash_label.text != "", "splash tip shown")
	var first: String = title._splash_label.text
	title._next_tip()
	_check(title._splash_label.text != first, "splash tip rotates")
	for i in TitleScreen.SCENES.size():
		var sc: Dictionary = TitleScreen.SCENES[i]
		title._show_scene(i, false)
		_check(title._bg.texture != null, "backdrop %s loads" % sc.bg)
		await _wait(2.5)
		_check(title._ambience._parts.size() > 0, "%s particles running" % sc.fx)
		title._ambience._spawn_walker()
		await _wait(1.0)
		_check(not title._ambience._walkers.is_empty(), "a Wildling wanders by")
		await _shot("title_%d_%s" % [i, sc.fx])
	var wk: Dictionary = title._ambience._walkers[0]
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = title._ambience._walker_pos(wk) - Vector2(0, 12)
	title._ambience._gui_input(click)
	_check(wk.jv > 0.0 or wk.jump > 0.0, "clicking a Wildling makes it hop")
	title._show_scene(1, true)
	await _wait(3.0)
	_check(title._ambience.fx == "petals", "crossfade switches the ambience")
	print("TITLE SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures else 0)

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
