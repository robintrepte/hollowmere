extends Node
## Creature-loop smoke test: wild encounter, battle, befriend, Tide watering job, rival battle.
##   godot --path game res://tests/smoke/creatures_smoke.tscn -- --out=/abs/dir

var out_dir := "user://shots"
var main: Node
var failures := 0
var _report: Dictionary = {}

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	if not main.has_method("_start_new"):
		get_tree().quit(1)
		return
	await _wait(0.3)
	var slot := SaveManager.first_free_slot()
	main._start_new({"player_name": "Robin", "farm_name": "Smoke", "starter": "puddlop", "seed": 777})
	await _wait(1.0)
	await main.ui.dialogue.dismiss()
	main.ui.close_all()
	var pd := GameState.local_player()
	pd.inventory.add("lure_charm", 5)
	# 1. Wild Wildlings in the meadow
	EventBus.map_change_requested.emit("meadow", Vector2i(3, 17))
	await _wait(1.0)
	main.player.locked = false
	var wild: WildCreature = null
	for w in main.world.creatures:
		if not w.pet:
			wild = w
			break
	_check(wild != null, "wild Wildlings spawn in the meadow (%d)" % main.world.creatures.size())
	if wild:
		main.player.position = wild.position + Vector2(-60, 0)
	await _wait(0.4)
	await _shot("c01_meadow")
	# 2. Battle it, weaken it, befriend it
	Engine.time_scale = 4.0
	if wild:
		EventBus.battle_requested.emit({"kind": "wild", "species": wild.species, "level": 3, "starry": false, "node": wild})
	await _until(func(): return main.battle != null and main.battle._cmd.visible and main.battle._cmd.get_child_count() > 0, 30.0)
	await _shot("c02_battle_menu")
	main.battle._show_moves()
	await _wait(0.2)
	await _shot("c03_battle_moves")
	main.battle._show_main_menu()
	if main.battle:
		main.battle.engine.active(1).hp = 1
		main.battle.setup["_last_item"] = "lure_charm"
		pd.inventory.remove("lure_charm", 1)
		main.battle._picked.emit({"k": "befriend", "id": "lure_charm"})
	await _drive(func(_b): return {"k": "befriend", "id": "lure_charm"}, 60.0)
	Engine.time_scale = 1.0
	await _until(func(): return main.ui.dialogue.visible, 5.0)
	await _shot("c04_befriended")
	main.ui.dialogue._advance()
	await main.ui.dialogue.dismiss()
	main.ui.close_all()
	_check(pd.party.size() + GameState.ranch.size() >= 2, "befriended a Wildling (party %d, den %d)" % [pd.party.size(), GameState.ranch.size()])
	# 3. Tide watering job: send the starter Puddlop (Tide) to the Den and give it the water job
	main.player.locked = false
	var pud: Creature = pd.party[0]
	_check(GameState.move_creature(pud.uid, "den", pd), "moved Puddlop to the Den")
	_check(GameState.set_job(pud.uid, "water"), "assigned Tide watering job")
	var g: FarmGrid = GameState.grid("farm")
	var t := Vector2i(10, 14)
	for i in 20:
		if g.can_till(t):
			break
		t.x += 1
	g.till(t)
	g.plant(t, "parsnip_seeds", GameState.season())
	EventBus.day_started.connect(func(_d, r): _report = r, CONNECT_ONE_SHOT)
	EventBus.map_change_requested.emit("farm", Vector2i(7, 7))
	await _wait(0.8)
	main.ui.open(PartyPanel.new(pd, "farm"))
	await _wait(0.3)
	await _shot("c05_party_farm_tab")
	main.ui.close_all()
	main.ui.open(PartyPanel.new(pd))
	await _wait(0.3)
	await _shot("c06_party_tab")
	main.ui.close_all()
	await _wait(0.3)
	await _shot("c07_farm_ranch")
	# Breeding + hatchery UI
	var mate := Creature.create("puddlop", 8, GameState.rng)
	GameState.ranch.append(mate)
	var bp := PartyPanel.new(pd, "farm")
	main.ui.open(bp)
	await _wait(0.2)
	bp._sel = pud
	bp._picking_mate = true
	bp._refresh()
	await _wait(0.2)
	await _shot("c071_breeding")
	main.ui.close_all()
	GameState.world.buildings.append("hatchery")
	var egg := Breeding.make_egg(pud, mate, GameState.rng)
	GameState.farm_chest.add("wildling_egg", 1, 0, {"egg": egg})
	GameState.world.hatchery.append({"egg": Breeding.wild_egg("embercub", GameState.rng), "days": 2})
	main.ui.open(HatcheryPanel.new(pd))
	await _wait(0.3)
	await _shot("c072_hatchery")
	main.ui.close_all()
	GameState.ranch.erase(mate)
	await _wait(0.2)
	main.sleep()
	await _wait(2.6)
	_check(int(_report.get("jobs", {}).get("watered", 0)) >= 1, "Tide watered %d tile(s) overnight" % int(_report.get("jobs", {}).get("watered", 0)))
	_check(float(g.crop_at(t).get("age", 0)) >= 1.0, "watered crop grew overnight")
	await _shot("c08_job_report")
	main.ui.close_all()
	await _wait(0.4)
	# 4. Rival battle
	Engine.time_scale = 4.0
	var lead := pd.lead()
	var info := Trainers.team_for("rowan", 0, lead.level, GameState.rng)
	_check(info.team.size() == 1, "rival team scales to progress")
	for c in pd.party:
		c.level = 12
		c.heal_full()
		for e in c.species().learnset:
			if not c.learned.has(e[1]):
				c.learned.append(e[1])
	var pp := PartyPanel.new(pd)
	main.ui.open(pp)
	await _wait(0.2)
	pp._swap_slot = 0
	pp._show_detail()
	await _wait(0.2)
	await _shot("c085_move_swap")
	main.ui.close_all()
	await _wait(0.2)
	GameState.world.weather = "rain"
	EventBus.battle_requested.emit({"kind": info.kind, "vid": "rowan", "team": info.team, "foe_name": "Rowan", "reward": info.reward})
	await _until(func(): return main.battle != null and main.battle._cmd.visible and main.battle._cmd.get_child_count() > 0, 30.0)
	await _shot("c09_trainer_battle")
	var money := GameState.money()
	await _drive(func(_b): return {"k": "move", "i": 0}, 90.0)
	Engine.time_scale = 1.0
	_check(GameState.money() > money, "won rival battle reward (%d -> %d)" % [money, GameState.money()])
	if slot >= 0:
		SaveManager.delete_slot(slot)
	print("CREATURE SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _drive(policy: Callable, max_t: float) -> void:
	var t0 := Time.get_ticks_msec()
	while main.battle != null and (Time.get_ticks_msec() - t0) / 1000.0 < max_t:
		await get_tree().process_frame
		var b: BattleScreen = main.battle
		if b and b._cmd.visible and b._cmd.get_child_count() > 0:
			await get_tree().create_timer(0.05).timeout
			if main.battle == b and b._cmd.visible:
				var a: Dictionary = policy.call(b)
				if a.get("k") == "befriend":
					b.setup["_last_item"] = a.id
				b._picked.emit(a)
		elif b and is_instance_valid(b._overlay):
			b._advance.emit()

func _until(cond: Callable, max_t: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call() and (Time.get_ticks_msec() - t0) / 1000.0 < max_t:
		await get_tree().process_frame

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
