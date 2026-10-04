extends Node
## The whole simulation state. The host is authoritative; actions here are
## called directly offline or via Net RPCs in co-op.

const SAVE_VERSION := 3
const PERSISTENT_MAPS := ["farm", "greenhouse", "terrace"]
const STARTERS := ["sproutle", "puddlop", "embercub"]

var world: Dictionary = {}
var grids: Dictionary = {}            # persistent FarmGrids
var farm_chest: Inventory
var shipping_bin: Inventory
var ranch: Array = []                 # Array[Creature] living at the farm (workers)
var sanctuary: Array = []             # overflow storage (unlimited)
var players: Dictionary = {}          # id -> PlayerData
var started: bool = false
var rng := RandomNumberGenerator.new()

var _map_cache: Dictionary = {}       # map_id -> build result (non-persistent maps)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	EventBus.quest_updated.connect(_queue_story)
	EventBus.creature_befriended.connect(_queue_story.unbind(1))
	EventBus.farm_level_up.connect(_queue_story.unbind(2))
	EventBus.shrine_restored.connect(_queue_story.unbind(1))
	TimeService.tick.connect(_on_time_tick)
	Modifiers.register("backpack", func(p): return p.pack_mods() if p else {})

func _queue_story() -> void:
	check_story.call_deferred()

# --- Setup ------------------------------------------------------------------------

## Every world key with its starting value. Loading fills keys an older save doesn't have.
static func default_world() -> Dictionary:
	return {
		"version": SAVE_VERSION, "seed": 0, "day": 0, "minute": Calendar.DAY_START, "weather": "sun",
		"money": 500, "farm_name": "Sunny", "buildings": [], "shrines": [],
		"regions": ["meadow", "whisperwood"], "dex": {}, "dex_claimed": [], "weekly": [], "weekly_week": -1,
		"board": [], "board_week": -1, "stats": {"earned": 0}, "farm": {"level": 1, "xp": 0}, "mine_depth": {},
		"flags": {}, "quest": 0, "legends": [], "festival_done": [], "hatchery": [], "shipping": [],
		"pairs": [], "luck": 0.0, "created": 0.0, "played": 0.0,
		"chains": {}, "bounty": {}, "bounty_week": -1,
		"time": {"last": 0.0}, "quests": {}, "skills": {}, "fishing": {}, "mining": {}, "casino": {}, "tutorial": {},
	}

func new_game(opts: Dictionary) -> void:
	var seed_v: int = int(opts.get("seed", randi()))
	rng.seed = seed_v
	world = default_world()
	world.seed = seed_v
	world.farm_name = opts.get("farm_name", "Sunny")
	world.created = Time.get_unix_time_from_system()
	world.time = {"last": TimeService.now()}
	grids.clear()
	_map_cache.clear()
	for m in PERSISTENT_MAPS:
		grids[m] = MapBuilder.build_authored(Data.get_map(m)).grid
	farm_chest = Inventory.new(10, 8)
	shipping_bin = _new_shipping_bin()
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
	world.weather = Calendar.roll_weather(seed_v, 0, season())
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

## The real-world season. In co-op everyone sees the host's, which travels with the world sync.
func season() -> String:
	if Net.is_authority() or not world.has("season"):
		world["season"] = Seasons.current(TimeService.now(), Settings.hemisphere)
	return str(world.season)

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

## Newest last: [unix, amount, reason msgid]. The Journal shows them as the farm's ledger.
const LEDGER_MAX := 50

func add_money(n: int, at: Vector2 = Vector2.INF, reason: String = "") -> void:
	world.money = maxi(0, int(world.money) + n)
	if n > 0:
		world.stats.earned = int(world.stats.get("earned", 0)) + n
	if n != 0:
		var led: Array = world.get("ledger", [])
		led.append([int(TimeService.now()), n, reason])
		if led.size() > LEDGER_MAX:
			led = led.slice(led.size() - LEDGER_MAX)
		world["ledger"] = led
	EventBus.money_changed.emit(int(world.money), n)
	if at != Vector2.INF and n != 0:
		EventBus.popup.emit(at, ("+" if n > 0 else "-") + Num.short(absi(n)), Color("#ffd447") if n > 0 else Color("#ff7a7a"), "_coin")

func spend(n: int, reason: String = "") -> bool:
	if int(world.money) < n:
		return false
	add_money(-n, Vector2.INF, reason)
	return true

func add_farm_xp(n: int, at: Vector2 = Vector2.INF) -> void:
	if n <= 0:
		return
	var ups := Progression.add_farm_xp(world.farm, n)
	if at != Vector2.INF:
		EventBus.popup.emit(at + Vector2(0, -10), tr("+%d XP") % n, Color("#8fe36b"), "")
	for lv in ups:
		var info := Progression.level_reward(lv)
		grant(info.get("reward", {}), local_player())
		EventBus.farm_level_up.emit(lv, info)

## Farm-wide counter (weekly challenges); with a player id it also counts for that player's quests.
func bump_stat(key: String, n: int = 1, pid: String = "") -> void:
	world.stats[key] = int(world.stats.get(key, 0)) + n
	var p := player(pid) if pid != "" else null
	if p:
		p.stat_add(key, n)
	for c in Progression.bump(world.weekly, key, n):
		add_money(int(c.reward_money), Vector2.INF, "Story")
		EventBus.toast.emit(tr("Weekly challenge complete: %s (+%s)") % [tr(c.text), CoinLabel.text(int(c.reward_money))], "star")
	EventBus.quest_updated.emit()

## Grants a reward dict {item: n, money: n, recipe: id}
func grant(reward: Dictionary, p: PlayerData) -> void:
	for k in reward:
		if k == "money":
			add_money(int(reward[k]), Vector2.INF, "Reward")
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
	var b := bounty()
	if Endless.bounty_met(b, c):
		b.done = true
		grant(b.reward, p)
		bump_stat("bounty")
		EventBus.toast.emit("Bounty complete: %s!" % Endless.bounty_text(b), "star")
	if p.party.size() < PlayerData.PARTY_MAX:
		p.party.append(c)
		EventBus.party_changed.emit()
		return "party"
	if ranch.size() < den_capacity():
		ranch.append(c)
		c.start_default_job()
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
		c.job_manual = false
	match dest:
		"party": p.party.append(c)
		"den":
			ranch.append(c)
			c.start_default_job()
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
	c.job_manual = true
	return true

