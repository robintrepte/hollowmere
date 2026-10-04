extends GutTest
## Player XP, skill points, the skill tree data and every bonus it feeds.

var pid := ""
var p: PlayerData

func before_each() -> void:
	GameState.new_game({"seed": 33, "starter": "puddlop"})
	pid = Net.local_id()
	p = GameState.local_player()

func _give_points(n: int) -> void:
	p.skill_points += n

func _learn(id: String, ranks: int = 1) -> void:
	for i in ranks:
		assert_true(GameState.invest_skill_act(pid, id).ok, "learn %s" % id)

func test_tree_data_is_consistent() -> void:
	var ids := {}
	var problems: Array = []
	assert_eq(Data.skill_branches.size(), 6)
	assert_between(Data.skill_nodes.size(), 100, 130)
	for n in Data.skill_nodes:
		if ids.has(n.id):
			problems.append("duplicate %s" % n.id)
		ids[n.id] = n
		if not Data.skill_branches.has(str(n.branch)):
			problems.append("%s: branch %s" % [n.id, n.branch])
		for k in n.mods:
			if not Skills.EFFECT_TEXT.has(k):
				problems.append("%s: no text for %s" % [n.id, k])
		if Art.item(str(n.icon)) == null:
			problems.append("%s: icon %s" % [n.id, n.icon])
		if n.has("unlock") and not Skills.UNLOCK_TEXT.has(str(n.unlock)):
			problems.append("%s: unlock %s" % [n.id, n.unlock])
	for n in Data.skill_nodes:
		for r in n.get("req", []):
			if not ids.has(r) or ids[r].branch != n.branch:
				problems.append("%s: requirement %s" % [n.id, r])
	assert_eq(problems, [])
	var roots := Data.skill_nodes.filter(func(n): return n.get("req", []).is_empty())
	assert_eq(roots.size(), 6, "one root per branch")

func test_xp_levels_and_points() -> void:
	assert_eq(p.level, 1)
	assert_eq(Skills.points_free(p, GameState.world), 0)
	Skills.add_xp(p, Skills.xp_to_next(1) + Skills.xp_to_next(2) + 5)
	assert_eq(p.level, 3)
	assert_eq(p.xp, 5)
	assert_eq(Skills.points_free(p, GameState.world), 2)
	GameState.world.shrines.append("whisperwood")
	GameState.world.quest = 2
	assert_eq(Skills.points_free(p, GameState.world), 5, "chapters and shrines add points")

func test_level_is_capped() -> void:
	Skills.add_xp(p, 10000000)
	assert_eq(p.level, Skills.MAX_LEVEL)
	assert_eq(p.xp, 0)

func test_actions_and_quests_give_xp() -> void:
	p.stat_add("harvested", 5)
	assert_eq(p.xp, 10)
	watch_signals(EventBus)
	p.stat_add("befriend", 3)
	assert_eq(p.level, 2)
	assert_signal_emitted(EventBus, "player_leveled")

func test_tree_needs_connected_skills_and_points() -> void:
	assert_false(GameState.invest_skill_act(pid, "green_thumb").ok, "no points yet")
	_give_points(3)
	assert_false(GameState.invest_skill_act(pid, "deep_roots").ok, "needs the root first")
	_learn("green_thumb")
	_learn("deep_roots", 2)
	assert_false(GameState.invest_skill_act(pid, "deep_roots").ok, "out of points")
	assert_eq(Skills.points_free(p, GameState.world), 0)
	assert_almost_eq(Modifiers.value(p, "crop_yield"), 0.06, 0.0001)
	assert_almost_eq(Modifiers.value(p, "crop_growth"), 0.03, 0.0001)

## Learns a node after the first of its requirements, all the way back to the root.
func _learn_path(id: String) -> void:
	var reqs: Array = Skills.node(id).get("req", [])
	if Skills.rank(p, id) == 0 and not reqs.is_empty() and reqs.all(func(r): return Skills.rank(p, str(r)) == 0):
		_learn_path(str(reqs[0]))
	_learn(id)

