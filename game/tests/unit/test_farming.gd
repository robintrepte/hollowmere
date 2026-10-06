extends GutTest
## Real-time farming: crops grow by the clock, seed tiers limit harvests, water nearby keeps fields wet.

const T0 := 1_780_000_000.0  # a spring day (June 2026 is summer in the north, but tests pin the season)

var rng := RandomNumberGenerator.new()

func _grid() -> FarmGrid:
	var g := FarmGrid.new()
	g.map_id = "test"
	g.setup(20, 20)
	g.tillable = ["grass"]
	return g

func _ctx(season: String = "spring") -> Dictionary:
	return {"season_at": func(_t): return season, "mult": 1.0}

func _ripe_seconds(crop: String, season: String = "spring", watered: bool = true) -> float:
	return CropGrowth.eta(crop, 0.0, season, watered, "", false)

func test_crop_ripens_in_real_time_when_watered() -> void:
	var g := _grid()
	var p := Vector2i(3, 3)
	assert_true(g.till(p, T0))
	assert_true(g.plant(p, "parsnip_seeds"))
	assert_false(g.plant(p, "parsnip_seeds"), "occupied")
	g.water(p, T0)
	var full := _ripe_seconds("parsnip")
	assert_almost_eq(full, CropGrowth.grow_minutes("parsnip") * 60.0, 1.0)
	g.advance(T0, T0 + full * 0.5, _ctx())
	assert_false(g.crop_ready(p))
	assert_eq(g.crop_stage(p), 2)
	g.advance(T0 + full * 0.5, T0 + full + 1.0, _ctx())
	assert_true(g.crop_ready(p))

func test_dry_crops_grow_slower_but_still_grow() -> void:
	var g := _grid()
	var p := Vector2i(3, 3)
	g.till(p, T0)
	g.plant(p, "parsnip_seeds")
	var wet := _ripe_seconds("parsnip")
	g.advance(T0, T0 + wet, _ctx())
	assert_false(g.crop_ready(p), "without water it takes longer")
	assert_almost_eq(float(g.crop_at(p).progress), 1.0 / CropGrowth.WATER_BOOST, 0.01)
	g.advance(T0 + wet, T0 + wet * CropGrowth.WATER_BOOST + 1.0, _ctx())
	assert_true(g.crop_ready(p))

func test_watering_wears_off_piecewise() -> void:
	var g := _grid()
	var p := Vector2i(3, 3)
	g.till(p, T0)
	g.plant(p, "cauliflower_seeds")
	g.water(p, T0)
	var span := float(CropGrowth.WATER_SECONDS) * 2.0
	g.advance(T0, T0 + span, _ctx())
	var r_w := CropGrowth.rate("cauliflower", "spring", true, "", false)
	var r_d := CropGrowth.rate("cauliflower", "spring", false, "", false)
	var expect := minf(1.0, r_w * CropGrowth.WATER_SECONDS + r_d * CropGrowth.WATER_SECONDS)
	assert_almost_eq(float(g.crop_at(p).progress), expect, 0.001)
	assert_false(g.is_watered(p, T0 + span))

func test_any_season_plantable_with_slower_off_season_growth() -> void:
	var g := _grid()
	g.till(Vector2i(1, 1), T0)
	assert_true(g.plant(Vector2i(1, 1), "parsnip_seeds", "winter"), "off-season seeds go in too")
	assert_gt(_ripe_seconds("parsnip", "fall"), _ripe_seconds("parsnip", "summer"), "the opposite season is slowest")
	assert_gt(_ripe_seconds("parsnip", "summer"), _ripe_seconds("parsnip", "spring"))
	var gh := _grid()
	gh.greenhouse = true
	assert_lt(CropGrowth.eta("parsnip", 0.0, "winter", true, "", true), _ripe_seconds("parsnip", "spring"), "the greenhouse beats even the best season")

func test_off_season_harvests_are_smaller_but_never_empty() -> void:
	assert_eq(CropGrowth.season_yield("parsnip", "fall", false), 0.5)
	assert_eq(CropGrowth.season_yield("parsnip", "fall", true), CropGrowth.GREENHOUSE_YIELD)
	var g := _grid()
	var local := RandomNumberGenerator.new()
	local.seed = 3
	for i in 20:
		var p := Vector2i(i % 10, int(i / 10))
		g.till(p, T0)
		g.plant(p, "parsnip_seeds")
		g.crop_at(p).progress = 1.0
		assert_gte(int(g.harvest(p, local, 0.0, 0, "fall").n), 1)

