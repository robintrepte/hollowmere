extends Node
## Plays with the on-screen touch controls forced on: joystick walking, the Use / Bag / menu buttons and
## long-press actions in the inventory, all through real screen-touch events.
##   godot --path game res://tests/smoke/touch_smoke.tscn -- --out=/abs/dir

var out_dir := "user://shots"
var main: Node
var failures := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var was: String = Settings.touch_controls
	Settings.touch_controls = "on"
	TouchControls.refresh_active()
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.3)
	var slot := SaveManager.first_free_slot()
	main._start_new({"player_name": "Robin", "farm_name": "Touch", "starter": "sproutle", "seed": 7})
	await _wait(1.0)
	var tc: TouchControls = null
	for c in main.get_children():
		if c is TouchControls:
			tc = c
	_check(tc != null, "main has touch controls")
	_check(not tc.visible or main.ui.dialogue.visible, "controls step aside for the intro letter")
	var lines := [0]
	main.ui.dialogue.advanced.connect(func(): lines[0] += 1)
	for i in 3:
		var p := Vector2(320, 300) if i < 2 else Vector2(500, 120)
		_touch(0, p, true)
		await get_tree().process_frame
		_touch(0, p, false)
		await _wait(0.3)
	_check(lines[0] >= 1, "tapping moves the letter along (%d advances)" % lines[0])
	await main.ui.dialogue.dismiss()
	main.ui.close_all()
	await _wait(0.2)
	_check(tc.visible, "controls show while walking around")
	await _shot("t01_touch_world")

	var size: Vector2 = tc._pad.size
	var start: Vector2 = main.player.position
	var stick := Vector2(70, size.y - 100)
	_touch(0, stick, true)
	for i in 6:
		await get_tree().process_frame
		_drag(0, stick + Vector2(5 * (i + 1), 0))
	_check(TouchControls.owns_pointer, "a finger on the stick owns the pointer")
	_check(Input.is_action_pressed("move_right") or main.player.position.x > start.x + 4, "pushing the stick right presses move_right")
	await _wait(0.5)
	await _shot("t02_touch_stick")
	_touch(0, stick + Vector2(30, 0), false)
	await get_tree().process_frame
	_check(main.player.position.x > start.x + 20, "the player walked right (%.0f px)" % (main.player.position.x - start.x))
	_check(not Input.is_action_pressed("move_right") and not TouchControls.owns_pointer, "lifting the finger stops walking")

	# Phones (especially iOS Safari) often only send an emulated left mouse, no ScreenTouch.
	start = main.player.position
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = stick + Vector2(28, 0)
	mb.button_mask = MOUSE_BUTTON_MASK_LEFT
	tc._pad._gui_input(mb)
	for i in 5:
		await get_tree().process_frame
		var mm := InputEventMouseMotion.new()
		mm.position = stick + Vector2(28 + i * 6, 0)
		mm.button_mask = MOUSE_BUTTON_MASK_LEFT
		tc._pad._gui_input(mm)
	await _wait(0.35)
	_check(Input.get_action_strength("move_right") > 0.3 or main.player.position.x > start.x + 8, "an emulated mouse drag also walks")
	mb = mb.duplicate()
	mb.pressed = false
	mb.button_mask = 0
	tc._pad._gui_input(mb)
	await get_tree().process_frame

	_touch(1, stick + Vector2(8, 0), true)
	for i in 3:
		await get_tree().process_frame
		_drag(1, stick + Vector2(8 + i, 0))
	_check(Input.get_action_strength("move_right") < 0.6, "a light push walks instead of running")
	_touch(1, stick, false)

	var use := _button(tc, "use")
	_touch(2, use, true)
	await get_tree().process_frame
	_touch(2, use, false)
	await _wait(0.05)
	_check(main.player.doll.is_swinging(), "the Use button swings the tool")
	await _wait(0.6)

	var bag := _button(tc, "bag")
	_touch(3, bag, true)
	await get_tree().process_frame
	_touch(3, bag, false)
	await _wait(0.3)
	var inv: InventoryPanel = main.ui.stack[-1] if not main.ui.stack.is_empty() else null
	_check(inv is InventoryPanel, "the Bag button opens the inventory")
	_check(tc.buttons().size() == 1, "only the back button stays over menus")
	if inv:
		await _shot("t03_touch_inventory")
		var view: GridView = null
		for v in inv.find_children("*", "GridView", true, false):
			if v.inv == GameState.local_player().inventory:
				view = v
		var e: Dictionary = view.inv.entries[0]
		var cell := Vector2(int(e.x), int(e.y))
		var at: Vector2 = view.get_global_transform_with_canvas() * (Vector2(1, 1) + (cell + Vector2(0.5, 0.5)) * GridView.CELL)
		_touch(4, at, true)
		await _wait(0.6)
		_check(inv._menu.visible, "holding an item opens its actions menu")
		_check(inv.held_uid == "", "the long press drops the item it picked up")
		await _shot("t04_touch_long_press")
		inv._menu.hide()
		_touch(4, at, false)
		await _wait(0.1)
		var back := _button(tc, "menu")
		_touch(5, back, true)
		await get_tree().process_frame
		_touch(5, back, false)
		await _wait(0.3)
		_check(not main.ui.is_open(), "the back button closes the inventory")

	var menu := _button(tc, "menu")
	_touch(6, menu, true)
	await get_tree().process_frame
	_touch(6, menu, false)
	await _wait(0.3)
	_check(main.ui.is_open(), "the menu button opens the pause menu")
	await _shot("t05_touch_pause")
	if main.ui.stack.is_empty():
		print("TOUCH SMOKE DONE, %d failures" % failures)
		get_tree().quit(1)
		return
	var journal: Button = null
	for b in main.ui.stack[-1].find_children("*", "Button", true, false):
		if b.text == "Journal":
			journal = b
	var jp := journal.get_global_rect().get_center()
	_touch(7, jp, true)
	await get_tree().process_frame
	_touch(7, jp, false)
	await _wait(0.3)
	_check(main.ui.stack.size() == 1 and main.ui.stack[0] is JournalPanel, "the pause menu opens the journal")
	main.ui.close_all()

	Settings.touch_controls = "off"
	TouchControls.refresh_active()
	await _wait(0.1)
	_check(not tc.visible, "turning touch controls off hides them")
	Settings.touch_controls = was
	TouchControls.refresh_active()
	if slot >= 0:
		SaveManager.delete_slot(slot)
	print("TOUCH SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _button(tc: TouchControls, id: String) -> Vector2:
	for b in tc.buttons():
		if b.id == id:
			return b.c
	_check(false, "button %s is showing" % id)
	return Vector2(-100, -100)

## Screen events are in window pixels; the controls work in the 640x360 canvas.
func _window(p: Vector2) -> Vector2:
	return get_tree().root.get_final_transform() * p

func _touch(index: int, p: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = _window(p)
	ev.pressed = pressed
	Input.parse_input_event(ev)

func _drag(index: int, p: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = _window(p)
	Input.parse_input_event(ev)

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
