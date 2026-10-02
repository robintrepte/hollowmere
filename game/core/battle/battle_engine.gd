class_name BattleEngine
extends RefCounted
## Deterministic 1v1 turn-based battle simulation. Produces event lists that the
## battle UI animates. Side 0 is the player (or host in PvP), side 1 the opponent.

enum Kind { WILD, TRAINER, PVP }

const STAGE_STATS := ["power", "guard", "focus", "speed"]
const MAJOR_STATUS := ["burn", "soak", "root", "daze", "sleep"]
const WEATHER_TURNS := 5
const WEATHER := {
	"sun": {"mult": {"ember": 1.5, "tide": 0.6}, "start": "The sunlight turned harsh!", "end": "The sunlight faded."},
	"rain": {"mult": {"tide": 1.5, "ember": 0.6}, "start": "Rain started to pour!", "end": "The rain stopped."},
	"storm": {"mult": {"spark": 1.3, "gale": 1.3}, "start": "A thunderstorm rolled in!", "end": "The storm passed."},
	"snow": {"mult": {"frost": 1.5}, "start": "Snow began to fall!", "end": "The snow stopped."},
	"fog": {"mult": {"shade": 1.3, "glow": 0.8}, "start": "A thick fog rolled in!", "end": "The fog lifted."},
}
## Overworld weather -> battle weather. Plain sunny days are a clear field.
const OVERWORLD_WEATHER := {"rain": "rain", "storm": "storm", "snow": "snow", "fog": "fog"}

class BattleSide:
	var name: String = ""
	var team: Array = []
	var active: int = 0
	var stages: Dictionary = {"power": 0, "guard": 0, "focus": 0, "speed": 0}
	var ai_level: int = 0
	var sturdy_used: Dictionary = {}
	var items: Dictionary = {}           # AI-only item stock {item_id: count}

	func current() -> Creature:
		return team[active]

	func alive_count() -> int:
		var n := 0
		for c in team:
			if not c.is_fainted():
				n += 1
		return n

	func first_alive() -> int:
		for i in team.size():
			if not team[i].is_fainted():
				return i
		return -1

	func reset_stages() -> void:
		for s in stages:
			stages[s] = 0

var sides: Array = []
var kind: int = Kind.WILD
var rng := RandomNumberGenerator.new()
var turn: int = 0
var result: String = ""
var befriended: Creature = null
var participants: Dictionary = {}
var xp_mult: float = 1.0
var run_attempts: int = 0
var weather: String = ""
var weather_turns: int = -1            # -1 = lasts the whole battle
var base_weather: String = ""

func _init(player_team: Array, foe_team: Array, battle_kind: int = Kind.WILD, seed_value: int = 0, foe_name: String = "", player_name: String = "You") -> void:
	kind = battle_kind
	rng.seed = seed_value if seed_value != 0 else randi()
	var a := BattleSide.new()
	a.name = player_name
	a.team = player_team
	a.active = max(0, a.first_alive())
	var b := BattleSide.new()
	b.name = foe_name
	b.team = foe_team
	b.active = max(0, b.first_alive())
	b.ai_level = 0 if battle_kind == Kind.WILD else 1
	sides = [a, b]
	if battle_kind == Kind.TRAINER:
		xp_mult = 1.5

## Sets the field weather the battle starts with (pass the overworld weather id).
func set_field_weather(overworld: String) -> void:
	base_weather = OVERWORLD_WEATHER.get(overworld, "")
	weather = base_weather
	weather_turns = -1

func weather_mult(move_type: String) -> float:
	if weather == "":
		return 1.0
	return float(WEATHER[weather].mult.get(move_type, 1.0))

func active(side: int) -> Creature:
	return sides[side].current()

func foe_of(side: int) -> int:
	return 1 - side

func is_over() -> bool:
	return result != ""

