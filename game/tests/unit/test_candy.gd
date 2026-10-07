extends GutTest
## Shelter releases pay candy. Candy grows a Wildling, and never replaces battling.

var rng := RandomNumberGenerator.new()

func before_each() -> void:
	# Not the farm seed: Creature uids come from this rng, and the starter uses the farm rng.
	rng.seed = 99
	GameState.new_game({"seed": 7, "starter": "puddlop"})

func test_yield_scales_with_level_and_rarity() -> void:
	var common := Creature.create("sproutle", 1, rng)
	assert_eq(WildlingCandy.yield_for(common), 1)
	common.level = 10
	assert_eq(WildlingCandy.yield_for(common), 2)
	common.level = 100
	assert_eq(WildlingCandy.yield_for(common), 11)
	common.level = 10
	common.starry = true
	assert_eq(WildlingCandy.yield_for(common), 3)
	var legend := Creature.create("verdantis", 10, rng)
	assert_eq(WildlingCandy.yield_for(legend), 3, "legendary leaves one extra")
	legend.starry = true
	assert_eq(WildlingCandy.yield_for(legend), 4)

func test_only_the_shelter_can_be_sent_off() -> void:
	var p := GameState.local_player()
	var lead: Creature = p.party[0]
	assert_false(GameState.release_creature(lead.uid, p).ok)
	assert_true(lead in p.party)
	assert_eq(p.inventory.count(WildlingCandy.ITEM), 0)
	var farmer := Creature.create("sproutle", 8, rng)
	GameState.ranch.append(farmer)
	assert_false(GameState.release_creature(farmer.uid, p).ok)
	assert_true(farmer in GameState.ranch)
	var spare := Creature.create("sproutle", 8, rng)
	p.party.append(spare)
	assert_true(GameState.move_creature(spare.uid, "sanctuary", p))
	var res: Dictionary = GameState.release_creature(spare.uid, p)
	assert_true(res.ok)
	assert_eq(int(res.candies), 1, "level 8 is still the first band")
	assert_null(GameState.find_creature(spare.uid))
	assert_eq(GameState.candy_count(p), 1)

func test_a_full_pack_and_chest_keep_the_wildling() -> void:
	var p := GameState.local_player()
	var spare := Creature.create("embercub", 12, rng)
	p.party.append(spare)
	GameState.move_creature(spare.uid, "sanctuary", p)
	_fill(p.inventory)
	_fill(GameState.farm_chest)
	var res: Dictionary = GameState.release_creature(spare.uid, p)
	assert_false(res.ok)
	assert_true(spare in GameState.sanctuary)
	assert_eq(GameState.candy_count(p), 0)

func test_overflow_candy_waits_in_the_farm_chest() -> void:
	var p := GameState.local_player()
	var spare := Creature.create("sproutle", 20, rng)
	spare.starry = true
	p.party.append(spare)
	GameState.move_creature(spare.uid, "sanctuary", p)
	_fill(p.inventory)
	var res: Dictionary = GameState.release_creature(spare.uid, p)
	assert_true(res.ok)
	assert_eq(p.inventory.count(WildlingCandy.ITEM), 0)
	assert_eq(GameState.farm_chest.count(WildlingCandy.ITEM), WildlingCandy.yield_for(spare))

func test_one_candy_never_skips_a_level() -> void:
	var p := GameState.local_player()
	var c: Creature = p.party[0]
	c.level = 10
	c.xp = Creature.xp_for_level(11) - 1
	c.hp = c.max_hp()
	p.inventory.add(WildlingCandy.ITEM, 1)
	var res: Dictionary = GameState.feed_candy(c.uid, p, false)
	assert_true(res.ok)
	assert_eq(c.level, 11)
	assert_eq(c.xp, Creature.xp_for_level(11))
	assert_eq(p.inventory.count(WildlingCandy.ITEM), 0)

func test_a_fresh_level_costs_the_full_candy_price() -> void:
	var p := GameState.local_player()
	var c := Creature.create("sproutle", 20, rng)
	p.party.append(c)
	var need := WildlingCandy.candies_left(c)
	assert_eq(need, WildlingCandy.cost_at(20))
	p.inventory.add(WildlingCandy.ITEM, need)
	var res: Dictionary = GameState.feed_candy(c.uid, p, true)
	assert_true(res.ok)
	assert_eq(c.level, 21)
	assert_eq(c.xp, Creature.xp_for_level(21))
	assert_eq(int(res.spent), need)
	assert_eq(GameState.candy_count(p), 0)

