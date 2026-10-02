extends Node
## Hosts a LAN farm in the real game, lets a headless bot (tests/net/coop_bot) join, then
## screenshots the co-op panel, a trade, and a friendly battle.
##   godot --path game res://tests/smoke/coop_smoke.tscn -- --out=/abs/dir

var out_dir := "user://shots"
var main: Node
var failures := 0
var _bot := -1

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.5)
	main.ui.open(CoopPanel.new(main.ui, false))
	await _wait(0.4)
	await _shot("p01_coop_join")
	main.ui.close_all()
	main._start_new({"player_name": "Robin", "farm_name": "Duo", "starter": "sproutle", "seed": 77})
	await _wait(1.0)
	main.ui.dialogue.visible = false
	main.ui.close_all()
	GameState.local_player().inventory.add("parsnip", 5)
	var extra := Creature.create("embercub", 9, GameState.rng)
	GameState.add_creature(GameState.local_player(), extra)
	var panel := CoopPanel.new(main.ui, true)
	main.ui.open(panel)
	await _wait(0.3)
	await _shot("p02_coop_host")
	var port := 27000 + randi() % 1000
	_check(Net.host_lan(port), "hosting on LAN")
	_bot = OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "res://tests/net/coop_bot.tscn", "--", "--port=%d" % port])
	await _until(func(): return Coop.online_players().size() == 1, 20.0)
	_check(Coop.online_players().size() == 1, "bot joined")
	await _wait(0.6)
	panel._rebuild()
	await _wait(0.3)
	await _shot("p03_coop_session")
	main.ui.close_all()

	Coop.trade_op("open", {"to": "bot"})
	await _until(func(): return main.ui.top() is TradePanel, 5.0)
	var tp: TradePanel = main.ui.top() as TradePanel
	_check(tp != null, "trade panel opened")
	if tp:
		await _until(func(): return not tp.state.get("views", {}).get("bot", []).is_empty(), 5.0)
		tp._add_item(GameState.local_player().inventory.first_of("parsnip").uid, 2)
		await _wait(0.6)
		await _shot("p04_trade")
		var bot_items: Array = tp.state.views.get("bot", [])
		Coop.trade_op("ready", {"tid": tp.tid})
		await _wait(0.3)
		await _shot("p05_trade_ready")
		Coop.trade_op("cancel", {"tid": tp.tid})
		_check(not bot_items.is_empty(), "bot's offer shows in our trade window")
	await _wait(0.4)
	main.ui.close_all()

	Coop.challenge("bot")
	await _until(func(): return main.battle != null and main.battle._cmd.visible and main.battle._cmd.get_child_count() > 0, 20.0)
	_check(main.battle != null, "friendly battle started")
	await _shot("p06_pvp_menu")
	var b: BattleScreen = main.battle
	var t0 := Time.get_ticks_msec()
	var shot_mid := false
	while main.battle != null and is_instance_valid(b) and Time.get_ticks_msec() - t0 < 90000:
		await get_tree().process_frame
		if not is_instance_valid(b):
			break
		if b._cmd.visible and b._cmd.get_child_count() > 0:
			if not shot_mid and b.engine.turn >= 2:
				shot_mid = true
				await _shot("p07_pvp_midfight")
			b._picked.emit({"k": "move", "i": 0})
		elif is_instance_valid(b._overlay):
			for btn in b._overlay.find_children("*", "Button", true, false):
				if not (btn as Button).disabled:
					(btn as Button).pressed.emit()
					break
		elif not b._typing:
			b._advance.emit()
	_check(main.battle == null, "friendly battle finished")
	_check(GameState.local_player().party.all(func(c: Creature): return c.xp >= 0), "party intact after the friendly battle")
	Net.leave()
	await _wait(0.5)
	if OS.is_process_running(_bot):
		OS.kill(_bot)
	print("COOP SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _until(cond: Callable, max_t: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call() and (Time.get_ticks_msec() - t0) / 1000.0 < max_t:
		await get_tree().process_frame

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