func start() -> Array:
	var ev: Array = []
	participants[active(0).uid] = true
	if kind == Kind.WILD:
		var foe := active(1)
		ev.append({"t": "text", "msg": "A wild %s%s appeared!" % ["Starry " if foe.starry else "", foe.display_name()]})
	else:
		ev.append({"t": "text", "msg": "%s wants to battle!" % sides[1].name})
		ev.append({"t": "switch", "side": 1, "index": sides[1].active, "species": active(1).species_id})
		ev.append({"t": "text", "msg": "%s sent out %s!" % [sides[1].name, active(1).display_name()]})
	ev.append({"t": "switch", "side": 0, "index": sides[0].active, "species": active(0).species_id})
	ev.append({"t": "text", "msg": "Go, %s!" % active(0).display_name()})
	if weather != "":
		ev.append({"t": "weather", "w": weather})
		ev.append({"t": "text", "msg": {"rain": "It's raining.", "storm": "A storm is raging.", "snow": "Snow is falling.", "fog": "The fog is thick.", "sun": "The sunlight is harsh."}[weather]})
	_on_entry(0, ev)
	_on_entry(1, ev)
	return ev

func _on_entry(side: int, ev: Array) -> void:
	var c := active(side)
	var tr: Dictionary = Data.traits.get(c.trait_id, {})
	if tr.has("entry_foe_stat"):
		var e: Array = tr.entry_foe_stat
		_apply_stage(foe_of(side), e[0], int(e[1]), ev, "%s's %s" % [c.display_name(), tr.name])

## Returns true if `side` must choose a replacement before the next turn.
func needs_switch(side: int) -> bool:
	return not is_over() and active(side).is_fainted() and sides[side].alive_count() > 0

func can_switch(side: int) -> bool:
	return active(side).status != "root" or active(side).is_fainted()

func force_switch(side: int, index: int) -> Array:
	var ev: Array = []
	_do_switch(side, index, ev)
	return ev

func _do_switch(side: int, index: int, ev: Array) -> void:
	var s: BattleSide = sides[side]
	if index < 0 or index >= s.team.size() or s.team[index].is_fainted() or index == s.active and not s.current().is_fainted():
		return
	var old := s.current()
	if not old.is_fainted():
		ev.append({"t": "text", "msg": "%s, come back!" % old.display_name()} if side == 0 else {"t": "text", "msg": "%s withdrew %s." % [s.name, old.display_name()]})
	if old.status == "root" or old.status == "daze":
		old.status = ""
	s.active = index
	s.reset_stages()
	if side == 0:
		participants[s.current().uid] = true
	ev.append({"t": "switch", "side": side, "index": index, "species": s.current().species_id})
	ev.append({"t": "text", "msg": ("Go, %s!" % s.current().display_name()) if side == 0 else ("%s sent out %s!" % [s.name, s.current().display_name()])})
	_on_entry(side, ev)

## Resolves one turn. Actions: {k:"move", i:int} {k:"switch", i:int} {k:"item", id:String, target:int}
## {k:"befriend", id:String} (treat or charm) {k:"run"}
func submit(a0: Dictionary, a1: Dictionary) -> Array:
	var ev: Array = []
	if is_over():
		return ev
	turn += 1
	var acts := [a0, a1]
	# 1. Run / forfeit
	for side in [0, 1]:
		if acts[side].get("k", "") == "run":
			if kind == Kind.WILD and side == 0:
				run_attempts += 1
				if active(0).status == "root":
					ev.append({"t": "text", "msg": "%s is rooted and can't escape!" % active(0).display_name()})
					acts[0] = {"k": "none"}
				else:
					ev.append({"t": "text", "msg": "You got away safely!"})
					_end("run", ev)
					return ev
			elif kind == Kind.PVP:
				ev.append({"t": "text", "msg": "%s forfeited." % sides[side].name})
				_end("lose" if side == 0 else "win", ev)
				return ev
			else:
				acts[side] = {"k": "none"}
	# 2. Switches (faster first)
	var order := [0, 1]
	if _eff_speed(1) > _eff_speed(0):
		order = [1, 0]
	for side in order:
		if acts[side].get("k", "") == "switch":
			if can_switch(side):
				_do_switch(side, int(acts[side].i), ev)
			else:
				ev.append({"t": "text", "msg": "%s is rooted and can't switch!" % active(side).display_name()})
	# 3. Items
	for side in order:
		if acts[side].get("k", "") == "item":
			_use_item(side, acts[side].id, int(acts[side].get("target", sides[side].active)), ev)
	# 4. Befriend
	if acts[0].get("k", "") == "befriend" and kind == Kind.WILD:
		_try_befriend(acts[0].id, ev)
		if is_over():
			return ev
	# 5. Moves
	var movers: Array = []
	for side in [0, 1]:
		if acts[side].get("k", "") == "move":
			movers.append(side)
	var keys := {}
	for side in movers:
		keys[side] = _move_order_key(side, acts[side])
	movers.sort_custom(func(x, y): return keys[x] > keys[y])
	for side in movers:
		if is_over():
			break
		var user := active(side)
		if user.is_fainted():
			continue
		var target_side := foe_of(side)
		if active(target_side).is_fainted():
			continue
		var idx: int = int(acts[side].i)
		var move_id: String = user.moves[idx] if idx >= 0 and idx < user.moves.size() else "struggle"
		_execute_move(side, move_id, ev)
		_check_faints(ev)
	# 6. End of turn
	if not is_over():
		_end_of_turn(ev)
		_check_faints(ev)
	return ev

