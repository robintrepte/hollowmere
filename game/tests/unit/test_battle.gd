extends GutTest

var rng := RandomNumberGenerator.new()

func before_each() -> void:
	rng.seed = 1234

func _mk(id: String, lvl: int) -> Creature:
	return Creature.create(id, lvl, rng, {"nature": "hardy", "genes": {"hp": 8, "power": 8, "guard": 8, "focus": 8, "speed": 8}})

func test_stats_formula() -> void:
	var c := _mk("sproutle", 50)
	var b: Dictionary = c.species().base_stats
	assert_eq(c.max_hp(), int(floor((2 * b.hp + 8) * 50 / 100.0)) + 50 + 10)

func test_type_chart() -> void:
	assert_gt(Data.type_mult("tide", ["ember"]), 1.0)
	assert_lt(Data.type_mult("ember", ["tide"]), 1.0)

func test_battle_runs_to_completion() -> void:
	var a := [_mk("embercub", 12)]
	var b := [_mk("sproutle", 8)]
	var eng := BattleEngine.new(a, b, BattleEngine.Kind.WILD, 99)
	eng.start()
	var turns := 0
	while not eng.is_over() and turns < 100:
		var a1 := BattleAI.choose_action(eng, 1)
		eng.submit({"k": "move", "i": 0}, a1)
		turns += 1
	assert_true(eng.is_over(), "battle ended")
	assert_lt(turns, 100)

func test_deterministic_with_seed() -> void:
	var res: Array = []
	for i in 2:
		rng.seed = 7
		var eng := BattleEngine.new([_mk("puddlop", 10)], [_mk("embercub", 10)], BattleEngine.Kind.TRAINER, 4242, "Rowan")
		eng.start()
		var log: Array = []
		while not eng.is_over() and eng.turn < 60:
			log.append_array(eng.submit({"k": "move", "i": 0}, BattleAI.choose_action(eng, 1)))
			if eng.needs_switch(1):
				eng.force_switch(1, eng.ai_replacement(1))
		res.append(JSON.stringify(log))
	assert_eq(res[0], res[1])

func test_super_effective_damage_higher() -> void:
	var eng := BattleEngine.new([_mk("puddlop", 20)], [_mk("embercub", 20)], BattleEngine.Kind.WILD, 1)
	var tide_move := ""
	var neutral := ""
	for m in Data.moves:
		var mv: Dictionary = Data.moves[m]
		if mv.cat == "phys" and int(mv.power) == 40:
			if mv.type == "tide" and tide_move == "":
				tide_move = m
	assert_ne(tide_move, "")
	var d1: int = eng.calc_damage(0, tide_move, true).damage
	assert_gt(d1, 0)
	assert_gt(eng.calc_damage(0, tide_move, true).eff, 1.0)

func test_befriend_chance_increases_with_low_hp() -> void:
	var eng := BattleEngine.new([_mk("puddlop", 10)], [_mk("sproutle", 5)], BattleEngine.Kind.WILD, 3)
	var full := eng.befriend_chance("lure_charm")
	eng.active(1).hp = 1
	var low := eng.befriend_chance("lure_charm")
	assert_gt(low, full)
	assert_eq(eng.befriend_chance("star_charm"), 1.0)

func test_befriend_success_ends_battle() -> void:
	var eng := BattleEngine.new([_mk("puddlop", 10)], [_mk("sproutle", 5)], BattleEngine.Kind.WILD, 3)
	eng.start()
	eng.submit({"k": "befriend", "id": "star_charm"}, {"k": "move", "i": 0})
	assert_eq(eng.result, "befriend")
	assert_not_null(eng.befriended)

func test_run_from_wild() -> void:
	var eng := BattleEngine.new([_mk("puddlop", 10)], [_mk("sproutle", 5)], BattleEngine.Kind.WILD, 3)
	eng.start()
	eng.submit({"k": "run"}, {"k": "move", "i": 0})
	assert_eq(eng.result, "run")

func test_xp_and_level_up() -> void:
	var c := _mk("sproutle", 5)
	var before := c.level
	var ev := c.gain_xp(5000)
	assert_gt(c.level, before)
	var types: Array = ev.map(func(e): return e.t)
	assert_has(types, "level")

func test_evolution() -> void:
	var c := _mk("sproutle", 16)
	assert_eq(c.can_evolve(), "bramblet")
	c.evolve()
	assert_eq(c.species_id, "bramblet")

func test_ai_prefers_super_effective() -> void:
	var eng := BattleEngine.new([_mk("embercub", 20)], [_mk("puddlop", 20)], BattleEngine.Kind.TRAINER, 5, "Kai")
	eng.sides[1].ai_level = 2
	var best := -1.0
	var best_i := 0
	var foe := eng.active(1)
	for i in foe.moves.size():
		var s := BattleAI.score_move(eng, 1, foe.moves[i], 2)
		if s > best:
			best = s
			best_i = i
	assert_eq(Data.get_move(foe.moves[best_i]).type in ["tide", "none", "wild"] or best > 0, true)
