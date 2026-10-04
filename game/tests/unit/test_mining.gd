extends GutTest
## Mining: deep layers, block hardness, saved diffs, placing and blasting, geodes, the museum and Eisenkamm.

var pid := ""
var p: PlayerData

func before_each() -> void:
	GameState.new_game({"seed": 77, "starter": "puddlop"})
	pid = Net.local_id()
	p = GameState.local_player()
	p.energy = p.max_energy

func _find(g: FarmGrid, test: Callable) -> Vector2i:
	for y in g.h:
		for x in g.w:
			if test.call(Vector2i(x, y)):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _open_tile(g: FarmGrid) -> Vector2i:
	return _find(g, func(t): return g.get_deco(t) == 0 and g.get_ground(t) == Tiles.GROUND.cave and t.distance_to(Vector2(Mining.LANDING)) > 3)

func test_layer_data_is_valid() -> void:
	assert_eq(Mining.layer_count(), 5)
	var last := -1
	for i in Mining.layer_count():
		var L := Mining.layer_spec(i + 1)
		assert_gte(int(L.min_pick), last, "layer %d gets harder" % (i + 1))
		last = int(L.min_pick)
		for s in L.spawns:
			assert_true(Data.species.has(str(s[0])), "layer %d spawn %s" % [i + 1, s[0]])
		for m in L.get("materials", []):
			assert_true(Tiles.DECO.has(str(m)), "layer %d material %s" % [i + 1, m])
	assert_true(Mining.layer_spec(5).has("boss"))
	assert_true(Data.species.has(str(Mining.layer_spec(5).boss.species)))

func test_layers_build_the_same_from_the_seed() -> void:
	for layer in [1, 3, 5]:
		var a: Dictionary = Mining.build_layer(layer, 1234)
		var b: Dictionary = Mining.build_layer(layer, 1234)
		assert_eq(a.grid.ground, b.grid.ground, "layer %d ground" % layer)
		assert_eq(a.grid.deco, b.grid.deco, "layer %d deco" % layer)
		assert_eq(a.grid.get_deco(Mining.LADDER_UP), Tiles.DECO.ladder_up)
		assert_eq(a.grid.get_deco(Mining.ELEVATOR), Tiles.DECO.elevator)
		assert_eq(a.grid.get_deco(Mining.LANDING), 0, "the landing is open")
		var blocks := 0
		for d in a.grid.deco:
			if Mining.is_block(d):
				blocks += 1
		assert_gt(blocks, a.grid.w * a.grid.h / 4, "layer %d is mostly rock" % layer)
	assert_ne(Mining.build_layer(2, 1).grid.deco, Mining.build_layer(2, 2).grid.deco, "a different seed digs a different cave")

func test_diffs_roundtrip_and_stay_small() -> void:
	var base: FarmGrid = Mining.build_layer(1, 5).grid
	var now: FarmGrid = Mining.build_layer(1, 5).grid
	assert_eq(Mining.encode_diff(base, now), "", "an untouched layer saves nothing")
	for x in range(10, 30):
		now.set_deco(Vector2i(x, 20), 0)
	now.set_deco(Vector2i(12, 12), Tiles.DECO.torch)
	var diff := Mining.encode_diff(base, now)
	assert_ne(diff, "")
	assert_lt(diff.length(), 400, "a tunnel costs a few hundred bytes")
	var fresh: FarmGrid = Mining.build_layer(1, 5).grid
	Mining.apply_diff(fresh, diff)
	assert_eq(fresh.deco, now.deco)
	assert_eq(fresh.ground, now.ground)

func test_hard_blocks_need_a_better_pickaxe() -> void:
	var info := GameState.map_info("deep:1")
	var g: FarmGrid = info.grid
	var t := _open_tile(g)
	g.set_deco(t, Tiles.DECO.obsidian)
	var r := GameState._mine_block(p, "deep:1", g, info, t, 0)
	assert_false(r.ok)
	assert_ne(r.reason, "", "it says why")
	assert_eq(g.get_deco(t), Tiles.DECO.obsidian)

func test_dirt_breaks_and_drops_and_is_saved() -> void:
	var info := GameState.map_info("deep:1")
	var g: FarmGrid = info.grid
	var t := _find(g, func(q): return g.get_deco(q) == Tiles.DECO.dirtblock and not info.get("ore_types", {}).has(Tiles.key(q)))
	assert_ne(t, Vector2i(-1, -1), "the clay layer has dirt")
	var before := int(p.stats.get("mined", 0))
	for i in 4:
		if g.get_deco(t) == 0:
			break
		assert_true(GameState._mine_block(p, "deep:1", g, info, t, 1).ok)
	assert_eq(g.get_deco(t), 0, "dirt breaks with a copper pickaxe")
	assert_eq(int(p.stats.get("mined", 0)), before + 1)
	assert_ne(str(GameState.world.mining.layers.get("1", "")), "", "the change is stored as a diff")
	GameState._map_cache.clear()
	assert_eq(GameState.grid("deep:1").get_deco(t), 0, "the dug tile survives a rebuild")

func test_placing_torches_and_ladders() -> void:
	var g := GameState.grid("deep:1")
	var t := _open_tile(g)
	GameState.give_item(p, "torch", 2)
	GameState.give_item(p, "mine_ladder", 1)
	assert_true(GameState.use_item(pid, "deep:1", t, p.inventory.first_of("torch").uid).ok)
	assert_eq(g.get_deco(t), Tiles.DECO.torch)
	assert_false(GameState.use_item(pid, "deep:1", t, p.inventory.first_of("torch").uid).ok, "not on top of another")
	assert_false(GameState.use_item(pid, "farm", Vector2i(5, 5), p.inventory.first_of("torch").uid).ok, "torches are for mines")
	var t2 := _find(g, func(q): return g.get_deco(q) == 0 and g.get_ground(q) == Tiles.GROUND.cave and q != t and q.distance_to(Vector2(Mining.LANDING)) > 3)
	assert_true(GameState.use_item(pid, "deep:1", t2, p.inventory.first_of("mine_ladder").uid).ok)
	assert_eq(g.get_deco(t2), Tiles.DECO.ladder)