func _move_order_key(side: int, act: Dictionary) -> float:
	var c := active(side)
	var idx: int = int(act.get("i", 0))
	var mid: String = c.moves[idx] if idx >= 0 and idx < c.moves.size() else "struggle"
	var prio: int = int(Data.get_move(mid).get("prio", 0))
	return prio * 10000.0 + _eff_speed(side) + rng.randf() * 0.5

func _stage_mult(n: int) -> float:
	return (2.0 + n) / 2.0 if n >= 0 else 2.0 / (2.0 - n)

func _eff_stat(side: int, stat: String) -> float:
	var c := active(side)
	return float(c.stat(stat)) * _stage_mult(int(sides[side].stages.get(stat, 0)))

func _eff_speed(side: int) -> float:
	var v := _eff_stat(side, "speed")
	if active(side).status == "soak":
		v *= 0.5
	return v

func _execute_move(side: int, move_id: String, ev: Array) -> void:
	var user := active(side)
	var target_side := foe_of(side)
	var target := active(target_side)
	# Status gates
	if user.status == "sleep":
		user.status_turns -= 1
		if user.status_turns <= 0:
			user.status = ""
			ev.append({"t": "status", "side": side, "status": ""})
			ev.append({"t": "text", "msg": "%s woke up!" % user.display_name()})
		else:
			ev.append({"t": "text", "msg": "%s is fast asleep." % user.display_name()})
			return
	if user.status == "daze":
		user.status_turns -= 1
		if user.status_turns <= 0:
			user.status = ""
			ev.append({"t": "status", "side": side, "status": ""})
			ev.append({"t": "text", "msg": "%s snapped out of its daze!" % user.display_name()})
		elif rng.randf() < 0.33:
			ev.append({"t": "text", "msg": "%s is too dazed to move!" % user.display_name()})
			return
	var m: Dictionary = Data.get_move(move_id)
	ev.append({"t": "move", "side": side, "move": move_id, "name": m.name, "type": m.type, "cat": m.cat})
	ev.append({"t": "text", "msg": "%s used %s!" % [user.display_name(), m.name]})
	var acc := float(m.acc)
	if weather == "fog" and not "shade" in user.types():
		acc *= 0.85
	if weather == "storm" and m.type == "spark":
		acc = 0.0
	if acc > 0.0 and (m.cat != "status" or _targets_foe(m)):
		if rng.randf() * 100.0 >= acc:
			ev.append({"t": "miss", "side": side})
			ev.append({"t": "text", "msg": "But it missed!"})
			return
	if m.cat == "status":
		_apply_effects(side, m, ev, 0)
		return
	var dmg_info := calc_damage(side, move_id)
	var dmg: int = dmg_info.damage
	if dmg_info.eff == 0.0:
		ev.append({"t": "text", "msg": "It had no effect..."})
		return
	# Sturdy
	if target.trait_id == "sturdy" and target.hp == target.max_hp() and dmg >= target.hp and not sides[target_side].sturdy_used.has(target.uid):
		dmg = target.hp - 1
		sides[target_side].sturdy_used[target.uid] = true
		ev.append({"t": "text", "msg": "%s hung on with Sturdy!" % target.display_name()})
	target.hp = max(0, target.hp - dmg)
	ev.append({"t": "damage", "side": target_side, "amount": dmg, "hp": target.hp, "max": target.max_hp(), "eff": dmg_info.eff, "crit": dmg_info.crit})
	if dmg_info.crit:
		ev.append({"t": "text", "msg": "A critical hit!"})
	if dmg_info.eff > 1.0:
		ev.append({"t": "text", "msg": "It's super effective!"})
	elif dmg_info.eff < 1.0:
		ev.append({"t": "text", "msg": "It's not very effective..."})
	# Contact traits
	if m.cat == "phys" and not target.is_fainted():
		var ttr: Dictionary = Data.traits.get(target.trait_id, {})
		if ttr.has("contact_status") and rng.randf() < float(ttr.contact_status[1]):
			_inflict(side, ttr.contact_status[0], ev)
	_apply_effects(side, m, ev, dmg)

