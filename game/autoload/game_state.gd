extends Node
## The whole simulation state. The host is authoritative; actions here are
## called directly offline or via Net RPCs in co-op.

const SAVE_VERSION := 1
const PERSISTENT_MAPS := ["farm", "greenhouse", "terrace"]
const STARTERS := ["sproutle", "puddlop", "embercub"]

var world: Dictionary = {}
var grids: Dictionary = {}            # persistent FarmGrids
var farm_chest: Inventory
var ranch: Array = []                 # Array[Creature] living at the farm (workers)
var sanctuary: Array = []             # overflow storage (unlimited)
var players: Dictionary = {}          # id -> PlayerData
var started: bool = false
var rng := RandomNumberGenerator.new()

var _map_cache: Dictionary = {}       # map_id -> build result (non-persistent maps)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

# --- Setup ------------------------------------------------------------------------

func new_game(opts: Dictionary) -> void:
	var seed_v: int = int(opts.get("seed", randi()))
	rng.seed = seed_v
	world = {
		"version": SAVE_VERSION, "seed": seed_v, "day": 0, "minute": Calendar.DAY_START, "weather": "sun",
		"money": 500, "farm_name": opts.get("farm_name", "Sunny"), "buildings": [], "shrines": [],
		"regions": ["meadow", "whisperwood"], "dex": {}, "dex_claimed": [], "weekly": [], "weekly_week": -1,
		"board": [], "board_week": -1, "stats": {"earned": 0}, "farm": {"level": 1, "xp": 0}, "mine_depth": {},
		"flags": {}, "quest": 0, "legends": [], "festival_done": [], "hatchery": [], "shipping": [],
		"pairs": [], "luck": 0.0, "created": Time.get_unix_time_from_system(), "played": 0.0,
	}
	grids.clear()
	_map_cache.clear()
	for m in PERSISTENT_MAPS:
		grids[m] = MapBuilder.build_authored(Data.get_map(m)).grid
	farm_chest = Inventory.new(10, 8)
	ranch.clear()
	sanctuary.clear()
	players.clear()
	var p := PlayerData.new()
	p.id = Net.local_id()
	p.name = opts.get("player_name", "Farmer")
	if opts.has("look"):
		p.look = opts.look
	p.give_starter_kit()
	var spawn: Array = Data.get_map("farm").spawn
	p.pos = tile_center(Vector2i(int(spawn[0]), int(spawn[1])))
	players[p.id] = p
	var starter: String = opts.get("starter", "puddlop")
	var c := Creature.create(starter, 5, rng, {"min_gene": 6})
	c.owner = p.id
	c.met = "Starter"
	c.happiness = 120
	p.party.append(c)
	Progression.mark(world.dex, starter, true)
	world.weekly = Progression.weekly_for(0, seed_v)
	world.weekly_week = 0
	world.board = Progression.board_for(0, seed_v)
	world.board_week = 0
	world.weather = Calendar.roll_weather(seed_v, 0)
	started = true

func local_player() -> PlayerData:
	return players.get(Net.local_id(), players.values()[0] if players.size() > 0 else null)

func player(pid: String) -> PlayerData:
	return players.get(pid, null)

func ensure_player(pid: String, pname: String) -> PlayerData:
	if players.has(pid):
		return players[pid]
	var p := PlayerData.new()
	p.id = pid
	p.name = pname
	p.give_starter_kit()
	var c := Creature.create(STARTERS[rng.randi() % STARTERS.size()], 5, rng, {"min_gene": 6})
	c.owner = pid
	c.met = "Starter"
	p.party.append(c)
	p.pos = tile_center(Vector2i(7, 6))
	players[pid] = p
	return p

static func tile_center(t: Vector2i) -> Vector2:
	return Vector2(t.x * Tiles.TILE + Tiles.TILE / 2, t.y * Tiles.TILE + Tiles.TILE / 2)

static func to_tile(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / Tiles.TILE), floori(pos.y / Tiles.TILE))

# --- Queries ------------------------------------------------------------------------

func day() -> int:
	return int(world.day)

func season() -> String:
	return Calendar.season(day())

func minute() -> int:
	return int(world.minute)

func money() -> int:
	return int(world.money)

func ctx() -> Dictionary:
	var p := local_player()
	return {
		"shrines": world.shrines.size(), "farm_level": int(world.farm.level),
		"hearts": p.hearts_dict() if p else {}, "recipes": p.recipes if p else [], "buildings": world.buildings,
	}

func has_building(id: String) -> bool:
	return id in world.buildings

func den_capacity() -> int:
	if has_building("deluxe_den"):
		return 16
	if has_building("big_den"):
		return 8
	return 4

func hatchery_capacity() -> int:
	if has_building("big_hatchery"):
		return 4
	if has_building("hatchery"):
		return 2
	return 0

func region_unlocked(rid: String) -> bool:
	return rid in world.regions

func is_open_requirement(req: String) -> bool:
	if req == "":
		return true
	if req.begins_with("region:"):
		return region_unlocked(req.substr(7))
	if Data.buildings.has(req):
		return has_building(req)
	return Economy.meets(req, ctx())

