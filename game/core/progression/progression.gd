class_name Progression
extends RefCounted
## Farm Level XP, Wildling-dex, weekly challenges, board requests and Creature Shows.

static func farm_xp_for(level: int) -> int:
	return int(100.0 * pow(float(level), 1.6))

## Adds XP to {level, xp}; returns array of newly reached levels.
static func add_farm_xp(st: Dictionary, amount: int) -> Array:
	var ups: Array = []
	st.xp = int(st.xp) + amount
	while int(st.xp) >= farm_xp_for(int(st.level)):
		st.xp = int(st.xp) - farm_xp_for(int(st.level))
		st.level = int(st.level) + 1
		ups.append(int(st.level))
	return ups

static func level_reward(level: int) -> Dictionary:
	for e in Data.progression.farm_levels:
		if int(e.level) == level:
			return e
	return {"level": level, "text": "Farm Level %d!" % level, "reward": {"money": 200 * level}}

## XP rewards for actions (Farm Story style: everything gives a little XP).
const XP := {
	"harvest": 3, "plant": 1, "water": 0, "ship_gold": 1, "befriend": 25, "hatch": 20, "win": 10, "craft": 4,
	"cook": 6, "mine_floor": 5, "clear": 1, "fruit": 2, "gift": 3, "request": 30, "build": 60, "shrine": 200,
}

# --- Dex -------------------------------------------------------------------------

## dex: {species_id: {"seen": bool, "owned": bool, "starry": bool}}
static func mark(dex: Dictionary, species_id: String, owned: bool, starry: bool = false) -> bool:
	var e: Dictionary = dex.get(species_id, {"seen": false, "owned": false, "starry": false})
	var new_owned: bool = owned and not bool(e.owned)
	e.seen = true
	e.owned = e.owned or owned
	e.starry = e.starry or starry
	dex[species_id] = e
	return new_owned

static func owned_count(dex: Dictionary) -> int:
	var n := 0
	for k in dex:
		if dex[k].owned:
			n += 1
	return n

static func pending_milestones(dex: Dictionary, claimed: Array) -> Array:
	var out: Array = []
	var n := owned_count(dex)
	for m in Data.progression.dex_milestones:
		if n >= int(m.n) and not int(m.n) in claimed:
			out.append(m)
	return out

# --- Weekly challenges -------------------------------------------------------------

static func weekly_for(week: int, world_seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, week, "weekly"])
	var tpl: Array = Data.progression.weekly_templates.duplicate()
	var out: Array = []
	for i in 3:
		var t: Dictionary = tpl.pop_at(rng.randi() % tpl.size())
		var n := rng.randi_range(int(t.n[0]), int(t.n[1]))
		var type_id: String = Data.type_order[rng.randi() % Data.type_order.size()]
		out.append({
			"id": t.id, "text": String(t.text).format({"n": n, "type": Data.type_name(type_id)}),
			"stat": String(t.stat).format({"type": type_id}), "n": n, "progress": 0,
			"reward_money": int(t.reward_money), "done": false,
		})
	return out

## Increments matching challenges; returns those that just completed.
static func bump(weekly: Array, stat: String, amount: int = 1) -> Array:
	var done: Array = []
	for c in weekly:
		if c.done:
			continue
		if c.stat == stat:
			c.progress = mini(int(c.n), int(c.progress) + amount)
			if int(c.progress) >= int(c.n):
				c.done = true
				done.append(c)
	return done

# --- Board requests ------------------------------------------------------------------

static func board_for(day_index: int, world_seed: int) -> Array:
	var season := Calendar.season(day_index)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, Calendar.week_number(day_index), "board"])
	var pool: Array = []
	for r in Data.progression.board_requests:
		if r.season == "" or r.season == season:
			pool.append(r)
	var out: Array = []
	for i in mini(3, pool.size()):
		var r: Dictionary = pool.pop_at(rng.randi() % pool.size()).duplicate()
		r.done = false
		out.append(r)
	return out

# --- Creature Shows ----------------------------------------------------------------

## Scores a Wildling for a Creature Show. Returns {score, parts:{...}}
static func show_score(c: Creature, rng: RandomNumberGenerator) -> Dictionary:
	var parts := {
		"grooming": clampi(c.grooming, 0, 100) * 0.35,
		"happiness": float(c.happiness) / 255.0 * 30.0,
		"genes": float(c.gene_total()) / 75.0 * 20.0,
		"level": minf(float(c.level), 50.0) / 50.0 * 10.0,
		"flair": (15.0 if c.starry else 0.0) + (6.0 if c.morph != "" else 0.0) + rng.randf_range(0.0, 8.0),
	}
	var total := 0.0
	for k in parts:
		total += parts[k]
	return {"score": int(round(total)), "parts": parts}

static func rival_show_scores(rng: RandomNumberGenerator, tier: int) -> Array:
	var out: Array = []
	for i in 3:
		out.append(int(rng.randf_range(35.0, 60.0) + tier * 6.0))
	out.sort()
	out.reverse()
	return out

# --- Farm score -------------------------------------------------------------------

static func farm_score(stats: Dictionary, dex: Dictionary, shrines: int, buildings: Array) -> int:
	return int(stats.get("earned", 0)) + owned_count(dex) * 500 + shrines * 5000 + buildings.size() * 1500
