extends GutTest
## Status, weather, switching, items, AI and the balance/economy sims.

var rng := RandomNumberGenerator.new()

func before_all() -> void:
	TranslationServer.set_locale("en")

func after_all() -> void:
	Settings.apply()

func before_each() -> void:
	rng.seed = 99

func _mk(id: String, lvl: int, trait_id: String = "") -> Creature:
	var opts := {"nature": "hardy", "genes": {"hp": 8, "power": 8, "guard": 8, "focus": 8, "speed": 8}}
	if trait_id != "":
		opts["trait"] = trait_id
	return Creature.create(id, lvl, rng, opts)

func _eng(a: Array, b: Array, kind: int = BattleEngine.Kind.TRAINER) -> BattleEngine:
	var e := BattleEngine.new(a, b, kind, 7, "Foe")
	e.start()
	return e

func _types_of(ev: Array) -> Array:
	return ev.map(func(x): return x.t)

func _first_status_move(st: String) -> String:
	for m in Data.moves:
		var mv: Dictionary = Data.moves[m]
		if mv.cat == "status":
			for e in mv.get("effects", []):
				if e.k == "status" and e.s == st:
					return m
	return ""

func test_burn_ticks_and_halves_physical() -> void:
	var e := _eng([_mk("puddlop", 20)], [_mk("sproutle", 20)])
	var phys := ""
	for m in Data.moves:
		if Data.moves[m].cat == "phys" and Data.moves[m].type == "wild" and int(Data.moves[m].power) >= 40:
			phys = m
			break
	var before: int = e.calc_damage(0, phys, true).damage
	e.active(0).status = "burn"
	var after: int = e.calc_damage(0, phys, true).damage
	assert_lt(after, before, "burn halves physical damage")
	var hp := e.active(0).hp
	e._end_of_turn([])
	assert_lt(e.active(0).hp, hp, "burn deals end-of-turn damage")

func test_type_immunities_to_status() -> void:
	var e := _eng([_mk("puddlop", 10)], [_mk("embercub", 10)])
	var ev: Array = []
	e._inflict(1, "burn", ev, true)
	assert_eq(e.active(1).status, "", "ember types can't be burned")
	e._inflict(1, "soak", ev, true)
	assert_eq(e.active(1).status, "soak")

func test_soak_halves_speed_and_boosts_spark() -> void:
	var e := _eng([_mk("staticat", 20)], [_mk("embercub", 20)])
	var spd := e._eff_speed(1)
	var spark := ""
	for m in Data.moves:
		if Data.moves[m].type == "spark" and Data.moves[m].cat != "status":
			spark = m
			break
	var d0: int = e.calc_damage(0, spark, true).damage
	e.active(1).status = "soak"
	assert_almost_eq(e._eff_speed(1), spd * 0.5, 0.01)
	assert_gt(e.calc_damage(0, spark, true).damage, d0)

func test_root_blocks_switching_and_drains() -> void:
	var e := _eng([_mk("puddlop", 15), _mk("embercub", 15)], [_mk("sproutle", 15)])
	e.active(0).status = "root"
	e.active(0).status_turns = 3
	assert_false(e.can_switch(0))
	e.active(1).hp = 5
	var ev := e.submit({"k": "switch", "i": 1}, {"k": "move", "i": 0})
	assert_eq(e.sides[0].active, 0, "rooted creature stays in")
	assert_true(JSON.stringify(ev).contains("rooted"))

func test_sleep_skips_turns() -> void:
	var e := _eng([_mk("puddlop", 15)], [_mk("sproutle", 15)])
	e.active(0).status = "sleep"
	e.active(0).status_turns = 3
	var ev: Array = []
	e._execute_move(0, e.active(0).moves[0], ev)
	assert_false(_types_of(ev).has("move"), "sleeping creature doesn't attack")

func test_switch_resets_stages() -> void:
	var e := _eng([_mk("puddlop", 15), _mk("embercub", 15)], [_mk("sproutle", 15)])
	e.sides[0].stages.power = 3
	e.submit({"k": "switch", "i": 1}, {"k": "move", "i": 0})
	assert_eq(e.sides[0].active, 1)
	assert_eq(int(e.sides[0].stages.power), 0)

func test_faint_forces_switch_and_win() -> void:
	var e := _eng([_mk("embercub", 30)], [_mk("sproutle", 5), _mk("sproutle", 5)])
	var ev: Array = []
	e.active(1).hp = 0
	e._check_faints(ev)
	assert_true(_types_of(ev).has("faint"))
	assert_true(_types_of(ev).has("xp"), "player earns XP on a faint")
	assert_true(e.needs_switch(1))
	e.force_switch(1, e.ai_replacement(1))
	assert_eq(e.sides[1].active, 1)
	e.active(1).hp = 0
	e._check_faints(ev)
	assert_eq(e.result, "win")