func luck() -> float:
	return float(world.get("luck", 0.0))

# --- Maps -----------------------------------------------------------------------------

func map_info(map_id: String) -> Dictionary:
	if map_id.begins_with("mine:") and map_id.split(":").size() == 3:
		map_id = "%s:%d" % [map_id, day()]
	if _map_cache.has(map_id):
		return _map_cache[map_id]
	var info: Dictionary = MapBuilder.build(map_id, int(world.seed))
	if grids.has(map_id):
		info.grid = grids[map_id]
	_map_cache[map_id] = info
	return info

func grid(map_id: String) -> FarmGrid:
	return map_info(map_id).grid

func farm_grids() -> Array:
	var out: Array = [grids.farm]
	if has_building("greenhouse"):
		out.append(grids.greenhouse)
	if has_building("terrace"):
		out.append(grids.terrace)
	return out

# --- Money, XP and stats ---------------------------------------------------------------

func add_money(n: int, at: Vector2 = Vector2.INF) -> void:
	world.money = maxi(0, int(world.money) + n)
	if n > 0:
		world.stats.earned = int(world.stats.get("earned", 0)) + n
	EventBus.money_changed.emit(int(world.money), n)
	if at != Vector2.INF and n != 0:
		EventBus.popup.emit(at, ("+%dg" % n) if n > 0 else ("%dg" % n), Color("#ffd447") if n > 0 else Color("#ff7a7a"))

func spend(n: int) -> bool:
	if int(world.money) < n:
		return false
	add_money(-n)
	return true

func add_farm_xp(n: int, at: Vector2 = Vector2.INF) -> void:
	if n <= 0:
		return
	var ups := Progression.add_farm_xp(world.farm, n)
	if at != Vector2.INF:
		EventBus.popup.emit(at + Vector2(0, -10), "+%d XP" % n, Color("#8fe36b"))
	for lv in ups:
		var info := Progression.level_reward(lv)
		grant(info.get("reward", {}), local_player())
		EventBus.farm_level_up.emit(lv, info)

func bump_stat(key: String, n: int = 1) -> void:
	world.stats[key] = int(world.stats.get(key, 0)) + n
	for c in Progression.bump(world.weekly, key, n):
		add_money(int(c.reward_money))
		EventBus.toast.emit("Weekly challenge complete: %s (+%dg)" % [c.text, int(c.reward_money)], "star")
	EventBus.quest_updated.emit()

## Grants a reward dict {item: n, money: n, recipe: id}
func grant(reward: Dictionary, p: PlayerData) -> void:
	for k in reward:
		if k == "money":
			add_money(int(reward[k]))
		elif k == "recipe":
			if p and not reward[k] in p.recipes:
				p.recipes.append(reward[k])
				EventBus.toast.emit("Learned recipe: %s" % Data.item_name(reward[k]), "book")
		elif Data.has_item(k):
			give_item(p, k, int(reward[k]))

## Adds to a player's pack; overflow goes to the farm chest (never lost).
func give_item(p: PlayerData, id: String, n: int, q: int = 0, meta: Dictionary = {}) -> int:
	var left := p.inventory.add(id, n, q, meta) if p else n
	if left > 0:
		var left2 := farm_chest.add(id, left, q, meta)
		if left2 < left:
			EventBus.toast.emit("Pack full: %d %s sent to the farm chest." % [left - left2, Data.item_name(id)], "chest")
		left = left2
	EventBus.inventory_changed.emit()
	return left

# --- Creatures ---------------------------------------------------------------------------

## Places a new Wildling: party first, then den, then sanctuary. Returns where.
func add_creature(p: PlayerData, c: Creature) -> String:
	c.owner = p.id
	var first := Progression.mark(world.dex, c.species_id, true, c.starry)
	if first:
		add_farm_xp(Progression.XP.befriend)
		for m in Progression.pending_milestones(world.dex, world.dex_claimed):
			world.dex_claimed.append(int(m.n))
			grant(m.reward, p)
			EventBus.toast.emit(m.text, "dex")
	EventBus.creature_befriended.emit(c)
	if p.party.size() < PlayerData.PARTY_MAX:
		p.party.append(c)
		EventBus.party_changed.emit()
		return "party"
	if ranch.size() < den_capacity():
		ranch.append(c)
		return "den"
	sanctuary.append(c)
	return "sanctuary"

func all_creatures() -> Array:
	var out: Array = []
	for pid in players:
		out.append_array(players[pid].party)
	out.append_array(ranch)
	out.append_array(sanctuary)
	return out

func find_creature(uid: String) -> Creature:
	for c in all_creatures():
		if c.uid == uid:
			return c
	return null

