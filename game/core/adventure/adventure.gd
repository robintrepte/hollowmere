class_name Adventure
extends RefCounted
## Rules for the valley's adventure layer: Wardens and shrines, mines and treasure,
## seasonal legends, festivals and the main story. Pure functions over the world dict.

const SHRINE_COUNT := 8
const ELEVATOR_STEP := 5
const EGG_HUNT_EGGS := 12
const EGG_HUNT_GOAL := 8
const FAIR_SLOTS := 9
const QUEST_GIVER := "barley"

# --- Shrines --------------------------------------------------------------------------

static func warden_of(region: String) -> String:
	return str(Data.regions.get(region, {}).get("warden", ""))

static func region_of_warden(vid: String) -> String:
	return str(Data.villagers.get(vid, {}).get("trainer", {}).get("warden", ""))

static func guardian_of(region: String) -> String:
	return str(Data.regions.get(region, {}).get("guardian", ""))

## "dark" (Warden unbeaten), "ready" (Warden beaten, guardian asleep) or "restored".
static func shrine_state(world: Dictionary, region: String) -> String:
	if region in world.shrines:
		return "restored"
	if world.flags.get("warden:" + region, false):
		return "ready"
	return "dark"

## The guardian stays near its shrine until someone befriends it.
static func guardian_free(world: Dictionary, region: String) -> bool:
	return region in world.shrines and not world.flags.get("guardian_home:" + region, false)

static func guardian_level(region: String) -> int:
	var lv: Array = Data.regions[region].get("levels", [5, 10])
	return int(lv[1]) + 4

static func shrine_reward(count: int) -> Dictionary:
	return Data.progression.shrine_rewards.get(str(count), {})

# --- Mines ----------------------------------------------------------------------------

## 0 means bottomless.
static func mine_floors(region: String) -> int:
	return int(Data.regions.get(region, {}).get("mine", {}).get("floors", 0))

static func deepest(world: Dictionary, region: String) -> int:
	return int(world.mine_depth.get(region, 0))

## Floors the cave mouth can drop you to: B1 plus every fifth floor you've reached.
static func elevator_floors(world: Dictionary, region: String) -> Array:
	var out: Array = [1]
	var deep := deepest(world, region)
	var f := ELEVATOR_STEP
	while f <= deep:
		out.append(f)
		f += ELEVATOR_STEP
	return out

static func is_bottom(region: String, floor_n: int) -> bool:
	var n := mine_floors(region)
	return n > 0 and floor_n >= n

static func treasure_key(map_id: String, day_index: int, t: Vector2i) -> String:
	return "chest:%s:%d:%d,%d" % [map_id, day_index, t.x, t.y]

## Loot for a cave chest. Grand chests sit at the bottom of finite mines.
static func treasure_loot(region: String, floor_n: int, rng: RandomNumberGenerator, grand: bool = false) -> Dictionary:
	var mine: Dictionary = Data.regions[region].get("mine", {})
	var ores: Array = mine.get("ores", ["stone"])
	var order := int(Data.regions[region].get("order", 1))
	var loot := {}
	var ore: String = ores[mini(ores.size() - 1, rng.randi_range(0, ores.size() - 1))]
	loot[ore] = rng.randi_range(3, 6) + floor_n / 3
	loot["money"] = (40 + floor_n * 12) * maxi(1, order)
	var extras: Array = [["potion", 2], ["super_potion", 1], ["great_charm", 1], ["sweet_treat", 2], ["revive_seed", 1]]
	if order >= 4:
		extras.append_array([["max_potion", 1], ["ultra_charm", 1], ["deluxe_treat", 1]])
	var ex: Array = extras[rng.randi() % extras.size()]
	loot[ex[0]] = int(ex[1])
	var gems := ["quartz", "amethyst", "topaz", "emerald", "aquamarine", "ruby", "diamond"]
	if rng.randf() < 0.35 + floor_n * 0.02:
		var g: String = gems[mini(gems.size() - 1, rng.randi_range(0, mini(gems.size() - 1, order)))]
		loot[g] = int(loot.get(g, 0)) + 1
	if grand:
		loot["money"] = int(loot.money) * 5
		loot["star_shard"] = 1
		loot[ex[0]] = int(loot[ex[0]]) + 2
	return loot

# --- Legends --------------------------------------------------------------------------

## The legend that can appear at this region's shrine today, or "".
static func legend_here(world: Dictionary, region: String, season: String) -> String:
	if world.shrines.size() < SHRINE_COUNT:
		return ""
	for lid in Data.legends:
		var l: Dictionary = Data.legends[lid]
		if str(l.region) == region and str(l.season) == season and not lid in world.legends:
			return lid
	return ""

# --- Festivals ------------------------------------------------------------------------

static func festival_today(day_index: int) -> Dictionary:
	var id := Calendar.festival_on(day_index)
	if id == "":
		return {}
	var f: Dictionary = Data.progression.festivals[id].duplicate(true)
	f["id"] = id
	return f

## Each player can take part in each festival once per year.
static func festival_key(day_index: int, fest_id: String, pid: String) -> String:
	return "%d:%s:%s" % [Calendar.year(day_index), fest_id, pid]

