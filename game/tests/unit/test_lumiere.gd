extends GutTest
## Lumière and the Grand Casino: the maps (doors reachable, nothing stacked, ferries both ways),
## the villagers standing on open floor, and the actions behind the town: chip shop, lucky egg,
## hats, hotel, jukebox, hidden cards and the hide-casino setting.

const MAPS := ["lumiere", "casino", "casino_vip"]
const FOOTPRINT := {"ferry": Vector2i(2, 1), "fountain": Vector2i(2, 2)}

var pid := ""
var p: PlayerData

func before_each() -> void:
	GameState.new_game({"seed": 43, "starter": "embercub"})
	pid = Net.local_id()
	p = GameState.local_player()

func after_each() -> void:
	Settings.hide_casino = false

func _footprint(o: Dictionary) -> Array:
	var size: Vector2i = FOOTPRINT.get(o.type, Vector2i(int(o.get("w", 1)), int(o.get("h", 1))))
	var out: Array = []
	for dx in size.x:
		for dy in size.y:
			out.append(Vector2i(int(o.x) + dx, int(o.y) + dy))
	return out

func _taken(info: Dictionary) -> Dictionary:
	var taken := {}
	for o in info.objects:
		for t in _footprint(o):
			taken[t] = o
	return taken

func _open(info: Dictionary, taken: Dictionary, t: Vector2i) -> bool:
	var g: FarmGrid = info.grid
	return g.in_bounds(t) and not taken.has(t) and not Tiles.blocks(g.get_ground(t), g.get_deco(t))

func test_objects_do_not_overlap_and_every_door_is_reachable() -> void:
	for m in MAPS:
		var info := MapBuilder.build_authored(Data.get_map(m))
		var seen := {}
		for o in info.objects:
			for t in _footprint(o):
				assert_false(seen.has(t), "%s: %s overlaps %s at %s" % [m, o.get("id", o.type), seen.get(t, {}).get("id", ""), t])
				seen[t] = o
		var taken := _taken(info)
		for o in info.objects:
			if o.type != "building" or (str(o.get("action", "")) == "" and not o.has("text")):
				continue
			var w := int(o.w)
			var front := Vector2i(int(o.x) + (w - 1) / 2, int(o.y) + int(o.h))
			var front2 := Vector2i(int(o.x) + w / 2, int(o.y) + int(o.h))
			assert_true(_open(info, taken, front) or _open(info, taken, front2), "%s: nothing to stand on in front of %s at %s" % [m, o.id, front])

func test_spawns_warps_and_ferries_connect() -> void:
	for m in MAPS:
		var info := MapBuilder.build_authored(Data.get_map(m))
		var taken := _taken(info)
		var sp: Array = info.spawn
		assert_true(_open(info, taken, Vector2i(int(sp[0]), int(sp[1]))), "%s spawn" % m)
		for wp in info.warps:
			var dest := MapBuilder.build_authored(Data.get_map(str(wp.to)))
			assert_true(_open(dest, _taken(dest), Vector2i(int(wp.tx), int(wp.ty))), "%s warp lands on open floor in %s" % [m, wp.to])
	for pair in [["gull_bay", "lumiere"], ["lumiere", "gull_bay"]]:
		var info := MapBuilder.build_authored(Data.get_map(pair[0]))
		var ferry: Dictionary = info.objects.filter(func(o): return o.type == "ferry")[0]
		assert_eq(str(ferry.to), pair[1])
		var dest := MapBuilder.build_authored(Data.get_map(pair[1]))
		assert_true(_open(dest, _taken(dest), Vector2i(int(ferry.tx), int(ferry.ty))), "ferry from %s lands on open floor" % pair[0])

func test_guest_spots_are_open_floor() -> void:
	for m in MAPS:
		var info := MapBuilder.build_authored(Data.get_map(m))
		assert_false(info.get("guest_lines", []).is_empty(), "%s guests have something to say" % m)
		for s in info.get("guests", []):
			assert_true(_open(info, _taken(info), Vector2i(int(s[0]), int(s[1]))), "%s guest spot %s" % [m, s])

func test_casino_villagers_stand_on_open_floor() -> void:
	for vid in ["rosalind", "dorian", "margaux", "marcel", "celeste", "bruno"]:
		for e in Data.villagers[vid].schedule:
			if str(e[1]) == "away":
				continue
			var info := MapBuilder.build_authored(Data.get_map(str(e[1])))
			assert_true(_open(info, _taken(info), Vector2i(int(e[2]), int(e[3]))), "%s at %s %d,%d" % [vid, e[1], e[2], e[3]])

