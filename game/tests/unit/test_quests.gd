extends GutTest
## Quest engine: data integrity, steps, hand-ins, rewards, dailies (roll, reroll, streak), tutorial skip.

var pid := ""
var p: PlayerData
const T0 := 1790000000.0

func before_each() -> void:
	GameState.new_game({"seed": 21, "starter": "puddlop"})
	pid = Net.local_id()
	p = GameState.local_player()
	p.map_id = "farm"
	TimeService.fixed_now = T0

func after_each() -> void:
	TimeService.fixed_now = -1.0
	Seasons.override = "spring"

func _goal_ok(g: Dictionary) -> String:
	for k in ["deliver", "have"]:
		if g.has(k) and not Data.has_item(str(g[k])):
			return "unknown item %s" % g[k]
	if g.has("to") and not Data.villagers.has(str(g.to)):
		return "unknown villager %s" % g.to
	if g.has("talk") and not Data.villagers.has(str(g.talk)):
		return "unknown villager %s" % g.talk
	var kinds := ["stat", "have", "deliver", "talk", "visit", "tile", "flag", "dex", "farm_level", "shrines", "hearts"]
	for k in g:
		if not k in kinds and not k in ["n", "to"]:
			return "unknown goal key %s" % k
	return ""

func test_quest_data_is_consistent() -> void:
	assert_gt(Data.quests.size(), 40)
	var problems: Array = []
	for qid in Data.quest_order:
		var d: Dictionary = Data.quests[qid]
		if not str(d.type) in Quests.TYPES:
			problems.append("%s: type %s" % [qid, d.type])
		if d.has("giver") and not Data.villagers.has(str(d.giver)):
			problems.append("%s: giver %s" % [qid, d.giver])
		for q in d.get("requires", {}).get("quests", []):
			if not Data.quests.has(q):
				problems.append("%s: requires unknown %s" % [qid, q])
		if d.steps.is_empty():
			problems.append("%s: no steps" % qid)
		for s in d.steps:
			var err := _goal_ok(s.goal)
			if err != "":
				problems.append("%s: %s" % [qid, err])
		for k in d.reward:
			if not k in ["money", "friendship", "recipe", "skill_points", "emote", "chips", "flag"] and not Data.has_item(k):
				problems.append("%s: reward %s" % [qid, k])
			if k == "recipe" and not Economy.recipe("cooking", str(d.reward[k])).size() and not Economy.recipe("crafting", str(d.reward[k])).size():
				problems.append("%s: recipe %s" % [qid, d.reward[k]])
	for t in Data.quest_daily:
		for it in t.get("items", []):
			if not Data.has_item(it):
				problems.append("daily %s: item %s" % [t.id, it])
	assert_eq(problems, [])

func test_every_villager_has_side_quests() -> void:
	var count := {}
	for qid in Data.quest_order:
		var d: Dictionary = Data.quests[qid]
		if d.type == "side":
			count[d.giver] = int(count.get(d.giver, 0)) + 1
	for vid in Data.villagers:
		assert_gte(int(count.get(vid, 0)), 2, "%s needs 2+ side quests" % vid)

func test_stat_step_then_talk_then_reward() -> void:
	assert_true("fern_survey" in Quests.offers(p, GameState.world, T0, "fern"))
	assert_true(Quests.start(p, "fern_survey", T0))
	assert_eq(Quests.progress(p, GameState.world, "fern_survey"), [0, 3])
	GameState.bump_stat("befriend", 2, pid)
	Quests.update(p, GameState.world, T0)
	assert_eq(int(Quests.state(p).active.fern_survey.step), 0)
	GameState.bump_stat("befriend", 1, pid)
	Quests.update(p, GameState.world, T0)
	assert_eq(int(Quests.state(p).active.fern_survey.step), 1, "now: talk to Fern")
	assert_true(Quests.turn_in_ready(p, "fern"))
	assert_eq(Quests.talk(p, GameState.world, "mira", T0), [], "wrong villager")
	var done := Quests.talk(p, GameState.world, "fern", T0)
	assert_eq(done.size(), 1)
	assert_true(Quests.is_done(p, "fern_survey"))
	var money := GameState.money()
	var pts := int(p.relationship("fern").pts)
	assert_true(GameState.claim_quest_act(pid, "fern_survey").ok)
	assert_eq(GameState.money(), money + 400)
	assert_gt(int(p.relationship("fern").pts), pts)
	assert_false(GameState.claim_quest_act(pid, "fern_survey").ok, "paid once")

func test_counters_only_count_after_the_quest_starts() -> void:
	GameState.bump_stat("befriend", 5, pid)
	Quests.start(p, "fern_survey", T0)
	assert_eq(Quests.progress(p, GameState.world, "fern_survey"), [0, 3])

func test_deliver_takes_the_items() -> void:
	Quests.start(p, "mira_restock", T0)
	p.inventory.add("parsnip", 6)
	assert_false(Quests.turn_in_ready(p, "mira"))
	assert_eq(Quests.talk(p, GameState.world, "mira", T0), [])
	p.inventory.add("parsnip", 6)
	assert_true(Quests.turn_in_ready(p, "mira"))
	Quests.talk(p, GameState.world, "mira", T0)
	assert_eq(p.inventory.count("parsnip"), 2)
	assert_true(Quests.is_done(p, "mira_restock"))

