extends GutTest
## Weekly Creature Show ladder, bounties, Starry chains, Warden rematches and machine automation.

func before_each() -> void:
	GameState.new_game({"player_name": "Hero", "farm_name": "T", "starter": "sproutle", "seed": 33})

func _p() -> PlayerData:
	return GameState.local_player()

func _star(lvl: int = 50) -> Creature:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var c := Creature.create("sproutle", lvl, rng, {"min_gene": Creature.MAX_GENE})
	c.happiness = 255
	c.grooming = 100
	return c

func _all_shrines() -> void:
	for rid in Data.region_order:
		if Data.regions[rid].has("warden") and not rid in GameState.world.shrines:
			GameState.world.shrines.append(rid)

# --- Shows -------------------------------------------------------------------------------

func test_show_only_on_saturdays_without_a_festival() -> void:
	var sat := Endless.next_show(0)
	assert_gt(sat, 0)
	assert_eq(Calendar.weekday(sat), Endless.SHOW_WEEKDAY)
	for d in 112:
		if Endless.show_open(d):
			assert_eq(Calendar.festival_on(d), "", "day %d clashes with a festival" % d)

func test_a_well_raised_wildling_climbs_the_ladder() -> void:
	var c := _star()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var r := Endless.judge(c, rng)
	assert_eq(int(r.place), 1)
	assert_true(r.rank_up)
	assert_eq(int(r.prize), Endless.SHOW_RANKS[0].prize)
	Endless.award(c, r)
	assert_eq(c.show_rank, 1)
	assert_eq(c.ribbons, 1)
	c.show_rank = Endless.SHOW_RANKS.size() - 1
	var top := Endless.judge(c, rng)
	assert_false(top.rank_up, "Master is the top class")

func test_a_scruffy_wildling_loses_at_gold() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var c := Creature.create("sproutle", 1, rng, {"genes": {"hp": 0, "power": 0, "guard": 0, "focus": 0, "speed": 0}})
	c.happiness = 0
	c.grooming = 0
	c.show_rank = 3
	var r := Endless.judge(c, rng)
	assert_gt(int(r.place), 1)
	Endless.award(c, r)
	assert_eq(c.ribbons, 0)
	assert_eq(c.show_rank, 3)

func test_show_act_once_per_show_and_pays() -> void:
	var c := _star()
	c.owner = _p().id
	_p().party.append(c)
	GameState.world.day = Endless.next_show(0) - 1
	assert_false(GameState.show_act(_p().id, c.uid).ok, "not Saturday")
	GameState.world.day = Endless.next_show(0)
	var money := GameState.money()
	var r := GameState.show_act(_p().id, c.uid)
	assert_true(r.ok)
	assert_eq(int(r.place), 1)
	assert_eq(GameState.money(), money + int(r.prize))
	assert_eq(c.ribbons, 1)
	assert_false(GameState.show_act(_p().id, c.uid).ok, "one entry per show")

func test_ribbons_and_rank_survive_saving() -> void:
	var c := _star()
	c.show_rank = 2
	c.ribbons = 5
	var d := Creature.from_dict(JSON.parse_string(JSON.stringify(c.to_dict())))
	assert_eq(d.show_rank, 2)
	assert_eq(d.ribbons, 5)

# --- Bounties ----------------------------------------------------------------------------

func test_bounty_is_stable_for_the_week_and_from_open_regions() -> void:
	var b := GameState.bounty()
	assert_false(b.is_empty())
	assert_true(b.region in GameState.world.regions)
	var found := false
	for s in Data.regions[b.region].spawns:
		if s[0] == b.species:
			found = true
	assert_true(found, "%s lives in %s" % [b.species, b.region])
	assert_eq(GameState.bounty(), b)
	assert_eq(Endless.bounty_for(0, 33, GameState.world.regions, {}), Endless.bounty_for(0, 33, GameState.world.regions, {}))

func test_befriending_the_bounty_pays_once() -> void:
	var b := GameState.bounty()
	b.min_genes = 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	var money := GameState.money()
	GameState.add_creature(_p(), Creature.create(b.species, 5, rng))
	assert_true(b.done)
	assert_eq(GameState.money(), money + int(b.reward.money))
	GameState.add_creature(_p(), Creature.create(b.species, 5, rng))
	assert_eq(GameState.money(), money + int(b.reward.money), "only once")

func test_bounty_gene_requirement() -> void:
	var b := {"species": "mushlet", "region": "whisperwood", "min_genes": 60, "done": false, "reward": {}}
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	assert_false(Endless.bounty_met(b, Creature.create("mushlet", 5, rng, {"genes": {"hp": 2, "power": 2, "guard": 2, "focus": 2, "speed": 2}})))
	assert_true(Endless.bounty_met(b, Creature.create("mushlet", 5, rng, {"min_gene": 15})))
	assert_false(Endless.bounty_met(b, Creature.create("acornib", 5, rng, {"min_gene": 15})))

# --- Starry chains -----------------------------------------------------------------------

