extends GutTest

var rng := RandomNumberGenerator.new()

func _grid() -> FarmGrid:
	var g := FarmGrid.new()
	g.map_id = "test"
	g.setup(10, 10)
	g.tillable = ["grass"]
	return g

func test_till_plant_grow_harvest() -> void:
	var g := _grid()
	var p := Vector2i(3, 3)
	assert_true(g.till(p))
	assert_true(g.plant(p, "parsnip_seeds", "spring"))
	assert_false(g.plant(p, "parsnip_seeds", "spring"), "occupied")
	var days: int = int(Data.crops.parsnip.days)
	for i in days:
		g.water(p)
		g.new_day("spring", "spring", "sun", rng, 0, true)
	assert_true(g.crop_ready(p))
	var h := g.harvest(p, rng)
	assert_eq(h.id, "parsnip")
	assert_true(g.crop_at(p).is_empty())

func test_out_of_season_rejected() -> void:
	var g := _grid()
	g.till(Vector2i(1, 1))
	assert_false(g.plant(Vector2i(1, 1), "parsnip_seeds", "winter"))

func test_season_change_withers() -> void:
	var g := _grid()
	g.till(Vector2i(1, 1))
	g.plant(Vector2i(1, 1), "parsnip_seeds", "spring")
	var rep := g.new_day("summer", "spring", "sun", rng, 0, true)
	assert_eq(int(rep.withered), 1)

func test_frost_protection() -> void:
	var g := _grid()
	g.till(Vector2i(1, 1))
	g.plant(Vector2i(1, 1), "parsnip_seeds", "spring")
	var rep := g.new_day("summer", "spring", "sun", rng, 5, true)
	assert_eq(int(rep.withered), 0)

func test_until_clears_empty_soil_only() -> void:
	var g := _grid()
	var p := Vector2i(3, 3)
	assert_true(g.till(p))
	assert_true(g.until(p))
	assert_false(g.is_tilled(p))
	g.till(p)
	g.plant(p, "parsnip_seeds", "spring")
	assert_false(g.until(p), "a crop stays")
	assert_false(g.crop_at(p).is_empty())

func test_bare_soil_reverts_overnight() -> void:
	var g := _grid()
	var local := RandomNumberGenerator.new()
	local.seed = 7
	var n := 0
	for x in range(1, 9):
		for y in range(1, 9):
			g.till(Vector2i(x, y))
			n += 1
	g.new_day("spring", "spring", "sun", local, 0, true)
	var left := g.soil.size()
	assert_lt(left, int(n * 0.75), "most dry empty soil is gone by morning")
	assert_gt(left, int(n * 0.2), "not every tile reverts in one night")

func test_watered_bare_soil_stays() -> void:
	var g := _grid()
	var p := Vector2i(2, 2)
	g.till(p)
	g.water(p)
	g.new_day("spring", "spring", "sun", rng, 0, true)
	assert_true(g.is_tilled(p))
	assert_false(bool(g.soil_at(p).watered))

func test_rain_waters() -> void:
	var g := _grid()
	g.till(Vector2i(2, 2))
	g.new_day("spring", "spring", "rain", rng, 0, true)
	assert_true(bool(g.soil_at(Vector2i(2, 2)).watered))

func test_sprinkler_waters_neighbors() -> void:
	var g := _grid()
	for x in range(3, 6):
		for y in range(3, 6):
			if not (x == 4 and y == 4):
				g.till(Vector2i(x, y))
				g.plant(Vector2i(x, y), "parsnip_seeds", "spring")
	assert_true(g.place_object(Vector2i(4, 4), "sprinkler"))
	g.new_day("spring", "spring", "sun", rng, 0, true)
	var watered := 0
	for k in g.soil:
		if g.soil[k].watered:
			watered += 1
	assert_gt(watered, 0)

func test_fruit_tree() -> void:
	var g := _grid()
	assert_true(g.place_object(Vector2i(5, 5), "cherry_sapling"))
	assert_false(g.place_object(Vector2i(5, 6), "peach_sapling"), "trees need space")
	for i in int(Data.trees.cherry.days) + 1:
		g.new_day("spring", "spring", "sun", rng, 0, true)
	assert_gt(int(g.object_at(Vector2i(5, 5)).fruit), 0)
	var fr := g.shake_tree(Vector2i(5, 5))
	assert_eq(fr.id, "cherry")

func test_debris_needs_tool_level() -> void:
	var g := _grid()
	g.set_deco(Vector2i(1, 1), Tiles.DECO.boulder)
	assert_false(g.clear_debris(Vector2i(1, 1), "pickaxe", 0, rng).ok)
	assert_true(g.clear_debris(Vector2i(1, 1), "pickaxe", 2, rng).ok)

func test_jobs_water_and_harvest() -> void:
	var g := _grid()
	for x in 4:
		g.till(Vector2i(x + 1, 1))
		g.plant(Vector2i(x + 1, 1), "parsnip_seeds", "spring")
	var w := Creature.create("puddlop", 10, rng)
	w.job = "water"
	var chest := Inventory.new(8, 6)
	var rep := FarmJobs.run([w], {"grids": [g], "chest": chest, "rng": rng, "season": "spring"})
	assert_eq(int(rep.watered), 4)
	assert_lt(w.energy, 100)

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
