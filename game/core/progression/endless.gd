class_name Endless
extends RefCounted
## Long-term goals that never run out: the weekly Creature Show ladder, weekly bounties,
## post-game Warden rematches and Starry chains.

const SHOW_WEEKDAY := 5
const SHOW_RANKS := [
	{"name": "Novice", "prize": 300},
	{"name": "Bronze", "prize": 600},
	{"name": "Silver", "prize": 1200},
	{"name": "Gold", "prize": 2500},
	{"name": "Master", "prize": 5000},
]
const CHAIN_CAP := 40
const CHAIN_LURE := 5
const REMATCH_BASE := 55
const REMATCH_STEP := 5
const REMATCH_WINS_PER_TIER := 4

# --- Weekly Creature Show ---------------------------------------------------------------

static func show_open(day_index: int) -> bool:
	return Calendar.weekday(day_index) == SHOW_WEEKDAY and Calendar.festival_on(day_index) == ""

static func next_show(day_index: int) -> int:
	for i in range(1, 15):
		if show_open(day_index + i):
			return day_index + i
	return -1

static func show_key(day_index: int, pid: String) -> String:
	return "show:%d:%s" % [day_index, pid]

static func rank_name(rank: int) -> String:
	match clampi(rank, 0, SHOW_RANKS.size() - 1):
		0:
			return tr("Novice")
		1:
			return tr("Bronze")
		2:
			return tr("Silver")
		3:
			return tr("Gold")
		_:
			return tr("Master")

static func show_rivals(rng: RandomNumberGenerator, rank: int) -> Array:
	var out: Array = []
	for i in 3:
		out.append(int(rng.randf_range(35.0, 60.0) + rank * 9.0))
	out.sort()
	out.reverse()
	return out

## Judges a Wildling against rivals of its own rank. Ties go to the rival.
## Returns {score, parts, rivals, place, prize, rank, rank_up}.
static func judge(c: Creature, rng: RandomNumberGenerator) -> Dictionary:
	var sc := Progression.show_score(c, rng)
	var rank := clampi(c.show_rank, 0, SHOW_RANKS.size() - 1)
	var rivals := show_rivals(rng, rank)
	var place := 1
	for s in rivals:
		if int(s) >= int(sc.score):
			place += 1
	var top: int = SHOW_RANKS[rank].prize
	var prize: int = [0, top, top / 3, top / 6, 50][place]
	return {
		"score": int(sc.score), "parts": sc.parts, "rivals": rivals, "place": place, "prize": prize,
		"rank": rank, "rank_up": place == 1 and rank < SHOW_RANKS.size() - 1,
	}

## Applies a judged result to the Wildling: a ribbon for 1st, and a step up the ladder.
static func award(c: Creature, res: Dictionary) -> void:
	if int(res.place) != 1:
		return
	c.ribbons += 1
	if res.rank_up:
		c.show_rank += 1

# --- Weekly bounty ----------------------------------------------------------------------

## A Wildling the Wildling Center wants to see this week, from regions the farm has opened.
## Returns {} if nothing is available, else {species, region, min_genes, reward, done}.
static func bounty_for(week: int, world_seed: int, regions: Array, dex: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, week, "bounty"])
	var pool: Array = []
	var home := {}
	for r in regions:
		for s in Data.regions.get(r, {}).get("spawns", []):
			var sid: String = s[0]
			if Data.species.has(sid) and not home.has(sid):
				pool.append(sid)
				home[sid] = r
	if pool.is_empty():
		return {}
	var fresh := pool.filter(func(sid): return not dex.get(sid, {}).get("owned", false))
	var from: Array = fresh if not fresh.is_empty() and rng.randf() < 0.6 else pool
	var sid: String = from[rng.randi() % from.size()]
	var region: String = home[sid]
	var min_genes := 0
	if rng.randf() < 0.45:
		min_genes = 35 + 5 * rng.randi_range(0, 4)
	var order := int(Data.regions[region].get("order", 0))
	return {
		"species": sid, "region": region, "min_genes": min_genes, "done": false,
		"reward": {"money": 500 + order * 250 + min_genes * 20, "deluxe_treat" if min_genes > 0 else "lure_charm": 2},
	}

static func bounty_met(b: Dictionary, c: Creature) -> bool:
	return not b.is_empty() and not b.get("done", false) and c.species_id == b.species and c.gene_total() >= int(b.min_genes)

static func bounty_text(b: Dictionary) -> String:
	if b.is_empty():
		return ""
	var name: String = Data.species.get(b.species, {}).get("name", b.species)
	var s := "Befriend or hatch a %s (%s)" % [name, Data.region_name(b.region)]
	if int(b.min_genes) > 0:
		s += " with genes %d+" % int(b.min_genes)
	return s

# --- Warden rematches -------------------------------------------------------------------

static func rematch_open(world: Dictionary) -> bool:
	return world.get("shrines", []).size() >= Adventure.SHRINE_COUNT

static func rematch_key(vid: String, week: int) -> String:
	return "rematch:%s:%d" % [vid, week]

static func rematch_tier(world: Dictionary) -> int:
	return int(world.get("stats", {}).get("rematch", 0)) / REMATCH_WINS_PER_TIER

static func rematch_level(tier: int) -> int:
	return mini(100, REMATCH_BASE + tier * REMATCH_STEP)

static func rematch_reward(vid: String, tier: int) -> Dictionary:
	var base := int(Data.villagers.get(vid, {}).get("trainer", {}).get("reward", 1000))
	var r := {"money": base * 2 + tier * 500, "deluxe_treat": 2}
	if tier >= 2:
		r["mystic_ore"] = 3 + tier
	return r

# --- Starry chains ----------------------------------------------------------------------

## Winning against or befriending the same species back to back builds a chain; any other
## species starts a new one. Chains raise Starry odds for that species (up to x5).
static func chain_after(chain: Dictionary, species: String) -> Dictionary:
	if chain.get("species", "") == species:
		return {"species": species, "n": mini(CHAIN_CAP, int(chain.n) + 1)}
	return {"species": species, "n": 1}

static func chain_mult(chain: Dictionary, species: String) -> float:
	if chain.get("species", "") != species:
		return 1.0
	return 1.0 + minf(float(chain.get("n", 0)), CHAIN_CAP) * 0.1

## Long chains draw that species out: it shows up more often where it already lives.
static func chain_lures(chain: Dictionary, spawns: Array) -> bool:
	if int(chain.get("n", 0)) < CHAIN_LURE:
		return false
	for s in spawns:
		if s[0] == chain.species:
			return true
	return false
