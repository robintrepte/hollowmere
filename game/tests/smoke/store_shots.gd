extends "res://tests/smoke/adventure_smoke.gd"
## Stages the Steam / itch.io screenshots at 1920x1080 (the 640x360 game at 3x).
##   godot --path game res://tests/smoke/store_shots.tscn -- --out=/abs/store/screenshots

const SUMMER := Calendar.DAYS_PER_SEASON + 9

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	get_window().size = Vector2i(1920, 1080)
	get_window().move_to_center()
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.3)
	var slot := SaveManager.first_free_slot()
	main._start_new({"player_name": "Robin", "farm_name": "Willowbrook", "starter": "embercub", "seed": 2026,
		"look": {"skin": "#f0c8a0", "hair": "#8a4a2a", "shirt": "#d05a4a", "pants": "#3a4a7a", "style": 1}})
	await _wait(1.0)
	await main.ui.dialogue.dismiss()
	main.ui.close_all()
	var pd := GameState.local_player()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	pd.party.clear()
	for sid in ["embercub", "brooklet", "bloomwing", "digsby"]:
		if Data.species.has(sid):
			var c := Creature.create(sid, 24, rng, {"min_gene": 20})
			c.owner = pd.id
			pd.party.append(c)
	EventBus.party_changed.emit()
	GameState.world.day = SUMMER
	GameState.world.weather = "sun"
	GameState.world.money = 18450
	_stage_farm(rng)
	GameState._map_cache.clear()

	# 1. The farm in summer with Wildlings around the den
	_set_time(10 * 60)
	await _go("farm", Vector2i(14, 9))
	pd.selected = 1
	EventBus.hotbar_changed.emit()
	await _wait(1.2)
	await _shot("01_farm_summer")

	# 2. Dusk over the fields
	_set_time(19 * 60)
	main.player.position = GameState.tile_center(Vector2i(19, 12))
	main.camera.reset_smoothing()
	await _wait(1.0)
	await _shot("02_farm_dusk")
	_set_time(10 * 60)

	# 3. Backpack with an open container (Tarkov-style grid)
	_fill_pack(pd)
	var inv := InventoryPanel.new(pd)
	main.ui.open(inv)
	await _wait(0.4)
	for e in pd.inventory.entries:
		if e.id == "gem_case":
			await inv._open_container(e)
		elif e.id == "keg":
			inv._on_hover(inv._pack_view, e)
	await _wait(0.3)
	await _shot("03_backpack_containers")
	main.ui.close_all()

	# 4. Wildlings at work: the farm tab of the party screen
	for i in GameState.ranch.size():
		GameState.ranch[i].job = FarmJobs.JOBS[i % FarmJobs.JOBS.size()]
	var pp := PartyPanel.new(pd, "farm")
	main.ui.open(pp)
	await _wait(0.3)
	if not GameState.ranch.is_empty():
		pp._sel = GameState.ranch[0]
		pp._refresh()
	await _wait(0.3)
	await _shot("04_wildlings_at_work")
	main.ui.close_all()

	# 5. A wild battle in the Whisperwood
	_set_time(11 * 60)
	await _go("whisperwood", Vector2i(20, 18))
	await _wait(0.5)
	main.controller.adventure._battle({"kind": "wild", "species": "glimmer" if Data.species.has("glimmer") else "sproutle", "level": 22, "ai": 1, "friendly": true})
	await _until_menu()
	main.battle._show_moves()
	await _wait(0.4)
	await _shot("05_battle_moves")
	main.battle._show_main_menu()
	main.battle.engine.active(1).hp = 1
	while main.battle != null:
		await _wait(0.1)
		if main.battle and is_instance_valid(main.battle._overlay):
			var pick := _first_option(main.battle._overlay)
			if pick:
				pick.pressed.emit()
			else:
				main.battle._advance.emit()
		elif main.battle and main.battle._cmd.visible:
			main.battle._picked.emit({"k": "move", "i": 0})
	await main.ui.dialogue.dismiss()

	# 6. The village on a sunny morning
	_set_time(10 * 60 + 30)
	await _go("town", Vector2i(15, 10))
	await _wait(1.5)
	await _shot("06_village")

	# 7. The mine
	await _go("whisperwood", Vector2i(37, 18))
	var cave := _object("cave")
	if not cave.is_empty():
		await _flow(func(): await main.controller.adventure.cave(cave), [0])
		await _wait(0.8)
		await _shot("07_mine")

	# 8. Journal: the Wildling dex
	for i in 54:
		Progression.mark(GameState.world.dex, Data.species_order[i], i % 3 != 2, i == 7)
	main.ui.open(JournalPanel.new(pd, "dex"))
	await _wait(0.5)
	await _shot("08_dex")
	main.ui.close_all()

	if slot >= 0:
		SaveManager.delete_slot(slot)
	print("STORE SHOTS DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _set_time(m: int) -> void:
	GameState.world.minute = m
	EventBus.time_changed.emit(m)

func _until_menu() -> void:
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) < 20000:
		await get_tree().process_frame
		if main.battle != null and main.battle._cmd.visible and main.battle._cmd.get_child_count() > 0:
			return