func set_pair(a_uid: String, b_uid: String) -> Dictionary:
	var a := find_creature(a_uid)
	var b := find_creature(b_uid)
	if a == null or b == null or not a in ranch or not b in ranch:
		return {"ok": false, "reason": tr("Both Wildlings must live in the Den.")}
	if not Breeding.compatible(a, b):
		return {"ok": false, "reason": tr("These two don't seem interested in each other.")}
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
	var secs := maxi(1, days) * CropGrowth.EGG_DAY_SECONDS / Modifiers.mult(p, "hatch_speed")
	world.hatchery.append({"egg": egg, "hatch_at": TimeService.now() + secs, "secs": secs})
	EventBus.inventory_changed.emit()
	return true

# --- Time ---------------------------------------------------------------------------------

func advance_minutes(n: int) -> void:
	world.minute = int(world.minute) + n
	world.played = float(world.get("played", 0.0)) + n
	EventBus.time_changed.emit(int(world.minute))
	if int(world.minute) >= Calendar.NIGHT_ROLLOVER:
		end_day(false)

func abs_minute() -> int:
	return day() * 1440 + minute()

# --- Real time ---------------------------------------------------------------------------------

## The real-world season at a unix time (tests pin it with Seasons.override).
func season_at(unix: float) -> String:
	return Seasons.current(unix, Settings.hemisphere)

func _on_time_tick() -> void:
	if started and Net.is_authority():
		idle_advance(TimeService.now())

## Runs the farm forward in real time to `to`: crops, trees, machines, eggs and Wildling jobs.
## Gaps longer than the offline cap are cut off. Returns what happened (merged into world.time.report).
func idle_advance(to: float, offline: bool = false) -> Dictionary:
	if not world.has("time"):
		world.time = {"last": to}
	var last := float(world.time.get("last", 0.0))
	if last <= 0.0:
		world.time.last = to
		return {}
	var from := maxf(last, to - TimeService.OFFLINE_CAP)
	if to <= from:
		return {}
	var rep := {"jobs": FarmJobs.new_report(), "hatched": [], "evolved": [], "eggs": 0, "ripe": 0, "seconds": to - from}
	var p := local_player()
	var mult := Modifiers.mult(p, "crop_growth") if p else 1.0
	var acc := float(world.time.get("job_acc", 0.0)) + (to - from)
	var ticks := int(acc / FarmJobs.TICK_SECONDS)
	world.time.job_acc = acc - ticks * FarmJobs.TICK_SECONDS
	var steps := mini(ticks, 144)
	var scale := float(ticks) / maxf(1.0, float(steps))
	var eff := 1.0
	if offline:
		eff = minf(1.0, FarmJobs.OFFLINE_EFFICIENCY + (Modifiers.value(p, "offline_efficiency") if p else 0.0))
	var t := from
	var span := (to - from) / maxf(1.0, float(steps))
	for i in steps:
		_grow_all(t, t + span, mult, rep)
		t += span
		_job_tick(t, scale, eff, rep)
	_grow_all(t, to, mult, rep)
	_hatch_due(to, rep)
	world.time.last = to
	_merge_idle(rep)
	return rep

func _grow_all(from: float, to: float, mult: float, rep: Dictionary) -> void:
	if to <= from:
		return
	for m in grids:
		var g: FarmGrid = grids[m]
		var ripe_before := 0
		for t in g.planted_tiles():
			if g.crop_ready(t):
				ripe_before += 1
		var changed := g.advance(from, to, {"season_at": season_at, "mult": mult})
		var ripe_after := 0
		for t in g.planted_tiles():
			if g.crop_ready(t):
				ripe_after += 1
		rep.ripe = int(rep.ripe) + maxi(0, ripe_after - ripe_before)
		for k in changed:
			EventBus.tile_changed.emit(m, Tiles.parse_key(k))

## One Wildling work step standing in for `scale` ten-minute ticks.
func _job_tick(now: float, scale: float, eff: float, rep: Dictionary) -> void:
	var trng := RandomNumberGenerator.new()
	trng.seed = hash([int(world.seed), int(now), "jobs"])
	var season_now := season_at(now)
	var jr: Dictionary = FarmJobs.run(ranch, {"grids": farm_grids(), "chest": farm_chest, "rng": trng, "season": season_now, "scale": scale, "efficiency": eff, "now": now})
	FarmJobs.collect_produce(ranch, farm_chest, trng, jr, scale * eff)
	FarmJobs.rest(ranch, has_building("wildling_spa"), scale)
	Machines.apply_power(farm_grids(), int(jr.powered))
	Machines.automate(farm_grids(), farm_chest, now, int(jr.machine_slots), jr)
	FarmJobs.merge_report(rep.jobs, jr)
	for c: Creature in ranch:
		if c.can_evolve() != "":
			var from_name: String = c.display_name()
			var from_species: String = c.species_id
			c.evolve()
			Progression.mark(world.dex, c.species_id, true, c.starry)
			rep.evolved.append({"from": from_name, "from_species": from_species, "to": c.species_id})
	var breed_f: float = scale * eff * FarmJobs.TICK_SECONDS / float(FarmJobs.BREED_PERIOD)
	for pair in world.pairs:
		var a := find_creature(pair[0])
		var b := find_creature(pair[1])
		if a and b and a in ranch and b in ranch and trng.randf() < Breeding.egg_chance(a, b) * breed_f:
			var egg := Breeding.make_egg(a, b, trng, {"heirloom": farm_chest.has("heirloom_charm") or _anyone_has("heirloom_charm"), "starry_mult": 3.0 if _anyone_has("starry_charm") else 1.0, "season": season_now})
			farm_chest.add("wildling_egg", 1, 0, {"egg": egg})
			rep.eggs = int(rep.eggs) + 1
	if trng.randf() < scale / 12.0:
		for m in grids:
			for t in grids[m].creep_weeds(trng, 1):
				EventBus.tile_changed.emit(m, t)

