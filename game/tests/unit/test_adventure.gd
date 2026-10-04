extends GutTest
## Shrines and Wardens, mines and treasure, legends, festivals and the main story.

func before_each() -> void:
	GameState.new_game({"player_name": "Hero", "farm_name": "T", "starter": "sproutle", "seed": 21})

func _p() -> PlayerData:
	return GameState.local_player()

func after_each() -> void:
	Seasons.override = "spring"

## Festivals happen in the real season; pin it to the festival's and pick its day of the cycle.
func _day_of(fest_id: String) -> int:
	var f: Dictionary = Data.progression.festivals[fest_id]
	Seasons.override = str(f.season)
	return Calendar.SEASONS.find(f.season) * Calendar.DAYS_PER_SEASON + int(f.day) - 1

func test_shrine_needs_warden_then_wakes_and_opens_next_region() -> void:
	assert_eq(Adventure.shrine_state(GameState.world, "whisperwood"), "dark")
	assert_false(GameState.guardian_result_act(_p().id, "whisperwood", false).ok, "dark shrine can't wake")
	assert_true(GameState.warden_won_act(_p().id, "whisperwood").ok)
	assert_eq(Adventure.shrine_state(GameState.world, "whisperwood"), "ready")
	var r := GameState.guardian_result_act(_p().id, "whisperwood", false)
	assert_true(r.ok)
	assert_true(r.has("text"))
	assert_eq(Adventure.shrine_state(GameState.world, "whisperwood"), "restored")
	assert_true(GameState.region_unlocked("tidecove"))
	assert_eq(_p().inventory.count("sweet_treat"), 5, "first shrine reward")
	assert_true(Adventure.guardian_free(GameState.world, "whisperwood"), "beaten, not befriended")
	GameState.guardian_result_act(_p().id, "whisperwood", true)
	assert_false(Adventure.guardian_free(GameState.world, "whisperwood"))
	assert_eq(GameState.world.shrines.size(), 1, "no double restore")

func test_wardens_and_guardians_line_up_with_regions() -> void:
	for rid in Data.regions:
		var r: Dictionary = Data.regions[rid]
		if not r.has("warden"):
			continue
		assert_eq(Adventure.region_of_warden(r.warden), rid)
		assert_true(Data.species.has(r.guardian), "guardian %s exists" % r.guardian)
		var sched: Array = Data.villagers[r.warden].schedule
		assert_eq(str(sched[0][1]), rid, "%s stands in their region" % r.warden)

func test_mine_depth_only_one_floor_at_a_time_and_elevators() -> void:
	var pid := _p().id
	assert_false(GameState.mine_floor_act(pid, "whisperwood", 3).ok, "can't skip ahead")
	for f in range(1, 6):
		assert_true(GameState.mine_floor_act(pid, "whisperwood", f).ok)
	assert_eq(Adventure.deepest(GameState.world, "whisperwood"), 5)
	assert_eq(Adventure.elevator_floors(GameState.world, "whisperwood"), [1, 5])
	assert_true(GameState.mine_floor_act(pid, "whisperwood", 5).ok, "elevator floor")
	assert_false(GameState.mine_floor_act(pid, "tidecove", 1).ok, "locked region")

func test_bottom_floor_has_grand_chest_and_no_ladder() -> void:
	var m := MapBuilder.build_mine("whisperwood", 10, 3, 0)
	assert_true(m.bottom)
	var grand := false
	for o in m.objects:
		if o.type == "treasure" and o.get("grand", false):
			grand = true
	assert_true(grand)
	var l: Array = m.ladder
	assert_ne(m.grid.get_deco(Vector2i(int(l[0]), int(l[1]))), Tiles.DECO.ladder)
	assert_false(MapBuilder.build_mine("stonehollow", 60, 3, 0).bottom, "the Deep Hollow is bottomless")

func test_treasure_opens_once_and_grants_loot() -> void:
	GameState.world.regions.append("stonehollow")
	var found := ""
	var spot := Vector2i.ZERO
	for f in range(1, 40):
		var mid := "mine:stonehollow:%d" % f
		for o in GameState.map_info(mid).objects:
			if o.type == "treasure" and not o.get("mimic", false):
				found = mid
				spot = Vector2i(int(o.x), int(o.y))
				break
		if found != "":
			break
	assert_ne(found, "", "some floor has a chest")
	var money := GameState.money()
	var r := GameState.open_treasure_act(_p().id, found, spot.x, spot.y)
	assert_true(r.ok)
	assert_gt(GameState.money(), money)
	assert_true(GameState.treasure_opened(found, spot))
	assert_false(GameState.open_treasure_act(_p().id, found, spot.x, spot.y).ok, "empty now")
	GameState.end_day()
	assert_false(GameState.treasure_opened(found, spot), "chests refill with the new day")

func test_legends_wait_for_all_shrines() -> void:
	assert_eq(Adventure.legend_here(GameState.world, "whisperwood", "spring"), "")
	for rid in Data.region_order:
		if Data.regions[rid].has("warden"):
			GameState.world.shrines.append(rid)
	assert_eq(Adventure.legend_here(GameState.world, "whisperwood", "spring"), "vernalis")
	assert_eq(Adventure.legend_here(GameState.world, "whisperwood", "summer"), "")
	assert_true(GameState.legend_result_act(_p().id, "vernalis").ok)
	assert_eq(Adventure.legend_here(GameState.world, "whisperwood", "spring"), "", "befriended legends don't return")