func test_plants_stay_after_harvest_until_their_tier_runs_out() -> void:
	var g := _grid()
	var p := Vector2i(3, 3)
	g.till(p, T0)
	g.plant(p, "parsnip_seeds", "", 1)
	for i in 3:
		g.crop_at(p).progress = 1.0
		var h := g.harvest(p, rng, 0.0, 0, "spring")
		assert_eq(h.id, "parsnip")
		assert_eq(bool(h.spent), i == 2)
		if i < 2:
			assert_eq(float(g.crop_at(p).progress), 0.0, "non-regrowing crops start over without replanting")
	assert_true(g.crop_at(p).is_empty(), "a tier I plant gives three harvests")
	assert_true(g.is_tilled(p), "the field stays tilled")
	g.plant(p, "parsnip_seeds", "", 4)
	for i in 30:
		g.crop_at(p).progress = 1.0
		g.harvest(p, rng, 0.0, 0, "spring")
	assert_false(g.crop_at(p).is_empty(), "everlasting seeds never run out")

func test_regrowing_crops_restart_partway() -> void:
	var g := _grid()
	var p := Vector2i(3, 3)
	g.till(p, T0)
	g.plant(p, "strawberry_seeds")
	g.crop_at(p).progress = 1.0
	g.harvest(p, rng, 0.0, 0, "spring")
	assert_almost_eq(float(g.crop_at(p).progress), CropGrowth.regrow_progress("strawberry"), 0.001)
	assert_gt(CropGrowth.regrow_progress("strawberry"), 0.0)

func test_until_clears_empty_soil_only() -> void:
	var g := _grid()
	var p := Vector2i(3, 3)
	assert_true(g.till(p, T0))
	assert_true(g.until(p))
	assert_false(g.is_tilled(p))
	g.till(p, T0)
	g.plant(p, "parsnip_seeds")
	assert_false(g.until(p), "a crop stays")
	assert_false(g.crop_at(p).is_empty())

func test_bare_dry_soil_reverts_after_two_days() -> void:
	var g := _grid()
	var p := Vector2i(10, 10)
	g.till(p, T0)
	g.advance(T0, T0 + 3600 * 24, _ctx())
	assert_true(g.is_tilled(p), "a day is fine")
	g.advance(T0 + 3600 * 24, T0 + CropGrowth.BARE_SOIL_SECONDS + 10, _ctx())
	assert_false(g.is_tilled(p), "left bare and dry for two days, it grows over")

func test_soil_near_water_stays_wet_and_never_reverts() -> void:
	var g := _grid()
	g.ground[g.idx(Vector2i(2, 2))] = Tiles.GROUND.water
	g.invalidate_water()
	var near := Vector2i(2, 6)
	var far := Vector2i(12, 12)
	g.till(near, T0)
	g.till(far, T0)
	assert_true(g.is_always_wet(near), "four tiles from the pond")
	assert_false(g.is_always_wet(Vector2i(2, 7)), "five is too far")
	g.advance(T0, T0 + CropGrowth.BARE_SOIL_SECONDS * 2, _ctx())
	assert_true(g.is_tilled(near))
	assert_true(bool(g.soil_at(near).watered))
	assert_false(g.is_tilled(far))

func test_sprinklers_keep_tiles_wet_and_tilled() -> void:
	var g := _grid()
	for x in range(3, 6):
		for y in range(3, 6):
			if not (x == 4 and y == 4):
				g.till(Vector2i(x, y), T0)
	assert_true(g.place_object(Vector2i(4, 4), "sprinkler"))
	g.advance(T0, T0 + CropGrowth.BARE_SOIL_SECONDS * 2, _ctx())
	assert_true(g.is_tilled(Vector2i(4, 3)), "plus-shape sprinkler tiles stay")
	assert_true(g.is_watered(Vector2i(4, 3), T0))
	assert_false(g.is_tilled(Vector2i(3, 3)), "the corner isn't covered")

func test_trench_carries_water_from_the_pond() -> void:
	var g := _grid()
	g.ground[g.idx(Vector2i(0, 10))] = Tiles.GROUND.water
	for x in range(1, 12):
		assert_true(g.dig_trench(Vector2i(x, 10), T0))
	assert_eq(g.get_ground(Vector2i(1, 10)), Tiles.GROUND.water, "next to the pond it fills")
	assert_eq(g.get_ground(Vector2i(8, 10)), Tiles.GROUND.water, "flows eight tiles")
	assert_eq(g.get_ground(Vector2i(9, 10)), Tiles.GROUND.dirt, "then stops")
	assert_true(g.is_always_wet(Vector2i(12, 10)), "fields near the wet trench count as watered")
	assert_true(g.pour_bucket(Vector2i(10, 10), T0))
	assert_eq(g.get_ground(Vector2i(11, 10)), Tiles.GROUND.water, "a bucket starts a new flow")
	g.advance(T0, T0 + FarmGrid.BUCKET_SECONDS + 1, _ctx())
	assert_eq(g.get_ground(Vector2i(11, 10)), Tiles.GROUND.dirt, "and dries out again")
	assert_true(g.fill_trench(Vector2i(1, 10), T0))
	assert_eq(g.get_ground(Vector2i(2, 10)), Tiles.GROUND.dirt, "cut off from the pond, the trench dries up")
	assert_eq(g.get_ground(Vector2i(1, 10)), Tiles.GROUND.grass)

