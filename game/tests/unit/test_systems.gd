extends GutTest
## Breeding, economy, relationships, progression, calendar, maps, save roundtrip.

var rng := RandomNumberGenerator.new()
var _autosave_slot := -1

func before_each() -> void:
	rng.seed = 55

func after_each() -> void:
	SaveManager.live = false
	SaveManager.set_quiet(false)
	if _autosave_slot >= 0:
		if SaveManager.current_slot == _autosave_slot:
			SaveManager.current_slot = -1
		SaveManager.delete_slot(_autosave_slot)
		_autosave_slot = -1

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

func test_shipping_bin_can_be_emptied_before_it_sells() -> void:
	GameState.new_game({"seed": 7})
	var p := GameState.local_player()
	p.inventory.add("parsnip", 4)
	var e: Dictionary = p.inventory.first_of("parsnip")
	assert_true(GameState.ship(p.id, e.uid).ok)
	assert_eq(GameState.shipping_bin.count("parsnip"), 4)
	assert_eq(p.inventory.count("parsnip"), 0)
	var back: Dictionary = GameState.shipping_bin.first_of("parsnip")
	var taken := GameState.shipping_bin.take(back.uid, 2)
	p.inventory.add(taken.id, int(taken.n), int(taken.q), taken.meta)
	assert_eq(p.inventory.count("parsnip"), 2)
	assert_eq(GameState.shipping_bin.count("parsnip"), 2)
	var hoe: Dictionary = p.inventory.first_of("hoe")
	assert_false(GameState.ship(p.id, hoe.uid).ok, "tools stay in the pack")
	var m0 := GameState.money()
	var rep := GameState.end_day()
	assert_eq(GameState.shipping_bin.count("parsnip"), 0)
	assert_eq(int(rep.ship_total), Data.sell_price("parsnip", 0) * 2)
	assert_eq(GameState.money() - m0, int(rep.ship_total))
	# A save from before the bin was a grid still loads those goods into it.
	GameState.world.shipping.append({"id": "parsnip", "n": 3, "q": 1})
	var d: Dictionary = JSON.parse_string(JSON.stringify(GameState.to_dict()))
	GameState.from_dict(d)
	assert_eq(GameState.shipping_bin.count("parsnip"), 3)
	assert_eq(int(GameState.shipping_bin.first_of("parsnip").q), 1)
	assert_eq(GameState.world.shipping.size(), 0)

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
	p.energy = 10.0
	var rep := GameState.end_day()
	assert_eq(GameState.day(), 1)
	assert_gt(GameState.money(), m0)
	assert_gt(int(rep.ship_total), 0)
	assert_eq(p.energy, p.max_energy, "sleeping refills energy")
	var to := float(GameState.world.time.last) + 600.0
	TimeService.fixed_now = to
	GameState.idle_advance(to)
	TimeService.fixed_now = -1.0
	assert_gt(float(g.crop_at(t).progress), 0.0, "crops grow with the real clock")

func test_night_rolls_over_at_six_without_passing_out() -> void:
	GameState.new_game({"seed": 43})
	var p := GameState.local_player()
	p.map_id = "town"
	GameState.world.minute = Calendar.DAY_END
	GameState.advance_minutes(10)
	assert_eq(GameState.day(), 0, "2:00 no longer knocks you out")
	assert_eq(p.map_id, "town")
	GameState.world.minute = Calendar.NIGHT_ROLLOVER - 10
	GameState.advance_minutes(10)
	assert_eq(GameState.day(), 1, "the day turns over at 6:00")
	assert_eq(GameState.minute(), Calendar.DAY_START)
	assert_eq(p.map_id, "town", "you stay where you are")

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
	assert_false(GameState.use_tool(pid, "farm", t, "hoe").ok, "hoe leaves a planted tile alone")
	assert_false(g.crop_at(t).is_empty())
	var bare := Vector2i(6, 12)
	g.set_deco(bare, 0)
	assert_true(GameState.use_tool(pid, "farm", bare, "hoe").ok)
	assert_true(g.is_tilled(bare))
	assert_true(GameState.use_tool(pid, "farm", bare, "hoe").ok, "hoe again clears empty soil")
	assert_false(g.is_tilled(bare))

