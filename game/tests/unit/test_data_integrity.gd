extends GutTest
## Validates that all content references point at real data.

func test_species_count_and_fields() -> void:
	assert_gte(Data.species.size(), 90, "Expected ~90+ Wildlings")
	for id in Data.species:
		var sp: Dictionary = Data.species[id]
		for t in sp.types:
			assert_true(Data.types.has(t), "%s has unknown type %s" % [id, t])
		assert_true(sp.learnset.size() >= 2, "%s needs a learnset" % id)
		for e in sp.learnset:
			assert_true(Data.moves.has(e[1]), "%s learns unknown move %s" % [id, e[1]])
		for tr in sp.traits:
			assert_true(Data.traits.has(tr), "%s has unknown trait %s" % [id, tr])
		if sp.evo != null:
			assert_true(Data.species.has(sp.evo[0]), "%s evolves into unknown %s" % [id, sp.evo[0]])
		if sp.fav != "":
			assert_true(Data.has_item(sp.fav), "%s favorite food %s missing" % [id, sp.fav])
		if sp.get("produce", "") != "":
			assert_true(Data.has_item(sp.produce), "%s produce %s missing" % [id, sp.produce])

func test_moves_valid() -> void:
	for id in Data.moves:
		var m: Dictionary = Data.moves[id]
		assert_true(m.type == "none" or Data.types.has(m.type), "move %s type" % id)
		assert_true(m.cat in ["phys", "spec", "status"], "move %s cat" % id)

func test_crops_and_seeds() -> void:
	assert_gte(Data.crops.size(), 40)
	for id in Data.crops:
		assert_true(Data.has_item(id + "_seeds"), "seed for %s" % id)
		assert_true(Data.has_item(id), "crop item %s" % id)
	for s in Data.SEASONS:
		assert_gt(Data.seeds_for_season(s).size(), 0, "seeds in %s" % s)

func test_recipes_reference_items() -> void:
	for kind in ["cooking", "crafting"]:
		for id in Data.recipes[kind]:
			assert_true(Data.has_item(id), "%s output %s is an item" % [kind, id])
			for k in Data.recipes[kind][id].in:
				assert_true(Data.has_item(k), "%s %s needs unknown %s" % [kind, id, k])

func test_shops_reference_items() -> void:
	for sid in Data.shops:
		var shop: Dictionary = Data.shops[sid]
		for s in shop.get("stock", []) + shop.get("pool", []):
			if String(s.id).begins_with("@"):
				continue
			assert_true(Data.has_item(s.id), "shop %s sells unknown %s" % [sid, s.id])

func test_villagers_reference_items_and_maps() -> void:
	assert_eq(Data.villagers.size(), 26)
	for vid in Data.villagers:
		var v: Dictionary = Data.villagers[vid]
		for k in ["loves", "likes", "dislikes"]:
			for it in v.get(k, []):
				assert_true(Data.has_item(it), "%s %s unknown item %s" % [vid, k, it])
		for e in v.schedule:
			var m: String = e[1]
			assert_true(m == "away" or not Data.get_map(m).is_empty() or Data.regions.has(m), "%s schedule map %s" % [vid, m])
		for ev in v.get("event_rewards", {}):
			for it in v.event_rewards[ev]:
				if it == "recipe":
					var rid: String = v.event_rewards[ev].recipe
					assert_true(Data.recipes.cooking.has(rid) or Data.recipes.crafting.has(rid), "%s recipe %s" % [vid, rid])
				else:
					assert_true(Data.has_item(it), "%s reward %s" % [vid, it])

func test_regions_spawns() -> void:
	assert_eq(Data.regions.size(), 9)
	for rid in Data.regions:
		var r: Dictionary = Data.regions[rid]
		for s in r.spawns:
			assert_true(Data.species.has(s[0]), "%s spawns unknown %s" % [rid, s[0]])
		if r.has("mine"):
			for s in r.mine.spawns:
				assert_true(Data.species.has(s[0]), "%s mine spawns unknown %s" % [rid, s[0]])
			for o in r.mine.ores:
				assert_true(Data.has_item(o), "%s ore %s" % [rid, o])
		for season in r.get("forage", {}):
			for f in r.forage[season]:
				assert_true(Data.has_item(f), "%s forage %s" % [rid, f])

func test_every_species_obtainable() -> void:
	var obtainable := {}
	for rid in Data.regions:
		for s in Data.regions[rid].spawns:
			obtainable[s[0]] = true
		if Data.regions[rid].has("mine"):
			for s in Data.regions[rid].mine.spawns:
				obtainable[s[0]] = true
	for layer in Data.mine_layers:
		for s in layer.get("spawns", []):
			obtainable[s[0]] = true
		if layer.has("boss"):
			obtainable[layer.boss.species] = true
	for lid in Data.legends:
		obtainable[lid] = true
	for rid in Data.regions:
		if Data.regions[rid].has("guardian"):
			obtainable[Data.regions[rid].guardian] = true
	# Evolutions count as obtainable if their base is.
	var changed := true
	while changed:
		changed = false
		for id in Data.species:
			var evo = Data.species[id].evo
			if obtainable.has(id) and evo != null and not obtainable.has(evo[0]):
				obtainable[evo[0]] = true
				changed = true
	var missing: Array = []
	for id in Data.species:
		if not obtainable.has(id):
			missing.append(id)
	assert_eq(missing, [], "Unobtainable species")

func test_progression_rewards() -> void:
	for m in Data.progression.dex_milestones:
		for k in m.reward:
			assert_true(k == "money" or Data.has_item(k), "milestone reward %s" % k)
	for lv in Data.progression.farm_levels:
		for k in lv.reward:
			assert_true(k == "money" or Data.has_item(k), "farm level reward %s" % k)
	for f in Data.progression.festivals.values():
		for k in f.get("reward", {}):
			assert_true(k == "money" or Data.has_item(k), "festival reward %s" % k)

func test_maps_build() -> void:
	for m in ["farm", "town", "greenhouse", "terrace"]:
		var info := MapBuilder.build_authored(Data.get_map(m))
		assert_not_null(info.grid)
		for wp in info.warps:
			var dest: String = wp.to
			assert_true(not Data.get_map(dest).is_empty() or Data.regions.has(dest), "warp target %s" % dest)