## Moves a creature between "party:<pid>", "den", "sanctuary". Returns ok.
func move_creature(uid: String, dest: String, p: PlayerData) -> bool:
	var c := find_creature(uid)
	if c == null:
		return false
	if dest == "party" and p.party.size() >= PlayerData.PARTY_MAX:
		return false
	if dest == "den" and ranch.size() >= den_capacity():
		return false
	if c in p.party and p.party.size() <= 1:
		return false
	p.party.erase(c)
	ranch.erase(c)
	sanctuary.erase(c)
	for pid in players:
		players[pid].party.erase(c)
	if dest != "den":
		c.job = ""
	match dest:
		"party": p.party.append(c)
		"den": ranch.append(c)
		_: sanctuary.append(c)
	EventBus.party_changed.emit()
	return true

func set_job(uid: String, job_id: String) -> bool:
	var c := find_creature(uid)
	if c == null or not c in ranch:
		return false
	if job_id != "" and not c.can_do_job(job_id):
		return false
	c.job = job_id
	return true

func set_pair(a_uid: String, b_uid: String) -> Dictionary:
	var a := find_creature(a_uid)
	var b := find_creature(b_uid)
	if a == null or b == null or not a in ranch or not b in ranch:
		return {"ok": false, "reason": "Both Wildlings must live in the Den."}
	if not Breeding.compatible(a, b):
		return {"ok": false, "reason": "These two don't seem interested in each other."}
	world.pairs = [[a_uid, b_uid]] if world.pairs.size() < 1 + int(has_building("big_den")) else world.pairs.slice(1) + [[a_uid, b_uid]]
	return {"ok": true, "reason": "", "chance": Breeding.egg_chance(a, b)}

func pair_of(uid: String) -> String:
	for pr in world.pairs:
		if pr[0] == uid:
			return pr[1]
		if pr[1] == uid:
			return pr[0]
	return ""

func clear_pair(uid: String) -> void:
	world.pairs = world.pairs.filter(func(pr): return pr[0] != uid and pr[1] != uid)

func add_egg_to_hatchery(p: PlayerData, uid: String) -> bool:
	if world.hatchery.size() >= hatchery_capacity():
		return false
	var f := p.inventory.find(uid)
	if f.is_empty():
		f = farm_chest.find(uid)
	if f.is_empty() or f.entry.id != "wildling_egg":
		return false
	var egg: Dictionary = f.entry.meta.get("egg", {})
	if egg.is_empty():
		egg = Breeding.wild_egg(Data.species_order[rng.randi() % 30], rng)
	f.inv.take(uid, 1)
	var days := int(egg.days) - (1 if has_building("big_hatchery") else 0)
	world.hatchery.append({"egg": egg, "days": maxi(1, days)})
	EventBus.inventory_changed.emit()
	return true

# --- Time ---------------------------------------------------------------------------------

func advance_minutes(n: int) -> void:
	world.minute = int(world.minute) + n
	world.played = float(world.get("played", 0.0)) + n
	EventBus.time_changed.emit(int(world.minute))
	if int(world.minute) >= Calendar.DAY_END:
		EventBus.toast.emit("You're exhausted... you pass out.", "zzz")
		end_day(true)

func abs_minute() -> int:
	return day() * 1440 + minute()

