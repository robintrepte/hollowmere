extends GutTest
## Enchanting: seeded table offers, bookshelf power, the anvil and grindstone, and what the
## enchantments actually change.

var pid := ""
var p: PlayerData
var g: FarmGrid

func before_each() -> void:
	GameState.new_game({"seed": 31, "starter": "puddlop"})
	pid = Net.local_id()
	p = GameState.local_player()
	g = GameState.grid("farm")

func _free_tile(skip: Array = []) -> Vector2i:
	for y in range(4, g.h - 4):
		for x in range(4, g.w - 4):
			var t := Vector2i(x, y)
			if not g.is_blocked(t) and not g.is_tilled(t) and g.object_at(t).is_empty() and not t in skip:
				return t
	return Vector2i(-1, -1)

func _station(id: String) -> Vector2i:
	var t := _free_tile()
	assert_true(g.place_object(t, id), "placed %s" % id)
	return t

func test_data_is_consistent() -> void:
	for id in Data.enchants.enchants:
		var e: Dictionary = Data.enchants.enchants[id]
		assert_gt(int(e.max), 0, id)
		assert_false(e.tools.is_empty(), id)
		for tl in e.tools:
			assert_true(tl in Enchanting.tools(), "%s on %s" % [id, tl])
			assert_true(Data.has_item(tl), tl)
		for tl in e.get("mods", {}):
			assert_true(tl in e.tools, "%s mods only its own tools" % id)
	for tl in Enchanting.tools():
		assert_gte(Enchanting.for_tool(tl).size(), 1, "%s has an enchantment" % tl)
	for id in ["arcane_essence", "glimmer_dust", "enchanting_table", "anvil", "grindstone", "bookshelf"]:
		assert_true(Data.has_item(id), id)
		assert_true(Data.recipes.crafting.has(id), "%s is craftable" % id)

func test_offers_are_seeded_and_scale_with_shelves() -> void:
	var a := Enchanting.offers(p, "pickaxe", 0)
	assert_eq(a.size(), 3)
	assert_eq(a, Enchanting.offers(p, "pickaxe", 0), "same seed, same offers")
	for o in a:
		for id in o.enchants:
			assert_true("pickaxe" in Enchanting.spec(id).tools, id)
			assert_eq(int(o.enchants[id]), 1, "a bare table only rolls level I")
	assert_lte(int(a[0].essence), int(a[2].essence), "the last offer costs the most")
	assert_eq(Enchanting.power(0), 1)
	assert_eq(Enchanting.power(3), 2)
	assert_eq(Enchanting.power(6), 3)
	assert_eq(Enchanting.power(40), 3)
	var top := 0
	for o in Enchanting.offers(p, "pickaxe", 6):
		for id in o.enchants:
			top = maxi(top, int(o.enchants[id]))
	assert_gt(top, 1, "six shelves unlock stronger levels")
	var cheap := Enchanting.offers(p, "pickaxe", 0, 0.5)
	assert_lte(int(cheap[2].dust), int(a[2].dust), "enchant_cost discount lowers prices")

func test_shelves_are_counted_around_the_table() -> void:
	var t := _station("enchanting_table")
	assert_eq(Enchanting.shelves_near(g, t), 0)
	var placed := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 2), Vector2i(3, 3), Vector2i(5, 0)]:
		if g.place_object(t + d, "bookshelf") and d.x <= 3:
			placed += 1
	assert_eq(Enchanting.shelves_near(g, t), placed, "only shelves within three tiles count")

func test_enchanting_a_tool_spends_materials_and_rerolls() -> void:
	var t := _station("enchanting_table")
	var before := GameState.enchant_offers(pid, "farm", t.x, t.y, "hoe")
	assert_eq(before.size(), 3)
	assert_false(GameState.enchant_act(pid, "farm", t.x, t.y, "hoe", 0).ok, "no essence, no enchantment")
	p.inventory.add("arcane_essence", 20)
	p.inventory.add("glimmer_dust", 20)
	assert_false(GameState.enchant_act(pid, "farm", t.x + 1, t.y, "hoe", 0).ok, "needs the table")
	var r := GameState.enchant_act(pid, "farm", t.x, t.y, "hoe", 1)
	assert_true(r.ok, str(r.reason))
	assert_eq(Enchanting.on_tool(p, "hoe"), before[1].enchants)
	assert_eq(p.inventory.count("arcane_essence"), 20 - int(before[1].essence))
	assert_eq(p.inventory.count("glimmer_dust"), 20 - int(before[1].dust))
	assert_false(GameState.enchant_act(pid, "farm", t.x, t.y, "hoe", 0).ok, "already enchanted")
	assert_ne(Enchanting.offers(p, "watering_can", 0), [], "other tools still get offers")
	assert_eq(int(p.flags.enchant_seed), 1, "the next offers are new")

func test_books_apply_and_combine_at_the_anvil() -> void:
	var t := _station("anvil")
	p.inventory.add("arcane_essence", 20)
	p.inventory.add(Enchanting.book_id("efficiency", 1), 2)
	var r := GameState.anvil_act(pid, "farm", t.x, t.y, "combine", "pickaxe", Enchanting.book_id("efficiency", 1))
	assert_true(r.ok, str(r.reason))
	assert_eq(r.book, Enchanting.book_id("efficiency", 2))
	assert_eq(p.inventory.count(Enchanting.book_id("efficiency", 2)), 1)
	r = GameState.anvil_act(pid, "farm", t.x, t.y, "apply", "pickaxe", Enchanting.book_id("efficiency", 2))
	assert_true(r.ok, str(r.reason))
	assert_eq(Enchanting.level(p, "pickaxe", "efficiency"), 2)
	assert_eq(p.inventory.count("arcane_essence"), 20 - 1 - 2)
	p.inventory.add(Enchanting.book_id("lure", 1))
	assert_false(GameState.anvil_act(pid, "farm", t.x, t.y, "apply", "pickaxe", Enchanting.book_id("lure", 1)).ok, "wrong tool")