func _hatch_due(now: float, rep: Dictionary) -> void:
	var still: Array = []
	var hrng := RandomNumberGenerator.new()
	hrng.seed = hash([int(world.seed), int(now), "hatch"])
	for slot in world.hatchery:
		if float(slot.get("hatch_at", 0.0)) <= now:
			var c := Breeding.hatch(slot.egg, hrng)
			var where := add_creature(local_player(), c)
			bump_stat("hatch")
			add_farm_xp(Progression.XP.hatch)
			rep.hatched.append({"species": c.species_id, "starry": c.starry, "where": where})
			EventBus.egg_hatched.emit(c)
		else:
			still.append(slot)
	world.hatchery = still

## Keeps a running summary until the player next sees a report.
func _merge_idle(rep: Dictionary) -> void:
	var acc: Dictionary = world.time.get("report", {})
	if acc.is_empty():
		acc = {"jobs": FarmJobs.new_report(), "hatched": [], "evolved": [], "eggs": 0, "ripe": 0, "seconds": 0.0}
	FarmJobs.merge_report(acc.jobs, rep.jobs)
	acc.hatched.append_array(rep.hatched)
	acc.evolved.append_array(rep.evolved)
	acc.eggs = int(acc.eggs) + int(rep.eggs)
	acc.ripe = int(acc.ripe) + int(rep.ripe)
	acc.seconds = float(acc.seconds) + float(rep.seconds)
	world.time.report = acc

## Hands over the summary collected since the last report and starts a fresh one.
func take_idle_report() -> Dictionary:
	var acc: Dictionary = world.get("time", {}).get("report", {})
	world.time.erase("report")
	return acc

## After loading: catches the farm up on the time nobody was playing and pays out the shipping
## bin if a game day's worth of time has passed. Returns the "while you were away" report.
func catch_up() -> Dictionary:
	var last := float(world.get("time", {}).get("last", 0.0))
	var now := TimeService.now()
	var away := TimeService.elapsed(last, now) if last > 0.0 else 0.0
	idle_advance(now, true)
	var rep := take_idle_report()
	if rep.is_empty():
		rep = {"jobs": {}, "hatched": [], "evolved": [], "eggs": 0, "ripe": 0}
	rep["away"] = away
	if away >= Settings.seconds_per_ten_minutes() * 120.0:
		var ship := _pay_shipping()
		rep["shipped"] = ship.shipped
		rep["ship_total"] = ship.total
		for pid in players:
			var pl: PlayerData = players[pid]
			pl.energy = minf(pl.max_energy, pl.energy + pl.max_energy * clampf(away / (8.0 * 3600.0), 0.0, 1.0))
	return rep

func _pay_shipping() -> Dictionary:
	if has_building("auto_shipper"):
		for e in farm_chest.all_entries().duplicate():
			var cat: String = Data.get_item(e.id).get("cat", "")
			if cat in ["crop", "fruit", "artisan", "produce", "forage", "gem"]:
				world.shipping.append({"id": e.id, "n": int(e.n), "q": int(e.q)})
				farm_chest.remove(e.id, int(e.n))
	for e in shipping_bin.entries.duplicate():
		world.shipping.append({"id": e.id, "n": int(e.n), "q": int(e.q)})
	shipping_bin.entries.clear()
	var shipped: Array = []
	var total := 0
	for sh in world.shipping:
		var v := Data.sell_price(sh.id, int(sh.q)) * int(sh.n)
		total += v
		shipped.append({"id": sh.id, "n": int(sh.n), "q": int(sh.q), "v": v})
		if Data.get_item(sh.id).get("cat", "") == "crop":
			bump_stat("ship:crop", int(sh.n))
	world.shipping = []
	if total > 0:
		add_money(total, Vector2.INF, "Shipping bin")
		add_farm_xp(int(total / 40))
	return {"shipped": shipped, "total": total}

func _job_luck() -> float:
	var l := 0.0
	for c: Creature in ranch:
		if c.job == "luck" and c.can_do_job("luck") and c.energy > 1.0:
			l += 0.01 * c.job_power("luck")
	return l

func _guarded() -> bool:
	for c: Creature in ranch:
		if c.job == "guard" and c.can_do_job("guard") and c.energy > 1.0:
			return true
	return false

## Ends the game day: shipping, weather, luck, friendships, weekly tasks. Sleeping skips the rest of
## the night, refills energy and wakes you at the farm; otherwise the clock just rolls over at 6:00.
## The farm itself runs in real time (idle_advance), so nothing grows here. Returns the report.
func end_day(slept: bool = true) -> Dictionary:
	SaveManager.set_quiet(true)
	EventBus.day_ending.emit()
	if Net.is_authority():
		idle_advance(TimeService.now())
	var report := {"shipped": [], "ship_total": 0, "jobs": {}, "farm": {}, "hatched": [], "eggs": 0, "slept": slept}
	var nrng := RandomNumberGenerator.new()
	nrng.seed = hash([int(world.seed), day(), "night"])
	var ship := _pay_shipping()
	report.shipped = ship.shipped
	report.ship_total = ship.total
	if slept:
		var idle := take_idle_report()
		for k in idle:
			report[k] = idle[k]
	# Advance the date
	world.day = day() + 1
	world.minute = Calendar.DAY_START
	world.weather = Calendar.roll_weather(int(world.seed), day(), season())
	var day_rng := RandomNumberGenerator.new()
	day_rng.seed = hash([int(world.seed), day(), "luck"])
	world.luck = day_rng.randf_range(-0.03, 0.05) + _job_luck()
	for o in grids.farm.objects.values():
		if o.id == "wishing_well":
			world.luck = float(world.luck) + 0.02
	var farm_rep := {}
	var guarded := _guarded()
	for m in grids:
		var g: FarmGrid = grids[m]
		if m != "greenhouse" and Calendar.weather_waters(world.weather):
			g.rain(TimeService.now())
		var r := g.night(nrng, guarded)
		for k in r:
			farm_rep[k] = int(farm_rep.get(k, 0)) + int(r[k])
	report.farm = farm_rep
	for c in ranch:
		c.grooming = maxi(0, c.grooming - 10)
	for pid in players:
		var p: PlayerData = players[pid]
		p.heal_party()
		if slept:
			p.energy = p.max_energy
			p.map_id = "farm"
			var spawn: Array = Data.get_map("farm").spawn
			p.pos = tile_center(Vector2i(int(spawn[0]), int(spawn[1])))
		p.water_left = p.water_capacity()
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
	bounty()
	for k in world.flags.keys():
		if str(k).begins_with("chest:"):
			world.flags.erase(k)
	_map_cache.clear()
	report["day"] = day()
	report["festival"] = Calendar.festival_on(day())
	EventBus.day_started.emit(day(), report)
	EventBus.weather_changed.emit(world.weather)
	EventBus.time_changed.emit(minute())
	SaveManager.set_quiet(false)
	SaveManager.autosave()
	return report

