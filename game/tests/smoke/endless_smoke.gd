extends "res://tests/smoke/adventure_smoke.gd"
## Endless + polish smoke test: the weekly Creature Show, the journal's weekly tab (bounty,
## show ladder, chain, rematches), a post-game Warden rematch, juice particles, large text,
## colorblind quality pips and gamepad grid navigation.
##   godot --path game res://tests/smoke/endless_smoke.tscn -- --out=/abs/dir

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.3)
	var slot := SaveManager.first_free_slot()
	main._start_new({"player_name": "Robin", "farm_name": "Smoke", "starter": "sproutle", "seed": 777})
	await _wait(1.0)
	await main.ui.dialogue.dismiss()
	main.ui.close_all()
	main.player.locked = false
	var pd := GameState.local_player()
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var star := Creature.create("thornwarden", 100, rng, {"min_gene": 28})
	star.owner = pd.id
	star.grooming = 100
	star.happiness = 255
	pd.party.insert(0, star)
	for sid in ["glacierox", "iciclaw"]:
		if Data.species.has(sid):
			var c := Creature.create(sid, 100, rng, {"min_gene": 28})
			c.owner = pd.id
			pd.party.insert(1, c)
	EventBus.party_changed.emit()
	var adv: AdventureFlow = main.controller.adventure

	# 1. Weekly Creature Show on a Saturday
	var d := 0
	while not Endless.show_open(d):
		d += 1
	GameState.world.day = d
	GameState._map_cache.clear()
	await _go("town", Vector2i(21, 18))
	main.hud._refresh_all()
	await _wait(0.3)
	_check(main.hud._quest.text.contains("Creature Show"), "HUD mentions today's show")
	var money := GameState.money()
	await _flow(func(): await adv.show_ring(), [0], "wins the Novice class", "e01_show_win")
	_check(star.ribbons == 1 and star.show_rank == 1, "won Novice: ribbon + Bronze (%d, %d)" % [star.ribbons, star.show_rank])
	_check(GameState.money() > money, "show prize paid")
	await _flow(func(): await adv.show_ring(), [], "packing up", "")
	_check(star.ribbons == 1, "one show per Saturday")

	main.player.locked = false

	# 2. Journal weekly tab: bounty, show ladder, Starry chain
	for i in 6:
		await Coop.act_async("chain_act", ["sproutle"])
	_check(int(GameState.chain_of(pd.id).get("n", 0)) == 6, "chain of 6")
	var journal := JournalPanel.new(pd, "weekly")
	main.ui.open(journal)
	await _wait(0.3)
	await _shot("e02_journal_weekly")
	journal._scroll.scroll_vertical = 100000
	await _wait(0.2)
	await _shot("e02b_journal_weekly_ladder")
	main.ui.close_all()

	# 3. Post-game: Warden rematch once all shrines are awake
	for rid in Data.region_order:
		if not rid in GameState.world.shrines:
			GameState.world.shrines.append(rid)
	_check(Endless.rematch_open(GameState.world), "rematches open after 8 shrines")
	await _go("whisperwood", Vector2i(37, 18))
	await _flow(func(): await adv.warden_battle("ivy"), [0], "Rematch?", "e03_rematch_offer", 240.0)
	_check(int(pd.stats.get("battled:ivy", -1)) == GameState.day(), "fought the rematch")
	var won := int(GameState.world.get("stats", {}).get("rematch", 0)) == 1
	print("rematch result: ", "win" if won else "loss")
	await _flow(func(): await adv.warden_battle("ivy"), [], "", "")
	_check(int(GameState.world.get("stats", {}).get("rematch", 0)) == (1 if won else 0), "one rematch per day")

	# 4. Juice: particles on actions
	var at := Vector2i(main.player.position / 32.0)
	for i in 3:
		main.controller._feedback({"ok": true, "sfx": ["harvest", "rock", "levelup"][i]}, at + Vector2i(i - 1, 1))
	await _wait(0.12)
	var bursts := 0
	for n in main.world.get_children():
		if n is CPUParticles2D:
			bursts += 1
	_check(bursts >= 3, "particle bursts spawned (%d)" % bursts)
	await _shot("e04_juice")

	# 5. Accessibility: larger text, colorblind pips, gamepad grid cursor
	pd.inventory.add("parsnip", 5, 2)
	pd.inventory.add("parsnip", 3, 3)
	Settings.colorblind = true
	Settings.set_text_scale(1.4)
	await _wait(0.3)
	_check(UITheme.theme().default_font_size == 14, "theme rebuilt at 140%")
	Settings.using_pad = true
	Settings.input_device_changed.emit(true)
	var inv := InventoryPanel.new(pd)
	main.ui.open(inv)
	await _wait(0.3)
	_check(inv._pack_view.has_focus(), "the pack grid takes gamepad focus")
	var right := InputEventAction.new()
	right.action = "ui_right"
	right.pressed = true
	inv._pack_view._pad_input(right)
	await _wait(0.1)
	_check(inv._pack_view.hover_cell == Vector2i(1, 0), "d-pad moves the grid cursor")
	await _shot("e05_large_text_pad_colorblind")
	main.ui.close_all()
	main.ui.open(SettingsPanel.new())
	await _wait(0.3)
	await _shot("e06_settings_large")
	main.ui.close_all()
	Settings.set_text_scale(1.0)
	Settings.colorblind = false
	Settings.using_pad = false

	if slot >= 0:
		SaveManager.delete_slot(slot)
	print("ENDLESS SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)