## Ends the day: shipping, jobs, growth, eggs, weather. Returns the morning report.
func end_day(passed_out: bool = false) -> Dictionary:
	EventBus.day_ending.emit()
	var report := {"shipped": [], "ship_total": 0, "jobs": {}, "farm": {}, "hatched": [], "eggs": 0, "passed_out": passed_out}
	var nrng := RandomNumberGenerator.new()
	nrng.seed = hash([int(world.seed), day(), "night"])
	# Auto-shipper: ship sellable farm chest contents (except tools/containers/eggs)
	if has_building("auto_shipper"):
		for e in farm_chest.all_entries().duplicate():
			var cat: String = Data.get_item(e.id).get("cat", "")
			if cat in ["crop", "fruit", "artisan", "produce", "forage", "gem"]:
				world.shipping.append({"id": e.id, "n": int(e.n), "q": int(e.q)})
				farm_chest.remove(e.id, int(e.n))
	# Shipping
	var total := 0
	for s in world.shipping:
		var v := Data.sell_price(s.id, int(s.q)) * int(s.n)
		total += v
		report.shipped.append({"id": s.id, "n": int(s.n), "q": int(s.q), "v": v})
		if Data.get_item(s.id).get("cat", "") == "crop":
			bump_stat("ship:crop", int(s.n))
	world.shipping = []
	report.ship_total = total
	if total > 0:
		add_money(total)
		add_farm_xp(int(total / 40))
	# Farm jobs
	var season_now := season()
	var job_rep := FarmJobs.run(ranch, {"grids": farm_grids(), "chest": farm_chest, "rng": nrng, "season": season_now})
	FarmJobs.collect_produce(ranch, farm_chest, nrng, job_rep)
	FarmJobs.rest(ranch, has_building("wildling_spa"))
	report.jobs = job_rep
	Machines.apply_power(farm_grids(), int(job_rep.powered))
	# Farm work XP can push Wildlings to evolve; they do it overnight in the Den.
	report["evolved"] = []
	for c: Creature in ranch:
		if c.can_evolve() != "":
			var from: String = c.display_name()
			var from_species: String = c.species_id
			c.evolve()
			Progression.mark(world.dex, c.species_id, true, c.starry)
			report.evolved.append({"from": from, "from_species": from_species, "to": c.species_id})
	# Breeding
	for pair in world.pairs:
		var a := find_creature(pair[0])
		var b := find_creature(pair[1])
		if a and b and a in ranch and b in ranch and nrng.randf() < Breeding.egg_chance(a, b):
			var egg := Breeding.make_egg(a, b, nrng, {"heirloom": farm_chest.has("heirloom_charm") or _anyone_has("heirloom_charm"), "starry_mult": 3.0 if _anyone_has("starry_charm") else 1.0, "season": season_now})
			farm_chest.add("wildling_egg", 1, 0, {"egg": egg})
			report.eggs += 1
	# Hatchery
	var still: Array = []
	for slot in world.hatchery:
		slot.days = int(slot.days) - 1
		if int(slot.days) <= 0:
			var c := Breeding.hatch(slot.egg, nrng)
			var where := add_creature(local_player(), c)
			bump_stat("hatch")
			add_farm_xp(Progression.XP.hatch)
			report.hatched.append({"species": c.species_id, "starry": c.starry, "where": where})
			EventBus.egg_hatched.emit(c)
		else:
			still.append(slot)
	world.hatchery = still
	# Advance the date
	var prev_season := season_now
	world.day = day() + 1
	world.minute = Calendar.DAY_START
	world.weather = Calendar.roll_weather(int(world.seed), day())
	var day_rng := RandomNumberGenerator.new()
	day_rng.seed = hash([int(world.seed), day(), "luck"])
	world.luck = day_rng.randf_range(-0.03, 0.05) + float(job_rep.luck)
	for o in grids.farm.objects.values():
		if o.id == "wishing_well":
			world.luck = float(world.luck) + 0.02
	var farm_rep := {}
	for m in grids:
		var g: FarmGrid = grids[m]
		var r := g.new_day(season(), prev_season, world.weather if m != "greenhouse" else "sun", nrng, int(job_rep.frost_protect), bool(job_rep.guarded))
		for k in r:
			farm_rep[k] = int(farm_rep.get(k, 0)) + int(r[k])
	report.farm = farm_rep
	# Ranch happiness drift, party fully healed by morning
	for c in ranch:
		c.grooming = maxi(0, c.grooming - 10)
	for pid in players:
		var p: PlayerData = players[pid]
		p.heal_party()
		if passed_out:
			p.energy = p.max_energy * 0.6
			var lost := mini(1000, int(int(world.money) * 0.1))
			if lost > 0 and p.map_id != "farm" and not p.map_id in ["greenhouse", "terrace"]:
				add_money(-lost)
				report["lost_money"] = lost
		else:
			p.energy = p.max_energy
		p.water_left = p.water_capacity()
		p.map_id = "farm"
		var spawn: Array = Data.get_map("farm").spawn
		p.pos = tile_center(Vector2i(int(spawn[0]), int(spawn[1])))
		var new_week := Calendar.weekday(day()) == 0
		for vid in p.relationships:
			Relationships.daily_reset(p.relationships[vid], new_week)
	# Weekly + board
	var wk := Calendar.week_number(day())
	if wk != int(world.weekly_week):
		world.weekly = Progression.weekly_for(wk, int(world.seed))
		world.weekly_week = wk
		world.board = Progression.board_for(day(), int(world.seed))
		world.board_week = wk
	_map_cache.clear()
	report["day"] = day()
	report["festival"] = Calendar.festival_on(day())
	EventBus.day_started.emit(day(), report)
	EventBus.weather_changed.emit(world.weather)
	EventBus.time_changed.emit(minute())
	SaveManager.autosave()
	return report

func _anyone_has(id: String) -> bool:
	for pid in players:
		if players[pid].inventory.has(id):
			return true
	return false

# --- World actions (host-authoritative) -----------------------------------------------------
## All return {ok, fx: [[text, color]], sfx, reason}

func _res(ok: bool, reason: String = "") -> Dictionary:
	return {"ok": ok, "fx": [], "sfx": "", "reason": reason, "energy": 0.0}

func _spend_energy(p: PlayerData, n: float) -> bool:
	if n <= 0:
		return true
	if p.energy <= 0.0:
		EventBus.toast.emit("You're too tired. Eat something or go to bed.", "zzz")
		return false
	p.energy = maxf(0.0, p.energy - n)
	EventBus.energy_changed.emit(p.energy, p.max_energy)
	return true