func test_capstone_needs_branch_points() -> void:
	_give_points(60)
	_learn_path("evergreen")
	var need := int(Skills.node("harvest_sweep").need)
	assert_lt(Skills.branch_points(p, "farming"), need)
	assert_ne(Skills.blocker(p, GameState.world, "harvest_sweep"), "", "capstone stays locked until the branch has enough points")
	for n in Data.skill_nodes:
		if n.branch == "farming" and not n.has("need"):
			while Skills.branch_points(p, "farming") < need and Skills.can_invest(p, GameState.world, str(n.id)):
				_learn(str(n.id))
	assert_gte(Skills.branch_points(p, "farming"), need)
	assert_true(GameState.invest_skill_act(pid, "harvest_sweep").ok)
	assert_true(Skills.has_unlock(p, "harvest_sweep"))

func test_respec_returns_points_for_rising_gold() -> void:
	_give_points(2)
	_learn("light_feet", 2)
	GameState.world.money = 5000
	assert_true(GameState.respec_skills_act(pid).ok)
	assert_eq(p.tree, {})
	assert_eq(Skills.points_free(p, GameState.world), 2)
	assert_eq(int(GameState.world.money), 4000)
	assert_eq(Skills.respec_cost(p), 2000)
	assert_almost_eq(Modifiers.value(p, "move_speed"), 0.0, 0.0001)

func test_tree_survives_save() -> void:
	_give_points(1)
	Skills.add_xp(p, 20)
	_learn("haggler")
	var q := PlayerData.from_dict(JSON.parse_string(JSON.stringify(p.to_dict())))
	assert_eq(Skills.rank(q, "haggler"), 1)
	assert_eq(q.xp, 20)
	assert_almost_eq(Modifiers.value(q, "sell_price"), 0.02, 0.0001)

func test_trade_bonuses_change_prices() -> void:
	var base := Data.sell_price("parsnip", 0)
	_give_points(4)
	_learn("haggler", 3)
	_learn("regular")
	assert_eq(GameState.sell_value(p, "parsnip", 0), int(round(base * 1.06)))
	assert_eq(GameState.buy_value(p, 1000), 970)

func test_season_relief_closes_off_season_gap() -> void:
	var off := CropGrowth.season_rate("parsnip", "fall", false)
	var half := CropGrowth.season_rate("parsnip", "fall", false, 0.5)
	assert_almost_eq(half, off + (1.0 - off) * 0.5, 0.0001)
	assert_eq(CropGrowth.season_rate("parsnip", "spring", false, 0.5), 1.0)

func test_battle_bonuses_raise_damage_and_befriending() -> void:
	var a := Creature.create("puddlop", 10, RandomNumberGenerator.new())
	var b := Creature.create("puddlop", 10, RandomNumberGenerator.new())
	var eng := BattleEngine.new([a], [b], BattleEngine.Kind.WILD, 7)
	var move: String = a.moves[0]
	var plain := float(eng._damage_core(0, move).raw)
	var chance := eng.befriend_chance("basic_treat")
	eng.side_mods[0] = {"battle_damage": 0.1, "befriend": 0.5}
	assert_almost_eq(float(eng._damage_core(0, move).raw), plain * 1.1, 0.01)
	assert_almost_eq(eng.befriend_chance("basic_treat"), minf(1.0, chance * 1.5), 0.0001)
	eng.side_mods[1] = {"battle_guard": 0.2}
	assert_almost_eq(float(eng._damage_core(0, move).raw), plain * 1.1 * 0.8, 0.01)

func test_energy_and_den_bonuses() -> void:
	_give_points(10)
	_learn("light_feet")
	_learn("stamina", 2)
	assert_almost_eq(p.energy_cap(), p.max_energy * 1.12, 0.01)
	var cap := GameState.den_capacity()
	_learn_path("roomy_den")
	assert_eq(GameState.den_capacity(), cap + 1)

func test_effect_text_reads_well() -> void:
	var lines := Skills.effect_lines(Skills.node("deep_roots"), 2)
	assert_eq(lines.size(), 1)
	assert_true("6" in str(lines[0]), str(lines[0]))
	var cap := Skills.effect_lines(Skills.node("map_reader"), 1)
	assert_eq(cap.size(), 2, "unlock nodes describe their unlock")
