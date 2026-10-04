extends GutTest
## Fishing: fish data, what bites where, casting and reeling, gear, crab pots, Gull Bay and its chapter.

var pid := ""
var p: PlayerData

func before_each() -> void:
	GameState.new_game({"seed": 41, "starter": "puddlop"})
	pid = Net.local_id()
	p = GameState.local_player()
	p.energy = p.max_energy

func _water_tile(map_id: String) -> Vector2i:
	var g: FarmGrid = GameState.map_info(map_id).grid
	for y in g.h:
		for x in g.w:
			if g.get_ground(Vector2i(x, y)) in Tiles.WATER_TILES:
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _cast_and_wait(map_id: String, t: Vector2i) -> Dictionary:
	var r: Dictionary = GameState.fish_cast_act(pid, map_id, t)
	if r.ok:
		GameState._hooked[pid].at = float(GameState._hooked[pid].at) - 60.0
	return r

func test_fish_data_is_complete() -> void:
	var problems: Array = []
	assert_between(Data.fish.size(), 40, 60)
	for id in Data.fish:
		var f: Dictionary = Data.fish[id]
		for k in ["name", "where", "seasons", "time", "weather", "w", "diff", "move", "size", "price", "desc"]:
			if not f.has(k):
				problems.append("%s: %s" % [id, k])
		if not Data.items.has(id):
			problems.append("%s: no item" % id)
		if float(f.size[0]) >= float(f.size[1]):
			problems.append("%s: size" % id)
		if Fishing.habitat_text(id) == "":
			problems.append("%s: habitat" % id)
	assert_eq(problems, [])
	assert_eq(Data.fish.values().filter(func(f): return f.get("legendary", false)).size(), 6)
	for e in Data.fish_meta.junk + Data.fish_meta.treasure:
		assert_true(Data.items.has(str(e[0])), "loot item %s" % e[0])
	for kind in Data.fish_meta.wildlings:
		for sid in Data.fish_meta.wildlings[kind]:
			assert_true(Data.species.has(str(sid)), "wildling %s" % sid)
	assert_eq(Data.get_item("smoked:salmon").get("cat", ""), "artisan")
	assert_eq(int(Data.get_item("smoked:salmon").sell), int(Data.get_item("salmon").sell) * 2)

func test_every_water_has_fish_in_every_season() -> void:
	for kind in ["pond", "river", "sea", "mine", "ice"]:
		for s in Calendar.SEASONS:
			var maps := {"mine": "mine:stonehollow"}
			var ids := Fishing.pool(kind, str(maps.get(kind, "")), s, false, "sun", 12, {})
			assert_gt(ids.size(), 0, "%s in %s" % [kind, s])

func test_pool_respects_time_weather_place_and_floor() -> void:
	var day := Fishing.pool("pond", "town", "summer", false, "sun", 0, {})
	var night := Fishing.pool("pond", "town", "summer", true, "sun", 0, {})
	assert_ne(day, night)
	assert_true("jade_koi" in Fishing.pool("pond", "town", "summer", false, "sun", 0, {}, true))
	assert_false("jade_koi" in Fishing.pool("pond", "farm", "summer", false, "sun", 0, {}, true))
	assert_false("jade_koi" in Fishing.pool("pond", "town", "summer", false, "sun", 0, {"jade_koi": {}}, true), "a legend bites once")
	assert_false("abyssal_angler" in Fishing.pool("mine", "mine:stonehollow", "summer", false, "sun", 3, {}, true))
	assert_true("abyssal_angler" in Fishing.pool("mine", "mine:stonehollow", "summer", false, "sun", 10, {}, true))

func test_roll_quality_and_gear_numbers() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var kinds := {}
	for i in 300:
		var c := Fishing.roll({"kind": "sea", "map": "gull_bay", "season": "summer", "night": false, "weather": "sun"}, rng)
		kinds[c.kind] = true
		if c.kind == "fish":
			var f := Fishing.fish(c.id)
			assert_between(float(c.size), float(f.size[0]), float(f.size[1]))
			assert_true(float(c.bite) >= 0.8)
	assert_true(kinds.has("fish") and kinds.has("junk"))
	var f := Fishing.fish("carp")
	assert_eq(Fishing.quality("carp", float(f.size[0]), false, false), 0)
	assert_eq(Fishing.quality("carp", float(f.size[1]), false, false), 3)
	assert_eq(Fishing.quality("carp", float(f.size[0]), true, false), 1)
	assert_eq(Fishing.quality("carp", float(f.size[0]), false, true), 0)
	assert_gt(Fishing.zone_size(3, "cork_bobber", 0.0), Fishing.zone_size(0, "", 0.0))
	assert_lt(Fishing.escape_mult("trap_bobber"), 1.0)
	assert_gt(Fishing.cast_range(3), Fishing.cast_range(0))
	assert_eq(Fishing.rod_spec(Fishing.MAX_ROD + 1), {})