func _fix_hatchery_types() -> void:
	for slot in world.hatchery:
		slot.hatch_at = float(slot.get("hatch_at", 0.0))
		slot.secs = float(slot.get("secs", CropGrowth.EGG_DAY_SECONDS))

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
				p.stat_add("till")
			elif g.is_tilled(t) and g.crop_at(t).is_empty():
				if not _spend_energy(p, base_cost):
					return r
				g.until(t)
				r.ok = true
				r.sfx = "hoe"
		"watering_can":
			if g.get_ground(t) in Tiles.WATER_TILES or g.object_at(t).get("id", "") == "birdbath":
				p.water_left = p.water_capacity()
				r.ok = true
				r.sfx = "refill"
				r.fx.append([tr("Refilled!"), Color("#7ac8ff")])
			elif g.is_tilled(t):
				if p.water_left <= 0:
					r.reason = tr("Your watering can is empty. Refill it at water.")
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
						p.stat_add("water")
				r.ok = true
				r.sfx = "water"
		"shovel":
			if g.is_trench(t):
				if not _spend_energy(p, base_cost):
					return r
				g.fill_trench(t)
				r.ok = true
				r.sfx = "hoe"
			elif g.can_dig_trench(t):
				if not _spend_energy(p, base_cost * 1.5):
					return r
				g.dig_trench(t)
				r.ok = true
				r.sfx = "hoe"
			if r.ok:
				_trench_redraw(map_id, t)
		"bucket":
			if g.is_natural_water(t):
				p.bucket_full = true
				r.ok = true
				r.sfx = "refill"
				r.fx.append([tr("Bucket filled"), Color("#7ac8ff")])
			elif g.is_trench(t) and p.bucket_full:
				if g.pour_bucket(t):
					p.bucket_full = false
					r.ok = true
					r.sfx = "water"
					_trench_redraw(map_id, t)
			elif g.is_tilled(t) and p.bucket_full:
				for a in [t, t + Vector2i(1, 0), t + Vector2i(-1, 0), t + Vector2i(0, 1), t + Vector2i(0, -1)]:
					g.water(a)
					EventBus.tile_changed.emit(map_id, a)
				p.bucket_full = false
				r.ok = true
				r.sfx = "water"
			elif not p.bucket_full:
				r.reason = tr("The bucket is empty. Fill it at a pond, river or the sea.")
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
			elif tool == "pickaxe" and g.until(t):
				r.ok = true
				r.sfx = "hoe"
			elif tool == "axe" and g.object_at(t).get("kind", "") == "tree" and FarmGrid.tree_growth(g.object_at(t), TimeService.now()) < 1.0:
				var o := g.remove_object(t)
				give_item(p, o.id, 1)
				r.ok = true
				r.sfx = "chop"
			elif tool == "pickaxe" and not g.object_at(t).is_empty() and g.object_at(t).kind in ["machine", "sprinkler", "scarecrow", "decor", "chest"]:
				return pick_up_object(pid, map_id, t)
	if r.ok:
		EventBus.tile_changed.emit(map_id, t)
		for fx in r.fx:
			EventBus.popup.emit(at, fx[0], fx[1], "")
	return r

## Water can flow far along a trench; repaint every trench tile and the soil around them.
func _trench_redraw(map_id: String, t: Vector2i) -> void:
	var g := grid(map_id)
	for k in g.trenches:
		EventBus.tile_changed.emit(map_id, Tiles.parse_key(k))
	EventBus.tile_changed.emit(map_id, t)
	for k in g.soil:
		EventBus.tile_changed.emit(map_id, Tiles.parse_key(k))

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
			r.reason = tr("Empty the chest first.")
			return r
	if o.kind == "machine" and Machines.is_busy(o):
		r.reason = tr("It's busy.")
		return r
	if not p.inventory.can_add(o.id, 1):
		r.reason = tr("No room in your pack.")
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
			if g.plant(t, e.id, season(), int(e.q) + 1):
				f.inv.take(uid, 1)
				p.stat_add("plant")
				r.ok = true
				r.sfx = "plant"
				add_farm_xp(Progression.XP.plant)
				var dist := CropGrowth.season_distance(Data.get_item(e.id).crop, season())
				if dist > 0 and not g.greenhouse:
					r.fx.append([tr("Grows slowly in %s") % Data.season_name(season()), Color("#ffb070")])
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
				r.reason = tr("Can't place that here.")
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
			r.reason = tr("Your pack is full.")
			return r
		var h := g.harvest(t, rng, luck() + Modifiers.value(p, "crop_quality"), int(p.skills.get("farming", 0)), season(), Modifiers.mult(p, "crop_yield"))
		give_item(p, h.id, int(h.n), int(h.q))
		if h.spent:
			r.fx.append([tr("The plant is spent."), Color("#c0a080")])
		r.ok = true
		r.sfx = "harvest"
		var qname: String = Data.QUALITY_NAMES[int(h.q)]
		r.fx.append(["+%d %s%s" % [int(h.n), (qname + " ") if qname != "" else "", Data.item_name(h.id)], [Color.WHITE, Color("#d8e0f0"), Color("#ffd447"), Color("#c890ff")][int(h.q)]])
		add_farm_xp(Progression.XP.harvest * int(h.n), at)
		bump_stat("harvest", int(h.n), pid)
		p.stat_add("harvest:" + str(h.id), int(h.n))
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
			bump_stat("harvest", int(fr.n), pid)
		elif o.get("kind", "") == "machine" and Machines.is_ready(o, TimeService.now()):
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
			EventBus.popup.emit(at, fx[0], fx[1], "")
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
		if k == f.entry.id and chk.has("consume_q"):
			p.inventory.remove_quality(k, int(chk.consume[k]), int(chk.consume_q))
		else:
			p.inventory.remove(k, int(chk.consume[k]))
	o.input = f.entry.id
	o.output = chk.output
	o.ready_at = TimeService.now() + Machines.seconds_for(int(chk.time))
	r.ok = true
	r.sfx = "machine"
	EventBus.inventory_changed.emit()
	EventBus.objects_changed.emit(map_id)
	return r