func test_rain_waters() -> void:
	var g := _grid()
	g.till(Vector2i(2, 2), T0)
	g.rain(T0)
	assert_true(g.is_watered(Vector2i(2, 2), T0 + 60))

func test_fruit_tree_matures_and_fruits_in_real_time() -> void:
	var g := _grid()
	assert_true(g.place_object(Vector2i(5, 5), "cherry_sapling"))
	assert_false(g.place_object(Vector2i(5, 6), "peach_sapling"), "trees need space")
	var o := g.object_at(Vector2i(5, 5))
	o.planted_at = T0
	var mature := float(Data.trees.cherry.days) * CropGrowth.TREE_DAY_SECONDS
	g.advance(T0, T0 + mature - 10, _ctx())
	assert_eq(int(o.fruit), 0)
	assert_lt(FarmGrid.tree_growth(o, T0 + mature - 10), 1.0)
	g.advance(T0 + mature - 10, T0 + mature + CropGrowth.FRUIT_SECONDS * 2 + 1, _ctx())
	assert_eq(int(o.fruit), 2)
	g.advance(T0 + mature + CropGrowth.FRUIT_SECONDS * 2 + 1, T0 + mature + CropGrowth.FRUIT_SECONDS * 10, _ctx())
	assert_eq(int(o.fruit), 3, "at most three on the tree")
	var fr := g.shake_tree(Vector2i(5, 5))
	assert_eq(fr.id, "cherry")

func test_debris_needs_tool_level() -> void:
	var g := _grid()
	g.set_deco(Vector2i(1, 1), Tiles.DECO.boulder)
	assert_false(g.clear_debris(Vector2i(1, 1), "pickaxe", 0, rng).ok)
	assert_true(g.clear_debris(Vector2i(1, 1), "pickaxe", 2, rng).ok)

func test_trees_take_three_swings_and_ground_wood_takes_one() -> void:
	GameState.new_game({"seed": 5, "starter": "puddlop"})
	var pid := Net.local_id()
	var p := GameState.local_player()
	var g := GameState.grid("farm")
	var stick := Vector2i(2, 2)
	var tree := Vector2i(4, 2)
	g.set_deco(stick, Tiles.DECO.branch)
	g.set_deco(tree, Tiles.DECO.tree)
	assert_true(GameState.use_tool(pid, "farm", stick, "axe").ok)
	assert_eq(g.get_deco(stick), 0, "wood on the ground falls in one swing")
	assert_true(GameState.use_tool(pid, "farm", tree, "axe").ok)
	assert_eq(g.get_deco(tree), Tiles.DECO.tree, "a tree stays standing after one swing")
	assert_gt(GameState.crack("farm", tree), 0.0)
	assert_true(GameState.use_tool(pid, "farm", tree, "axe").ok)
	assert_eq(g.get_deco(tree), Tiles.DECO.tree)
	var wood := p.inventory.count("wood")
	assert_true(GameState.use_tool(pid, "farm", tree, "axe").ok)
	assert_eq(g.get_deco(tree), 0, "the third swing fells it")
	assert_gt(p.inventory.count("wood"), wood)
	assert_eq(GameState.crack("farm", tree), 0.0)
	g.set_deco(tree, Tiles.DECO.pine)
	p.tool_levels["axe"] = 5
	assert_true(GameState.use_tool(pid, "farm", tree, "axe").ok)
	assert_eq(g.get_deco(tree), Tiles.DECO.pine, "even a top axe needs a second swing")
	assert_true(GameState.use_tool(pid, "farm", tree, "axe").ok)
	assert_eq(g.get_deco(tree), 0)

