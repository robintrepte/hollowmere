class_name FarmJobs
extends RefCounted
## Overnight work done by Wildlings assigned to farm jobs, plus daily produce.

const JOB_COST := 25
const JOBS := ["water", "grow", "clear", "smelt", "pollinate", "power", "preserve", "guard", "luck", "harvest"]

static func job_name(job_id: String) -> String:
	for t in Data.types:
		if Data.types[t].job == job_id:
			return Data.types[t].job_name
	return "Resting"

static func job_type(job_id: String) -> String:
	for t in Data.types:
		if Data.types[t].job == job_id:
			return t
	return ""

## Runs all jobs. `ctx` = {grids: Array[FarmGrid], chest: Inventory, rng, season, spa: bool, minute_now: int}
## Returns a report dictionary for the morning summary.
static func run(workers: Array, ctx: Dictionary) -> Dictionary:
	var rng: RandomNumberGenerator = ctx.rng
	var chest: Inventory = ctx.chest
	var grids: Array = ctx.grids
	var rep := {
		"watered": 0, "grown": 0, "cleared": 0, "smelted": 0, "pollinated": 0, "preserved": 0,
		"harvested": 0, "powered": 0, "machine_slots": 0, "machines_loaded": 0, "machines_collected": 0, "guarded": false, "luck": 0.0, "frost_protect": 0,
		"items": {}, "produce": {}, "workers": 0, "tired": 0, "overflow": {},
	}
	# Order matters: harvest first (frees ripe crops), then water/grow.
	var order := ["clear", "harvest", "water", "grow", "pollinate", "smelt", "preserve", "power", "guard", "luck"]
	var by_job := {}
	for c in workers:
		if c.job == "" or not c.can_do_job(c.job):
			continue
		if not by_job.has(c.job):
			by_job[c.job] = []
		by_job[c.job].append(c)
	for job in order:
		for c in by_job.get(job, []):
			var cost := int(JOB_COST * float(Data.traits.get(c.trait_id, {}).get("energy_cost_mult", 1.0)))
			if c.energy < cost:
				rep.tired += 1
				continue
			c.energy -= cost
			rep.workers += 1
			var power: int = c.job_power(job)
			_do_job(job, c, power, grids, chest, rng, rep, ctx)
			c.gain_xp(3 + power)
			c.change_happiness(1)
			if int(Data.traits.get(c.trait_id, {}).get("forage_bonus", 0)) > 0 and rng.randf() < 0.5:
				_give(chest, _random_forage(ctx.season, rng), 1, 0, rep)
	return rep

static func _give(chest: Inventory, id: String, n: int, q: int, rep: Dictionary) -> void:
	if id == "" or n <= 0:
		return
	var left := chest.add(id, n, q)
	if left > 0:
		rep.overflow[id] = int(rep.overflow.get(id, 0)) + left
	var got := n - left
	if got > 0:
		rep.items[id] = int(rep.items.get(id, 0)) + got

static func _random_forage(season: String, rng: RandomNumberGenerator) -> String:
	var f: Dictionary = Data.regions.meadow.forage
	var arr: Array = f.get(season, ["wild_berry"])
	return arr[rng.randi() % arr.size()]