func _targets_foe(m: Dictionary) -> bool:
	for e in m.get("effects", []):
		if e.k == "status" or (e.k == "stat" and e.get("target", "foe") == "foe"):
			return true
	return false

## Damage calculation. Returns {damage, eff, crit}.
func calc_damage(side: int, move_id: String, force_no_random: bool = false) -> Dictionary:
	var user := active(side)
	var target_side := foe_of(side)
	var target := active(target_side)
	var m: Dictionary = Data.get_move(move_id)
	var phys: bool = m.cat == "phys"
	var a := _eff_stat(side, "power" if phys else "focus")
	var d := _eff_stat(target_side, "guard" if phys else "focus")
	var power := float(m.power)
	var lvl := float(user.level)
	var base: float = floorf(floorf(floorf(2.0 * lvl / 5.0 + 2.0) * power * a / maxf(1.0, d)) / 50.0) + 2.0
	var eff := 1.0 if m.type == "none" else Data.type_mult(m.type, target.types())
	var mult := eff * weather_mult(m.type)
	if m.type in user.types():
		mult *= 1.5
	var utr: Dictionary = Data.traits.get(user.trait_id, {})
	if utr.get("pinch", "") == m.type and user.hp * 3 <= user.max_hp():
		mult *= 1.5
	if phys and user.status == "burn":
		mult *= 0.5
	if m.type == "spark" and target.status == "soak":
		mult *= 1.5
	mult *= float(Data.traits.get(target.trait_id, {}).get("damage_taken_mult", 1.0))
	var crit := false
	if not force_no_random and target.trait_id != "thick_hide":
		var crit_chance := 1.0 / 16.0
		for e in m.get("effects", []):
			if e.k == "crit":
				crit_chance = 1.0 / 8.0
		crit_chance *= float(utr.get("crit_mult", 1.0))
		crit = rng.randf() < crit_chance
	if crit:
		mult *= 1.5
	var rand := 1.0 if force_no_random else rng.randf_range(0.85, 1.0)
	var dmg := int(floor(base * mult * rand))
	if eff > 0.0:
		dmg = max(1, dmg)
	return {"damage": dmg, "eff": eff, "crit": crit}

func _apply_effects(side: int, m: Dictionary, ev: Array, dealt: int) -> void:
	var user := active(side)
	for e in m.get("effects", []):
		match e.k:
			"status":
				if rng.randf() < float(e.get("p", 1.0)):
					_inflict(foe_of(side), e.s, ev, m.cat == "status")
			"stat":
				if rng.randf() < float(e.get("p", 1.0)):
					var tgt := side if e.get("target", "foe") == "self" else foe_of(side)
					if not active(tgt).is_fainted():
						_apply_stage(tgt, e.stat, int(e.n), ev)
			"heal":
				var f := float(e.f)
				if m.type == "leaf" and weather == "sun":
					f = 0.66
				elif m.type == "leaf" and weather in ["rain", "storm", "snow", "fog"]:
					f = 0.25
				_heal(side, int(ceil(user.max_hp() * f)), ev)
			"weather":
				_start_weather(str(e.w), ev)
			"drain":
				if dealt > 0:
					_heal(side, max(1, int(dealt * float(e.f))), ev)
			"recoil":
				if dealt > 0 and not user.is_fainted():
					var r := maxi(1, int(dealt * float(e.f)))
					user.hp = max(0, user.hp - r)
					ev.append({"t": "damage", "side": side, "amount": r, "hp": user.hp, "max": user.max_hp(), "eff": 1.0, "crit": false})
					ev.append({"t": "text", "msg": "%s is hit with recoil!" % user.display_name()})
			"rest":
				user.hp = user.max_hp()
				user.status = "sleep"
				user.status_turns = 3
				ev.append({"t": "heal", "side": side, "amount": user.max_hp(), "hp": user.hp, "max": user.max_hp()})
				ev.append({"t": "status", "side": side, "status": "sleep"})
				ev.append({"t": "text", "msg": "%s curled up for a cozy nap!" % user.display_name()})