func _new_shipping_bin() -> Inventory:
	return Inventory.new(8, 6, [], false, true)

## Older saves kept the bin as a flat list on the world. Pull that into the grid once.
func _load_shipping_bin(d: Dictionary) -> void:
	shipping_bin = _new_shipping_bin()
	shipping_bin.from_dict(d.get("shipping_bin", {}))
	var queued: Array = world.get("shipping", []).duplicate(true)
	world.shipping = []
	for s in queued:
		if typeof(s) != TYPE_DICTIONARY:
			continue
		var id := str(s.get("id", ""))
		if id == "":
			continue
		var n := int(s.get("n", 1))
		var q := int(s.get("q", 0))
		var left := n
		if shipping_bin.accepts(id):
			left = shipping_bin.add(id, n, q)
		if left > 0:
			world.shipping.append({"id": id, "n": left, "q": q})

func ship(pid: String, uid: String, n: int = -1) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	var f := p.inventory.find(uid)
	if f.is_empty():
		return r
	if not shipping_bin.accepts(f.entry.id):
		r.reason = tr("That can't be shipped.")
		return r
	var amount: int = int(f.entry.n) if n < 0 else mini(n, int(f.entry.n))
	var taken: Dictionary = f.inv.take(uid, amount)
	var left := shipping_bin.add(taken.id, int(taken.n), int(taken.q), taken.meta)
	if left > 0:
		p.inventory.add(taken.id, left, int(taken.q), taken.meta)
		if left == int(taken.n):
			r.reason = tr("The shipping bin is full.")
			return r
	r.ok = true
	r.sfx = "ship"
	p.stat_add("ship", int(taken.n) - left)
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
		r.reason = tr("That's not for sale right now.")
		return r
	# Prefer the backpack grid. Matching bags (seed pouch, treat tin, gem case)
	# only catch what doesn't fit, so a purchase doesn't vanish inside one.
	if not p.inventory.can_add(item_id, n, 0, false):
		r.reason = tr("Your pack is full.")
		return r
	if not spend(price * n, "Shop"):
		r.reason = tr("Not enough gold.")
		return r
	var before := p.inventory.homes_of(item_id)
	var left := p.inventory.add(item_id, n, 0, {}, false)
	var chest_gain := 0
	if left > 0:
		var still := farm_chest.add(item_id, left)
		chest_gain = left - still
		if still > 0:
			add_money(price * still, Vector2.INF, "Shop")
			n -= still
	if n <= 0:
		r.reason = tr("Your pack is full.")
		EventBus.inventory_changed.emit()
		return r
	EventBus.inventory_changed.emit()
	bump_stat("spent", price * n)
	r.ok = true
	r.sfx = "coin"
	r.note = _purchase_note(item_id, n, before, p.inventory.homes_of(item_id), chest_gain)
	return r

func _purchase_note(item_id: String, n: int, before: Dictionary, after: Dictionary, chest_gain: int) -> String:
	var name := Data.item_name(item_id)
	var stashed: Array = []
	for b in after.get("bags", []):
		var prev := 0
		for a in before.get("bags", []):
			if str(a.uid) == str(b.uid):
				prev = int(a.n)
				break
		var gain := int(b.n) - prev
		if gain > 0:
			stashed.append({"n": gain, "where": str(b.name)})
	if chest_gain > 0:
		stashed.append({"n": chest_gain, "where": tr("the farm chest")})
	if stashed.is_empty():
		return tr("Bought %d %s") % [n, name]
	var top_gain := int(after.get("top", 0)) - int(before.get("top", 0))
	if stashed.size() == 1 and top_gain <= 0:
		return tr("Bought %d %s (in %s)") % [n, name, stashed[0].where]
	var parts: PackedStringArray = []
	for s in stashed:
		parts.append(tr("%d in %s") % [int(s.n), s.where])
	return tr("Bought %d %s (%s)") % [n, name, ", ".join(parts)]

## Sells straight to a shopkeeper (instant, unlike the shipping bin).
func sell(pid: String, uid: String, n: int = -1) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	var f := p.inventory.find(uid) if p else {}
	if f.is_empty():
		return r
	var price := Data.sell_price(f.entry.id, int(f.entry.q))
	if price <= 0 or Data.get_item(f.entry.id).get("cat", "") in ["tool", "key"]:
		r.reason = tr("They won't buy that.")
		return r
	var amount: int = int(f.entry.n) if n < 0 else mini(n, int(f.entry.n))
	f.inv.take(uid, amount)
	add_money(price * amount, Vector2.INF, "Sold")
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
		r.reason = tr("You don't know that recipe yet.")
		return r
	if kind == "cooking" and not has_building("kitchen"):
		r.reason = tr("You need a kitchen to cook.")
		return r
	var srcs := craft_sources(p)
	if not Economy.can_make(kind, recipe_id, srcs):
		r.reason = tr("Missing ingredients.")
		return r
	if not Economy.make(kind, recipe_id, srcs):
		r.reason = tr("Your pack is full.")
		return r
	var kind_key := "cook" if kind == "cooking" else "craft"
	bump_stat(kind_key, 1, pid)
	p.stat_add(kind_key + ":" + recipe_id)
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
	spend(int(b.price), "Building")
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
		r.reason = tr("That tool is already the best it can be.")
		return r
	var srcs := craft_sources(p)
	if Economy.count_in(srcs, spec.bar) < int(spec.n):
		r.reason = tr("Bring %d %s.") % [int(spec.n), Data.item_name(spec.bar)]
		return r
	if not spend(int(spec.price), "Tool upgrade"):
		r.reason = tr("Not enough gold.")
		return r
	Economy.consume(srcs, {spec.bar: int(spec.n)})
	p.tool_levels[tool] = int(spec.level)
	bump_stat("upgrade")
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "levelup"
	return r

func buy_backpack(pid: String, id: String) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	var spec := Economy.backpack_spec(id)
	if p == null or spec.is_empty() or id in p.packs:
		return r
	if not is_open_requirement(spec.get("requires", "")):
		r.reason = Economy.req_text(spec.requires)
		return r
	if int(spec.get("chips", 0)) > 0:
		if not Casino.spend_chips(p, int(spec.chips)):
			r.reason = tr("Not enough chips.")
			return r
	elif not spend(int(spec.price), "Backpack"):
		r.reason = tr("Not enough gold.")
		return r
	p.packs.append(id)
	p.set_backpack(id)
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "levelup"
	return r