static func _do_job(job: String, c: Creature, power: int, grids: Array, chest: Inventory, rng: RandomNumberGenerator, rep: Dictionary, ctx: Dictionary) -> void:
	match job:
		"water":
			var n := power * 4
			for g in grids:
				for p in g.planted_tiles():
					if n <= 0:
						break
					if g.water(p):
						n -= 1
						rep.watered += 1
		"grow":
			var n2 := power * 3
			for g in grids:
				for p in g.planted_tiles():
					if n2 <= 0:
						break
					if not g.crop_ready(p) and rng.randf() < 0.5:
						var crop: Dictionary = g.crop_at(p)
						crop.age = float(crop.age) + 0.5
						n2 -= 1
						rep.grown += 1
		"clear":
			var n3 := power * 2
			for g in grids:
				for i in g.deco.size():
					if n3 <= 0:
						break
					var d: int = g.deco[i]
					if d in [Tiles.DECO.weed, Tiles.DECO.rock, Tiles.DECO.branch] or (d == Tiles.DECO.stump and power >= 3) or (d == Tiles.DECO.boulder and power >= 5):
						var res: Dictionary = g.clear_debris(Vector2i(i % g.w, int(i / g.w)), Tiles.DEBRIS[d].tool, 9, rng)
						if res.ok:
							for dr in res.drops:
								_give(chest, dr[0], int(dr[1]), 0, rep)
							n3 -= 1
							rep.cleared += 1
		"harvest":
			var n4 := power * 3
			for g in grids:
				for p in g.planted_tiles():
					if n4 <= 0:
						break
					if g.crop_ready(p):
						var h: Dictionary = g.harvest(p, rng, 0.0, 0)
						if not h.is_empty():
							_give(chest, h.id, int(h.n), int(h.q), rep)
							n4 -= 1
							rep.harvested += int(h.n)
				for k in g.objects:
					var o: Dictionary = g.objects[k]
					if n4 > 0 and o.kind == "tree" and int(o.get("fruit", 0)) > 0:
						var fr: Dictionary = g.shake_tree(Tiles.parse_key(k))
						_give(chest, fr.id, int(fr.n), 0, rep)
						n4 -= 1
						rep.harvested += int(fr.n)
		"pollinate":
			var n5 := power * 4
			for g in grids:
				for p in g.planted_tiles():
					if n5 <= 0:
						break
					var crop2: Dictionary = g.crop_at(p)
					if not bool(crop2.pollinated):
						crop2.pollinated = true
						crop2.quality_boost = int(crop2.get("quality_boost", 0)) + int(Data.traits.get(c.trait_id, {}).get("quality_bonus", 0))
						n5 -= 1
						rep.pollinated += 1
			if rng.randf() < 0.4 + 0.1 * power:
				_give(chest, _random_forage(ctx.season, rng), 1, 0, rep)
		"smelt":
			var n6 := power
			for ore_bar in [["copper_ore", "copper_bar"], ["iron_ore", "iron_bar"], ["gold_ore", "gold_bar"], ["mystic_ore", "mystic_bar"]]:
				while n6 > 0 and chest.count(ore_bar[0]) >= 5:
					chest.remove(ore_bar[0], 5)
					_give(chest, ore_bar[1], 1, 0, rep)
					rep.smelted += 1
					n6 -= 1
			for g in grids:
				for i in g.deco.size():
					if g.deco[i] == Tiles.DECO.weed and rng.randf() < 0.3:
						g.deco[i] = 0
		"preserve":
			var n7 := power
			rep.frost_protect += power * 4
			for e in chest.entries_of_cat(["crop", "fruit"]).duplicate():
				if n7 <= 0:
					break
				var amount := mini(int(e.n), 3)
				var id: String = e.id
				var q: int = int(e.q)
				chest.take(e.uid, amount)
				_give(chest, "preserved:" + id, amount, q, rep)
				rep.preserved += amount
				n7 -= 1
		"power":
			rep.powered += power * 60
			rep.machine_slots += power * 2
		"guard":
			rep.guarded = true
		"luck":
			rep.luck += 0.01 * power
			if rng.randf() < 0.08 * power:
				var gems := ["quartz", "amethyst", "topaz", "aquamarine", "emerald", "ruby"]
				_give(chest, gems[mini(gems.size() - 1, rng.randi() % (2 + power))], 1, 0, rep)

## Daily produce from happy Wildlings living on the farm (all den residents).
static func collect_produce(residents: Array, chest: Inventory, rng: RandomNumberGenerator, rep: Dictionary) -> void:
	for c in residents:
		var pid: String = c.species().get("produce", "")
		if pid == "":
			continue
		var chance := 0.35 + float(c.happiness) / 400.0
		if rng.randf() < chance:
			var q := 0
			if c.happiness > 200:
				q = 2 if rng.randf() < 0.5 else 1
			elif c.happiness > 140:
				q = 1 if rng.randf() < 0.5 else 0
			var left := chest.add(pid, 1, q)
			if left == 0:
				rep.produce[pid] = int(rep.produce.get(pid, 0)) + 1

## Overnight energy recovery for everyone at the farm.
static func rest(residents: Array, spa: bool) -> void:
	for c in residents:
		var regen := 40 + int(Data.traits.get(c.trait_id, {}).get("energy_regen_bonus", 0))
		if spa:
			regen = 100
			c.change_happiness(2)
		c.energy = mini(100, c.energy + regen)
		if c.job == "" and not spa:
			c.energy = mini(100, c.energy + 30)