func use_tool(pid: String, map_id: String, t: Vector2i, tool: String) -> Dictionary:
	var p := player(pid)
	var g := grid(map_id)
	var info := map_info(map_id)
	var r := _res(false)
	if p == null or g == null:
		return r
	var lvl := p.tool_level(tool)
	var base_cost := maxf(0.5, 2.0 - 0.3 * lvl)
	var at := tile_center(t)
	match tool:
		"hoe":
			if g.can_till(t):
				if not _spend_energy(p, base_cost):
					return r
				g.till(t)
				r.ok = true
				r.sfx = "hoe"
		"watering_can":
			if g.get_ground(t) in Tiles.WATER_TILES or g.object_at(t).get("id", "") == "birdbath":
				p.water_left = p.water_capacity()
				r.ok = true
				r.sfx = "refill"
				r.fx.append(["Refilled!", Color("#7ac8ff")])
			elif g.is_tilled(t):
				if p.water_left <= 0:
					r.reason = "Your watering can is empty. Refill it at water."
					return r
				if not _spend_energy(p, base_cost * 0.5):
					return r
				var area: Array = [t]
				if lvl >= 2:
					area = [t, t + Vector2i(1, 0), t + Vector2i(-1, 0)]
				if lvl >= 4:
					area = [t, t + Vector2i(1, 0), t + Vector2i(-1, 0), t + Vector2i(0, 1), t + Vector2i(0, -1)]
				for a in area:
					if g.water(a):
						p.water_left -= 1
				r.ok = true
				r.sfx = "water"
		"pickaxe", "axe", "scythe":
			if tool == "scythe":
				if g.crop_ready(t):
					return harvest_at(pid, map_id, t)
				if g.get_ground(t) == Tiles.GROUND.tallgrass:
					g.ground[g.idx(t)] = Tiles.GROUND.grass if map_id == "farm" else g.ground[g.idx(t)]
					if map_id == "farm":
						if rng.randf() < 0.5:
							give_item(p, "fiber", 1)
						r.ok = true
						r.sfx = "scythe"
			var d := g.get_deco(t)
			if Tiles.DEBRIS.has(d) and (Tiles.DEBRIS[d].tool == tool or d == Tiles.DECO.weed):
				var cost := float(Tiles.DEBRIS[d].energy) * maxf(0.4, 1.0 - 0.15 * lvl)
				var res := g.clear_debris(t, tool, lvl, rng)
				if not res.ok:
					r.reason = res.reason
					return r
				if not _spend_energy(p, cost):
					g.set_deco(t, d)
					return r
				if d == Tiles.DECO.ore:
					var ore: String = info.get("ore_types", {}).get(Tiles.key(t), "copper_ore")
					res.drops = [[ore, rng.randi_range(1, 3)]]
					if rng.randf() < 0.1 + luck():
						res.drops.append(["coal", 1])
					if rng.randf() < 0.05 + luck():
						var gems := ["quartz", "amethyst", "topaz"]
						res.drops.append([gems[rng.randi() % 3], 1])
				if d == Tiles.DECO.rock and info.get("mine", false):
					if rng.randf() < 0.15:
						res.drops.append(["coal", 1])
					if rng.randf() < 0.05:
						res.drops.append(["quartz", 1])
					if rng.randf() < 0.04:
						res.drops.append(["clay", 1])
				for dr in res.drops:
					give_item(p, dr[0], int(dr[1]))
					r.fx.append(["+%d %s" % [int(dr[1]), Data.item_name(dr[0])], Color.WHITE])
				r.ok = true
				r.sfx = {"pickaxe": "rock", "axe": "chop", "scythe": "scythe"}[tool]
				add_farm_xp(Progression.XP.clear)
				p.stat_add("cleared")
				EventBus.shake.emit(1.5 if d in [24, 25, 30, 33] else 0.5)
			elif tool == "pickaxe" and g.is_tilled(t) and g.crop_at(t).is_empty():
				g.soil.erase(Tiles.key(t))
				r.ok = true
				r.sfx = "hoe"
			elif tool == "axe" and g.object_at(t).get("kind", "") == "tree" and int(g.object_at(t).age) < int(Data.trees[g.object_at(t).tree].days):
				var o := g.remove_object(t)
				give_item(p, o.id, 1)
				r.ok = true
				r.sfx = "chop"
			elif tool == "pickaxe" and not g.object_at(t).is_empty() and g.object_at(t).kind in ["machine", "sprinkler", "scarecrow", "decor", "chest"]:
				return pick_up_object(pid, map_id, t)
	if r.ok:
		EventBus.tile_changed.emit(map_id, t)
		for fx in r.fx:
			EventBus.popup.emit(at, fx[0], fx[1])
	return r

func pick_up_object(pid: String, map_id: String, t: Vector2i) -> Dictionary:
	var p := player(pid)
	var g := grid(map_id)
	var o := g.object_at(t)
	var r := _res(false)
	if o.is_empty():
		return r
	if o.kind == "chest":
		var inv := Inventory.new(8, 6)
		inv.from_dict(o.inv)
		if not inv.is_empty():
			r.reason = "Empty the chest first."
			return r
	if o.kind == "machine" and Machines.is_busy(o):
		r.reason = "It's busy."
		return r
	if not p.inventory.can_add(o.id, 1):
		r.reason = "No room in your pack."
		return r
	g.remove_object(t)
	give_item(p, o.id, 1)
	r.ok = true
	r.sfx = "pickup"
	EventBus.objects_changed.emit(map_id)
	return r