## Switches to another owned pack if everything fits.
func equip_backpack(pid: String, id: String) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null or not id in p.packs:
		return r
	if not p.set_backpack(id):
		r.reason = tr("Your things don't fit in the %s. Make some room first.") % Data.item_name(id)
		return r
	EventBus.inventory_changed.emit()
	r.ok = true
	r.sfx = "pickup"
	return r

## Hands in a Village Board request from the player's pack.
func deliver_board(pid: String, idx: int) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null or idx < 0 or idx >= world.board.size():
		return r
	var b: Dictionary = world.board[idx]
	if b.get("done", false):
		r.reason = tr("Already delivered.")
		return r
	if p.inventory.count(b.item) < int(b.n):
		r.reason = tr("You need %d %s.") % [int(b.n), Data.item_name(b.item)]
		return r
	p.inventory.remove(b.item, int(b.n))
	b.done = true
	add_money(int(b.money), Vector2.INF, "Request board")
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
	return _res(ok, "" if ok else tr("The Hatchery is full."))

func set_job_act(pid: String, uid: String, job_id: String) -> Dictionary:
	var ok := set_job(uid, job_id)
	if ok and player(pid):
		player(pid).stat_add("job_set")
	return _res(ok)

func move_creature_act(pid: String, uid: String, dest: String) -> Dictionary:
	var ok := move_creature(uid, dest, player(pid))
	return _res(ok, "" if ok else tr("There's no room there."))

## A co-op client befriended a Wildling in its own battle; the host files it (dex, den, farm XP).
func befriend_act(pid: String, creature_json: String) -> Dictionary:
	var p := player(pid)
	var d = JSON.parse_string(creature_json)
	if p == null or not d is Dictionary:
		return _res(false, tr("Bad creature."))
	var c := Creature.from_dict(d)
	if find_creature(c.uid) != null:
		return _res(false, tr("Already on the farm."))
	var r := _res(true, add_creature(p, c))
	bump_stat("befriend", 1, pid)
	return r

func dex_seen_act(_pid: String, species_id: String, owned: bool = false, starry: bool = false) -> Dictionary:
	if Data.species.has(species_id):
		Progression.mark(world.dex, species_id, owned, starry)
	return _res(true)

## Prize money from a client's trainer battle (money is shared by the farm).
func reward_act(_pid: String, amount: int) -> Dictionary:
	add_money(clampi(amount, 0, 20000), Vector2.INF, "Battle")
	return _res(true)

## Marks a species seen/owned in the farm dex, routing through the host when we're a client.
func dex_mark(species_id: String, owned: bool = false, starry: bool = false) -> void:
	Progression.mark(world.dex, species_id, owned, starry)
	if not Net.is_authority():
		Coop.act("dex_seen_act", [species_id, owned, starry])

## Farm money earned by the local player (routed to the host when visiting).
func earn(amount: int) -> void:
	if Net.is_authority():
		add_money(amount, Vector2.INF, "Battle")
	else:
		Coop.act("reward_act", [amount])

# --- Adventure: Wardens, shrines, mines, legends, festivals, story -----------------------------

func warden_won_act(_pid: String, region: String) -> Dictionary:
	if Adventure.warden_of(region) == "" or not region_unlocked(region):
		return _res(false, tr("There's no Warden there."))
	world.flags["warden:" + region] = true
	EventBus.quest_updated.emit()
	return _res(true)

## The shrine's guardian was beaten or befriended; the first time, the shrine wakes.
func guardian_result_act(pid: String, region: String, befriended: bool) -> Dictionary:
	var state := Adventure.shrine_state(world, region)
	if state == "dark":
		return _res(false, tr("The shrine is still dark."))
	if befriended:
		world.flags["guardian_home:" + region] = true
	var r := _res(true)
	if state == "restored":
		return r
	world.shrines.append(region)
	var rw := Adventure.shrine_reward(world.shrines.size())
	grant(rw.get("items", {}), player(pid))
	var next: String = rw.get("unlock_region", "")
	if next != "" and not next in world.regions:
		world.regions.append(next)
	add_farm_xp(Progression.XP.shrine)
	bump_stat("shrine")
	r["text"] = tr(str(rw.get("text", tr("The shrine glows!"))))
	r.sfx = "levelup"
	EventBus.shrine_restored.emit(region)
	return r

func legend_result_act(_pid: String, legend_id: String) -> Dictionary:
	if not Data.legends.has(legend_id) or legend_id in world.legends:
		return _res(false)
	world.legends.append(legend_id)
	EventBus.quest_updated.emit()
	return _res(true)

## Records reaching a mine floor; you can only go one floor deeper than your best.
func mine_floor_act(pid: String, region: String, floor_n: int) -> Dictionary:
	if not Data.regions.get(region, {}).has("mine") or not region_unlocked(region) or floor_n < 1:
		return _res(false, tr("The cave is blocked."))
	var deep := Adventure.deepest(world, region)
	if floor_n > deep + 1 and not floor_n in Adventure.elevator_floors(world, region):
		return _res(false, tr("You haven't been that deep yet."))
	var r := _res(true)
	if floor_n > deep:
		world.mine_depth[region] = floor_n
		add_farm_xp(Progression.XP.mine_floor)
		bump_stat("mine_floor", 1, pid)
		r["new_elevator"] = floor_n % Adventure.ELEVATOR_STEP == 0
	return r

func open_treasure_act(pid: String, map_id: String, x: int, y: int) -> Dictionary:
	var info := map_info(map_id)
	var t := Vector2i(x, y)
	var chest := {}
	for o in info.get("objects", []):
		if o.type == "treasure" and int(o.x) == x and int(o.y) == y:
			chest = o
	if chest.is_empty():
		return _res(false)
	var key := Adventure.treasure_key(str(info.id), day(), t)
	if world.flags.get(key, false):
		return _res(false, "It's empty.")
	world.flags[key] = true
	var r := _res(true)
	if chest.get("mimic", false):
		r["mimic"] = true
		return r
	var trng := RandomNumberGenerator.new()
	trng.seed = hash([int(world.seed), key])
	var loot := Adventure.treasure_loot(str(info.region), int(info.get("floor", 1)), trng, chest.get("grand", false))
	grant(loot, player(pid))
	r["loot"] = loot
	r.sfx = "chest"
	return r