func test_apply_book_rules() -> void:
	assert_eq(Enchanting.apply_book({}, "pickaxe", "fortune", 1).enchants, {"fortune": 1})
	assert_eq(Enchanting.apply_book({"fortune": 1}, "pickaxe", "fortune", 1).enchants, {"fortune": 2}, "same level stacks up")
	assert_eq(Enchanting.apply_book({"fortune": 1}, "pickaxe", "fortune", 3).enchants, {"fortune": 3}, "a stronger book replaces")
	assert_false(Enchanting.apply_book({"fortune": 3}, "pickaxe", "fortune", 3).ok, "capped at max")
	assert_false(Enchanting.apply_book({"fortune": 2}, "pickaxe", "fortune", 1).ok, "a weaker book does nothing")
	assert_false(Enchanting.apply_book({"fortune": 1, "efficiency": 1, "extra": 1}, "pickaxe", "gentle", 1).ok, "three at most")
	assert_eq(Enchanting.combine_books("book:gentle:1"), "", "max-1 books don't combine")
	assert_eq(Enchanting.parse_book("book:nope:1"), [])
	assert_eq(Enchanting.parse_book("book:efficiency:9"), ["efficiency", 3], "levels are clamped")
	assert_string_contains(Data.item_name("book:efficiency:2"), "II")
	assert_eq(Data.get_item("book:efficiency:2").get("cat", ""), "book")

func test_grindstone_refunds_half() -> void:
	var t := _station("grindstone")
	p.tool_enchants["axe"] = {"efficiency": 3, "lumberjack": 1}
	var have := p.inventory.count("arcane_essence")
	var r := GameState.grindstone_act(pid, "farm", t.x, t.y, "axe")
	assert_true(r.ok)
	assert_eq(int(r.refund), 2)
	assert_false(Enchanting.has_any(p, "axe"))
	assert_eq(p.inventory.count("arcane_essence"), have + 2)
	assert_false(GameState.grindstone_act(pid, "farm", t.x, t.y, "axe").ok, "nothing left to grind")

func test_enchantments_feed_modifiers() -> void:
	var speed := Modifiers.mult(p, "mine_speed")
	var cap := p.water_capacity()
	p.tool_enchants["pickaxe"] = {"efficiency": 2}
	p.tool_enchants["watering_can"] = {"abundance": 2}
	p.tool_enchants["fishing_rod"] = {"lure": 1}
	assert_almost_eq(Modifiers.mult(p, "mine_speed"), speed + 0.5, 0.001)
	assert_almost_eq(Modifiers.value(p, "fish_bite"), 0.12, 0.001)
	assert_eq(p.water_capacity(), cap + 30)

func test_shovel_and_deep_dig_extend_trenches() -> void:
	GameState._apply_relief(p)
	assert_eq(g.trench_extra, 0)
	p.tool_levels["shovel"] = 2
	p.tool_enchants["shovel"] = {"deep_dig": 2}
	GameState._apply_relief(p)
	assert_eq(g.trench_extra, 10, "two shovel tiers and Deep Dig II")

func test_wide_furrow_tills_three() -> void:
	p.tool_enchants["hoe"] = {"wide_furrow": 1}
	var t := Vector2i(-1, -1)
	for y in range(4, g.h - 4):
		for x in range(4, g.w - 4):
			var c := Vector2i(x, y)
			if [c, c + Vector2i(1, 0), c - Vector2i(1, 0)].all(func(q): return not g.is_blocked(q) and not g.is_tilled(q) and g.object_at(q).is_empty()):
				t = c
				break
		if t.x >= 0:
			break
	assert_true(GameState.use_tool(pid, "farm", t, "hoe").ok)
	assert_true(g.is_tilled(t + Vector2i(1, 0)) and g.is_tilled(t - Vector2i(1, 0)), "both neighbours tilled")

func test_enchantments_survive_save() -> void:
	p.tool_enchants["scythe"] = {"sweep": 1}
	p.tool_enchants["pickaxe"] = {"fortune": 2, "gentle": 1}
	var q := PlayerData.from_dict(p.to_dict())
	assert_eq(q.tool_enchants, p.tool_enchants)
	assert_eq(Enchanting.level(q, "pickaxe", "fortune"), 2)

func test_battle_spoils_and_loot_books() -> void:
	var got := 0
	for i in 60:
		var r := GameState.battle_spoils_act(pid, "trainer", 20)
		got += int(r.get("essence", 0))
	assert_gt(got, 0, "trainers drop essence now and then")
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var books := 0
	for i in 100:
		for k in Adventure.treasure_loot("stonehollow", 3, rng):
			if str(k).begins_with("book:"):
				books += 1
				assert_true(Data.has_item(k), k)
	assert_gt(books, 0, "chests sometimes hold books")
	var grand := Adventure.treasure_loot("stonehollow", 10, rng, true)
	assert_true(grand.keys().any(func(k): return str(k).begins_with("book:")), "grand chests always do")
