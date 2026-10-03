extends Node
## Opens every life-sim panel with some data in it and screenshots it.
##   godot --path game res://tests/smoke/ui_smoke.tscn -- --out=/abs/dir

var out_dir := "user://shots"
var main: Node
var failures := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.3)
	var slot := SaveManager.first_free_slot()
	main._start_new({"player_name": "Robin", "farm_name": "Smoke", "starter": "sproutle", "seed": 99})
	await _wait(1.0)
	await main.ui.dialogue.dismiss()
	main.ui.close_all()
	var pd := GameState.local_player()
	pd.inventory.add("fiber", 6)
	pd.inventory.add("wild_berry", 3)
	pd.inventory.add("leek", 2)
	pd.inventory.add("parsnip", 6)
	pd.inventory.add("wood", 120)
	pd.inventory.add("copper_bar", 5)
	GameState.add_money(6000)
	GameState.world.buildings.append("kitchen")
	Progression.mark(GameState.world.dex, "embercub", false)
	Progression.mark(GameState.world.dex, "puddlop", true)
	Relationships.add_points(Data.villagers.keys()[0], pd.relationship(Data.villagers.keys()[0]), 700)
	for spec in [
		["u01_crafting", CraftPanel.new(pd, "crafting")],
		["u02_cooking", CraftPanel.new(pd, "cooking")],
		["u03_journal_people", JournalPanel.new(pd, "people")],
		["u04_journal_board", JournalPanel.new(pd, "board")],
		["u05_journal_dex", JournalPanel.new(pd, "dex")],
		["u06_journal_weekly", JournalPanel.new(pd, "weekly")],
	]:
		main.ui.open(spec[1])
		await _wait(0.25)
		await _shot(spec[0])
		main.ui.close_all()
		await _wait(0.1)
	for spec2 in [["u07_carpenter_build", "carpenter", "build"], ["u08_blacksmith_upgrades", "blacksmith", "upgrades"], ["u09_store_backpacks", "general_store", "backpacks"]]:
		var sp := ShopPanel.new(spec2[1])
		main.ui.open(sp)
		await _wait(0.1)
		sp._tab = spec2[2]
		sp._refresh()
		await _wait(0.25)
		await _shot(spec2[0])
		main.ui.close_all()
		await _wait(0.1)
	var made: Dictionary = Coop.act("craft", ["crafting", "basic_treat"])
	_check(made.ok, "crafted a Basic Treat from the UI action")
	_check(Coop.act("upgrade_tool", ["hoe"]).ok, "upgraded the hoe")
	if slot >= 0:
		SaveManager.delete_slot(slot)
	print("UI SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