func treasure_opened(map_id: String, t: Vector2i) -> bool:
	return world.flags.get(Adventure.treasure_key(str(map_info(map_id).id), day(), t), false)

## Festival participation at the Show Ring. op: social | eggs | show | fair | cup.
func festival_act(pid: String, op: String) -> Dictionary:
	var fest := Adventure.festival_today(day())
	var p := player(pid)
	if fest.is_empty() or p == null:
		return _res(false, tr("There's no festival today."))
	if Adventure.festival_done(world, day(), fest.id, pid):
		return _res(false, tr("You've already joined this year's %s.") % tr(str(fest.name)))
	var r := _res(true)
	var reward: Dictionary = fest.get("reward", {}).duplicate()
	var frng := RandomNumberGenerator.new()
	frng.seed = hash([int(world.seed), day(), pid, "festival"])
	match op:
		"social":
			for vid in Data.villagers:
				Relationships.add_points(vid, p.relationship(vid), int(fest.get("friendship", 20)))
		"eggs":
			var n := p.inventory.count("festival_egg")
			if n <= 0:
				return _res(false, tr("You haven't found any eggs yet."))
			p.inventory.remove("festival_egg", n)
			r["eggs"] = n
			reward = Adventure.egg_hunt_reward(n, fest)
		"show":
			var lead := p.lead()
			if lead == null:
				return _res(false, tr("You need a Wildling to enter."))
			var mine: int = Progression.show_score(lead, frng).score
			var rivals := Progression.rival_show_scores(frng, world.shrines.size() / 2)
			var place := 1
			for s in rivals:
				if int(s) > mine:
					place += 1
			r["score"] = mine
			r["rivals"] = rivals
			r["place"] = place
			if place > 1:
				reward = {"money": [0, 0, 600, 300, 100][place]}
		"fair":
			var picks := Adventure.fair_pick(p.inventory.all_entries())
			if picks.is_empty():
				return _res(false, tr("You have nothing to display. Bring crops, artisan goods or gems."))
			var mine2 := Adventure.fair_score(picks)
			var rivals2 := Adventure.fair_rivals(frng, Calendar.year(day()))
			var place2 := 1
			for rv in rivals2:
				if int(rv[1]) > mine2:
					place2 += 1
			r["picks"] = picks
			r["score"] = mine2
			r["rivals"] = rivals2
			r["place"] = place2
			if place2 > 1:
				reward = {"money": [0, 0, 500, 250, 100][place2]}
		"cup":
			pass
		_:
			return _res(false)
	world.festival_done.append(Adventure.festival_key(day(), fest.id, pid))
	grant(reward, p)
	r["reward"] = reward
	r.sfx = "levelup"
	EventBus.inventory_changed.emit()
	return r

# --- Endless goals ------------------------------------------------------------------------

## This week's Wildling Center bounty, rolled once per week from the regions open at the time.
func bounty() -> Dictionary:
	var wk := Calendar.week_number(day())
	if int(world.get("bounty_week", -1)) != wk:
		world.bounty = Endless.bounty_for(wk, int(world.seed), world.regions, world.dex)
		world.bounty_week = wk
	return world.bounty

func chain_of(pid: String) -> Dictionary:
	return world.get("chains", {}).get(pid, {})

func chain_act(pid: String, species: String) -> Dictionary:
	if not Data.species.has(species):
		return _res(false)
	if not world.has("chains"):
		world.chains = {}
	var ch := Endless.chain_after(chain_of(pid), species)
	world.chains[pid] = ch
	var r := _res(true)
	r["chain"] = ch
	return r

## Weekly Creature Show (Saturdays without a festival): one entry per player per show.
func show_act(pid: String, uid: String) -> Dictionary:
	var p := player(pid)
	if p == null or not Endless.show_open(day()):
		return _res(false, tr("The weekly Creature Show is held on Saturdays."))
	if int(world.flags.get("show:" + pid, -1)) == day():
		return _res(false, tr("You've already shown a Wildling today. Come back next Saturday!"))
	var c := find_creature(uid)
	if c == null or not c in p.party:
		return _res(false, tr("Bring the Wildling along in your party."))
	var srng := RandomNumberGenerator.new()
	srng.seed = hash([int(world.seed), day(), pid, "show"])
	var res := Endless.judge(c, srng)
	Endless.award(c, res)
	world.flags["show:" + pid] = day()
	add_money(int(res.prize), Vector2.INF, "Show prize")
	bump_stat("show")
	if int(res.place) == 1:
		bump_stat("show_win")
	var r := _res(true)
	r.merge(res)
	r["name"] = c.display_name()
	r["new_rank"] = c.show_rank
	r["ribbons"] = c.ribbons
	r.sfx = "levelup" if int(res.place) == 1 else "coin"
	EventBus.party_changed.emit()
	return r

func rematch_ready(pid: String, vid: String) -> bool:
	return Endless.rematch_open(world) and int(world.flags.get("rematch:%s:%s" % [vid, pid], -1)) != Calendar.week_number(day())

## A post-game Warden rematch was won: weekly reward, and every few wins the Wardens get stronger.
func rematch_won_act(pid: String, vid: String) -> Dictionary:
	if not Data.villagers.get(vid, {}).get("trainer", {}).has("warden"):
		return _res(false)
	if not rematch_ready(pid, vid):
		return _res(false, tr("%s only takes one rematch a week.") % Data.villager_name(vid))
	world.flags["rematch:%s:%s" % [vid, pid]] = Calendar.week_number(day())
	var tier := Endless.rematch_tier(world)
	var reward := Endless.rematch_reward(vid, tier)
	grant(reward, player(pid))
	bump_stat("rematch")
	var r := _res(true)
	r["reward"] = reward
	r["tier_up"] = Endless.rematch_tier(world) > tier
	r["level"] = Endless.rematch_level(Endless.rematch_tier(world))
	r.sfx = "levelup"
	EventBus.inventory_changed.emit()
	return r

