class_name BattleAI
extends RefCounted
## Opponent decision making. ai_level: 0 = wild (playful), 1 = trainer, 2 = warden (smart).

static func choose_action(engine: BattleEngine, side: int) -> Dictionary:
	var s: BattleEngine.BattleSide = engine.sides[side]
	var me: Creature = s.current()
	var foe: Creature = engine.active(engine.foe_of(side))
	var lvl: int = s.ai_level
	if lvl >= 2 and engine.can_switch(side):
		var sw := _consider_switch(engine, side)
		if sw >= 0:
			return {"k": "switch", "i": sw}
	var scores: Array = []
	for i in me.moves.size():
		scores.append(score_move(engine, side, me.moves[i], lvl))
	if scores.is_empty():
		return {"k": "move", "i": 0}
	if lvl == 0:
		# Wild: weighted random, favoring damaging moves.
		var total := 0.0
		for sc in scores:
			total += maxf(1.0, sc)
		var r := engine.rng.randf() * total
		for i in scores.size():
			r -= maxf(1.0, scores[i])
			if r <= 0.0:
				return {"k": "move", "i": i}
		return {"k": "move", "i": 0}
	var best := 0
	for i in scores.size():
		if scores[i] > scores[best]:
			best = i
	if lvl == 1 and engine.rng.randf() < 0.25:
		best = engine.rng.randi() % scores.size()
	return {"k": "move", "i": best}

static func score_move(engine: BattleEngine, side: int, move_id: String, lvl: int) -> float:
	var m: Dictionary = Data.get_move(move_id)
	var me: Creature = engine.active(side)
	var foe: Creature = engine.active(engine.foe_of(side))
	var stages: Dictionary = engine.sides[side].stages
	if m.cat == "status":
		var sc := 20.0
		for e in m.get("effects", []):
			match e.k:
				"heal", "rest":
					var frac := float(me.hp) / float(me.max_hp())
					sc = 90.0 * (1.0 - frac) if frac < 0.5 else 5.0
				"status":
					sc = 45.0 if foe.status == "" else 0.0
				"stat":
					var tgt_self: bool = e.get("target", "foe") == "self"
					var cur: int = int(stages.get(e.stat, 0)) if tgt_self else int(engine.sides[engine.foe_of(side)].stages.get(e.stat, 0))
					if tgt_self:
						sc = 35.0 if cur < 2 else 0.0
					else:
						sc = 30.0 if cur > -2 else 0.0
		if lvl >= 2 and me.hp == me.max_hp():
			sc *= 1.3
		return sc
	var est := engine.calc_damage(side, move_id, true)
	var acc := float(m.acc) / 100.0 if int(m.acc) > 0 else 1.0
	var dmg := float(est.damage) * acc
	if dmg >= foe.hp:
		dmg += 60.0 + float(m.get("prio", 0)) * 20.0
	return dmg

static func _consider_switch(engine: BattleEngine, side: int) -> int:
	var s: BattleEngine.BattleSide = engine.sides[side]
	var me: Creature = s.current()
	var foe: Creature = engine.active(engine.foe_of(side))
	var threat := _matchup(foe, me)
	if threat < 2.0 or me.hp * 3 < me.max_hp():
		return -1
	var best := -1
	var best_score := threat
	for i in s.team.size():
		var c: Creature = s.team[i]
		if i == s.active or c.is_fainted():
			continue
		var t := _matchup(foe, c)
		if t < best_score:
			best_score = t
			best = i
	if best >= 0 and engine.rng.randf() < 0.6:
		return best
	return -1

## How dangerous `attacker`'s types are to `defender` (max multiplier).
static func _matchup(attacker: Creature, defender: Creature) -> float:
	var worst := 0.0
	for t in attacker.types():
		worst = maxf(worst, Data.type_mult(t, defender.types()))
	return worst

static func choose_replacement(engine: BattleEngine, side: int) -> int:
	var s: BattleEngine.BattleSide = engine.sides[side]
	var foe: Creature = engine.active(engine.foe_of(side))
	var best := -1
	var best_score := -1.0
	for i in s.team.size():
		var c: Creature = s.team[i]
		if c.is_fainted():
			continue
		var offense := 0.0
		for t in c.types():
			offense = maxf(offense, Data.type_mult(t, foe.types()))
		var sc := offense - _matchup(foe, c) * 0.5 + float(c.level) * 0.01
		if s.ai_level == 0:
			sc = engine.rng.randf()
		if sc > best_score:
			best_score = sc
			best = i
	return best