func _start_weather(w: String, ev: Array) -> void:
	if weather == w:
		ev.append({"t": "text", "msg": "But it failed!"})
		return
	weather = w
	weather_turns = WEATHER_TURNS
	ev.append({"t": "weather", "w": w})
	ev.append({"t": "text", "msg": WEATHER[w].start})

func _inflict(target_side: int, st: String, ev: Array, announce_fail: bool = false) -> void:
	var c := active(target_side)
	if c.is_fainted():
		return
	if c.status != "":
		if announce_fail:
			ev.append({"t": "text", "msg": "But it failed!"})
		return
	var immune: Array = Data.traits.get(c.trait_id, {}).get("status_immune", [])
	if st in immune or (st == "burn" and "ember" in c.types()) or (st == "soak" and "tide" in c.types()) or (st == "root" and "leaf" in c.types()):
		if announce_fail:
			ev.append({"t": "text", "msg": "%s is unaffected!" % c.display_name()})
		return
	c.status = st
	match st:
		"sleep": c.status_turns = rng.randi_range(1, 3)
		"daze": c.status_turns = rng.randi_range(2, 4)
		"soak": c.status_turns = 4
		"root": c.status_turns = 5
		_: c.status_turns = 0
	ev.append({"t": "status", "side": target_side, "status": st})
	var msgs := {"burn": "%s was burned!", "soak": "%s got soaked!", "root": "%s was rooted in place!", "daze": "%s became dazed!", "sleep": "%s fell asleep!"}
	ev.append({"t": "text", "msg": msgs[st] % c.display_name()})

func _apply_stage(side: int, stat: String, n: int, ev: Array, source: String = "") -> void:
	var cur: int = int(sides[side].stages[stat])
	var nv := clampi(cur + n, -6, 6)
	var c := active(side)
	if nv == cur:
		ev.append({"t": "text", "msg": "%s's %s won't go any %s!" % [c.display_name(), stat.capitalize(), "higher" if n > 0 else "lower"]})
		return
	sides[side].stages[stat] = nv
	ev.append({"t": "stat", "side": side, "stat": stat, "n": n})
	var how := "rose" if n == 1 else "rose sharply" if n > 1 else "fell" if n == -1 else "fell sharply"
	var prefix := (source + " lowered ") if source != "" else ""
	if prefix != "":
		ev.append({"t": "text", "msg": "%s%s's %s!" % [prefix, c.display_name(), stat.capitalize()]})
	else:
		ev.append({"t": "text", "msg": "%s's %s %s!" % [c.display_name(), stat.capitalize(), how]})

func _heal(side: int, amount: int, ev: Array) -> void:
	var c := active(side)
	if c.is_fainted():
		return
	var before := c.hp
	c.hp = mini(c.max_hp(), c.hp + amount)
	if c.hp > before:
		ev.append({"t": "heal", "side": side, "amount": c.hp - before, "hp": c.hp, "max": c.max_hp()})
		ev.append({"t": "text", "msg": "%s restored HP!" % c.display_name()})