func test_follow_up_needs_the_first_quest_and_hearts() -> void:
	assert_false("mira_sweet" in Quests.offers(p, GameState.world, T0, "mira"))
	Quests.state(p).done["mira_restock"] = {"at": T0, "claimed": true}
	assert_false("mira_sweet" in Quests.offers(p, GameState.world, T0, "mira"), "needs 2 hearts")
	Relationships.add_points("mira", p.relationship("mira"), 500)
	assert_true("mira_sweet" in Quests.offers(p, GameState.world, T0, "mira"))

func test_seasonal_quest_follows_the_real_season() -> void:
	Seasons.override = "spring"
	assert_true("season_spring" in Quests.offers(p, GameState.world, T0, "lila"))
	Seasons.override = "winter"
	assert_false("season_spring" in Quests.offers(p, GameState.world, T0, "lila"))
	assert_true("season_winter" in Quests.offers(p, GameState.world, T0, "cora"))

func test_event_dates_wrap_over_new_year() -> void:
	assert_true(Quests.in_dates(Time.get_unix_time_from_datetime_string("2027-01-03T12:00:00"), ["12-31", "01-07"]))
	assert_false(Quests.in_dates(Time.get_unix_time_from_datetime_string("2027-03-03T12:00:00"), ["12-31", "01-07"]))

func test_three_dailies_per_day_and_they_expire() -> void:
	assert_true(Quests.roll_daily(p, GameState.world, T0))
	var ids: Array = Quests.state(p).daily.ids.duplicate()
	assert_eq(ids.size(), 3)
	assert_false(Quests.roll_daily(p, GameState.world, T0 + 60), "same day")
	for qid in ids:
		assert_true(Quests.is_active(p, qid))
	assert_true(Quests.roll_daily(p, GameState.world, T0 + 86400))
	for qid in ids:
		assert_false(Quests.is_active(p, qid), "yesterday's dailies are gone")
	assert_eq(Quests.state(p).daily.ids.size(), 3)

func test_reroll_once_per_day() -> void:
	Quests.roll_daily(p, GameState.world, T0)
	var qid: String = Quests.state(p).daily.ids[0]
	var before := str(Quests.def_of(p, qid).template)
	assert_true(Quests.reroll_daily(p, GameState.world, qid, T0))
	assert_ne(str(Quests.def_of(p, qid).template), before)
	assert_false(Quests.reroll_daily(p, GameState.world, Quests.state(p).daily.ids[1], T0), "only once")

func _finish_dailies(unix: float) -> void:
	Quests.roll_daily(p, GameState.world, unix)
	for qid in Quests.state(p).daily.ids:
		var st := Quests.state(p)
		var entry: Dictionary = st.active[qid]
		entry.step = 1
		st.done[qid] = {"at": unix, "claimed": false, "def": entry.def}
		st.active.erase(qid)
		GameState.claim_quest_act(pid, qid)

func test_daily_streak_grows_on_consecutive_days() -> void:
	_finish_dailies(T0)
	assert_eq(int(Quests.state(p).daily.streak), 1)
	_finish_dailies(T0 + 86400)
	assert_eq(int(Quests.state(p).daily.streak), 2)
	_finish_dailies(T0 + 86400 * 3)
	assert_eq(int(Quests.state(p).daily.streak), 1, "a missed day resets it")

func test_daily_targets_grow_with_the_farm() -> void:
	var t: Dictionary = Data.quest_daily[0]
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var low := int(Quests.make_daily(t, GameState.world, rng).steps[0].goal.n)
	GameState.world.farm.level = 10
	rng.seed = 1
	var high := int(Quests.make_daily(t, GameState.world, rng).steps[0].goal.n)
	assert_gt(high, low)

func test_skipping_the_tutorial_still_pays_out() -> void:
	Quests.start_tutorial(p, T0)
	assert_true(Quests.is_active(p, "tut_move"))
	Quests.skip_tutorial(p, T0)
	assert_eq(Quests.state(p).tutorial, "skipped")
	assert_false(Quests.is_active(p, "tut_move"))
	var unclaimed := Quests.unclaimed(p)
	assert_eq(unclaimed.size(), Quests.tutorial_ids().size())
	var money := GameState.money()
	for qid in unclaimed:
		GameState.claim_quest_act(pid, qid)
	assert_gt(GameState.money(), money)
	assert_eq(p.inventory.count("parsnip_seeds") >= 5, true)

func test_tutorial_chain_moves_on() -> void:
	Quests.start_tutorial(p, T0)
	p.stat_add("walk", 25)
	var ev := Quests.update(p, GameState.world, T0)
	assert_eq(ev, [{"qid": "tut_move", "event": "done"}])
	assert_eq(Quests.next_tutorial(p, T0), "tut_till")

func test_quest_state_survives_save() -> void:
	Quests.start(p, "fern_survey", T0)
	Quests.roll_daily(p, GameState.world, T0)
	var q := PlayerData.from_dict(JSON.parse_string(JSON.stringify(p.to_dict())))
	assert_true(Quests.is_active(q, "fern_survey"))
	assert_eq(Quests.state(q).daily.ids.size(), 3)
	assert_true(Quests.def_of(q, Quests.state(q).daily.ids[0]).has("steps"), "generated dailies keep their definition")

func test_input_hints_fill_tokens() -> void:
	var s := InputHints.fill("Press {use} to till.")
	assert_false(s.contains("{use}"))