func test_jobs_water_per_tick_and_cost_energy() -> void:
	var g := _grid()
	for x in 12:
		g.till(Vector2i(x + 1, 1), T0)
		g.plant(Vector2i(x + 1, 1), "parsnip_seeds")
	var w := Creature.create("puddlop", 10, rng)
	w.job = "water"
	var chest := Inventory.new(8, 6)
	var rep: Dictionary = FarmJobs.run([w], {"grids": [g], "chest": chest, "rng": rng, "season": "spring", "now": T0})
	assert_gt(int(rep.watered), 0)
	assert_lt(int(rep.watered), 12, "one ten-minute tick waters a few fields, not all")
	assert_lt(w.energy, 100.0)
	var rep2: Dictionary = FarmJobs.run([w], {"grids": [g], "chest": chest, "rng": rng, "season": "spring", "now": T0, "scale": 36.0})
	assert_eq(int(rep.watered) + int(rep2.watered), 12, "six hours of work waters the rest")

func test_machines_furnace() -> void:
	var inv := Inventory.new(5, 5)
	inv.add("copper_ore", 5)
	inv.add("coal", 1)
	var chk := Machines.can_load("furnace", "copper_ore", 0, inv)
	assert_true(chk.ok)
	assert_eq(chk.output.id, "copper_bar")
	var keg := Machines.can_load("keg", "parsnip", 1, inv)
	assert_true(keg.ok)
	assert_true(Data.sell_price(keg.output.id, 0) > Data.sell_price("parsnip", 0))

func _plant_field(g: FarmGrid, n: int) -> void:
	for i in n:
		var p := Vector2i(i % 8, 2 + int(i / 8))
		if not g.is_tilled(p):
			g.till(p, T0)
		if g.crop_at(p).is_empty():
			g.plant(p, "parsnip_seeds")
		else:
			g.crop_at(p).erase("ruined")

func test_crows_leave_a_ruined_plant() -> void:
	var g := _grid()
	_plant_field(g, 16)
	var local := RandomNumberGenerator.new()
	var found := false
	for s in 40:
		_plant_field(g, 16)
		local.seed = s
		var rep := g.night(local, false)
		if int(rep.crow) == 0:
			assert_eq(g.planted_tiles().size(), 16)
			continue
		found = true
		assert_eq(int(rep.crow), 1)
		var ruined: Array = []
		for k in g.soil:
			if bool(g.soil[k].get("crop", {}).get("ruined", false)):
				ruined.append(Tiles.parse_key(k))
		assert_eq(ruined.size(), 1, "the plant stays, snapped")
		var p: Vector2i = ruined[0]
		assert_false(g.crop_ready(p))
		assert_eq(g.planted_tiles().size(), 15)
		var prog := float(g.crop_at(p).progress)
		g.advance(T0, T0 + 100000.0, _ctx())
		assert_almost_eq(float(g.crop_at(p).progress), prog, 0.0001, "a ruined plant does not keep growing")
		assert_true(g.clear_ruined(p))
		assert_true(g.crop_at(p).is_empty())
		assert_true(g.is_tilled(p), "the soil stays ready to replant")
		assert_false(g.clear_ruined(p))
		break
	assert_true(found, "a crow raid happened")

func test_crows_skip_small_fields_scarecrows_and_guards() -> void:
	var g := _grid()
	_plant_field(g, 15)
	var local := RandomNumberGenerator.new()
	for s in 10:
		local.seed = s
		assert_eq(int(g.night(local, false).crow), 0, "fifteen plants is not a feast")
	_plant_field(g, 16)
	assert_true(g.place_object(Vector2i(4, 4), "scarecrow"))
	for s in 20:
		local.seed = s
		assert_eq(int(g.night(local, false).crow), 0, "a scarecrow covers this patch")
	g.greenhouse = true
	g.remove_object(Vector2i(4, 4))
	local.seed = 1
	assert_eq(int(g.night(local, false).crow), 0, "the greenhouse is safe")
	g.greenhouse = false
	assert_eq(int(g.night(local, true).crow), 0, "a guardian on duty")

func test_seed_refiner_raises_the_tier() -> void:
	var inv := Inventory.new(6, 6)
	inv.add("parsnip_seeds", 5)
	assert_false(Machines.can_load("seed_refiner", "parsnip_seeds", 0, inv).ok, "needs sap")
	inv.add("sap", 5)
	var chk := Machines.can_load("seed_refiner", "parsnip_seeds", 0, inv)
	assert_true(chk.ok)
	assert_eq(int(chk.output.q), 1)
	assert_eq(int(chk.output.n), 5)
	assert_false(Machines.can_load("seed_refiner", "parsnip_seeds", 3, inv).ok, "everlasting is the top")
	assert_eq(Data.item_name("parsnip_seeds", 2), TranslationServer.translate("%s (%s)") % [Data.item_name("parsnip_seeds"), TranslationServer.translate("Noble")])