## Uses the selected (non-tool) item on a tile: seeds, fertilizer, saplings, placeables.
func use_item(pid: String, map_id: String, t: Vector2i, uid: String) -> Dictionary:
	var p := player(pid)
	var g := grid(map_id)
	var r := _res(false)
	var f := p.inventory.find(uid)
	if f.is_empty():
		return r
	var e: Dictionary = f.entry
	var it: Dictionary = Data.get_item(e.id)
	var cat: String = it.get("cat", "")
	if map_id in PERSISTENT_MAPS:
		if cat == "seed":
			if g.plant(t, e.id, season()):
				f.inv.take(uid, 1)
				r.ok = true
				r.sfx = "plant"
				add_farm_xp(Progression.XP.plant)
			elif g.is_tilled(t) and g.crop_at(t).is_empty():
				r.reason = "%s can't grow in %s." % [Data.item_name(e.id), season().capitalize()]
		elif it.has("fert"):
			if g.fertilize(t, it.fert):
				f.inv.take(uid, 1)
				r.ok = true
				r.sfx = "plant"
		elif cat == "sapling" or it.has("place"):
			if g.place_object(t, e.id):
				f.inv.take(uid, 1)
				r.ok = true
				r.sfx = "place"
				EventBus.objects_changed.emit(map_id)
			else:
				r.reason = "Can't place that here."
	if r.ok:
		EventBus.inventory_changed.emit()
		EventBus.tile_changed.emit(map_id, t)
	return r

## Interact-harvest: ripe crops, fruit trees, machine output, forage.
func harvest_at(pid: String, map_id: String, t: Vector2i) -> Dictionary:
	var p := player(pid)
	var g := grid(map_id)
	var r := _res(false)
	var at := tile_center(t)
	if g.crop_ready(t):
		var c: Dictionary = g.crop_at(t)
		var cid: String = c.id
		if not p.inventory.can_add(cid, 1):
			r.reason = "Your pack is full."
			return r
		var h := g.harvest(t, rng, luck(), int(p.skills.get("farming", 0)))
		give_item(p, h.id, int(h.n), int(h.q))
		r.ok = true
		r.sfx = "harvest"
		var qname: String = Data.QUALITY_NAMES[int(h.q)]
		r.fx.append(["+%d %s%s" % [int(h.n), (qname + " ") if qname != "" else "", Data.item_name(h.id)], [Color.WHITE, Color("#d8e0f0"), Color("#ffd447"), Color("#c890ff")][int(h.q)]])
		add_farm_xp(Progression.XP.harvest * int(h.n), at)
		bump_stat("harvest", int(h.n))
		p.stat_add("harvested", int(h.n))
	else:
		var o := g.object_at(t)
		if o.get("kind", "") == "tree" and int(o.get("fruit", 0)) > 0:
			var fr := g.shake_tree(t)
			give_item(p, fr.id, int(fr.n))
			r.ok = true
			r.sfx = "harvest"
			r.fx.append(["+%d %s" % [int(fr.n), Data.item_name(fr.id)], Color.WHITE])
			add_farm_xp(Progression.XP.fruit * int(fr.n), at)
			bump_stat("harvest", int(fr.n))
		elif o.get("kind", "") == "machine" and Machines.is_ready(o, abs_minute()):
			var out: Dictionary = o.output
			give_item(p, out.id, int(out.n), int(out.q))
			o.output = {}
			o.input = ""
			r.ok = true
			r.sfx = "harvest"
			r.fx.append(["+%d %s" % [int(out.n), Data.item_name(out.id)], Color.WHITE])
			add_farm_xp(Progression.XP.craft, at)
		elif o.get("kind", "") == "forage":
			g.remove_object(t)
			var q := FarmGrid.roll_quality("", false, 0, luck(), int(p.skills.get("foraging", 0)), rng)
			give_item(p, o.id, 1, q)
			r.ok = true
			r.sfx = "pickup"
			r.fx.append(["+1 %s" % Data.item_name(o.id), Color.WHITE])
			p.stat_add("foraged")
	if r.ok:
		EventBus.tile_changed.emit(map_id, t)
		EventBus.objects_changed.emit(map_id)
		for fx in r.fx:
			EventBus.popup.emit(at, fx[0], fx[1])
	return r

func load_machine(pid: String, map_id: String, t: Vector2i, uid: String) -> Dictionary:
	var p := player(pid)
	var g := grid(map_id)
	var o := g.object_at(t)
	var r := _res(false)
	if o.get("kind", "") != "machine" or Machines.is_busy(o):
		return r
	var f := p.inventory.find(uid)
	if f.is_empty():
		return r
	var chk := Machines.can_load(o.id, f.entry.id, int(f.entry.q), p.inventory)
	if not chk.ok:
		r.reason = chk.reason
		return r
	for k in chk.consume:
		p.inventory.remove(k, int(chk.consume[k]))
	o.input = f.entry.id
	o.output = chk.output
	o.ready_at = abs_minute() + int(chk.time)
	r.ok = true
	r.sfx = "machine"
	EventBus.inventory_changed.emit()
	EventBus.objects_changed.emit(map_id)
	return r