static func festival_done(world: Dictionary, day_index: int, fest_id: String, pid: String) -> bool:
	return festival_key(day_index, fest_id, pid) in world.festival_done

## Deterministic egg spots on the village map for the hunt.
static func egg_spots(g: FarmGrid, world_seed: int, day_index: int, n: int = EGG_HUNT_EGGS) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, day_index, "eggs"])
	var out: Array = []
	for i in n * 20:
		if out.size() >= n:
			break
		var t := Vector2i(rng.randi_range(2, g.w - 3), rng.randi_range(2, g.h - 3))
		if t in out or g.get_deco(t) != 0 or g.is_blocked(t) or g.get_ground(t) in Tiles.BLOCKING_GROUND or not g.object_at(t).is_empty():
			continue
		out.append(t)
	return out

static func egg_hunt_reward(eggs: int, fest: Dictionary) -> Dictionary:
	if eggs >= EGG_HUNT_GOAL:
		return fest.get("reward", {}).duplicate()
	return {"money": eggs * 50} if eggs > 0 else {}

## Picks the most valuable goods from a pack for the Harvest Fair display.
## entries: [{id, n, q}] -> [{id, q, v}] (one of each kind, best quality).
static func fair_pick(entries: Array) -> Array:
	var best := {}
	for e in entries:
		var cat: String = Data.get_item(e.id).get("cat", "")
		if not cat in ["crop", "fruit", "artisan", "produce", "forage", "gem", "food"] or e.id == "festival_egg":
			continue
		var v := Data.sell_price(e.id, int(e.q))
		if not best.has(e.id) or v > int(best[e.id].v):
			best[e.id] = {"id": e.id, "q": int(e.q), "v": v}
	var picks: Array = best.values()
	picks.sort_custom(func(a, b): return int(a.v) > int(b.v))
	return picks.slice(0, FAIR_SLOTS)

## Variety matters as much as price: each different good adds a flat bonus.
static func fair_score(picks: Array) -> int:
	var total := 0
	for p in picks:
		total += int(p.v)
	return total + picks.size() * 60

static func fair_rivals(rng: RandomNumberGenerator, year: int) -> Array:
	var out: Array = []
	for vid in ["rowan", "lila", "theo"]:
		out.append([vid, int(rng.randf_range(900.0, 1700.0) * (1.0 + 0.35 * (year - 1)))])
	return out

## Village champions grow with you.
static func cup_level(shrines: int, round_i: int) -> int:
	return 10 + shrines * 6 + round_i * 3

# --- Story ----------------------------------------------------------------------------

static func chapters() -> Array:
	return Data.progression.get("story", [])

## Position of a story chapter by id (past the end if it doesn't exist).
static func chapter_index(id: String) -> int:
	var ch := chapters()
	for i in ch.size():
		if str(ch[i].id) == id:
			return i
	return ch.size() + 1

static func chapter(world: Dictionary) -> Dictionary:
	var ch := chapters()
	var i := int(world.get("quest", 0))
	return ch[i] if i >= 0 and i < ch.size() else {}

## Facts the story goals are checked against.
static func story_facts(world: Dictionary, p: PlayerData) -> Dictionary:
	var hearts: Dictionary = p.hearts_dict() if p else {}
	var deep := 0
	for r in world.mine_depth:
		deep = maxi(deep, int(world.mine_depth[r]))
	return {
		"dex": Progression.owned_count(world.dex), "shrines": world.shrines.size(),
		"farm_level": int(world.farm.level), "legends": world.legends.size(), "hearts": hearts, "mine": deep,
		"fish": int(world.get("stats", {}).get("fish", 0)),
	}

## [have, need] for a goal; a goal with no keys is never complete (the epilogue).
static func goal_progress(goal: Dictionary, facts: Dictionary) -> Array:
	if goal.is_empty():
		return [0, 1]
	for k in goal:
		if k == "friends":
			var spec: Array = goal[k]
			var n := 0
			for vid in facts.hearts:
				if int(facts.hearts[vid]) >= int(spec[1]):
					n += 1
			return [mini(n, int(spec[0])), int(spec[0])]
		return [mini(int(facts.get(k, 0)), int(goal[k])), int(goal[k])]
	return [0, 1]

static func goal_done(goal: Dictionary, facts: Dictionary) -> bool:
	var pr := goal_progress(goal, facts)
	return not goal.is_empty() and int(pr[0]) >= int(pr[1])

## Short tracker text for the HUD.
static func tracker(world: Dictionary, p: PlayerData) -> String:
	var ch := chapter(world)
	if ch.is_empty():
		return ""
	if not world.flags.get("story_seen:" + str(ch.id), false):
		return TranslationServer.translate("Talk to Elder Barley in the village.")
	var pr := goal_progress(ch.goal, story_facts(world, p))
	var hint := TranslationServer.translate(str(ch.get("hint", "")))
	if ch.goal.is_empty():
		return hint
	return TranslationServer.translate("%s (%d/%d)") % [hint, int(pr[0]), int(pr[1])]
