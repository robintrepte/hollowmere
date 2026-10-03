extends Node
## Visual smoke test: drives the real game through a short session and saves screenshots.
##   godot --path game res://tests/smoke/smoke.tscn -- --out=/abs/dir

var out_dir := "user://shots"
var main: Node

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	if not main.has_method("_start_new"):
		push_error("main.gd failed to load")
		get_tree().quit(1)
		return
	await _wait(0.6)
	await _shot("01_title")
	var slot := SaveManager.first_free_slot()
	main._start_new({"player_name": "Robin", "farm_name": "Smoke", "starter": "puddlop", "seed": 1234,
		"look": {"skin": "#f0c8a0", "hair": "#c87838", "shirt": "#d07050", "pants": "#3a3a5a", "style": 2}})
	await _wait(1.2)
	await _shot("02_intro")
	await main.ui.dialogue.dismiss()
	main.ui.close_all()
	main.player.locked = false
	await _wait(0.4)
	await _shot("03_farm")
	var pd := GameState.local_player()
	main.player.position += Vector2(0, 64)
	await _wait(0.3)
	var tilled := GameState.to_tile(main.player.position) + Vector2i(0, 1)
	main.controller._on_use(tilled)
	await _wait(0.4)
	await _shot("04_farm_tool")
	main.ui.open(InventoryPanel.new(pd))
	await _wait(0.3)
	await _shot("05_inventory")
	main.ui.close_all()
	EventBus.map_change_requested.emit("town", Vector2i(24, 17))
	await _wait(1.0)
	await _shot("06_town")
	main.ui.open(ShopPanel.new("general_store"))
	await _wait(0.3)
	await _shot("07_shop")
	main.ui.close_all()
	GameState.world.minute = 1290
	EventBus.time_changed.emit(1290)
	await _wait(0.4)
	await _shot("08_town_night")
	main.sleep()
	await _wait(2.4)
	await _shot("09_day_report")
	main.ui.close_all()
	await _wait(0.5)
	await _shot("10_morning")
	# Farming loop: plant the tilled tile, water daily, harvest, ship.
	var g: FarmGrid = GameState.grid("farm")
	_check(g.is_tilled(tilled), "tile tilled by hoe")
	pd.selected = 5
	main.controller._on_use(tilled)
	await _wait(0.2)
	_check(not g.crop_at(tilled).is_empty(), "parsnip planted")
	for d in 5:
		if g.crop_ready(tilled):
			break
		pd.selected = 1
		main.controller._on_use(tilled)
		await _wait(0.4)
		main.sleep()
		await _wait(2.4)
		main.ui.close_all()
		await _wait(0.3)
	await _shot("11_grown")
	_check(g.crop_ready(tilled), "parsnip grew in 4 days")
	main.controller._on_interact(tilled)
	await _wait(0.3)
	_check(pd.inventory.count("parsnip") >= 1, "harvested parsnip")
	var e := pd.inventory.first_of("parsnip")
	if not e.is_empty():
		Coop.act("ship", [e.uid, -1])
	var money_before := GameState.money()
	main.sleep()
	await _wait(2.4)
	await _shot("12_ship_report")
	main.ui.close_all()
	_check(GameState.money() > money_before, "shipping paid out (%d -> %d)" % [money_before, GameState.money()])
	var day_saved := GameState.day()
	SaveManager.save_game()
	main.show_title()
	await _wait(0.5)
	main._load_slot(slot)
	await _wait(1.0)
	await _shot("13_loaded")
	_check(GameState.day() == day_saved and main.world != null, "save/load round trip")
	if slot >= 0:
		SaveManager.delete_slot(slot)
	print("SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)

var failures := 0

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("shot ", name)