func test_water_kinds() -> void:
	assert_eq(Fishing.water_kind(GameState.map_info("gull_bay"), _water_tile("gull_bay")), "sea")
	assert_eq(Fishing.water_kind(GameState.map_info("farm"), _water_tile("farm")), "pond")
	var ww := GameState.map_info("whisperwood")
	var rx := int(Data.regions.whisperwood.river)
	assert_eq(Fishing.water_kind(ww, Vector2i(rx + 1, 5)), "river")
	assert_eq(Fishing.water_kind(GameState.map_info("farm"), Vector2i(2, 2)), "")

func test_cast_needs_a_rod_and_water() -> void:
	var t := _water_tile("farm")
	assert_false(GameState.fish_cast_act(pid, "farm", t).ok, "no rod yet")
	GameState.give_item(p, "fishing_rod", 1)
	assert_false(GameState.fish_cast_act(pid, "farm", Vector2i(2, 2)).ok, "dry land")
	var e := p.energy
	assert_true(GameState.fish_cast_act(pid, "farm", t).ok)
	assert_lt(p.energy, e)

func test_reeling_in_too_fast_is_rejected() -> void:
	GameState.give_item(p, "fishing_rod", 1)
	var r: Dictionary = GameState.fish_cast_act(pid, "farm", _water_tile("farm"))
	assert_true(r.ok)
	assert_false(GameState.fish_result_act(pid, "caught").ok)
	assert_false(GameState.fish_result_act(pid, "caught").ok, "the hook is gone after one result")

func test_a_catch_lands_in_the_pack_and_the_dex() -> void:
	GameState.give_item(p, "fishing_rod", 1)
	var t := _water_tile("gull_bay")
	var caught := 0
	for i in 40:
		var c := _cast_and_wait("gull_bay", t)
		assert_true(c.ok)
		var r: Dictionary = GameState.fish_result_act(pid, "perfect")
		assert_true(r.ok)
		if r.get("size", 0.0) > 0.0:
			caught += 1
			assert_gt(p.inventory.count(str(r.id)), 0)
			assert_true(p.fishing.dex.has(str(r.id)))
		p.energy = p.max_energy
	assert_gt(caught, 10)
	assert_eq(int(GameState.world.stats.get("fish", 0)), caught)
	assert_eq(Fishing.species_caught(p), p.fishing.dex.size())

func test_lost_and_missed_give_nothing() -> void:
	GameState.give_item(p, "fishing_rod", 1)
	_cast_and_wait("farm", _water_tile("farm"))
	var before := p.inventory.used_cells()
	var r: Dictionary = GameState.fish_result_act(pid, "lost")
	assert_true(r.ok and r.get("lost", false))
	assert_eq(p.inventory.used_cells(), before)

func test_bait_is_used_up_and_tackle_wears() -> void:
	GameState.give_item(p, "fishing_rod", 1)
	GameState.give_item(p, "bait", 2)
	GameState.give_item(p, "spinner", 1)
	var t := _water_tile("farm")
	assert_true(GameState.equip_tackle_act(pid, p.inventory.first_of("bait").uid).ok)
	assert_false(GameState.equip_tackle_act(pid, p.inventory.first_of("spinner").uid).ok, "tackle needs a Gold rod")
	p.tool_levels["fishing_rod"] = 2
	assert_true(GameState.equip_tackle_act(pid, p.inventory.first_of("spinner").uid).ok)
	assert_eq(p.inventory.count("spinner"), 0)
	p.fishing.tackle_uses = 1
	_cast_and_wait("farm", t)
	assert_eq(p.inventory.count("bait"), 1)
	GameState.fish_result_act(pid, "caught")
	assert_false(p.fishing.has("tackle"), "the spinner wore out")
	_cast_and_wait("farm", t)
	GameState.fish_result_act(pid, "lost")
	_cast_and_wait("farm", t)
	assert_false(p.fishing.has("bait"), "out of bait")