## Pays out a finished quest once. Finishing the last daily of the day may add a streak bonus.
func claim_quest_act(pid: String, qid: String) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _res(false)
	var st := Quests.state(p)
	var d: Dictionary = st.done.get(qid, {})
	if d.is_empty() or d.get("claimed", false):
		return _res(false)
	d.claimed = true
	var r := _res(true)
	r["reward"] = Quests.reward_of(p, qid)
	grant_quest_reward(p, r.reward)
	if qid.begins_with("daily:"):
		var bonus := Quests.daily_finished(p)
		if not bonus.is_empty():
			grant_quest_reward(p, bonus)
			r["streak"] = int(st.daily.streak)
			r["bonus"] = bonus
	r.sfx = "levelup"
	EventBus.inventory_changed.emit()
	return r

## Quest rewards: money, items, recipe, friendship {villager: points}, skill points, emotes, chips, flags.
func grant_quest_reward(p: PlayerData, reward: Dictionary) -> void:
	var rest := {}
	for k in reward:
		match k:
			"friendship":
				for vid in reward[k]:
					Relationships.add_points(vid, p.relationship(vid), int(reward[k][vid]))
			"skill_points":
				p.skill_points += int(reward[k])
			"emote":
				if not reward[k] in p.emotes:
					p.emotes.append(reward[k])
			"chips":
				Casino.add_chips(p, int(reward[k]))
			"flag":
				world.flags[str(reward[k])] = true
			_:
				rest[k] = reward[k]
	grant(rest, p)

func story_seen_act(_pid: String, chapter_id: String) -> Dictionary:
	world.flags["story_seen:" + chapter_id] = true
	EventBus.quest_updated.emit()
	return _res(true)

var _story_busy := false

## Moves the main story on when the current chapter's goal is met.
func check_story() -> void:
	if not started or _story_busy or not Net.is_authority():
		return
	_story_busy = true
	while true:
		var ch := Adventure.chapter(world)
		if ch.is_empty() or not world.flags.get("story_seen:" + str(ch.id), false):
			break
		if not Adventure.goal_done(ch.goal, Adventure.story_facts(world, local_player())):
			break
		world.quest = int(world.quest) + 1
		grant(ch.get("reward", {}), local_player())
		EventBus.story_advanced.emit(ch)
	_story_busy = false

## Checks one side of a trade: [{kind:"item", uid, n} | {kind:"creature", uid}]. Returns "" if ok.
func validate_offer(p: PlayerData, offer: Array) -> String:
	var giving := 0
	for o: Dictionary in offer:
		if o.kind == "item":
			var f := p.inventory.find(str(o.uid))
			if f.is_empty() or int(f.entry.n) < int(o.n) or int(o.n) <= 0:
				return tr("%s no longer has that item.") % p.name
		elif o.kind == "creature":
			var c := find_creature(str(o.uid))
			if c == null or not c in p.party:
				return tr("%s no longer has that Wildling.") % p.name
			giving += 1
		else:
			return tr("Unknown offer.")
	if giving > 0 and giving >= p.party.size():
		return tr("%s has to keep at least one Wildling.") % p.name
	return ""

## Swaps both offers at once. Both must validate first.
func execute_trade(a: PlayerData, offer_a: Array, b: PlayerData, offer_b: Array) -> String:
	var err := validate_offer(a, offer_a)
	if err == "":
		err = validate_offer(b, offer_b)
	if err != "":
		return err
	var moving: Array = []
	for pair in [[a, offer_a, b], [b, offer_b, a]]:
		var from: PlayerData = pair[0]
		for o: Dictionary in pair[1]:
			if o.kind == "item":
				moving.append([pair[2], from.inventory.take(str(o.uid), int(o.n))])
			else:
				var c := find_creature(str(o.uid))
				from.party.erase(c)
				moving.append([pair[2], c])
	for m in moving:
		var to: PlayerData = m[0]
		if m[1] is Creature:
			var c2: Creature = m[1]
			add_creature(to, c2)
		else:
			var e: Dictionary = m[1]
			give_item(to, e.id, int(e.n), int(e.q), e.meta)
	bump_stat("trades")
	EventBus.inventory_changed.emit()
	EventBus.party_changed.emit()
	return ""

## Applies the host's world-level state (everything except map grids and players).
func apply_meta(d: Dictionary) -> void:
	var before := _ranch_signature()
	world = d.world.duplicate(true)
	farm_chest.from_dict(d.get("farm_chest", {}))
	_load_shipping_bin(d)
	ranch.clear()
	for c in d.get("ranch", []):
		ranch.append(Creature.from_dict(c))
	sanctuary.clear()
	for c in d.get("sanctuary", []):
		sanctuary.append(Creature.from_dict(c))
	EventBus.money_changed.emit(int(world.money), 0)
	if _ranch_signature() != before:
		EventBus.party_changed.emit()
	EventBus.quest_updated.emit()

func _ranch_signature() -> String:
	var parts: PackedStringArray = []
	for c: Creature in ranch:
		parts.append(c.uid + c.species_id)
	return ",".join(parts)

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
	if map_id == "town" and Calendar.festival_on(day()) == "egg_hunt":
		for t in Adventure.egg_spots(info.grid, int(world.seed), day()):
			info.grid.objects[Tiles.key(t)] = {"id": "festival_egg", "kind": "forage"}
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
	return {"world": world.duplicate(true), "grids": g, "farm_chest": farm_chest.to_dict(), "shipping_bin": shipping_bin.to_dict(), "ranch": rn, "sanctuary": sn, "players": pl}

func from_dict(d: Dictionary) -> void:
	world = d.world.duplicate(true)
	var defaults := default_world()
	for k in defaults:
		if not world.has(k):
			world[k] = defaults[k]
	rng.seed = hash([int(world.seed), int(world.day)])
	grids.clear()
	for m in PERSISTENT_MAPS:
		if d.grids.has(m):
			grids[m] = FarmGrid.from_dict(d.grids[m])
		else:
			grids[m] = MapBuilder.build_authored(Data.get_map(m)).grid
	farm_chest = Inventory.new(10, 8)
	farm_chest.from_dict(d.get("farm_chest", {}))
	_load_shipping_bin(d)
	ranch.clear()
	for c in d.get("ranch", []):
		var cr := Creature.from_dict(c)
		cr.start_default_job()
		ranch.append(cr)
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
	_fix_hatchery_types()
	for g in world.get("pending_gifts", []):
		var pl := player(str(g.pid)) if players.has(str(g.pid)) else local_player()
		give_item(pl, str(g.id), 1)
	world.erase("pending_gifts")
	started = true