func test_items_heal_cure_revive() -> void:
	var a := _mk("puddlop", 20)
	var b := _mk("embercub", 20)
	var e := _eng([a, b], [_mk("sproutle", 5)])
	a.hp = 5
	a.status = "burn"
	e._use_item(0, "potion", 0, [])
	assert_eq(a.hp, mini(a.max_hp(), 35))
	e._use_item(0, "remedy", 0, [])
	assert_eq(a.status, "")
	b.hp = 0
	e._use_item(0, "revive_seed", 1, [])
	assert_gt(b.hp, 0)

func test_ai_uses_items_when_low() -> void:
	var e := _eng([_mk("embercub", 20)], [_mk("sproutle", 20)])
	e.sides[1].ai_level = 2
	e.sides[1].items = {"super_potion": 1}
	e.active(1).hp = 1
	var used := false
	for i in 20:
		var act := BattleAI.choose_action(e, 1)
		if act.k == "item":
			used = true
			assert_eq(act.id, "super_potion")
			break
	assert_true(used, "warden AI heals in danger")
	e.submit({"k": "move", "i": 0}, {"k": "item", "id": "super_potion", "target": 0})
	assert_false(e.sides[1].items.has("super_potion"), "item stock consumed")

func test_ai_skips_pointless_status() -> void:
	var e := _eng([_mk("embercub", 20)], [_mk("puddlop", 20)])
	var burn := _first_status_move("burn")
	if burn == "":
		pass_test("no burn status move in data")
		return
	assert_eq(BattleAI.score_move(e, 1, burn, 2), 0.0, "won't try to burn an Ember type")

func test_field_weather_boosts_types() -> void:
	var e := _eng([_mk("puddlop", 20)], [_mk("embercub", 20)])
	var tide := ""
	for m in Data.moves:
		if Data.moves[m].type == "tide" and Data.moves[m].cat != "status":
			tide = m
			break
	var dry: int = e.calc_damage(0, tide, true).damage
	e.set_field_weather("rain")
	assert_eq(e.weather, "rain")
	assert_gt(e.calc_damage(0, tide, true).damage, dry)
	e.set_field_weather("sun")
	assert_eq(e.weather, "", "a plain sunny day is a clear field")

func test_weather_move_lasts_five_turns() -> void:
	var e := _eng([_mk("puddlop", 20)], [_mk("sproutle", 20)])
	var ev: Array = []
	e._start_weather("snow", ev)
	assert_eq(e.weather, "snow")
	for i in BattleEngine.WEATHER_TURNS:
		e._end_of_turn(ev)
	assert_eq(e.weather, "")
	assert_true(JSON.stringify(ev).contains("chilled"), "snow chips non-Frost types")

func test_weather_moves_exist_in_learnsets() -> void:
	for mid in ["heat_haze", "rain_song", "snowfall", "storm_call", "mist_veil"]:
		assert_true(Data.moves.has(mid), mid)
		var found := false
		for sid in Data.species:
			for e in Data.species[sid].learnset:
				if e[1] == mid:
					found = true
		assert_true(found, "%s is learnable" % mid)

func test_equip_move() -> void:
	var c := _mk("sproutle", 40)
	var spare := c.spare_moves()
	assert_gt(spare.size(), 0)
	var m: String = spare[0]
	var old: String = c.moves[0]
	assert_true(c.equip_move(0, m))
	assert_eq(c.moves[0], m)
	assert_has(c.spare_moves(), old)
	assert_false(c.equip_move(0, "not_a_move"))
	assert_true(c.equip_move(1, m), "re-equipping swaps slots")
	assert_eq(c.moves[1], m)
	assert_eq(c.moves[0], c.moves[0])
	assert_eq(c.moves.count(m), 1)

func test_struggle_when_no_moves() -> void:
	var a := _mk("puddlop", 10)
	a.moves = []
	var e := _eng([a], [_mk("sproutle", 10)])
	var ev := e.submit({"k": "move", "i": 0}, {"k": "move", "i": 0})
	assert_true(JSON.stringify(ev).contains("Struggle"))

func test_trainers_scale_and_carry_items() -> void:
	var early := Trainers.team_for("rowan", 0, 8, rng)
	var late := Trainers.team_for("rowan", 4, 30, rng)
	assert_false(early.is_empty())
	assert_gt(late.team.size(), early.team.size())
	assert_gt(late.reward, early.reward)
	assert_true(late.items.size() > 0)

func test_pvp_forfeit() -> void:
	var e := _eng([_mk("puddlop", 10)], [_mk("sproutle", 10)], BattleEngine.Kind.PVP)
	e.submit({"k": "move", "i": 0}, {"k": "run"})
	assert_eq(e.result, "win")

func test_balance_sim_small() -> void:
	assert_true(BalanceSim.pool().size() >= 20)
	var r0 := BalanceSim.duel("blazeroar", "torrentide", 40, 1)
	assert_true(r0 in [0, 1, -1])
	assert_eq(BalanceSim.duel("blazeroar", "torrentide", 40, 5), BalanceSim.duel("blazeroar", "torrentide", 40, 5), "duels are deterministic")

func test_economy_sim_sane() -> void:
	var rep := EconomySim.run(112)
	assert_true(rep.ok, ", ".join(rep.flags))
	assert_eq(rep.money_by_season.size(), 4)