func test_egg_hunt_places_eggs_and_rewards_hand_in() -> void:
	GameState.world.day = _day_of("egg_hunt")
	GameState._map_cache.clear()
	GameState.spawn_forage("town")
	var eggs := 0
	for k in GameState.grid("town").objects:
		if GameState.grid("town").objects[k].id == "festival_egg":
			eggs += 1
	assert_eq(eggs, Adventure.EGG_HUNT_EGGS)
	assert_false(GameState.festival_act(_p().id, "eggs").ok, "no eggs yet")
	GameState.give_item(_p(), "festival_egg", 9)
	var r := GameState.festival_act(_p().id, "eggs")
	assert_true(r.ok)
	assert_eq(int(r.eggs), 9)
	assert_eq(_p().inventory.count("festival_egg"), 0)
	assert_true(_p().inventory.has("wildling_egg"), "grand prize")
	assert_false(GameState.festival_act(_p().id, "eggs").ok, "once a year")

func test_no_festival_no_entry() -> void:
	GameState.world.day = _day_of("egg_hunt") + 1
	assert_false(GameState.festival_act(_p().id, "social").ok)

func test_social_festival_raises_every_friendship() -> void:
	GameState.world.day = _day_of("bloom_dance")
	assert_true(GameState.festival_act(_p().id, "social").ok)
	for vid in ["mira", "barley", "rowan"]:
		assert_gt(int(_p().relationship(vid).pts), 0)
	assert_true(_p().inventory.has("flower_crown"))

func test_fair_display_picks_goods_not_tools() -> void:
	var picks := Adventure.fair_pick(_p().inventory.all_entries())
	for pk in picks:
		assert_ne(Data.get_item(pk.id).get("cat", ""), "tool")
	GameState.give_item(_p(), "diamond", 1)
	GameState.give_item(_p(), "pumpkin", 3, 2)
	picks = Adventure.fair_pick(_p().inventory.all_entries())
	assert_eq(picks[0].id, "diamond", "most valuable first")
	assert_true(picks.size() <= Adventure.FAIR_SLOTS)
	GameState.world.day = _day_of("harvest_fair")
	var r := GameState.festival_act(_p().id, "fair")
	assert_true(r.ok)
	assert_between(int(r.place), 1, 4)

func test_show_scores_lead_against_rivals() -> void:
	GameState.world.day = _day_of("summer_show")
	var r := GameState.festival_act(_p().id, "show")
	assert_true(r.ok)
	assert_eq(r.rivals.size(), 3)
	assert_between(int(r.place), 1, 4)

func test_story_waits_for_barley_then_advances() -> void:
	assert_eq(Adventure.chapter(GameState.world).id, "roots")
	for s in ["puddlop", "embercub"]:
		Progression.mark(GameState.world.dex, s, true)
	GameState.check_story()
	assert_eq(int(GameState.world.quest), 0, "goal met but Barley hasn't spoken yet")
	GameState.story_seen_act(_p().id, "roots")
	GameState.check_story()
	assert_eq(int(GameState.world.quest), 1)
	assert_true(_p().inventory.has("lure_charm"), "chapter reward")
	assert_string_contains(Adventure.tracker(GameState.world, _p()), "Barley")

func test_story_tracker_shows_progress() -> void:
	GameState.story_seen_act(_p().id, "roots")
	assert_string_contains(Adventure.tracker(GameState.world, _p()), "(1/3)")

func test_friends_goal_counts_villagers_at_hearts() -> void:
	var facts := {"hearts": {"mira": 3, "bram": 4, "pip": 1}}
	assert_eq(Adventure.goal_progress({"friends": [4, 3]}, facts), [2, 4])

func test_story_data_is_valid() -> void:
	var keys := ["dex", "shrines", "farm_level", "legends", "friends", "mine", "fish", "depth", "deep_boss"]
	var chs := Adventure.chapters()
	assert_gt(chs.size(), 8)
	assert_true(chs[-1].goal.is_empty(), "epilogue is open-ended")
	for ch in chs:
		for k in ch.goal:
			assert_true(k in keys, "goal %s in %s" % [k, ch.id])
		for item in ch.get("reward", {}):
			assert_true(item == "money" or Data.has_item(item), "reward %s in %s" % [item, ch.id])
		assert_false(ch.get("lines", []).is_empty())

func test_loot_tables_use_real_items() -> void:
	var rng := RandomNumberGenerator.new()
	for rid in Data.regions:
		if not Data.regions[rid].has("mine"):
			continue
		for i in 20:
			rng.seed = i
			for k in Adventure.treasure_loot(rid, i, rng, i % 5 == 0):
				assert_true(k == "money" or Data.has_item(k), "%s loot %s" % [rid, k])

func test_cup_opponents_are_trainers() -> void:
	for vid in Data.progression.festivals.battle_cup.opponents:
		var info := Trainers.team_for(vid, 3, Adventure.cup_level(3, 0), GameState.rng)
		assert_false(info.is_empty(), "%s can battle" % vid)
		assert_gt(info.team.size(), 0)