func ship(pid: String, uid: String, n: int = -1) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	var f := p.inventory.find(uid)
	if f.is_empty():
		return r
	if Data.sell_price(f.entry.id, 0) <= 0:
		r.reason = "That can't be shipped."
		return r
	var amount: int = int(f.entry.n) if n < 0 else mini(n, int(f.entry.n))
	var taken: Dictionary = f.inv.take(uid, amount)
	world.shipping.append({"id": taken.id, "n": int(taken.n), "q": int(taken.q)})
	r.ok = true
	r.sfx = "ship"
	EventBus.inventory_changed.emit()
	return r

func buy(pid: String, shop_id: String, item_id: String, n: int = 1) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null or n <= 0:
		return r
	var price := -1
	for s in Economy.shop_stock(shop_id, season(), ctx(), day(), int(world.seed)):
		if s.id == item_id and not s.locked:
			price = int(s.price)
	if price < 0:
		r.reason = "That's not for sale right now."
		return r
	if not p.inventory.can_add(item_id, n):
		r.reason = "Your pack is full."
		return r
	if not spend(price * n):
		r.reason = "Not enough gold."
		return r
	give_item(p, item_id, n)
	bump_stat("spent", price * n)
	r.ok = true
	r.sfx = "coin"
	return r

## Sells straight to a shopkeeper (instant, unlike the shipping bin).
func sell(pid: String, uid: String, n: int = -1) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	var f := p.inventory.find(uid) if p else {}
	if f.is_empty():
		return r
	var price := Data.sell_price(f.entry.id, int(f.entry.q))
	if price <= 0 or Data.get_item(f.entry.id).get("cat", "") in ["tool", "key"]:
		r.reason = "They won't buy that."
		return r
	var amount: int = int(f.entry.n) if n < 0 else mini(n, int(f.entry.n))
	f.inv.take(uid, amount)
	add_money(price * amount)
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "coin"
	return r

## Inventories a player can craft from: their pack, plus the farm chest when at home.
func craft_sources(p: PlayerData) -> Array:
	if p.map_id in ["farm", "farmhouse", "greenhouse"]:
		return [p.inventory, farm_chest]
	return [p.inventory]

func craft(pid: String, kind: String, recipe_id: String) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null:
		return r
	var c := ctx()
	c["recipes"] = p.recipes
	if not recipe_id in Economy.known_recipes(kind, c):
		r.reason = "You don't know that recipe yet."
		return r
	if kind == "cooking" and not has_building("kitchen"):
		r.reason = "You need a kitchen to cook."
		return r
	var srcs := craft_sources(p)
	if not Economy.can_make(kind, recipe_id, srcs):
		r.reason = "Missing ingredients."
		return r
	if not Economy.make(kind, recipe_id, srcs):
		r.reason = "Your pack is full."
		return r
	bump_stat("cook" if kind == "cooking" else "craft")
	add_farm_xp(3 if kind == "cooking" else 2)
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "chest"
	return r

func construct(pid: String, building_id: String) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null:
		return r
	var srcs := craft_sources(p)
	var chk := Economy.building_ok(building_id, ctx(), money(), srcs)
	if not chk.ok:
		r.reason = chk.reason
		return r
	var b: Dictionary = Data.buildings[building_id]
	spend(int(b.price))
	Economy.consume(srcs, b.materials)
	world.buildings.append(building_id)
	bump_stat("build")
	add_farm_xp(50)
	EventBus.inventory_changed.emit()
	EventBus.toast.emit("%s is ready!" % b.name, "")
	r.ok = true
	r.sfx = "levelup"
	return r

func upgrade_tool(pid: String, tool: String) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null or not p.tool_levels.has(tool):
		return r
	var spec := Economy.upgrade_spec(p.tool_level(tool) + 1)
	if spec.is_empty():
		r.reason = "That tool is already the best it can be."
		return r
	var srcs := craft_sources(p)
	if Economy.count_in(srcs, spec.bar) < int(spec.n):
		r.reason = "Bring %d %s." % [int(spec.n), Data.item_name(spec.bar)]
		return r
	if not spend(int(spec.price)):
		r.reason = "Not enough gold."
		return r
	Economy.consume(srcs, {spec.bar: int(spec.n)})
	p.tool_levels[tool] = int(spec.level)
	bump_stat("upgrade")
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "levelup"
	return r

func buy_backpack(pid: String, level: int) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null or level != p.backpack_level + 1:
		return r
	var spec := Economy.backpack_spec(level)
	if spec.is_empty():
		return r
	if not is_open_requirement(spec.get("requires", "")):
		r.reason = Economy.req_text(spec.requires)
		return r
	if not spend(int(spec.price)):
		r.reason = "Not enough gold."
		return r
	p.set_backpack(level)
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "levelup"
	return r