func test_chains_build_reset_and_cap() -> void:
	var ch := {}
	for i in 3:
		ch = Endless.chain_after(ch, "mushlet")
	assert_eq(int(ch.n), 3)
	assert_almost_eq(Endless.chain_mult(ch, "mushlet"), 1.3, 0.001)
	assert_eq(Endless.chain_mult(ch, "acornib"), 1.0)
	ch = Endless.chain_after(ch, "acornib")
	assert_eq(int(ch.n), 1, "another species resets")
	for i in 100:
		ch = Endless.chain_after(ch, "acornib")
	assert_eq(int(ch.n), Endless.CHAIN_CAP)
	assert_almost_eq(Endless.chain_mult(ch, "acornib"), 5.0, 0.001)
	var spawns: Array = Data.regions.whisperwood.spawns
	assert_true(Endless.chain_lures(ch, spawns))
	assert_false(Endless.chain_lures({"species": "acornib", "n": 2}, spawns), "short chains don't lure")
	assert_false(Endless.chain_lures({"species": "glacierox", "n": 30}, spawns), "only where it lives")

func test_chain_act_is_per_player() -> void:
	GameState.chain_act(_p().id, "mushlet")
	GameState.chain_act(_p().id, "mushlet")
	GameState.chain_act("someone_else", "acornib")
	assert_eq(int(GameState.chain_of(_p().id).n), 2)
	assert_eq(GameState.chain_of("someone_else").species, "acornib")

# --- Warden rematches --------------------------------------------------------------------

func test_rematches_open_after_all_shrines_once_a_week() -> void:
	assert_false(GameState.rematch_ready(_p().id, "ivy"))
	assert_false(GameState.rematch_won_act(_p().id, "ivy").ok)
	_all_shrines()
	assert_true(GameState.rematch_ready(_p().id, "ivy"))
	var money := GameState.money()
	var r := GameState.rematch_won_act(_p().id, "ivy")
	assert_true(r.ok)
	assert_eq(GameState.money(), money + int(r.reward.money))
	assert_false(GameState.rematch_ready(_p().id, "ivy"))
	assert_false(GameState.rematch_won_act(_p().id, "ivy").ok)
	GameState.world.day = int(GameState.world.day) + 7
	assert_true(GameState.rematch_ready(_p().id, "ivy"), "back next week")
	assert_false(GameState.rematch_won_act(_p().id, "fern").ok, "only Wardens")

func test_rematch_teams_scale_and_cap() -> void:
	_all_shrines()
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var t0 := Trainers.rematch_team("ivy", 0, rng)
	assert_eq(t0.team.size(), 5, "Ivy's four plus Verdantis")
	assert_eq(t0.team[-1].level, Endless.REMATCH_BASE)
	assert_eq(t0.team[-1].species_id, Data.form_at_level("verdantis", Endless.REMATCH_BASE))
	var t9 := Trainers.rematch_team("selene", 20, rng)
	assert_eq(t9.team.size(), 6)
	assert_eq(t9.team[-1].level, 100)
	for w in ["ivy", "marina", "ash", "gideon"]:
		GameState.rematch_won_act(_p().id, w)
	assert_eq(Endless.rematch_tier(GameState.world), 1)
	assert_true(Trainers.rematch_team("fern", 0, rng).is_empty())

# --- Machine automation ------------------------------------------------------------------

func _machine_farm() -> Array:
	var g := FarmGrid.new()
	g.setup(8, 4)
	g.place_object(Vector2i(1, 1), "keg")
	g.place_object(Vector2i(3, 1), "preserves_jar")
	g.place_object(Vector2i(5, 1), "seed_maker")
	return [g]

func test_spark_workers_load_collect_and_refill_machines() -> void:
	var grids := _machine_farm()
	var g: FarmGrid = grids[0]
	var chest := Inventory.new(10, 8)
	chest.add("blueberry", 4)
	var rep := {"items": {}}
	Machines.automate(grids, chest, 1000, 10, rep)
	assert_eq(int(rep.machines_loaded), 2, "keg and jar, never the seed maker")
	assert_eq(chest.count("blueberry"), 2)
	assert_eq(g.object_at(Vector2i(1, 1)).output.id, "juice:blueberry")
	assert_eq(g.object_at(Vector2i(3, 1)).output.id, "jam:blueberry")
	assert_true(g.object_at(Vector2i(5, 1)).output.is_empty())
	Machines.automate(grids, chest, 1000 + 1440, 10, rep)
	assert_eq(int(rep.machines_collected), 2)
	assert_eq(chest.count("juice:blueberry"), 1)
	assert_eq(chest.count("jam:blueberry"), 1)
	assert_eq(chest.count("blueberry"), 0, "refilled with the rest")
	assert_eq(int(rep.machines_loaded), 4)

func test_automation_respects_worker_slots() -> void:
	var grids := _machine_farm()
	var chest := Inventory.new(10, 8)
	chest.add("blueberry", 4)
	var rep := {"items": {}}
	Machines.automate(grids, chest, 0, 1, rep)
	assert_eq(int(rep.get("machines_loaded", 0)), 1)

func test_overnight_spark_job_runs_the_line() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var c := Creature.create("staticat", 10, rng)
	c.owner = _p().id
	GameState.ranch.append(c)
	c.job = "power"
	assert_true(c.can_do_job("power"))
	GameState.grids.farm.place_object(Vector2i(10, 12), "keg")
	GameState.farm_chest.add("blueberry", 3)
	var rep := GameState.end_day()
	assert_gt(int(rep.jobs.machines_loaded), 0)
	assert_eq(GameState.grids.farm.object_at(Vector2i(10, 12)).output.id, "juice:blueberry")