func _use_item(side: int, item_id: String, target: int, ev: Array) -> void:
	var it: Dictionary = Data.get_item(item_id)
	var team: Array = sides[side].team
	if target < 0 or target >= team.size():
		target = sides[side].active
	var c: Creature = team[target]
	var stock: Dictionary = sides[side].items
	if stock.has(item_id):
		stock[item_id] = int(stock[item_id]) - 1
		if int(stock[item_id]) <= 0:
			stock.erase(item_id)
	ev.append({"t": "item", "side": side, "id": item_id})
	ev.append({"t": "text", "msg": "%s used a %s." % [sides[side].name, it.get("name", item_id)]})
	if it.has("revive"):
		if c.is_fainted():
			c.hp = max(1, int(c.max_hp() * float(it.revive)))
			ev.append({"t": "text", "msg": "%s was revived!" % c.display_name()})
		return
	if c.is_fainted():
		ev.append({"t": "text", "msg": "It had no effect."})
		return
	if it.has("heal"):
		var before := c.hp
		c.hp = mini(c.max_hp(), c.hp + int(it.heal))
		if target == sides[side].active:
			ev.append({"t": "heal", "side": side, "amount": c.hp - before, "hp": c.hp, "max": c.max_hp()})
		ev.append({"t": "text", "msg": "%s recovered %d HP." % [c.display_name(), c.hp - before]})
	if it.get("cure", false) and c.status != "":
		c.status = ""
		if target == sides[side].active:
			ev.append({"t": "status", "side": side, "status": ""})
		ev.append({"t": "text", "msg": "%s was cured!" % c.display_name()})

## Chance to befriend the wild foe with an item (treat or charm).
func befriend_chance(item_id: String) -> float:
	var foe := active(1)
	var sp: Dictionary = foe.species()
	var it: Dictionary = Data.get_item(item_id)
	var bonus := 1.0
	if it.has("charm"):
		bonus = float(it.charm)
	else:
		bonus = Data.treat_power(item_id, foe.species_id)
		if bonus <= 0.0:
			bonus = 0.5
	var maxhp := float(foe.max_hp())
	var hp_factor := (3.0 * maxhp - 2.0 * float(foe.hp)) / (3.0 * maxhp)
	var status_bonus := 2.0 if foe.status == "sleep" else (1.5 if foe.status != "" else 1.0)
	var trait_mult := float(Data.traits.get(foe.trait_id, {}).get("befriend_mult", 1.0))
	var a := float(sp.rate) * hp_factor * bonus * status_bonus * trait_mult / 255.0
	return clampf(a, 0.0, 1.0)

func _try_befriend(item_id: String, ev: Array) -> void:
	var foe := active(1)
	var it: Dictionary = Data.get_item(item_id)
	var chance := befriend_chance(item_id)
	if it.has("charm"):
		ev.append({"t": "text", "msg": "You held up the %s!" % it.name})
	else:
		var fav := Data.treat_power(item_id, foe.species_id) > float(it.get("treat", 0.0))
		ev.append({"t": "text", "msg": "You offered the %s %s." % [foe.display_name(), it.get("name", item_id)]})
		if fav:
			ev.append({"t": "text", "msg": "It's %s's favorite food!" % foe.display_name()})
	var success := rng.randf() < chance
	var shakes := 3
	if not success:
		var per := pow(chance, 1.0 / 3.0)
		shakes = 0
		for i in 3:
			if rng.randf() < per:
				shakes += 1
			else:
				break
		shakes = mini(shakes, 2)
	ev.append({"t": "befriend", "shakes": shakes, "success": success})
	if success:
		ev.append({"t": "text", "msg": "%s wants to be your friend!" % foe.display_name()})
		befriended = foe
		foe.status = ""
		_end("befriend", ev)
	else:
		var lines := ["%s isn't convinced yet.", "%s sniffed it, then looked away.", "So close! %s almost came over!"]
		ev.append({"t": "text", "msg": lines[clampi(shakes, 0, 2)] % foe.display_name()})

