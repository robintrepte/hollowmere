class_name Skills
extends RefCounted
## Player XP, levels and the skill tree (data/skills.json). Each player has their own tree;
## points come from levels, finished story chapters, woken shrines and quest rewards.
## Invested ranks feed the Modifiers registry through the "skills" provider.

const MAX_LEVEL := 60
const RESPEC_BASE := 1000

## XP per counted action (PlayerData.stat_add keys).
const STAT_XP := {
	"till": 1, "water": 1, "plant": 1, "harvested": 2, "cleared": 1, "foraged": 3, "ship": 1,
	"craft": 4, "cook": 5, "befriend": 25, "mine_floor": 10, "win_battle": 12, "trainer_wins": 30,
	"gifts": 3, "fish": 6, "mined": 1, "enchant": 15, "casino_round": 0,
}
## XP for a claimed quest, by type.
const QUEST_XP := {"main": 150, "side": 80, "daily": 40, "weekly": 120, "tutorial": 15, "seasonal": 150, "event": 150}

## Effect text per modifier key; %s is the formatted amount.
const EFFECT_TEXT := {
	"crop_growth": "%s crop growth", "crop_yield": "%s crop yield", "crop_quality": "%s crop quality",
	"water_range": "%s watering reach", "water_duration": "%s watering duration",
	"seed_return": "%s chance to get a seed back on the last harvest", "season_relief": "%s less off-season slowdown",
	"farm_energy": "%s energy for hoe, can and shovel", "happiness": "%s Wildling happiness",
	"job_power": "%s farm job output", "job_energy": "%s farm job energy", "wildling_regen": "%s Wildling energy recovery",
	"breed_speed": "%s egg chance for pairs", "hatch_speed": "%s hatching speed", "den_slots": "%s farm slots",
	"produce": "%s Wildling produce", "battle_damage": "%s damage in battle", "battle_heal": "%s healing in battle",
	"befriend": "%s befriend chance", "battle_xp": "%s battle XP", "battle_guard": "%s less damage taken",
	"move_speed": "%s walking speed", "max_energy": "%s max energy", "energy_cost": "%s energy for all tools",
	"energy_regen": "%s energy recovery while away", "forage_luck": "%s forage finds", "chest_luck": "%s chest loot",
	"craft_extra": "%s chance to craft an extra one", "ore_luck": "%s ore finds", "mine_speed": "%s mining speed",
	"fish_bite": "%s faster bites", "fish_zone": "%s larger catch zone", "fish_luck": "%s fishing treasure",
	"machine_speed": "%s machine speed", "enchant_cost": "%s enchanting cost", "sell_price": "%s sell prices",
	"shop_discount": "%s shop discount", "friendship": "%s friendship gain", "ship_bonus": "%s shipping bin payout",
	"offline_efficiency": "%s farm work while away", "casino_daily": "%s daily chip bonus",
	"dmg_leaf": "%s Leaf damage", "dmg_tide": "%s Tide damage", "dmg_ember": "%s Ember damage",
	"dmg_stone": "%s Stone damage", "dmg_gale": "%s Gale damage", "dmg_spark": "%s Spark damage",
	"dmg_frost": "%s Frost damage", "dmg_shade": "%s Shade damage", "dmg_glow": "%s Glow damage",
	"dmg_wild": "%s Wild damage",
}
## Keys counted in whole steps rather than percent.
const FLAT_KEYS := ["water_range", "den_slots"]
const UNLOCK_TEXT := {
	"harvest_sweep": "Unlocks: the scythe harvests a 3×3 area",
	"map_travel": "Unlocks: travel from the Map to any open region",
	"craft_x10": "Unlocks: craft ×10 at once",
}

static var _by_id: Dictionary = {}

static func node(id: String) -> Dictionary:
	if _by_id.is_empty() or _by_id.size() != Data.skill_nodes.size():
		_by_id.clear()
		for n in Data.skill_nodes:
			_by_id[str(n.id)] = n
	return _by_id.get(id, {})

static func nodes() -> Array:
	return Data.skill_nodes

static func branch(id: String) -> Dictionary:
	return Data.skill_branches.get(id, {})

# --- XP and levels -----------------------------------------------------------------------

static func xp_to_next(level: int) -> int:
	return 30 + 15 * level + level * level

## Adds XP; returns how many levels were gained.
static func add_xp(p: PlayerData, n: int) -> int:
	if n <= 0 or p.level >= MAX_LEVEL:
		return 0
	p.xp += n
	var ups := 0
	while p.level < MAX_LEVEL and p.xp >= xp_to_next(p.level):
		p.xp -= xp_to_next(p.level)
		p.level += 1
		ups += 1
	if p.level >= MAX_LEVEL:
		p.xp = 0
	return ups

