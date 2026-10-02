extends GutTest
## Breeding, economy, relationships, progression, calendar, maps, save roundtrip.

var rng := RandomNumberGenerator.new()

func before_each() -> void:
	rng.seed = 55

func test_breeding_compatibility_and_egg() -> void:
	var a := Creature.create("sproutle", 20, rng)
	var b := Creature.create("bramblet", 20, rng)
	assert_true(Breeding.compatible(a, b))
	var egg := Breeding.make_egg(a, b, rng)
	assert_eq(egg.species, "sproutle")
	for s in Data.STATS:
		assert_between(int(egg.genes[s]), 0, Creature.MAX_GENE)
	var c := Breeding.hatch(egg, rng)
	assert_eq(c.level, 1)
	assert_eq(c.species_id, "sproutle")

func test_guardians_cannot_breed() -> void:
	var a := Creature.create("verdantis", 50, rng)
	var b := Creature.create("sproutle", 20, rng)
	assert_false(Breeding.compatible(a, b))

func test_gene_inheritance_trends() -> void:
	var a := Creature.create("sproutle", 20, rng, {"genes": {"hp": 15, "power": 15, "guard": 15, "focus": 15, "speed": 15}})
	var b := Creature.create("sproutle", 20, rng, {"genes": {"hp": 15, "power": 15, "guard": 15, "focus": 15, "speed": 15}})
	var total := 0
	for i in 50:
		var egg := Breeding.make_egg(a, b, rng)
		for s in Data.STATS:
			total += int(egg.genes[s])
	assert_gt(float(total) / 250.0, 12.0, "Perfect parents produce strong genes")

func test_economy_gates() -> void:
	var ctx := {"shrines": 1, "farm_level": 3, "hearts": {"mira": 4}, "buildings": ["hatchery"]}
	assert_true(Economy.meets("shrine:1", ctx))
	assert_false(Economy.meets("shrine:2", ctx))
	assert_true(Economy.meets("level:3", ctx))
	assert_true(Economy.meets("hearts:mira:3", ctx))
	assert_true(Economy.meets("hatchery", ctx))
	var stock := Economy.shop_stock("general_store", "spring", ctx)
	var ids: Array = stock.map(func(s): return s.id)
	assert_has(ids, "parsnip_seeds")
	assert_has(ids, "cherry_sapling")

func test_traveler_deterministic() -> void:
	var a := Economy.shop_stock("traveler", "spring", {}, 4, 99)
	var b := Economy.shop_stock("traveler", "spring", {}, 4, 99)
	assert_eq(JSON.stringify(a), JSON.stringify(b))
	assert_eq(a.size(), 6)

func test_crafting_consumes() -> void:
	var inv := Inventory.new(6, 6)
	inv.add("wood", 60)
	assert_true(Economy.make("crafting", "chest", [inv]))
	assert_eq(inv.count("wood"), 10)
	assert_eq(inv.count("chest"), 1)
	assert_false(Economy.make("crafting", "chest", [inv]))

func test_relationships() -> void:
	var st := Relationships.new_state()
	var r := Relationships.give_gift("mira", st, "strawberry", 0, false)
	assert_true(r.ok)
	assert_eq(r.taste, "love")
	assert_false(Relationships.give_gift("mira", st, "parsnip", 0, false).ok, "one gift per day")
	st.pts = 8 * Relationships.PTS_PER_HEART + 500
	Relationships.add_points("theo", st, 9999)
	assert_lte(Relationships.hearts(st), 8, "romanceable capped at 8 until dating")

func test_heart_events() -> void:
	var st := Relationships.new_state()
	st.pts = 2 * Relationships.PTS_PER_HEART
	assert_eq(Relationships.pending_event("mira", st), "2")
	st.events.append("2")
	assert_eq(Relationships.pending_event("mira", st), "")

func test_farm_level() -> void:
	var st := {"level": 1, "xp": 0}
	var ups := Progression.add_farm_xp(st, 10000)
	assert_gt(ups.size(), 2)
	assert_eq(int(st.level), 1 + ups.size())

func test_weekly_challenges() -> void:
	var w := Progression.weekly_for(3, 77)
	assert_eq(w.size(), 3)
	var w2 := Progression.weekly_for(3, 77)
	assert_eq(JSON.stringify(w), JSON.stringify(w2))
	var c: Dictionary = w[0]
	var done := Progression.bump(w, c.stat, int(c.n))
	assert_eq(done.size(), 1)

