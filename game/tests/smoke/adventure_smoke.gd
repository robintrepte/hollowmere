extends Node
## Adventure smoke test: Barley's story, Warden Ivy, waking the Whisperwood shrine, the mine
## (ladders, treasure, the bottom floor), the Story journal, the Egg Hunt and wayshrine travel.
##   godot --path game res://tests/smoke/adventure_smoke.tscn -- --out=/abs/dir

var out_dir := "user://shots"
var main: Node
var failures := 0
var _flow_done := true

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.3)
	var slot := SaveManager.first_free_slot()
	main._start_new({"player_name": "Robin", "farm_name": "Smoke", "starter": "sproutle", "seed": 4242})
	await _wait(1.0)
	main.ui.dialogue.visible = false
	main.ui.close_all()
	main.player.locked = false
	var pd := GameState.local_player()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for sid in ["thornwarden", "glacierox"]:
		var c := Creature.create(sid, 55, rng, {"min_gene": 12})
		c.owner = pd.id
		pd.party.insert(0, c)
	EventBus.party_changed.emit()
	var adv: AdventureFlow = main.controller.adventure

	# 1. Elder Barley starts the story
	await _flow(func(): await adv.story_talk("barley"), [], "Hazel's grandchild", "a01_barley")
	_check(GameState.world.flags.get("story_seen:roots", false), "Barley handed out chapter one")

	# 2. Whisperwood: the dark shrine and Warden Ivy
	await _go("whisperwood", Vector2i(37, 18))
	_check(main.world.npcs.has("ivy"), "Ivy keeps watch at the shrine")
	await _shot("a02_shrine_dark")
	await _flow(func(): await adv.warden_battle("ivy"), [0], "real thing", "a03_warden_won")
	_check(Adventure.shrine_state(GameState.world, "whisperwood") == "ready", "beating Ivy readies the shrine")

	# 3. Wake the shrine: battle its guardian
	var shrine := _object("shrine")
	await _flow(func(): await adv.shrine(shrine), [0], "Shrine glows", "a04_shrine_woken")
	_check("whisperwood" in GameState.world.shrines, "the shrine is awake")
	_check(GameState.region_unlocked("tidecove"), "Tidecove opened")
	await _wait(0.4)
	await _shot("a05_shrine_restored")
	var guardian := false
	for w in main.world.creatures:
		if is_instance_valid(w) and w.boss:
			guardian = true
	_check(guardian, "the guardian lingers near its shrine")

	# 4. The mine: enter, descend, treasure, the bottom floor, climb out
	var cave := _object("cave")
	_check(not cave.is_empty(), "Whisperwood has a cave")
	await _flow(func(): await adv.cave(cave), [0])
	await _wait(0.6)
	_check(main.world.map_id == "mine:whisperwood:1", "entered B1 (%s)" % main.world.map_id)
	await _shot("a06_mine_b1")
	var opened := false
	for i in 8:
		var chest := _object("treasure")
		if not chest.is_empty() and not chest.get("mimic", false):
			main.player.position = GameState.tile_center(Vector2i(int(chest.x) - 1, int(chest.y)))
			main.camera.reset_smoothing()
			var money := GameState.money()
			await _flow(func(): await adv.treasure(Vector2i(int(chest.x), int(chest.y)), chest), [], "You found", "a07_treasure")
			_check(GameState.money() > money, "treasure paid out")
			opened = true
			break
		await _flow(func(): await adv.ladder_down(), [])
		await _wait(0.5)
	_check(opened, "found a treasure chest within a few floors")
	GameState.world.mine_depth["whisperwood"] = 9
	await _flow(func(): await adv.enter_floor("whisperwood", 10), [])
	await _wait(0.6)
	_check(main.world.info.get("bottom", false), "B10 is the bottom")
	var grand := _object("treasure")
	_check(grand.get("grand", false), "a grand chest waits at the bottom")
	if not grand.is_empty():
		main.player.position = GameState.tile_center(Vector2i(int(grand.x) - 1, int(grand.y)))
		main.camera.reset_smoothing()
	await _wait(0.3)
	await _shot("a08_mine_bottom")
	await _flow(func(): await adv.ladder_up(), [0])
	await _wait(0.6)
	_check(main.world.map_id == "whisperwood", "climbed back out")

	# 5. Story journal + HUD tracker
	main.ui.open(JournalPanel.new(pd, "story"))
	await _wait(0.3)
	await _shot("a09_journal_story")
	main.ui.close_all()

	# 6. Egg Hunt in the village
	var f: Dictionary = Data.progression.festivals.egg_hunt
	GameState.world.day = Calendar.SEASONS.find(f.season) * Calendar.DAYS_PER_SEASON + int(f.day) - 1
	GameState._map_cache.clear()
	await _go("town", Vector2i(21, 18))
	main.hud._refresh_all()
	await _wait(0.3)
	await _shot("a10_egg_hunt")
	var picked := 0
	var g := GameState.grid("town")
	for k in g.objects.keys():
		if g.objects[k].id == "festival_egg" and picked < 9:
			if GameState.harvest_at(pd.id, "town", Tiles.parse_key(k)).ok:
				picked += 1
	_check(pd.inventory.count("festival_egg") == 9, "collected 9 eggs (%d)" % pd.inventory.count("festival_egg"))
	await _flow(func(): await adv.show_ring(), [0], "handed in", "a11_egg_prize")
	_check(pd.inventory.has("wildling_egg"), "egg hunt grand prize")

	# 7. Wayshrine travel to Tidecove
	await _flow(func(): await adv.wayshrine(), [2], "wayshrine hums", "a12_wayshrine")
	await _wait(0.6)
	_check(main.world.map_id == "tidecove", "wayshrine took us to Tidecove (%s)" % main.world.map_id)
	for rid in Data.region_order + ["town"]:
		var at := AdventureFlow.wayshrine_arrival(rid)
		var rg: FarmGrid = GameState.map_info(rid).grid
		_check(at.y < rg.h - 1 and not rg.is_blocked(at), "%s wayshrine arrival %s is walkable" % [rid, at])
	await _shot("a13_tidecove")

	if slot >= 0:
		SaveManager.delete_slot(slot)
	print("ADVENTURE SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _object(type: String) -> Dictionary:
	for o in main.world.info.get("objects", []):
		if o.type == type:
			return o
	return {}

func _go(map_id: String, t: Vector2i) -> void:
	EventBus.map_change_requested.emit(map_id, t)
	await _wait(0.8)
	main.player.locked = false
	main.camera.reset_smoothing()

## Runs a flow while answering its dialogue and fighting its battles. Takes one screenshot
## when a line containing `shot_on` appears.
func _flow(fn: Callable, answers: Array, shot_on: String = "", shot_name: String = "") -> void:
	_flow_done = false
	_run(fn)
	Engine.time_scale = 4.0
	var t0 := Time.get_ticks_msec()
	while not _flow_done and (Time.get_ticks_msec() - t0) / 1000.0 < 90.0:
		await get_tree().process_frame
		var b: BattleScreen = main.battle
		if b:
			if b._cmd.visible and b._cmd.get_child_count() > 0:
				await get_tree().create_timer(0.05).timeout
				if main.battle == b and b._cmd.visible:
					b._picked.emit({"k": "move", "i": 0})
			elif is_instance_valid(b._overlay):
				b._advance.emit()
			continue
		var d: DialogueBox = main.ui.dialogue
		if not d.visible:
			continue
		if d._typing:
			d._advance()
			continue
		if shot_on != "" and d._text.text.contains(shot_on):
			Engine.time_scale = 1.0
			await _shot(shot_name)
			Engine.time_scale = 4.0
			shot_on = ""
		if not d._choice_buttons.is_empty():
			d.chosen.emit(int(answers.pop_front()) if not answers.is_empty() else 0)
		else:
			d._advance()
		await get_tree().create_timer(0.05).timeout
	Engine.time_scale = 1.0
	if shot_on != "":
		_check(false, "never saw a line containing '%s'" % shot_on)
	_check(_flow_done, "flow finished")
	main.player.locked = false

func _run(fn: Callable) -> void:
	await fn.call()
	_flow_done = true

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	print("shot ", name)
