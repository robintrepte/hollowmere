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

func test_default_pack_is_nine_by_five() -> void:
	assert_eq([p.inventory.w, p.inventory.h], [9, 5])
	assert_eq(p.backpack, "pack_rucksack")

func test_buy_backpack() -> void:
	GameState.add_money(5000)
	var w0 := p.inventory.w
	assert_false(GameState.buy_backpack(pid, "pack_explorer").ok, "needs restored shrines")
	assert_true(GameState.buy_backpack(pid, "pack_farmer").ok)
	assert_gt(p.inventory.w, w0)
	assert_eq(p.backpack, "pack_farmer")
	assert_false(GameState.buy_backpack(pid, "pack_farmer").ok, "already owned")

func test_switching_packs_keeps_items_and_bonuses() -> void:
	GameState.add_money(20000)
	GameState.world.farm.level = 4
	assert_true(GameState.buy_backpack(pid, "pack_gardener").ok)
	assert_almost_eq(Modifiers.value(p, "crop_growth"), 0.05, 0.001)
	p.inventory.add("kale_seeds", 3)
	assert_true(GameState.equip_backpack(pid, "pack_rucksack").ok)
	assert_eq(p.inventory.count("kale_seeds"), 3)
	assert_almost_eq(Modifiers.value(p, "crop_growth"), 0.0, 0.001)

func test_switching_to_a_smaller_pack_fails_when_full() -> void:
	GameState.add_money(5000)
	assert_true(GameState.buy_backpack(pid, "pack_farmer").ok)
	var i := 0
	while p.inventory.find_space("stone").size() > 0 and i < 200:
		p.inventory.add("stone", 999)
		i += 1
	var w := p.inventory.w
	assert_false(GameState.equip_backpack(pid, "pack_rucksack").ok)
	assert_eq(p.inventory.w, w, "nothing changed")

func test_old_backpack_level_becomes_owned_packs() -> void:
	var d := p.to_dict()
	d.erase("backpack")
	d.erase("packs")
	d["backpack_level"] = 2
	var q := PlayerData.from_dict(d)
	assert_eq(q.backpack, "pack_explorer")
	assert_eq(q.packs, ["pack_rucksack", "pack_farmer", "pack_explorer"])
	assert_eq([q.inventory.w, q.inventory.h], [12, 7])

func _top_count(inv: Inventory, id: String) -> int:
	var n := 0
	for e in inv.entries:
		if e.id == id:
			n += int(e.n)
	return n

func test_buy_lands_in_the_backpack() -> void:
	GameState.add_money(20000)
	var m := GameState.money()
	p.inventory.add("kale_seeds", 2)
	var pouch: Dictionary = p.inventory.first_of("seed_pouch")
	assert_eq(pouch.inv.count("kale_seeds"), 2, "picked-up seeds still file into the pouch")
	var r := GameState.buy(pid, "general_store", "kale_seeds", 3)
	assert_true(r.ok, r.get("reason", ""))
	assert_eq(GameState.money(), m - int(Data.buy_price("kale_seeds")) * 3)
	assert_eq(_top_count(p.inventory, "kale_seeds"), 3, "the purchase is visible in the pack")
	assert_eq(pouch.inv.count("kale_seeds"), 2, "the pouch keeps only what was already in it")
	var sap := GameState.buy(pid, "general_store", "cherry_sapling", 1)
	assert_true(sap.ok, sap.get("reason", ""))
	assert_eq(_top_count(p.inventory, "cherry_sapling"), 1)
	assert_eq(pouch.inv.count("cherry_sapling"), 0)

func test_buy_overflow_goes_into_the_matching_bag() -> void:
	GameState.add_money(5000)
	var inv := Inventory.new(2, 1)
	assert_eq(inv.add("seed_pouch", 1), 0)
	assert_eq(inv.add("fiber", 20), 0)
	p.inventory = inv
	var r := GameState.buy(pid, "general_store", "potato_seeds", 4)
	assert_true(r.ok, r.get("reason", ""))
	assert_eq(_top_count(inv, "potato_seeds"), 0)
	assert_eq(inv.first_of("seed_pouch").inv.count("potato_seeds"), 4)
	assert_eq(str(r.note), tr("Bought %d %s (in %s)") % [4, Data.item_name("potato_seeds"), Data.item_name("seed_pouch")])

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

func test_game_days_leave_the_real_season_alone() -> void:
	for i in Calendar.DAYS_PER_SEASON:
		GameState.end_day()
	assert_eq(GameState.season(), "spring", "seasons follow the calendar, not the day counter")
	assert_true(GameState.world.weather in ["sun", "rain", "storm", "snow", "fog", "cloudy"])