func test_calendar() -> void:
	assert_eq(Calendar.season(0), "spring")
	assert_eq(Calendar.season(28), "summer")
	assert_eq(Calendar.year(112), 2)
	assert_eq(Calendar.time_string(390), "6:30am")
	assert_eq(Calendar.festival_on(12), "egg_hunt")

func test_region_generation_deterministic() -> void:
	var a := MapBuilder.build_region("whisperwood", 5)
	var b := MapBuilder.build_region("whisperwood", 5)
	assert_eq(a.grid.deco, b.grid.deco)
	assert_false(a.grid.is_blocked(Vector2i(1, 17)), "entrance walkable")

func test_mine_has_reachable_ladder() -> void:
	for fl in [1, 5, 20]:
		var m := MapBuilder.build_mine("stonehollow", fl, 3, 10)
		var g: FarmGrid = m.grid
		var start := Vector2i(int(m.entry[0]), int(m.entry[1]))
		var goal := Vector2i(int(m.ladder[0]), int(m.ladder[1]))
		var seen := {start: true}
		var q: Array = [start]
		var found := false
		while not q.is_empty():
			var p: Vector2i = q.pop_front()
			if p == goal:
				found = true
				break
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = p + d
				if g.in_bounds(n) and not seen.has(n):
					var deco := g.get_deco(n)
					var passable := not g.is_blocked(n) or deco in [Tiles.DECO.rock, Tiles.DECO.ore] or n == goal
					if passable:
						seen[n] = true
						q.append(n)
		assert_true(found, "ladder reachable on floor %d" % fl)

func test_spawn_picker_respects_conditions() -> void:
	var spawns := [["sproutle", 10, {"t": "day"}], ["shadeling", 10, {"t": "night"}]]
	for i in 20:
		assert_eq(MapBuilder.pick_spawn(spawns, "spring", "sun", false, rng), "sproutle")
		assert_eq(MapBuilder.pick_spawn(spawns, "spring", "sun", true, rng), "shadeling")

func test_game_state_save_roundtrip() -> void:
	GameState.new_game({"seed": 42, "player_name": "Tess", "starter": "sproutle"})
	var p := GameState.local_player()
	p.inventory.add("wood", 20)
	GameState.grids.farm.till(Vector2i(4, 12))
	GameState.add_money(250)
	var d: Dictionary = JSON.parse_string(JSON.stringify(GameState.to_dict()))
	GameState.from_dict(d)
	var p2 := GameState.local_player()
	assert_eq(p2.name, "Tess")
	assert_eq(p2.inventory.count("wood"), 20)
	assert_eq(p2.party[0].species_id, "sproutle")
	assert_true(GameState.grids.farm.is_tilled(Vector2i(4, 12)))
	assert_eq(GameState.money(), 750)

func test_end_day_progresses() -> void:
	GameState.new_game({"seed": 42})
	var p := GameState.local_player()
	var g: FarmGrid = GameState.grids.farm
	var t := Vector2i(4, 12)
	g.till(t)
	g.plant(t, "parsnip_seeds", "spring")
	g.water(t)
	GameState.world.shipping.append({"id": "parsnip", "n": 5, "q": 0})
	var m0 := GameState.money()
	var rep := GameState.end_day()
	assert_eq(GameState.day(), 1)
	assert_gt(GameState.money(), m0)
	assert_gt(int(rep.ship_total), 0)
	assert_gt(float(g.crop_at(t).age), 0.0)
	assert_eq(p.energy, p.max_energy)

func test_world_actions() -> void:
	GameState.new_game({"seed": 1})
	var pid := Net.local_id()
	var g: FarmGrid = GameState.grids.farm
	var t := Vector2i(5, 12)
	g.set_deco(t, 0)
	assert_true(GameState.use_tool(pid, "farm", t, "hoe").ok)
	var p := GameState.local_player()
	var seeds: Dictionary = p.inventory.first_of("parsnip_seeds")
	assert_true(GameState.use_item(pid, "farm", t, seeds.uid).ok)
	assert_true(GameState.use_tool(pid, "farm", t, "watering_can").ok)
	assert_eq(p.inventory.count("parsnip_seeds"), 14)
