class_name Modifiers
extends RefCounted
## One place that adds up every bonus a player has: skills, enchantments, backpack, food buffs,
## buildings and the season. Each system registers a provider that returns {key: amount}.
##
## Amounts are fractions that stack by adding: two +10 % bonuses give mult() == 1.2.
## Known keys (keep in sync with skills.json and enchantments.json):
##   crop_growth, crop_yield, crop_quality, water_range, water_duration, job_power, job_energy,
##   wildling_regen, breed_speed, hatch_speed, den_slots, battle_damage, battle_heal, befriend,
##   battle_xp, move_speed, forage_luck, chest_luck, mine_speed, ore_luck,
##   chop_speed, fish_bite, fish_zone, fish_luck, craft_cost, enchant_cost, sell_price, shop_discount,
##   ship_bonus, offline_efficiency, casino_daily, light_radius

## name -> Callable(PlayerData) -> Dictionary
static var _providers: Dictionary = {}

static func register(name: String, provider: Callable) -> void:
	_providers[name] = provider

static func unregister(name: String) -> void:
	_providers.erase(name)

## Every bonus for a player, summed per key.
static func collect(p: PlayerData) -> Dictionary:
	var out := {}
	for name in _providers:
		var d: Dictionary = _providers[name].call(p)
		for k in d:
			out[k] = float(out.get(k, 0.0)) + float(d[k])
	return out

static func value(p: PlayerData, key: String) -> float:
	var total := 0.0
	for name in _providers:
		total += float(_providers[name].call(p).get(key, 0.0))
	return total

## 1.0 plus every bonus for `key`, never below `floor_v`.
static func mult(p: PlayerData, key: String, floor_v: float = 0.1) -> float:
	return maxf(floor_v, 1.0 + value(p, key))

## Where each bonus for `key` comes from, for tooltips: [[source, amount]].
static func breakdown(p: PlayerData, key: String) -> Array:
	var out: Array = []
	for name in _providers:
		var v := float(_providers[name].call(p).get(key, 0.0))
		if not is_zero_approx(v):
			out.append([name, v])
	return out
