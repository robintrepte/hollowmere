class_name BalanceSim
extends RefCounted
## Round-robin AI-vs-AI duels used to sanity-check the type chart, base stats and movepools.

const MAX_TURNS := 80
const SPECIES_BAND := [0.15, 0.85]
const TYPE_BAND := [0.33, 0.67]

static func make(id: String, level: int, rng: RandomNumberGenerator) -> Creature:
	var sp: Dictionary = Data.get_species(id)
	return Creature.create(id, level, rng, {"nature": "hardy", "trait": sp.traits[0], "starry": false,
		"genes": {"hp": 8, "power": 8, "guard": 8, "focus": 8, "speed": 8}})

## 0 = a wins, 1 = b wins, -1 = draw (turn cap).
static func duel(a_id: String, b_id: String, level: int, seed_value: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var eng := BattleEngine.new([make(a_id, level, rng)], [make(b_id, level, rng)], BattleEngine.Kind.PVP, seed_value)
	eng.sides[0].ai_level = 2
	eng.sides[1].ai_level = 2
	eng.start()
	while not eng.is_over() and eng.turn < MAX_TURNS:
		eng.submit(BattleAI.choose_action(eng, 0), BattleAI.choose_action(eng, 1))
	match eng.result:
		"win": return 0
		"lose": return 1
	return -1

## Fully evolved, non-legendary species: the fairest pool to compare.
static func pool() -> Array:
	var out: Array = []
	for id in Data.species:
		var sp: Dictionary = Data.species[id]
		if sp.evo == null and not sp.get("legendary", false):
			out.append(id)
	out.sort()
	return out

## Returns {species: {id: {w, l, d, rate}}, types: {t: {w, l, rate}}, battles, draws, flags: Array[String], ok}.
static func run(level: int = 40, rounds: int = 2, seed_value: int = 1) -> Dictionary:
	var ids := pool()
	var sp_stats := {}
	var ty_stats := {}
	for id in ids:
		sp_stats[id] = {"w": 0, "l": 0, "d": 0}
		for t in Data.species[id].types:
			if not ty_stats.has(t):
				ty_stats[t] = {"w": 0, "l": 0}
	var battles := 0
	var draws := 0
	var s := seed_value
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			for r in rounds:
				s += 1
				var a: String = ids[i] if r % 2 == 0 else ids[j]
				var b: String = ids[j] if r % 2 == 0 else ids[i]
				var res := duel(a, b, level, s)
				battles += 1
				if res < 0:
					draws += 1
					sp_stats[a].d += 1
					sp_stats[b].d += 1
					continue
				var win: String = a if res == 0 else b
				var lose: String = b if res == 0 else a
				sp_stats[win].w += 1
				sp_stats[lose].l += 1
				for t in Data.species[win].types:
					ty_stats[t].w += 1
				for t in Data.species[lose].types:
					ty_stats[t].l += 1
	var flags: Array = []
	var ok := true
	for id in sp_stats:
		var e: Dictionary = sp_stats[id]
		e["rate"] = float(e.w) / float(maxi(1, e.w + e.l))
		if e.rate < SPECIES_BAND[0] or e.rate > SPECIES_BAND[1]:
			flags.append("species %s win rate %.2f" % [id, e.rate])
	for t in ty_stats:
		var e2: Dictionary = ty_stats[t]
		e2["rate"] = float(e2.w) / float(maxi(1, e2.w + e2.l))
		if e2.rate < TYPE_BAND[0] or e2.rate > TYPE_BAND[1]:
			flags.append("type %s win rate %.2f" % [t, e2.rate])
			ok = false
	if float(draws) / float(maxi(1, battles)) > 0.05:
		flags.append("too many draws: %d / %d" % [draws, battles])
		ok = false
	return {"species": sp_stats, "types": ty_stats, "battles": battles, "draws": draws, "flags": flags, "ok": ok}

static func format_report(rep: Dictionary) -> String:
	var lines: Array = ["Balance sim: %d battles, %d draws" % [rep.battles, rep.draws], "", "Types:"]
	var types: Array = rep.types.keys()
	types.sort_custom(func(a, b): return rep.types[a].rate > rep.types[b].rate)
	for t in types:
		lines.append("  %-6s %.2f  (%d-%d)" % [t, rep.types[t].rate, rep.types[t].w, rep.types[t].l])
	lines.append("")
	lines.append("Species (best and worst 8):")
	var ids: Array = rep.species.keys()
	ids.sort_custom(func(a, b): return rep.species[a].rate > rep.species[b].rate)
	for i in ids.size():
		if i < 8 or i >= ids.size() - 8:
			var e: Dictionary = rep.species[ids[i]]
			lines.append("  %-12s %.2f  (%d-%d-%d)" % [ids[i], e.rate, e.w, e.l, e.d])
		elif i == 8:
			lines.append("  ...")
	if not rep.flags.is_empty():
		lines.append("")
		lines.append("Flags:")
		for f in rep.flags:
			lines.append("  - " + f)
	return "\n".join(lines)
