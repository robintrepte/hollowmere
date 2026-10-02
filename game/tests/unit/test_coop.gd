extends GutTest
## Co-op logic that doesn't need a network: PvP mirroring, trades, client-routed actions, meta sync.

func before_each() -> void:
	GameState.new_game({"player_name": "Host", "farm_name": "T", "starter": "sproutle", "seed": 11})

func _team(species: Array, lvl: int, seed_v: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var out: Array = []
	for s in species:
		out.append(Creature.create(s, lvl, rng))
	return out

func _copy(team: Array) -> Array:
	var out: Array = []
	for c: Creature in team:
		out.append(Creature.from_dict(c.to_dict()))
	return out

func test_mirror_events_flips_sides_and_result() -> void:
	var ev := [{"t": "damage", "side": 0, "hp": 3}, {"t": "text", "msg": "hi"}, {"t": "end", "result": "win"}]
	var m := BattleEngine.mirror_events(ev)
	assert_eq(int(m[0].side), 1)
	assert_false(m[1].has("side"))
	assert_eq(m[2].result, "lose")
	assert_eq(int(ev[0].side), 0, "original untouched")

func test_guest_view_tracks_host_engine_through_a_whole_battle() -> void:
	var a := _team(["sproutle", "embercub"], 12, 1)
	var b := _team(["puddlop", "sproutle"], 12, 2)
	var host := BattleEngine.new(_copy(a), _copy(b), BattleEngine.Kind.PVP, 99, "Guest", "Host")
	var guest := BattleEngine.new(_copy(b), _copy(a), BattleEngine.Kind.PVP, 99, "Host", "Guest")
	host.start()
	guest.apply_snapshot(host.snapshot(), true)
	var turns := 0
	while not host.is_over() and turns < 80:
		turns += 1
		if host.needs_switch(1):
			host.force_switch(1, host.sides[1].first_alive())
		elif host.needs_switch(0):
			host.force_switch(0, host.sides[0].first_alive())
		else:
			host.submit({"k": "move", "i": 0}, {"k": "move", "i": 0})
		guest.apply_snapshot(host.snapshot(), true)
		for i in 2:
			var hs: BattleEngine.BattleSide = host.sides[1 - i]
			var gs: BattleEngine.BattleSide = guest.sides[i]
			assert_eq(gs.active, hs.active)
			assert_eq(gs.current().hp, hs.current().hp)
	assert_true(host.is_over(), "battle finished in %d turns" % turns)
	assert_eq(guest.result, BattleEngine.mirror_result(host.result))

func test_pvp_forfeit_and_no_xp() -> void:
	var a := _team(["sproutle"], 10, 3)
	var b := _team(["puddlop"], 10, 4)
	var xp0: int = a[0].xp
	var e := BattleEngine.new(a, b, BattleEngine.Kind.PVP, 5, "B", "A")
	e.start()
	while not e.is_over():
		e.submit({"k": "move", "i": 0}, {"k": "move", "i": 0})
		if e.needs_switch(0) or e.needs_switch(1):
			break
	assert_eq(a[0].xp, xp0, "friendly battles give no XP")
	var e2 := BattleEngine.new(_team(["sproutle"], 10, 3), _team(["puddlop"], 10, 4), BattleEngine.Kind.PVP, 5, "B", "A")
	e2.start()
	e2.submit({"k": "move", "i": 0}, {"k": "run"})
	assert_eq(e2.result, "win", "opponent forfeits")

func test_pvp_text_is_neutral() -> void:
	var e := BattleEngine.new(_team(["sproutle"], 5, 1), _team(["puddlop"], 5, 2), BattleEngine.Kind.PVP, 1, "Bea", "Al")
	for ev: Dictionary in e.start():
		if ev.t == "text":
			assert_false(str(ev.msg).begins_with("Go,"), "no first-person lines: %s" % ev.msg)

func test_trade_swaps_items_and_wildlings() -> void:
	var a := GameState.local_player()
	var b := GameState.ensure_player("friend", "Friend")
	a.inventory.add("parsnip", 5)
	b.inventory.add("wood", 9)
	var extra := Creature.create("embercub", 5, GameState.rng)
	a.party.append(extra)
	var pa := a.inventory.first_of("parsnip")
	var pb := b.inventory.first_of("wood")
	var offer_a := [{"kind": "item", "uid": pa.uid, "n": 3}, {"kind": "creature", "uid": extra.uid}]
	var offer_b := [{"kind": "item", "uid": pb.uid, "n": 9}]
	var p0 := a.inventory.count("parsnip")
	var w0 := a.inventory.count("wood")
	assert_eq(GameState.execute_trade(a, offer_a, b, offer_b), "")
	assert_eq(a.inventory.count("parsnip"), p0 - 3)
	assert_eq(a.inventory.count("wood"), w0 + 9)
	assert_eq(b.inventory.count("parsnip"), 3)
	assert_true(extra in b.party, "Wildling moved to the friend")
	assert_eq(extra.owner, "friend")

func test_trade_rejects_last_wildling_and_missing_items() -> void:
	var a := GameState.local_player()
	var b := GameState.ensure_player("friend", "Friend")
	assert_ne(GameState.validate_offer(a, [{"kind": "creature", "uid": a.party[0].uid}]), "", "can't trade away your only Wildling")
	assert_ne(GameState.validate_offer(a, [{"kind": "item", "uid": "nope", "n": 1}]), "")
	b.inventory.add("wood", 2)
	var w := b.inventory.first_of("wood")
	assert_ne(GameState.validate_offer(b, [{"kind": "item", "uid": w.uid, "n": 5}]), "", "can't offer more than you have")

func test_befriend_act_files_creature_once() -> void:
	var b := GameState.ensure_player("friend", "Friend")
	var c := Creature.create("puddlop", 4, GameState.rng)
	var json := JSON.stringify(c.to_dict())
	assert_true(GameState.befriend_act("friend", json).ok)
	assert_not_null(GameState.find_creature(c.uid))
	assert_true(Progression.owned_count(GameState.world.dex) >= 1)
	assert_false(GameState.befriend_act("friend", json).ok, "duplicate uid rejected")
	assert_eq(b.party[-1].uid, c.uid)

func test_apply_meta_replaces_farm_state() -> void:
	var d := GameState.to_dict()
	d.erase("grids")
	d.erase("players")
	d.world.money = 4321
	d.world.buildings = ["kitchen"]
	var c := Creature.create("sproutle", 3, GameState.rng)
	d.ranch = [c.to_dict()]
	watch_signals(EventBus)
	GameState.apply_meta(d)
	assert_eq(GameState.money(), 4321)
	assert_has(GameState.world.buildings, "kitchen")
	assert_eq(GameState.ranch.size(), 1)
	assert_signal_emitted(EventBus, "party_changed", "ranch roster changed")
	GameState.apply_meta(d)
	assert_signal_emit_count(EventBus, "party_changed", 1, "unchanged ranch doesn't respawn creatures")