func _end_of_turn(ev: Array) -> void:
	for side in [0, 1]:
		var c := active(side)
		if c.is_fainted():
			continue
		match c.status:
			"burn":
				var d := maxi(1, c.max_hp() / 16)
				c.hp = max(0, c.hp - d)
				ev.append({"t": "damage", "side": side, "amount": d, "hp": c.hp, "max": c.max_hp(), "eff": 1.0, "crit": false})
				ev.append({"t": "text", "msg": "%s is hurt by its burn!" % c.display_name()})
			"root":
				var d2 := maxi(1, c.max_hp() / 8)
				d2 = mini(d2, c.hp)
				c.hp -= d2
				ev.append({"t": "damage", "side": side, "amount": d2, "hp": c.hp, "max": c.max_hp(), "eff": 1.0, "crit": false})
				ev.append({"t": "text", "msg": "Roots drain %s's energy!" % c.display_name()})
				_heal(foe_of(side), d2, ev)
				c.status_turns -= 1
				if c.status_turns <= 0 and not c.is_fainted():
					c.status = ""
					ev.append({"t": "status", "side": side, "status": ""})
					ev.append({"t": "text", "msg": "%s broke free of the roots!" % c.display_name()})
			"soak":
				c.status_turns -= 1
				if c.status_turns <= 0:
					c.status = ""
					ev.append({"t": "status", "side": side, "status": ""})
					ev.append({"t": "text", "msg": "%s dried off." % c.display_name()})
		var regen := float(Data.traits.get(c.trait_id, {}).get("regen", 0.0))
		if regen > 0.0 and not c.is_fainted() and c.hp < c.max_hp():
			_heal(side, max(1, int(c.max_hp() * regen)), ev)
		if weather == "snow" and weather_turns > 0 and not c.is_fainted() and not "frost" in c.types():
			var chill := maxi(1, c.max_hp() / 16)
			c.hp = max(0, c.hp - chill)
			ev.append({"t": "damage", "side": side, "amount": chill, "hp": c.hp, "max": c.max_hp(), "eff": 1.0, "crit": false})
			ev.append({"t": "text", "msg": "%s is chilled by the snow!" % c.display_name()})
	if weather_turns > 0:
		weather_turns -= 1
		if weather_turns == 0:
			ev.append({"t": "text", "msg": WEATHER[weather].end})
			weather = base_weather
			weather_turns = -1
			ev.append({"t": "weather", "w": weather})

func _check_faints(ev: Array) -> void:
	for side in [1, 0]:
		var c := active(side)
		if c.is_fainted() and not _announced_faint.has(c.uid):
			_announced_faint[c.uid] = true
			ev.append({"t": "faint", "side": side})
			ev.append({"t": "text", "msg": "%s%s fainted!" % ["The wild " if kind == Kind.WILD and side == 1 else "", c.display_name()]})
			c.status = ""
			if side == 1:
				_award_xp(c, ev)
	if sides[1].alive_count() == 0:
		_end("win", ev)
	elif sides[0].alive_count() == 0:
		_end("lose", ev)

var _announced_faint: Dictionary = {}

func _award_xp(foe: Creature, ev: Array) -> void:
	if kind == Kind.PVP:
		return
	var sp: Dictionary = foe.species()
	var bst := 0
	for s in Data.STATS:
		bst += int(sp.base_stats[s])
	var total := int(float(bst) / 4.0 * float(foe.level) / 7.0 * xp_mult) + 5
	var alive: Array = []
	for c in sides[0].team:
		if participants.has(c.uid) and not c.is_fainted():
			alive.append(c)
	if alive.is_empty():
		return
	var each := maxi(1, total / alive.size())
	for c in alive:
		ev.append({"t": "xp", "uid": c.uid, "amount": each})
		ev.append({"t": "text", "msg": "%s gained %d XP!" % [c.display_name(), each]})
		for e in c.gain_xp(each):
			e["uid"] = c.uid
			ev.append(e)
			if e.t == "level":
				ev.append({"t": "text", "msg": "%s grew to level %d!" % [c.display_name(), e.level]})
				if c == active(0):
					ev.append({"t": "heal", "side": 0, "amount": 0, "hp": c.hp, "max": c.max_hp()})
			elif e.t == "learn":
				ev.append({"t": "text", "msg": ("%s learned %s!" if e.equipped else "%s can now use %s! (Equip it from the Party menu.)") % [c.display_name(), Data.get_move(e.move).name]})
		c.change_happiness(2)

func _end(res: String, ev: Array) -> void:
	result = res
	for side in [0, 1]:
		sides[side].reset_stages()
	for c in sides[0].team:
		if c.status in ["daze", "root", "soak"]:
			c.status = ""
	ev.append({"t": "end", "result": res})

## Applies a forced switch for an AI side after its active fainted.
func ai_replacement(side: int) -> int:
	return BattleAI.choose_replacement(self, side)
