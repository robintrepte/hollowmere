extends GutTest
## Crafting, cooking, buildings, tool + backpack upgrades and Village Board deliveries.

var pid := ""
var p: PlayerData

func before_each() -> void:
	GameState.new_game({"seed": 11, "starter": "puddlop"})
	pid = Net.local_id()
	p = GameState.local_player()
	p.map_id = "farm"

func test_craft_consumes_ingredients() -> void:
	var r: Dictionary = Economy.recipe("crafting", "basic_treat")
	for k in r.in:
		p.inventory.add(k, int(r.in[k]))
	var before := p.inventory.count("basic_treat")
	assert_true(GameState.craft(pid, "crafting", "basic_treat").ok)
	assert_eq(p.inventory.count("basic_treat"), before + 1)
	for k in r.in:
		assert_eq(p.inventory.count(k), 0, "used up %s" % k)
	assert_false(GameState.craft(pid, "crafting", "basic_treat").ok, "nothing left to craft with")

func test_craft_pulls_from_farm_chest_at_home() -> void:
	var r: Dictionary = Economy.recipe("crafting", "basic_treat")
	for k in r.in:
		GameState.farm_chest.add(k, int(r.in[k]))
	assert_true(GameState.craft(pid, "crafting", "basic_treat").ok)
	p.map_id = "town"
	for k in r.in:
		GameState.farm_chest.add(k, int(r.in[k]))
	assert_false(GameState.craft(pid, "crafting", "basic_treat").ok, "away from home only the pack counts")

func test_locked_recipe_rejected() -> void:
	var locked := ""
	for id in Data.recipes.crafting:
		if Data.recipes.crafting[id].unlock != "start":
			locked = id
			break
	assert_ne(locked, "")
	var r: Dictionary = Economy.recipe("crafting", locked)
	for k in r.in:
		p.inventory.add(k, int(r.in[k]))
	assert_false(GameState.craft(pid, "crafting", locked).ok)

func test_cooking_needs_kitchen() -> void:
	var r: Dictionary = Economy.recipe("cooking", "garden_salad")
	for k in r.in:
		p.inventory.add(k, int(r.in[k]))
	var res := GameState.craft(pid, "cooking", "garden_salad")
	assert_false(res.ok)
	GameState.world.buildings.append("kitchen")
	assert_true(GameState.craft(pid, "cooking", "garden_salad").ok)

func test_construct_spends_money_and_materials() -> void:
	GameState.add_money(10000)
	p.inventory.add("wood", 100)
	p.inventory.add("stone", 50)
	var m := GameState.money()
	assert_true(GameState.construct(pid, "hatchery").ok)
	assert_true(GameState.has_building("hatchery"))
	assert_eq(GameState.money(), m - int(Data.buildings.hatchery.price))
	assert_eq(p.inventory.count("wood"), 0)
	assert_eq(GameState.hatchery_capacity(), 2)
	assert_false(GameState.construct(pid, "hatchery").ok, "can't build twice")

func test_construct_respects_requirements() -> void:
	GameState.add_money(100000)
	p.inventory.add("hardwood", 50)
	p.inventory.add("iron_bar", 5)
	assert_false(GameState.construct(pid, "deluxe_den").ok, "needs the Big Den first")

func test_upgrade_tool() -> void:
	GameState.add_money(5000)
	assert_false(GameState.upgrade_tool(pid, "hoe").ok, "needs bars")
	p.inventory.add("copper_bar", 5)
	assert_true(GameState.upgrade_tool(pid, "hoe").ok)
	assert_eq(p.tool_level("hoe"), 1)
	assert_eq(p.inventory.count("copper_bar"), 0)

func test_buy_backpack() -> void:
	GameState.add_money(5000)
	var w0 := p.inventory.w
	assert_false(GameState.buy_backpack(pid, 2).ok, "must go in order")
	assert_true(GameState.buy_backpack(pid, 1).ok)
	assert_gt(p.inventory.w, w0)
	assert_eq(p.backpack_level, 1)

func test_deliver_board() -> void:
	assert_gt(GameState.world.board.size(), 0)
	var b: Dictionary = GameState.world.board[0]
	assert_false(GameState.deliver_board(pid, 0).ok)
	p.inventory.add(b.item, int(b.n))
	var m := GameState.money()
	var pts := int(p.relationship(b.from).pts)
	assert_true(GameState.deliver_board(pid, 0).ok)
	assert_eq(GameState.money(), m + int(b.money))
	assert_gt(int(p.relationship(b.from).pts), pts)
	assert_true(b.done)
	p.inventory.add(b.item, int(b.n))
	assert_false(GameState.deliver_board(pid, 0).ok, "only once")

func test_gifts_and_talk_raise_friendship() -> void:
	var vid: String = Data.villagers.keys()[0]
	var st := p.relationship(vid)
	var rng := RandomNumberGenerator.new()
	Relationships.talk(vid, st, "spring", rng)
	assert_gt(int(st.pts), 0)
	var loves: Array = Data.villagers[vid].get("loves", [])
	if loves.size() > 0:
		var before := int(st.pts)
		var res := Relationships.give_gift(vid, st, loves[0], 0, false)
		assert_true(res.ok)
		assert_eq(res.taste, "love")
		assert_gt(int(st.pts), before)
		assert_false(Relationships.give_gift(vid, st, loves[0], 0, false).ok, "one gift a day")

func test_season_rollover_and_weather() -> void:
	for i in Calendar.DAYS_PER_SEASON:
		GameState.end_day()
	assert_eq(GameState.season(), "summer")
	assert_true(GameState.world.weather in ["sun", "rain", "storm", "snow", "fog", "cloudy"])
