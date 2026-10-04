class_name CropGrowth
extends RefCounted
## Real-time growth rules. A crop's `progress` runs 0..1 in real seconds: `grow_min` minutes when
## watered, in season and without bonuses. Off-season crops still grow, just slower and smaller;
## the greenhouse always counts as the best season plus a bonus.

const WATER_BOOST := 1.6
const WATER_SECONDS := 4 * 3600
const GREENHOUSE_RATE := 1.15
const GREENHOUSE_YIELD := 1.1
const SEASON_RATE := [1.0, 0.6, 0.35]
const SEASON_YIELD := [1.0, 0.75, 0.5]
const TIER_HARVESTS := [3, 6, 12, -1]
const BARE_SOIL_SECONDS := 48 * 3600
const TREE_DAY_SECONDS := 3600
const FRUIT_SECONDS := 2 * 3600
const MACHINE_SECONDS_PER_MINUTE := 2.0
const EGG_DAY_SECONDS := 2 * 3600

static func grow_minutes(crop_id: String) -> float:
	var c: Dictionary = Data.crops.get(crop_id, {})
	if c.has("grow_min"):
		return float(c.grow_min)
	return float(roundi(pow(float(c.get("days", 4)), 1.5) * 4.0))

static func regrow_progress(crop_id: String) -> float:
	var c: Dictionary = Data.crops.get(crop_id, {})
	if int(c.get("regrow", 0)) <= 0:
		return 0.0
	return clampf(1.0 - float(c.regrow) / maxf(1.0, float(c.days)), 0.0, 0.95)

## 0 = in season, 1 = a neighbouring season, 2 = the opposite one.
static func season_distance(crop_id: String, season: String) -> int:
	var seasons: Array = Data.crops.get(crop_id, {}).get("seasons", [])
	if season in seasons or seasons.is_empty():
		return 0
	var i := Calendar.SEASONS.find(season)
	var best := 2
	for s in seasons:
		var d := absi(Calendar.SEASONS.find(s) - i)
		best = mini(best, mini(d, 4 - d))
	return best

## `relief` (0..1) closes part of the off-season gap (skill tree).
static func season_rate(crop_id: String, season: String, greenhouse: bool, relief: float = 0.0) -> float:
	if greenhouse:
		return GREENHOUSE_RATE
	var r: float = SEASON_RATE[season_distance(crop_id, season)]
	return r + (1.0 - r) * clampf(relief, 0.0, 1.0)

static func season_yield(crop_id: String, season: String, greenhouse: bool, relief: float = 0.0) -> float:
	if greenhouse:
		return GREENHOUSE_YIELD
	var y: float = SEASON_YIELD[season_distance(crop_id, season)]
	return y + (1.0 - y) * clampf(relief, 0.0, 1.0)

## Progress per real second.
static func rate(crop_id: String, season: String, watered: bool, fert: String, greenhouse: bool, mult: float = 1.0, relief: float = 0.0) -> float:
	var r := 1.0 / (grow_minutes(crop_id) * 60.0)
	r *= season_rate(crop_id, season, greenhouse, relief)
	if not watered:
		r /= WATER_BOOST
	if fert == "speed":
		r *= 1.25
	return r * mult

## Seconds until ripe from `progress` under steady conditions.
static func eta(crop_id: String, progress: float, season: String, watered: bool, fert: String, greenhouse: bool, mult: float = 1.0, relief: float = 0.0) -> float:
	return maxf(0.0, 1.0 - progress) / rate(crop_id, season, watered, fert, greenhouse, mult, relief)

static func harvests_for_tier(tier: int) -> int:
	return TIER_HARVESTS[clampi(tier, 1, 4) - 1]

## Rounds a fractional amount up with the leftover as chance, never below one.
static func roll_amount(x: float, rng: RandomNumberGenerator) -> int:
	var n := int(floor(x))
	if rng.randf() < x - n:
		n += 1
	return maxi(1, n)

static func describe_tier(tier: int) -> String:
	var n := harvests_for_tier(tier)
	if n < 0:
		return TranslationServer.translate("Harvests forever")
	return TranslationServer.translate("%d harvests") % n