func test_rod_upgrade_needs_fish_and_gold() -> void:
	GameState.give_item(p, "fishing_rod", 1)
	GameState.world.money = 100000
	assert_false(GameState.upgrade_rod_act(pid).ok, "needs 5 kinds caught")
	for id in ["carp", "sunfish", "perch", "bream", "chub"]:
		Fishing.record(p, id, 20.0)
	assert_true(GameState.upgrade_rod_act(pid).ok)
	assert_eq(p.tool_level("fishing_rod"), 1)
	assert_lt(int(GameState.world.money), 100000)

func test_crab_pot_catches_on_its_own_and_with_bait() -> void:
	var t := _water_tile("farm")
	var g: FarmGrid = GameState.grid("farm")
	assert_true(g.place_object(t, "crab_pot"))
	assert_false(g.place_object(Vector2i(2, 2), "crab_pot"), "pots go in water")
	var o := g.object_at(t)
	assert_eq(o.kind, "crab_pot")
	var r: Dictionary = GameState.harvest_at(pid, "farm", t)
	assert_false(r.ok, "nothing yet")
	o.next_at = TimeService.now() - Fishing.CRAB_SECONDS * 10
	r = GameState.harvest_at(pid, "farm", t)
	assert_true(r.ok)
	assert_eq(r.fx.size(), Fishing.CRAB_HOLD, "a pot holds three catches")
	GameState.give_item(p, "bait", 1)
	o.next_at = TimeService.now() + Fishing.CRAB_SECONDS
	assert_true(GameState.use_item(pid, "farm", t, p.inventory.first_of("bait").uid).ok)
	assert_lte(float(o.next_at), TimeService.now() + Fishing.CRAB_BAIT_SECONDS + 1.0)

func test_smoker_takes_fish_only() -> void:
	var inv := Inventory.new(6, 4)
	inv.add("salmon", 1)
	inv.add("crab", 1)
	var m := Machines.can_load("smoker", "salmon", 0, inv)
	assert_true(m.ok)
	assert_eq(str(m.output.id), "smoked:salmon")
	assert_false(Machines.can_load("smoker", "crab", 0, inv).ok, "shellfish don't go in")

func test_first_gift_comes_once() -> void:
	assert_true(GameState.first_gift_act(pid, "ansel").ok)
	assert_eq(p.inventory.count("fishing_rod"), 1)
	assert_false(GameState.first_gift_act(pid, "ansel").ok)
	assert_eq(p.inventory.count("fishing_rod"), 1)

func test_gull_bay_opens_with_its_chapter() -> void:
	var i := Adventure.chapter_index("coast")
	assert_eq(i, 4)
	GameState.world.quest = i - 1
	assert_false(GameState.place_open("gull_bay"))
	assert_false(GameState.is_open_requirement("story:coast"))
	GameState.world.quest = i
	assert_true(GameState.place_open("gull_bay"))
	var info := GameState.map_info("gull_bay")
	assert_eq(str(info.get("water", "")), "sea")
	for v in ["ansel", "wren"]:
		for s in Data.villagers[v].schedule:
			assert_eq(str(s[1]), "gull_bay")
			var at := Vector2i(int(s[2]), int(s[3]))
			assert_false(info.grid.is_blocked(at) or info.grid.get_ground(at) in Tiles.WATER_TILES, "%s stands somewhere walkable" % v)
	GameState.world.stats["fish"] = 5
	assert_true(Adventure.goal_done(Adventure.chapter(GameState.world).goal, Adventure.story_facts(GameState.world, p)))

func test_farm_pond_patch_reaches_old_saves() -> void:
	var g: FarmGrid = GameState.grid("farm")
	assert_true(g.get_ground(Vector2i(40, 30)) in Tiles.WATER_TILES)
	assert_true(GameState.world.flags.get("patch:lakeside_pier", false))
	var old: FarmGrid = MapBuilder.build_authored(Data.get_map("farm")).grid
	old.ground[old.idx(Vector2i(40, 30))] = Tiles.GROUND.grass
	MapBuilder.apply_patch(old, Data.get_map("farm").patches[0].ops)
	assert_true(old.get_ground(Vector2i(40, 30)) in Tiles.WATER_TILES)

func test_v3_saves_skip_past_the_new_chapter() -> void:
	var state := {"world": {"quest": 6}}
	SaveManager._migrate_3_to_4(state)
	assert_eq(int(state.world.quest), 7)
	state = {"world": {"quest": 3}}
	SaveManager._migrate_3_to_4(state)
	assert_eq(int(state.world.quest), 3)