func test_fence_neighbor_mask_matches_sprite_bits() -> void:
	# Art in tools/art_pipeline/fences.py is numbered N=1 E=2 S=4 W=8.
	var east_and_south := func(q: Vector2i) -> bool: return q == Vector2i(1, 0) or q == Vector2i(0, 1)
	assert_eq(Tiles.neighbor_mask(Vector2i.ZERO, east_and_south), 6)
	var cross := func(_q: Vector2i) -> bool: return true
	assert_eq(Tiles.neighbor_mask(Vector2i(3, 3), cross), 15)
	var none := func(_q: Vector2i) -> bool: return false
	assert_eq(Tiles.neighbor_mask(Vector2i(1, 1), none), 0)
	var w := World.new()
	var g := FarmGrid.new()
	g.setup(5, 5)
	w.grid = g
	g.set_deco(Vector2i(2, 1), Tiles.DECO.fence)
	g.set_deco(Vector2i(3, 2), Tiles.DECO.fence)
	g.set_deco(Vector2i(2, 2), Tiles.DECO.fence)
	assert_eq(w._link_mask(Vector2i(2, 2), "fence"), 1 | 2, "north and east fences select the corner piece")
	w.free()

func test_focus_tile_reaches_something_one_step_off() -> void:
	var w := World.new()
	w.interactables[Vector2i(6, 5)] = {"type": "sign", "text": "hi"}
	var me := Vector2i(5, 5)
	assert_eq(w.focus_tile(me, Vector2i(6, 5)), Vector2i(6, 5), "the tile you aimed at still wins")
	assert_eq(w.focus_tile(me, Vector2i(6, 6)), Vector2i(6, 5), "a door one tile beside the aim is close enough")
	assert_eq(w.focus_tile(me, Vector2i(5, 4)), Vector2i(5, 4), "something you are not facing is left alone")
	w.free()

func test_shop_purchase_does_not_stack_rows_or_repeat() -> void:
	GameState.new_game({"seed": 3, "player_name": "Shop", "farm_name": "T", "starter": "sproutle"})
	GameState.add_money(500)
	var sp := ShopPanel.new("general_store")
	add_child(sp)
	var rows := sp._list.get_child_count()
	assert_gt(rows, 0)
	sp._refresh()
	assert_eq(sp._list.get_child_count(), rows, "rebuilding the list replaces rows instead of keeping the old ones")
	var before := GameState.money()
	sp._buy("parsnip_seeds", 1)
	sp._buy("parsnip_seeds", 1)
	assert_eq(GameState.money(), before - Data.buy_price("parsnip_seeds"), "a second click during the purchase is ignored")
	sp.free()

func test_wheel_does_not_cycle_hotbar_while_a_panel_is_open() -> void:
	GameState.new_game({"seed": 3, "player_name": "Wheel", "farm_name": "T", "starter": "sproutle"})
	var hud := Hud.new()
	add_child(hud)
	var p := GameState.local_player()
	p.selected = 0
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	UIRoot.blocking = true
	hud._unhandled_input(down)
	var while_open := p.selected
	UIRoot.blocking = false
	hud._unhandled_input(down)
	var while_playing := p.selected
	hud.free()
	assert_eq(while_open, 0, "scrolling an open panel leaves the hotbar alone")
	assert_eq(while_playing, 1, "the wheel still cycles the bar while playing")

func test_sixth_toast_does_not_stall() -> void:
	GameState.new_game({"seed": 3, "player_name": "Shop", "farm_name": "T", "starter": "sproutle"})
	var hud := Hud.new()
	add_child(hud)
	for i in 8:
		hud.toast("Bought %d Green Bean Seeds" % i)
	assert_eq(hud._toasts.get_child_count(), 5, "only the latest toasts stay on screen")
	assert_eq(hud._toasts.get_child(4).get_child(0).text, "Bought 7 Green Bean Seeds")
	hud.free()

func test_purchase_is_written_straight_away() -> void:
	_autosave_slot = 99
	GameState.new_game({"seed": 3, "player_name": "Save", "farm_name": "T", "starter": "sproutle"})
	SaveManager.current_slot = _autosave_slot
	SaveManager.live = true
	var before := GameState.money()
	var bought: Dictionary = GameState.buy(GameState.local_player().id, "general_store", "parsnip_seeds", 1)
	assert_true(bought.ok)
	var saved := SaveManager.read_payload(_autosave_slot)
	assert_eq(int(saved.state.world.money), GameState.money())
	assert_ne(int(saved.state.world.money), before, "the purchase is already on disk")
	SaveManager.set_quiet(true)
	GameState.add_money(40)
	var during: Dictionary = SaveManager.read_payload(_autosave_slot)
	assert_eq(int(during.state.world.money), GameState.money() - 40, "overnight bookkeeping does not store a half-finished change")
	SaveManager.set_quiet(false)