func test_lumiere_opens_with_the_friends_chapter() -> void:
	assert_false(GameState.place_open("lumiere"))
	GameState.world.quest = Adventure.chapter_index("friends")
	assert_true(GameState.place_open("lumiere"))

func test_chip_shop_takes_chips_not_gold() -> void:
	var gold := GameState.money()
	assert_false(GameState.buy(pid, "casino", "lucky_cap").ok, "no chips yet")
	Casino.add_chips(p, 1000)
	assert_true(GameState.buy(pid, "casino", "lucky_cap").ok)
	assert_eq(p.chips, 400)
	assert_eq(GameState.money(), gold)
	assert_true(p.inventory.has("lucky_cap"))
	assert_false(GameState.buy(pid, "casino", "record_vip").ok, "VIP stock stays locked")

func test_lucky_egg_holds_a_rare_wildling() -> void:
	Casino.add_chips(p, 4000)
	assert_true(GameState.buy(pid, "casino", "lucky_egg").ok)
	assert_eq(p.chips, 0)
	var e := p.inventory.first_of("wildling_egg")
	assert_false(e.is_empty())
	assert_true(str(e.meta.egg.species) in Data.get_item("lucky_egg").egg_pool.map(func(s): return Data.base_form(s)))
	assert_false(p.inventory.has("lucky_egg"))

func test_hats_go_on_and_come_off() -> void:
	p.inventory.add("top_hat", 1)
	p.inventory.add("fedora", 1)
	assert_true(GameState.wear_hat_act(pid, p.inventory.first_of("top_hat").uid).ok)
	assert_eq(p.hat, "top_hat")
	assert_false(p.inventory.has("top_hat"))
	assert_true(GameState.wear_hat_act(pid, p.inventory.first_of("fedora").uid).ok)
	assert_eq(p.hat, "fedora")
	assert_true(p.inventory.has("top_hat"), "the old hat goes back into the pack")
	assert_true(GameState.wear_hat_act(pid, "").ok)
	assert_eq(p.hat, "")
	assert_true(p.inventory.has("fedora"))
	p.inventory.add("parsnip", 1)
	assert_false(GameState.wear_hat_act(pid, p.inventory.first_of("parsnip").uid).ok, "only hats")

func test_hotel_restores_energy_for_gold() -> void:
	GameState.add_money(GameState.HOTEL_PRICE)
	var gold := GameState.money()
	p.energy = 10.0
	assert_true(GameState.hotel_act(pid).ok)
	assert_eq(p.energy, p.energy_cap())
	assert_eq(GameState.money(), gold - GameState.HOTEL_PRICE)

func test_jukebox_needs_the_record() -> void:
	assert_false(GameState.jukebox_act(pid, "casino").ok)
	p.inventory.add("record_casino", 1)
	assert_true(GameState.jukebox_act(pid, "casino").ok)
	assert_eq(GameState.world.flags.jukebox, "casino")
	assert_true(GameState.jukebox_act(pid, "").ok)
	assert_false(GameState.world.flags.has("jukebox"))

func test_clients_never_see_the_hole_card_or_the_spare_cards() -> void:
	Casino.add_chips(p, 200)
	var r := GameState.blackjack_act(pid, "deal", 20)
	if str(r.hand.phase) != "done":
		assert_eq(int(r.hand.dealer[1]), -1)
		assert_eq(int(GameState.blackjack_act(pid, "state").hand.dealer[1]), -1, "the state view hides it too")
	var pr := GameState.poker_act(pid, "deal", 1)
	assert_false(pr.hand.has("spare"))

func test_race_card_is_shared_with_clients() -> void:
	var r := GameState.race_card_act(pid)
	assert_true(r.ok)
	assert_eq(r.card.size(), GameState.race_card(pid).size())

func test_hidden_casino_hides_its_quests() -> void:
	GameState.world.quest = Adventure.chapter_index("friends")
	var req: Dictionary = Data.quests["tut_casino"].requires
	assert_true(Quests.requirements_met(p, GameState.world, req, TimeService.now()))
	Settings.hide_casino = true
	assert_false(Quests.requirements_met(p, GameState.world, req, TimeService.now()))
	assert_true(Quests.requirements_met(p, GameState.world, Data.quests["celeste_roses"].requires, TimeService.now()), "Lumière itself stays")