## Hands in a Village Board request from the player's pack.
func deliver_board(pid: String, idx: int) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null or idx < 0 or idx >= world.board.size():
		return r
	var b: Dictionary = world.board[idx]
	if b.get("done", false):
		r.reason = "Already delivered."
		return r
	if p.inventory.count(b.item) < int(b.n):
		r.reason = "You need %d %s." % [int(b.n), Data.item_name(b.item)]
		return r
	p.inventory.remove(b.item, int(b.n))
	b.done = true
	add_money(int(b.money))
	Relationships.add_points(b.from, p.relationship(b.from), 40)
	bump_stat("board")
	add_farm_xp(20)
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "coin"
	return r

func set_pair_act(_pid: String, a_uid: String, b_uid: String) -> Dictionary:
	var res := set_pair(a_uid, b_uid)
	return _res(res.ok, res.reason)

func clear_pair_act(_pid: String, uid: String) -> Dictionary:
	clear_pair(uid)
	return _res(true)

func incubate(pid: String, egg_uid: String) -> Dictionary:
	var ok := add_egg_to_hatchery(player(pid), egg_uid)
	return _res(ok, "" if ok else "The Hatchery is full.")

func set_job_act(_pid: String, uid: String, job_id: String) -> Dictionary:
	return _res(set_job(uid, job_id))

func move_creature_act(pid: String, uid: String, dest: String) -> Dictionary:
	var ok := move_creature(uid, dest, player(pid))
	return _res(ok, "" if ok else "There's no room there.")

func eat(pid: String, uid: String) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	var f := p.inventory.find(uid)
	if f.is_empty():
		return r
	var it: Dictionary = Data.get_item(f.entry.id)
	var e_gain: float = float(it.get("energy", 0))
	if e_gain <= 0:
		e_gain = maxf(5.0, Data.sell_price(f.entry.id, int(f.entry.q)) * 0.4) if Data.is_edible(f.entry.id) else 0.0
	if e_gain <= 0:
		return r
	f.inv.take(uid, 1)
	p.energy = minf(p.max_energy, p.energy + e_gain)
	EventBus.energy_changed.emit(p.energy, p.max_energy)
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "eat"
	return r

# --- Regional forage -------------------------------------------------------------------------

## Spawns forage objects on a map for the current day (deterministic).
func spawn_forage(map_id: String) -> void:
	var info := map_info(map_id)
	if info.get("forage_done", false) or info.get("indoor", false) or map_id in ["greenhouse"]:
		return
	info["forage_done"] = true
	var region: String = info.get("region", "")
	var pool: Array = []
	if region != "":
		pool = Data.regions[region].get("forage", {}).get(season(), [])
	elif map_id == "farm" or map_id == "town":
		pool = Data.regions.meadow.get("forage", {}).get(season(), [])
	if pool.is_empty():
		return
	var g: FarmGrid = info.grid
	var frng := RandomNumberGenerator.new()
	frng.seed = hash([int(world.seed), day(), map_id, "forage"])
	var count := 6 if region != "" else 2
	for i in count * 4:
		if count <= 0:
			break
		var t := Vector2i(frng.randi_range(2, g.w - 3), frng.randi_range(2, g.h - 3))
		if g.get_deco(t) == 0 and not g.is_blocked(t) and not g.is_tilled(t) and g.get_ground(t) not in Tiles.BLOCKING_GROUND:
			g.objects[Tiles.key(t)] = {"id": pool[frng.randi() % pool.size()], "kind": "forage"}
			count -= 1

# --- Save --------------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var g := {}
	for m in grids:
		g[m] = grids[m].to_dict()
	var pl := {}
	for pid in players:
		pl[pid] = players[pid].to_dict()
	var rn: Array = []
	for c in ranch:
		rn.append(c.to_dict())
	var sn: Array = []
	for c in sanctuary:
		sn.append(c.to_dict())
	return {"world": world.duplicate(true), "grids": g, "farm_chest": farm_chest.to_dict(), "ranch": rn, "sanctuary": sn, "players": pl}

func from_dict(d: Dictionary) -> void:
	world = d.world.duplicate(true)
	rng.seed = hash([int(world.seed), int(world.day)])
	grids.clear()
	for m in PERSISTENT_MAPS:
		if d.grids.has(m):
			grids[m] = FarmGrid.from_dict(d.grids[m])
		else:
			grids[m] = MapBuilder.build_authored(Data.get_map(m)).grid
	farm_chest = Inventory.new(10, 8)
	farm_chest.from_dict(d.get("farm_chest", {}))
	ranch.clear()
	for c in d.get("ranch", []):
		ranch.append(Creature.from_dict(c))
	sanctuary.clear()
	for c in d.get("sanctuary", []):
		sanctuary.append(Creature.from_dict(c))
	players.clear()
	for pid in d.get("players", {}):
		players[pid] = PlayerData.from_dict(d.players[pid])
	# Re-key the host's own player to the current local id.
	if not players.has(Net.local_id()) and players.has("local"):
		var lp: PlayerData = players["local"]
		players.erase("local")
		lp.id = Net.local_id()
		players[lp.id] = lp
	_map_cache.clear()
	started = true
