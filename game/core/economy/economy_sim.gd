class_name EconomySim
extends RefCounted
## A greedy "spreadsheet farmer" that only grows and ships crops. It checks the money
## curve stays in a sane band: rewarding in week one, never runaway by the end of year one.

const START_MONEY := 500
const RESERVE := 50
const MIN_AFTER_SPRING := 1500
const MAX_AFTER_YEAR := 2_000_000

## Tiles a player can realistically tend on `day` (hand watering early, sprinklers and Tide helpers later).
static func capacity(day: int) -> int:
	return mini(400, 15 + day * 3)

static func _profit_per_day(c: Dictionary, days_left: int) -> float:
	var grow := int(c.days)
	if grow > days_left:
		return -1.0
	var harvests := 1
	if int(c.regrow) > 0:
		harvests += int((days_left - grow) / int(c.regrow))
	return (float(c.sell) * harvests - float(c.seed)) / float(days_left)

static func best_crop(season: String, days_left: int, money: int) -> String:
	var best := ""
	var best_v := 0.0
	for id in Data.crop_order:
		var c: Dictionary = Data.crops[id]
		if not season in c.seasons or int(c.seed) > money:
			continue
		var v := _profit_per_day(c, days_left)
		if v > best_v:
			best_v = v
			best = id
	return best

## Returns {money_by_season: Array[int], picks: Array[String], final, ok, flags}.
static func run(days: int = 112, _seed_value: int = 1) -> Dictionary:
	var money := START_MONEY
	var plots: Array = []         # {crop, age, ready}
	var by_season: Array = []
	var picks: Array = []
	var flags: Array = []
	for day in days:
		var season: String = Calendar.SEASONS[int(day / Calendar.DAYS_PER_SEASON) % 4]
		var day_in_season := day % Calendar.DAYS_PER_SEASON
		var days_left := Calendar.DAYS_PER_SEASON - day_in_season
		if day_in_season == 0:
			plots = plots.filter(func(p): return season in Data.crops[p.crop].seasons)
		var keep: Array = []
		for p in plots:
			var c: Dictionary = Data.crops[p.crop]
			p.age += 1
			if p.age >= p.ready:
				money += int(c.sell)
				if int(c.regrow) > 0:
					p.ready = p.age + int(c.regrow)
					keep.append(p)
			else:
				keep.append(p)
		plots = keep
		var free := capacity(day) - plots.size()
		var pick := best_crop(season, days_left, money - RESERVE)
		if pick != "" and free > 0:
			var seed_cost := int(Data.crops[pick].seed)
			var n := mini(free, (money - RESERVE) / maxi(1, seed_cost))
			for i in n:
				plots.append({"crop": pick, "age": 0, "ready": int(Data.crops[pick].days)})
			money -= n * seed_cost
			if day_in_season == 0 or picks.size() <= int(day / Calendar.DAYS_PER_SEASON):
				picks.append("%s: %s" % [season, pick])
		if day_in_season == Calendar.DAYS_PER_SEASON - 1:
			by_season.append(money)
	var ok := true
	if by_season.size() > 0 and by_season[0] < MIN_AFTER_SPRING:
		flags.append("spring ends with only %d gold (want >= %d)" % [by_season[0], MIN_AFTER_SPRING])
		ok = false
	if money > MAX_AFTER_YEAR:
		flags.append("runaway money: %d gold" % money)
		ok = false
	for i in range(1, mini(3, by_season.size())):
		if by_season[i] <= by_season[i - 1]:
			flags.append("money shrank in season %d" % (i + 1))
			ok = false
	return {"money_by_season": by_season, "picks": picks, "final": money, "ok": ok, "flags": flags}

static func format_report(rep: Dictionary) -> String:
	var lines: Array = ["Economy sim (crops only):"]
	for i in rep.money_by_season.size():
		lines.append("  end of %-6s %d gold" % [Calendar.SEASONS[i % 4], rep.money_by_season[i]])
	lines.append("  first picks: " + ", ".join(rep.picks))
	for f in rep.flags:
		lines.append("  - " + f)
	return "\n".join(lines)