static func xp_for_stat(key: String, n: int) -> int:
	return int(STAT_XP.get(key, 0)) * maxi(0, n)

# --- Points ------------------------------------------------------------------------------

## Points from levels, the farm's story and shrines, and quest rewards.
static func points_total(p: PlayerData, world: Dictionary) -> int:
	var story := int(world.get("quest", 0))
	var shrines: int = world.get("shrines", []).size()
	return (p.level - 1) + story + shrines + p.skill_points

static func points_spent(p: PlayerData) -> int:
	var n := 0
	for id in p.tree:
		n += int(p.tree[id])
	return n

static func points_free(p: PlayerData, world: Dictionary) -> int:
	return maxi(0, points_total(p, world) - points_spent(p))

static func rank(p: PlayerData, id: String) -> int:
	return int(p.tree.get(id, 0))

static func branch_points(p: PlayerData, branch_id: String) -> int:
	var n := 0
	for id in p.tree:
		if str(node(id).get("branch", "")) == branch_id:
			n += int(p.tree[id])
	return n

## Requirements and branch points are met (a free point is all that is missing, if anything).
static func reachable(p: PlayerData, id: String) -> bool:
	var n := node(id)
	if n.is_empty():
		return false
	if rank(p, id) > 0:
		return true
	var reqs: Array = n.get("req", [])
	if not reqs.is_empty() and not reqs.any(func(r): return rank(p, str(r)) > 0):
		return false
	return branch_points(p, str(n.branch)) >= int(n.get("need", 0))

## "" when the next rank can be bought, else why not (translated).
static func blocker(p: PlayerData, world: Dictionary, id: String) -> String:
	var n := node(id)
	if n.is_empty():
		return TranslationServer.translate("Unknown skill.")
	if rank(p, id) >= int(n.ranks):
		return TranslationServer.translate("Already maxed.")
	var reqs: Array = n.get("req", [])
	if rank(p, id) == 0 and not reqs.is_empty() and not reqs.any(func(r): return rank(p, str(r)) > 0):
		return TranslationServer.translate("Learn a connected skill first.")
	if branch_points(p, str(n.branch)) < int(n.get("need", 0)):
		return TranslationServer.translate("Needs %d points in this branch.") % int(n.need)
	if points_free(p, world) <= 0:
		return TranslationServer.translate("No skill points left.")
	return ""

static func can_invest(p: PlayerData, world: Dictionary, id: String) -> bool:
	return blocker(p, world, id) == ""

static func invest(p: PlayerData, world: Dictionary, id: String) -> bool:
	if not can_invest(p, world, id):
		return false
	p.tree[id] = rank(p, id) + 1
	p.mods_dirty = true
	return true

static func respec_cost(p: PlayerData) -> int:
	return RESPEC_BASE * (p.respecs + 1)

## Clears the tree; the caller takes the gold.
static func respec(p: PlayerData) -> void:
	p.tree = {}
	p.respecs += 1
	p.mods_dirty = true

# --- Effects -----------------------------------------------------------------------------

## Summed modifiers of every invested rank, cached on the player until the tree changes.
static func mods(p: PlayerData) -> Dictionary:
	if not p.mods_dirty:
		return p.mods_cache
	var out := {}
	for id in p.tree:
		var n := node(id)
		var r := int(p.tree[id])
		for k in n.get("mods", {}):
			out[k] = float(out.get(k, 0.0)) + float(n.mods[k]) * r
	p.mods_cache = out
	p.mods_dirty = false
	return out

static func has_unlock(p: PlayerData, key: String) -> bool:
	if p == null:
		return false
	for id in p.tree:
		if int(p.tree[id]) > 0 and str(node(id).get("unlock", "")) == key:
			return true
	return false

static func format_amount(key: String, v: float) -> String:
	if key in FLAT_KEYS:
		return "%+d" % int(round(v))
	var pct := v * 100.0
	var txt := Num.decimal(absf(pct), 0 if is_equal_approx(pct, round(pct)) else 1)
	return ("+" if pct >= 0 else "−") + txt + " %"

## One line per effect at `ranks` ranks, plus the unlock if any.
static func effect_lines(n: Dictionary, ranks: int) -> Array:
	var out: Array = []
	for k in n.get("mods", {}):
		var fmt := str(TranslationServer.translate(EFFECT_TEXT.get(k, k + " %s")))
		out.append(fmt % format_amount(k, float(n.mods[k]) * ranks))
	if n.has("unlock"):
		out.append(str(TranslationServer.translate(UNLOCK_TEXT.get(str(n.unlock), str(n.unlock)))))
	return out

static func node_name(n: Dictionary) -> String:
	return str(TranslationServer.translate(str(n.get("name", ""))))