## A tidy summer field below the farmhouse and den: mature crops in rows, sprinklers, a scarecrow.
func _stage_farm(rng: RandomNumberGenerator) -> void:
	var g: FarmGrid = GameState.grid("farm")
	var crops: Array = Data.crop_order.filter(func(c): return "summer" in Data.crops[c].seasons)
	var row := 0
	for y in range(10, 16):
		if y == 12:
			continue
		var cid: String = crops[row % crops.size()]
		row += 1
		for x in range(4, 26):
			var p := Vector2i(x, y)
			if not g.can_till(p):
				continue
			g.till(p)
			if x % 7 == 3 and y in [11, 14]:
				g.place_object(p, "quality_sprinkler" if Data.items.has("quality_sprinkler") else "sprinkler")
				continue
			if g.plant(p, cid + "_seeds", "summer"):
				var days := float(Data.crops[cid].days)
				g.soil[Tiles.key(p)].crop.age = days if rng.randf() < 0.8 else days - 1.0
				g.water(p)
	if g.can_till(Vector2i(15, 12)):
		g.place_object(Vector2i(15, 12), "scarecrow")
	for sid in ["sproutle", "cloudmoo", "clovehare", "bubbloo", "cluckle", "fluffeather", "acornib", "brooklet"]:
		if Data.species.has(sid):
			var c := Creature.create(sid, 12, rng)
			c.owner = GameState.local_player().id
			GameState.ranch.append(c)

func _fill_pack(pd: PlayerData) -> void:
	pd.inventory.resize(10, 5)
	for spec in [["gem_case", 1], ["seed_pouch", 1], ["forage_basket", 1], ["treat_tin", 1], ["keg", 1], ["preserves_jar", 1],
			["quality_sprinkler", 4], ["scarecrow", 1], ["straw_hat", 1], ["bouquet", 1], ["copper_bar", 10], ["stone", 60],
			["honey_cake", 3], ["veggie_stew", 2], ["super_potion", 4], ["ultra_charm", 3], ["remedy", 2]]:
		if Data.items.has(spec[0]):
			pd.inventory.add(spec[0], spec[1])
	for e in pd.inventory.entries:
		if e.id == "gem_case" and e.has("inv"):
			for gem in ["ruby", "emerald", "amethyst", "topaz", "diamond", "aquamarine", "star_shard"]:
				e.inv.add(gem, 1 + gem.length() % 3)
		elif e.id == "seed_pouch" and e.has("inv"):
			for cid in Data.crop_order.slice(0, 6):
				e.inv.add(cid + "_seeds", 12)
	for spec in [["melon", 3, 2], ["blueberry", 12, 1], ["sunflower", 4, 0], ["honey_cake", 2, 0], ["potion", 5, 0],
			["great_charm", 6, 0], ["iron_bar", 8, 0], ["hardwood", 20, 0], ["wool", 3, 3], ["truffle", 2, 2],
			["pumpkin_soup", 1, 0], ["sweet_treat", 9, 0], ["gold_ore", 14, 0]]:
		if Data.items.has(spec[0]) or Data.crops.has(spec[0]):
			pd.inventory.add(spec[0], spec[1], spec[2])

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img.get_size() != Vector2i(1920, 1080):
		print("  note: %s rendered at %s" % [name, img.get_size()])
	img.save_png(out_dir.path_join(name + ".png"))
	print("shot ", name, " ", img.get_size())