func test_ladder_down_needs_the_pickaxe_and_records_depth() -> void:
	var g := GameState.grid("deep:1")
	var t := _open_tile(g)
	g.set_deco(t, Tiles.DECO.ladder)
	assert_false(GameState.deep_enter_act(pid, 2, 0, 0, "elevator").ok, "the lift only goes where you've been")
	p.tool_levels["pickaxe"] = 0
	assert_false(GameState.deep_enter_act(pid, 2, t.x, t.y, "ladder").ok, "layer 2 needs copper")
	p.tool_levels["pickaxe"] = 1
	var r := GameState.deep_enter_act(pid, 2, t.x, t.y, "ladder")
	assert_true(r.ok)
	assert_true(r.get("new_layer", false))
	assert_eq(GameState.deep_max(), 2)
	assert_eq(GameState.grid("deep:2").get_deco(t), Tiles.DECO.ladder_up)
	assert_eq(Vector2i(int(r.to[0]), int(r.to[1])), t + Vector2i(0, 1))
	assert_true(GameState.deep_enter_act(pid, 2, 0, 0, "elevator").ok)
	Quests.start(p, "brannoc_crystal", 0.0)
	assert_eq(Quests.progress(p, GameState.world, "brannoc_crystal"), [2, 3])

func test_bombs_clear_soft_rock_around_them() -> void:
	var info := GameState.map_info("deep:1")
	var g: FarmGrid = info.grid
	var t := _open_tile(g)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1)]:
		g.set_deco(t + d, Tiles.DECO.stoneblock)
	GameState.give_item(p, "cherry_bomb", 1)
	assert_true(GameState.use_item(pid, "deep:1", t, p.inventory.first_of("cherry_bomb").uid).ok)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1)]:
		assert_eq(g.get_deco(t + d), 0)
	assert_eq(p.inventory.count("cherry_bomb"), 0)

func test_geologist_cracks_geodes() -> void:
	GameState.give_item(p, "geode", 3)
	GameState.add_money(1000)
	var gold := GameState.money()
	var r := GameState.crack_geode_act(pid, 3)
	assert_true(r.ok)
	var n := 0
	for k in r.loot:
		assert_true(Data.has_item(k))
		n += int(r.loot[k])
	assert_eq(n, 3)
	assert_eq(GameState.money(), gold - 75)
	assert_eq(p.inventory.count("geode"), 0)
	assert_false(GameState.crack_geode_act(pid, 1).ok)

func test_museum_takes_each_find_once_and_pays_milestones() -> void:
	for id in ["quartz", "ammonite", "obsidian", "amber_drop"]:
		GameState.give_item(p, id, 2)
	var gold := GameState.money()
	var r := GameState.donate_museum_act(pid)
	assert_true(r.ok)
	assert_eq(r.given.size(), 4)
	assert_eq(int(r.get("milestone", 0)), 4)
	assert_gt(GameState.money(), gold, "the first milestone pays out")
	assert_eq(p.inventory.count("quartz"), 1)
	assert_false(GameState.donate_museum_act(pid).ok, "nothing new the second time")
	Quests.start(p, "opal_museum", 0.0)
	assert_eq(Quests.progress(p, GameState.world, "opal_museum"), [4, 8])

func test_every_mining_item_and_recipe_exists() -> void:
	for id in Mining.MUSEUM + Mining.GEODE_LOOT.map(func(e): return e[0]):
		assert_true(Data.has_item(str(id)), "item %s" % id)
	for id in ["torch", "mine_ladder", "support_beam", "stone_block", "rail", "minecart", "cherry_bomb", "mega_bomb", "drill", "crystal_sprinkler"]:
		assert_true(Data.recipes.crafting.has(id), "recipe %s" % id)
		assert_true(ResourceLoader.exists("res://assets/items/%s.png" % id), "icon %s" % id)

func test_regional_mines_have_breakable_walls_with_ore() -> void:
	var info: Dictionary = MapBuilder.build("mine:stonehollow:3:1", 9)
	var g: FarmGrid = info.grid
	var blocks := 0
	var veins := 0
	for d in g.deco:
		if Mining.BLOCKS.has(d):
			blocks += 1
		if d == Tiles.DECO.vein:
			veins += 1
	assert_gt(blocks, 50)
	assert_gt(veins, 0)

func test_eisenkamm_opens_with_the_mountain_chapter() -> void:
	assert_false(GameState.place_open("eisenkamm"))
	GameState.world.quest = Adventure.chapter_index("mountain")
	assert_true(GameState.place_open("eisenkamm"))
	var m: Dictionary = GameState.map_info("eisenkamm")
	assert_eq(m.get("music", ""), "mining_town")
	for vid in ["brannoc", "hilde", "opal", "tobin"]:
		assert_true(Data.villagers.has(vid))
		assert_true(ResourceLoader.exists("res://assets/portraits/%s.png" % vid), "portrait %s" % vid)

func test_v4_saves_shift_past_the_new_chapters() -> void:
	for pair in [[3, 3], [8, 9], [11, 12], [12, 14], [13, 15]]:
		var state := {"world": {"quest": pair[0]}}
		SaveManager._migrate_4_to_5(state)
		assert_eq(int(state.world.quest), pair[1], "old chapter %d" % pair[0])
	assert_eq(int(Adventure.chapters()[Adventure.chapter_index("heart")].goal.deep_boss), 1)