func test_short_candy_only_goes_partway() -> void:
	var p := GameState.local_player()
	var c := Creature.create("sproutle", 20, rng)
	p.party.append(c)
	var before := c.xp
	p.inventory.add(WildlingCandy.ITEM, 3)
	assert_true(GameState.feed_candy(c.uid, p, true).ok)
	assert_eq(c.level, 20)
	assert_eq(c.xp, before + 3 * WildlingCandy.xp_per_candy(20))
	assert_eq(GameState.candy_count(p), 0)

func test_candy_in_the_chest_still_feeds() -> void:
	var p := GameState.local_player()
	var c: Creature = p.party[0]
	var before := c.xp
	GameState.farm_chest.add(WildlingCandy.ITEM, 1)
	assert_true(GameState.feed_candy(c.uid, p, false).ok)
	assert_gt(c.xp, before)
	assert_eq(GameState.farm_chest.count(WildlingCandy.ITEM), 0)

func test_max_level_and_someone_elses_party_refuse() -> void:
	var p := GameState.local_player()
	var c: Creature = p.party[0]
	c.level = Creature.MAX_LEVEL
	c.xp = Creature.xp_for_level(Creature.MAX_LEVEL)
	p.inventory.add(WildlingCandy.ITEM, 5)
	assert_false(GameState.feed_candy(c.uid, p, true).ok)
	assert_eq(p.inventory.count(WildlingCandy.ITEM), 5)
	var other := GameState.ensure_player("guest", "Guest")
	assert_false(GameState.feed_candy(other.party[0].uid, p, false).ok)
	assert_eq(p.inventory.count(WildlingCandy.ITEM), 5)

func test_candy_can_teach_and_evolve() -> void:
	var p := GameState.local_player()
	var pupil := Creature.create("sproutle", 14, rng)
	p.party.append(pupil)
	var known := pupil.learned.size()
	p.inventory.add(WildlingCandy.ITEM, WildlingCandy.candies_left(pupil))
	var taught: Dictionary = GameState.feed_candy(pupil.uid, p, true)
	assert_eq(pupil.level, 15)
	assert_eq(pupil.species_id, "sproutle")
	assert_gt(pupil.learned.size(), known)
	assert_false(taught.learned.is_empty())
	var growing := Creature.create("sproutle", 15, rng)
	p.party.append(growing)
	p.inventory.add(WildlingCandy.ITEM, WildlingCandy.candies_left(growing))
	var res: Dictionary = GameState.feed_candy(growing.uid, p, true)
	assert_true(res.ok)
	assert_eq(growing.level, 16)
	assert_eq(growing.species_id, "bramblet")
	assert_eq(str(res.evolved), "bramblet")
	assert_true(GameState.world.dex.has("bramblet"))

func test_a_release_is_less_than_half_a_level() -> void:
	for lvl in [10, 30, 50]:
		var c := Creature.create("sproutle", lvl, rng)
		var paid := WildlingCandy.yield_for(c) * WildlingCandy.xp_per_candy(lvl)
		var gap := Creature.xp_for_level(lvl + 1) - Creature.xp_for_level(lvl)
		assert_lt(paid, gap / 2, "level %d release" % lvl)
	var battle := _battle_xp("sproutle", 10)
	var candy := WildlingCandy.yield_for(Creature.create("sproutle", 10, rng)) * WildlingCandy.xp_per_candy(10)
	assert_lt(candy, battle, "catching to release should not beat fighting")

func test_actions_are_replicated() -> void:
	assert_true("release_creature_act" in Coop.ACTIONS)
	assert_true("feed_candy_act" in Coop.ACTIONS)

func _battle_xp(species: String, level: int) -> int:
	var bst := 0
	for s in Data.STATS:
		bst += int(Data.get_species(species).base_stats[s])
	return int((float(bst) / 4.0 * float(level) / 7.0 + 5.0) * BattleEngine.XP_YIELD)

func _fill(inv: Inventory) -> void:
	inv.entries.clear()
	inv.w = 1
	inv.h = 1
	assert_eq(inv.add("basic_treat", 1), 0)
