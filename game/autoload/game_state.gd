extends Node
## The whole simulation state. The host is authoritative; actions here are
## called directly offline or via Net RPCs in co-op.

const SAVE_VERSION := 5
const PERSISTENT_MAPS := ["farm", "greenhouse", "terrace"]
const STARTERS := ["sproutle", "puddlop", "embercub"]
const PLACE_REQUIRES := {"gull_bay": "story:coast", "eisenkamm": "story:mountain", "lumiere": "story:friends"}

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
	Modifiers.register("skills", func(p): return Skills.mods(p) if p else {})
	Modifiers.register("enchantments", func(p): return Enchanting.mods(p) if p else {})

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
	_cracks.clear()
	for m in PERSISTENT_MAPS:
		grids[m] = MapBuilder.build_authored(Data.get_map(m)).grid
		_mark_patches(m)
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
		"fish": Fishing.species_caught(p), "depth": deep_max(), "quest": int(world.get("quest", 0)),
		"vip": Casino.vip(p) if p else false,
	}

func has_building(id: String) -> bool:
	return id in world.buildings

func den_capacity() -> int:
	var base := 4
	if has_building("deluxe_den"):
		base = 16
	elif has_building("big_den"):
		base = 8
	var p := local_player()
	return base + (int(Modifiers.value(p, "den_slots")) if p else 0)

func hatchery_capacity() -> int:
	if has_building("big_hatchery"):
		return 4
	if has_building("hatchery"):
		return 2
	return 0

func region_unlocked(rid: String) -> bool:
	return rid in world.regions

## Places on the valley map: regions open with their shrines, the rest by their road's requirement.
func place_open(id: String) -> bool:
	if id in ["farm", "town"]:
		return true
	if Data.regions.has(id):
		return region_unlocked(id)
	return is_open_requirement(str(PLACE_REQUIRES.get(id, "")))

func is_open_requirement(req: String) -> bool:
	if req == "":
		return true
	if req.begins_with("region:"):
		return region_unlocked(req.substr(7))
	if req.begins_with("story:"):
		return int(world.get("quest", 0)) >= Adventure.chapter_index(req.substr(6))
	if Data.buildings.has(req):
		return has_building(req)
	return Economy.meets(req, ctx())

func luck() -> float:
	return float(world.get("luck", 0.0))

# --- Maps -----------------------------------------------------------------------------

func _mark_patches(m: String) -> void:
	for patch in Data.get_map(m).get("patches", []):
		world.flags["patch:" + str(patch.id)] = true

func map_info(map_id: String) -> Dictionary:
	if map_id.begins_with("mine:") and map_id.split(":").size() == 3:
		map_id = "%s:%d" % [map_id, day()]
	if _map_cache.has(map_id):
		return _map_cache[map_id]
	var info: Dictionary = MapBuilder.build(map_id, int(world.seed))
	if grids.has(map_id):
		info.grid = grids[map_id]
	if map_id.begins_with("deep:"):
		var base := FarmGrid.new()
		base.setup(info.grid.w, info.grid.h)
		base.ground = info.grid.ground.duplicate()
		base.deco = info.grid.deco.duplicate()
		info["base"] = base
		Mining.apply_diff(info.grid, str(_deep().layers.get(map_id.substr(5), "")))
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

## Moves a creature between "party", "den" and "sanctuary". Returns ok.
func move_creature(uid: String, dest: String, p: PlayerData) -> bool:
	var c := find_creature(uid)
	if c == null or p == null:
		return false
	if dest != "party" and dest != "den" and dest != "sanctuary":
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
		c.napping = false
	match dest:
		"party": p.party.append(c)
		"den":
			ranch.append(c)
			c.start_default_job()
		"sanctuary": sanctuary.append(c)
	EventBus.party_changed.emit()
	return true

func candy_count(p: PlayerData) -> int:
	if p == null:
		return 0
	return p.inventory.count(WildlingCandy.ITEM) + farm_chest.count(WildlingCandy.ITEM)

## Sends a Shelter Wildling away. The candy has to fit in the pack or the farm chest first.
func release_creature(uid: String, p: PlayerData) -> Dictionary:
	var c := find_creature(uid)
	var r := _res(false, tr("Only a Wildling waiting in the Shelter can be sent off."))
	if c == null or p == null or not c in sanctuary:
		return r
	var n := WildlingCandy.yield_for(c)
	var who := c.display_name()
	if not _give_all(p, WildlingCandy.ITEM, n):
		r.reason = tr("No room for the candy. Make space in your pack or the farm chest.")
		return r
	sanctuary.erase(c)
	clear_pair(uid)
	EventBus.party_changed.emit()
	r = _res(true)
	r.sfx = "gift"
	r.candies = n
	r.name = who
	return r

## Feeds Wildling Candy to a party, farm or Shelter Wildling. `until_level` spends enough for one level.
func feed_candy(uid: String, p: PlayerData, until_level: bool) -> Dictionary:
	var c := find_creature(uid)
	var r := _res(false)
	if c == null or p == null or not (c in p.party or c in ranch or c in sanctuary):
		r.reason = tr("That Wildling isn't with you.")
		return r
	if c.level >= Creature.MAX_LEVEL:
		r.reason = tr("%s can't grow any higher.") % c.display_name()
		return r
	var have := candy_count(p)
	if have <= 0:
		r.reason = tr("You don't have any Wildling Candy.")
		return r
	var spend := 1
	if until_level:
		spend = mini(have, WildlingCandy.candies_left(c))
	if spend <= 0 or not _take_candy(p, spend):
		r.reason = tr("You don't have any Wildling Candy.")
		return r
	var start := c.level
	var before := c.display_name()
	var events: Array = []
	var used := 0
	for _i in spend:
		var grant := mini(c.xp_to_next(), WildlingCandy.xp_per_candy(c.level))
		if grant <= 0:
			break
		used += 1
		events.append_array(c.gain_xp(grant))
		if c.level != start:
			break
	if used < spend:
		_give_all(p, WildlingCandy.ITEM, spend - used)
	var learned: Array = []
	for e in events:
		if str(e.get("t", "")) == "learn":
			learned.append({"move": str(e.move), "equipped": bool(e.get("equipped", false))})
	var evolved := ""
	if c.can_evolve() != "":
		c.evolve()
		Progression.mark(world.dex, c.species_id, true, c.starry)
		evolved = c.species_id
	EventBus.party_changed.emit()
	r = _res(true)
	r.sfx = "levelup" if c.level > start or evolved != "" else "gift"
	r.spent = used
	r.level = c.level
	r.gained_level = c.level > start
	r.learned = learned
	r.evolved = evolved
	r.name = before
	return r

func _give_all(p: PlayerData, id: String, n: int) -> bool:
	if n <= 0:
		return true
	var pack_d := p.inventory.to_dict()
	var chest_d := farm_chest.to_dict()
	var left := p.inventory.add(id, n)
	var spilled := left
	if left > 0:
		left = farm_chest.add(id, left)
	if left > 0:
		p.inventory.from_dict(pack_d)
		farm_chest.from_dict(chest_d)
		return false
	if spilled > 0:
		EventBus.toast.emit(tr("Pack full: %d %s sent to the farm chest.") % [spilled, Data.item_name(id)], "chest")
	EventBus.inventory_changed.emit()
	return true

func _take_candy(p: PlayerData, n: int) -> bool:
	if n <= 0 or candy_count(p) < n:
		return false
	var from_pack := mini(n, p.inventory.count(WildlingCandy.ITEM))
	var from_chest := n - from_pack
	if from_pack > 0:
		p.inventory.remove(WildlingCandy.ITEM, from_pack)
	if from_chest > 0:
		farm_chest.remove(WildlingCandy.ITEM, from_chest)
	EventBus.inventory_changed.emit()
	return true

func set_job(uid: String, job_id: String) -> bool:
	var c := find_creature(uid)
	if c == null or not c in ranch:
		return false
	if job_id == "" or not c.can_do_job(job_id):
		return false
	c.job = job_id
	c.napping = false
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
	_apply_relief(p)
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

func _apply_relief(p: PlayerData) -> void:
	var rv := Modifiers.value(p, "season_relief") if p else 0.0
	var extra := 0
	if p:
		extra = p.tool_level("shovel") * 2 + Enchanting.level(p, "shovel", "deep_dig") * 3
	for m in grids:
		grids[m].relief = rv
		grids[m].trench_extra = extra

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
	var mods := Modifiers.collect(local_player()) if local_player() else {}
	var comfort := FarmJobs.comfort(farm_grids())
	var spa := has_building("wildling_spa")
	var jr: Dictionary = FarmJobs.run(ranch, {"grids": farm_grids(), "chest": farm_chest, "rng": trng, "season": season_now, "scale": scale, "efficiency": eff, "now": now, "mods": mods, "happy": comfort.happy, "spa": spa})
	FarmJobs.collect_produce(ranch, farm_chest, trng, jr, scale * eff * (1.0 + float(mods.get("produce", 0.0))))
	FarmJobs.rest(ranch, spa, scale, 1.0 + float(mods.get("wildling_regen", 0.0)), comfort.rest)
	Machines.apply_power(farm_grids(), int(jr.powered))
	Machines.automate(farm_grids(), farm_chest, now, int(jr.machine_slots), jr, 1.0 + float(mods.get("machine_speed", 0.0)))
	FarmJobs.merge_report(rep.jobs, jr)
	for c: Creature in ranch:
		if c.can_evolve() != "":
			var from_name: String = c.display_name()
			var from_species: String = c.species_id
			c.evolve()
			Progression.mark(world.dex, c.species_id, true, c.starry)
			rep.evolved.append({"from": from_name, "from_species": from_species, "to": c.species_id})
	var breed_f: float = scale * eff * FarmJobs.TICK_SECONDS / float(FarmJobs.BREED_PERIOD) * (1.0 + float(mods.get("breed_speed", 0.0)))
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
	for m in grids:
		for k in grids[m].take_look_dirty():
			EventBus.tile_changed.emit(m, Tiles.parse_key(k))

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
	return rep

## What a shopkeeper pays this player for one item, with their sell bonus.
func sell_value(p: PlayerData, id: String, q: int, shipping: bool = false, shop_id: String = "") -> int:
	var base := Data.sell_price(id, q)
	if base <= 0:
		return 0
	var bonus := Modifiers.value(p, "sell_price") + (Modifiers.value(p, "ship_bonus") if shipping else 0.0)
	bonus += float(Data.shops.get(shop_id, {}).get("buys", {}).get(str(Data.get_item(id).get("cat", "")), 0.0))
	return maxi(1, int(round(base * (1.0 + bonus))))

## A shop price after this player's discount (at most half off).
func buy_value(p: PlayerData, price: int) -> int:
	return maxi(1, int(round(price * (1.0 - clampf(Modifiers.value(p, "shop_discount"), 0.0, 0.5)))))

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
	var owner := local_player()
	for sh in world.shipping:
		var v := sell_value(owner, sh.id, int(sh.q), true) * int(sh.n)
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
## the night and wakes you at the farm; otherwise the clock just rolls over at 6:00.
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
		for k in g.take_look_dirty():
			EventBus.tile_changed.emit(m, Tiles.parse_key(k))
	report.farm = farm_rep
	for c in ranch:
		c.grooming = maxi(0, c.grooming - 10)
	for pid in players:
		var p: PlayerData = players[pid]
		p.heal_party()
		if slept:
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
	return {"ok": ok, "fx": [], "sfx": "", "reason": reason}

func use_tool(pid: String, map_id: String, t: Vector2i, tool: String) -> Dictionary:
	return _use_tool(pid, map_id, t, tool)

func _use_tool(pid: String, map_id: String, t: Vector2i, tool: String) -> Dictionary:
	var p := player(pid)
	var g := grid(map_id)
	var info := map_info(map_id)
	var r := _res(false)
	if p == null or g == null:
		return r
	_apply_relief(p)
	var lvl := p.tool_level(tool)
	var at := tile_center(t)
	match tool:
		"hoe":
			if g.can_till(t):
				g.till(t)
				r.ok = true
				r.sfx = "hoe"
				p.stat_add("till")
				if Enchanting.level(p, "hoe", "wide_furrow") > 0:
					for side in [t + Vector2i(1, 0), t + Vector2i(-1, 0)]:
						if g.can_till(side):
							g.till(side)
							p.stat_add("till")
							EventBus.tile_changed.emit(map_id, side)
			elif g.crop_ruined(t):
				g.clear_ruined(t)
				r.ok = true
				r.sfx = "hoe"
			elif g.is_tilled(t) and g.crop_at(t).is_empty():
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
				var reach := lvl + 2 * int(Modifiers.value(p, "water_range"))
				if Enchanting.level(p, "watering_can", "mist") > 0:
					reach = maxi(reach, 6)
				var area: Array = [t]
				if reach >= 2:
					area = [t, t + Vector2i(1, 0), t + Vector2i(-1, 0)]
				if reach >= 4:
					area = [t, t + Vector2i(1, 0), t + Vector2i(-1, 0), t + Vector2i(0, 1), t + Vector2i(0, -1)]
				if reach >= 6:
					area = []
					for dy in [-1, 0, 1]:
						for dx in [-1, 0, 1]:
							area.append(t + Vector2i(dx, dy))
				var secs := CropGrowth.WATER_SECONDS * Modifiers.mult(p, "water_duration")
				for a in area:
					if g.water(a, -1.0, secs):
						p.water_left -= 1
						p.stat_add("water")
				r.ok = true
				r.sfx = "water"
		"shovel":
			if g.is_trench(t):
				g.fill_trench(t)
				r.ok = true
				r.sfx = "hoe"
			elif g.can_dig_trench(t):
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
				var reach := 2 if lvl >= 4 or Enchanting.level(p, "bucket", "big_splash") > 0 else (1 if lvl >= 2 else 0)
				var splash: Array = [t, t + Vector2i(1, 0), t + Vector2i(-1, 0), t + Vector2i(0, 1), t + Vector2i(0, -1)]
				if reach > 0:
					splash.clear()
					for dy in range(-reach, reach + 1):
						for dx in range(-reach, reach + 1):
							splash.append(t + Vector2i(dx, dy))
				for a in splash:
					g.water(a)
					EventBus.tile_changed.emit(map_id, a)
				p.bucket_full = false
				r.ok = true
				r.sfx = "water"
			elif not p.bucket_full:
				r.reason = tr("The bucket is empty. Fill it at a pond, river or the sea.")
		"drill":
			r = _drill(p, map_id, g, info, t)
		"pickaxe", "axe", "scythe":
			if tool == "scythe":
				if g.crop_ruined(t):
					g.clear_ruined(t)
					r.ok = true
					r.sfx = "scythe"
				elif g.crop_ready(t):
					if not Skills.has_unlock(p, "harvest_sweep") and Enchanting.level(p, "scythe", "sweep") == 0:
						return harvest_at(pid, map_id, t)
					var sweep := harvest_at(pid, map_id, t)
					for dy in [-1, 0, 1]:
						for dx in [-1, 0, 1]:
							if (dx != 0 or dy != 0) and g.crop_ready(t + Vector2i(dx, dy)):
								harvest_at(pid, map_id, t + Vector2i(dx, dy))
					return sweep
				if g.get_ground(t) == Tiles.GROUND.tallgrass:
					g.ground[g.idx(t)] = Tiles.GROUND.grass if map_id == "farm" else g.ground[g.idx(t)]
					if map_id == "farm":
						if rng.randf() < 0.5:
							give_item(p, "fiber", 1)
						r.ok = true
						r.sfx = "scythe"
			var d := g.get_deco(t)
			if tool == "pickaxe" and Mining.is_block(d):
				r = _mine_block(p, map_id, g, info, t, lvl)
			elif Tiles.DEBRIS.has(d) and (Tiles.DEBRIS[d].tool == tool or d == Tiles.DECO.weed):
				var spec: Dictionary = Tiles.DEBRIS[d]
				var hp := float(spec.get("hp", 1.0))
				var chipped := false
				if hp > 1.0 and lvl >= int(spec.min):
					var ck := Tiles.key(t)
					var cracks: Dictionary = _cracks.get(map_id, {})
					var speed := Modifiers.mult(p, "chop_speed") if tool == "axe" else 1.0
					var hits := maxi(2, ceili(hp / (Mining.power(lvl) * speed)))
					var dmg := float(cracks.get(ck, 0.0)) + 1.0 / float(hits)
					if dmg < 0.999:
						cracks[ck] = dmg
						_cracks[map_id] = cracks
						r.ok = true
						r.sfx = "chop"
						EventBus.shake.emit(0.4)
						chipped = true
				if not chipped:
					var res := g.clear_debris(t, tool, lvl, rng)
					if not res.ok:
						r.reason = res.reason
						return r
					_crack_clear(map_id, t)
					if d == Tiles.DECO.ore:
						var ore: String = info.get("ore_types", {}).get(Tiles.key(t), "copper_ore")
						var ol := Modifiers.value(p, "ore_luck")
						res.drops = [[ore, rng.randi_range(1, 3) + (1 if rng.randf() < ol else 0)]]
						if rng.randf() < 0.1 + luck():
							res.drops.append(["coal", 1])
						if rng.randf() < 0.05 + luck() + ol * 0.5:
							var gems := ["quartz", "amethyst", "topaz"]
							res.drops.append([gems[rng.randi() % 3], 1])
					if d == Tiles.DECO.rock and info.get("mine", false):
						if rng.randf() < 0.15:
							res.drops.append(["coal", 1])
						if rng.randf() < 0.05:
							res.drops.append(["quartz", 1])
						if rng.randf() < 0.04:
							res.drops.append(["clay", 1])
					var lj := Enchanting.level(p, "axe", "lumberjack") if tool == "axe" else 0
					if lj > 0 and d in [24, 25, 27]:
						for dr in res.drops:
							dr[1] = int(ceil(int(dr[1]) * (1.0 + 0.25 * lj)))
						if rng.randf() < 0.15 * lj:
							res.drops.append(["hardwood", 1])
					if tool == "pickaxe":
						_gentle(p, res.drops)
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
			elif tool == "pickaxe" and not g.object_at(t).is_empty() and g.object_at(t).kind in ["machine", "sprinkler", "scarecrow", "decor", "chest", "crab_pot", "station"]:
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
	if o.kind == "crab_pot" and not o.get("catch", []).is_empty():
		r.reason = tr("Empty the pot first.")
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
	if it.has("mine_place") or it.has("blast"):
		r = _blast(p, map_id, g, map_info(map_id), t, f, it) if it.has("blast") else _place_mining(p, map_id, g, map_info(map_id), t, f, it)
		if r.ok:
			EventBus.inventory_changed.emit()
			EventBus.tile_changed.emit(map_id, t)
		return r
	if map_id in PERSISTENT_MAPS and cat == "bait" and g.object_at(t).get("kind", "") == "crab_pot":
		var pot := g.object_at(t)
		if int(pot.get("bait", 0)) >= 5:
			r.reason = tr("The pot is full of bait.")
			return r
		f.inv.take(uid, 1)
		pot["bait"] = int(pot.get("bait", 0)) + 1
		if pot.get("catch", []).size() < Fishing.CRAB_HOLD:
			pot.next_at = minf(float(pot.next_at), TimeService.now() + Fishing.CRAB_BAIT_SECONDS)
		r.ok = true
		r.sfx = "plant"
		r.fx.append([tr("Baited (%d)") % int(pot.bait), Color("#a0e080")])
		EventBus.inventory_changed.emit()
		return r
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
		var h := g.harvest(t, rng, luck() + Modifiers.value(p, "crop_quality"), 0, season(), Modifiers.mult(p, "crop_yield"))
		give_item(p, h.id, int(h.n), int(h.q))
		if h.spent:
			r.fx.append([tr("The plant is spent."), Color("#c0a080")])
			if Data.items.has(cid + "_seeds") and rng.randf() < Modifiers.value(p, "seed_return"):
				give_item(p, cid + "_seeds", 1)
				r.fx.append(["+1 %s" % Data.item_name(cid + "_seeds"), Color("#a0e080")])
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
		elif o.get("kind", "") == "crab_pot":
			_collect_crab_pot(p, map_id, t, o, r)
		elif o.get("kind", "") == "forage":
			g.remove_object(t)
			var fl := Modifiers.value(p, "forage_luck")
			var q := FarmGrid.roll_quality("", false, 0, luck() + fl * 0.5, 0, rng)
			var fn := 2 if rng.randf() < fl else 1
			give_item(p, o.id, fn, q)
			r.ok = true
			r.sfx = "pickup"
			r.fx.append(["+%d %s" % [fn, Data.item_name(o.id)], Color.WHITE])
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
	o.ready_at = TimeService.now() + Machines.seconds_for(int(chk.time), Modifiers.mult(p, "machine_speed"))
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
	var chips := Economy.chip_shop(shop_id)
	for s in Economy.shop_stock(shop_id, season(), ctx(), day(), int(world.seed)):
		if s.id == item_id and not s.locked:
			price = int(s.price) if chips else buy_value(p, int(s.price))
	if price < 0:
		r.reason = tr("That's not for sale right now.")
		return r
	var pool: Array = Data.get_item(item_id).get("egg_pool", [])
	if not pool.is_empty():
		return _buy_egg(p, pool, price, chips)
	# Prefer the backpack grid. Matching bags (seed pouch, treat tin, gem case)
	# only catch what doesn't fit, so a purchase doesn't vanish inside one.
	if not p.inventory.can_add(item_id, n, 0, false):
		r.reason = tr("Your pack is full.")
		return r
	if chips:
		if not Casino.spend_chips(p, price * n):
			r.reason = tr("Not enough chips.")
			return r
	elif not spend(price * n, "Shop"):
		r.reason = tr("Not enough gold.")
		return r
	var before := p.inventory.homes_of(item_id)
	var left := p.inventory.add(item_id, n, 0, {}, false)
	var chest_gain := 0
	if left > 0:
		var still := farm_chest.add(item_id, left)
		chest_gain = left - still
		if still > 0:
			if chips:
				Casino.add_chips(p, price * still)
			else:
				add_money(price * still, Vector2.INF, "Shop")
			n -= still
	if n <= 0:
		r.reason = tr("Your pack is full.")
		EventBus.inventory_changed.emit()
		return r
	EventBus.inventory_changed.emit()
	if chips:
		EventBus.chips_changed.emit()
		bump_stat("chips_spent", price * n, pid)
	else:
		bump_stat("spent", price * n)
	r.ok = true
	r.sfx = "coin"
	r.note = _purchase_note(item_id, n, before, p.inventory.homes_of(item_id), chest_gain)
	return r

## Shop eggs hatch a random rare Wildling from the item's pool, with doubled Starry odds.
func _buy_egg(p: PlayerData, pool: Array, price: int, chips: bool) -> Dictionary:
	var r := _res(false)
	if not p.inventory.can_add("wildling_egg", 1, 0, false):
		r.reason = tr("Your pack is full.")
		return r
	if chips:
		if not Casino.spend_chips(p, price):
			r.reason = tr("Not enough chips.")
			return r
	elif not spend(price, "Shop"):
		r.reason = tr("Not enough gold.")
		return r
	var egg := Breeding.wild_egg(str(pool[rng.randi() % pool.size()]), rng, 2.0)
	p.inventory.add("wildling_egg", 1, 0, {"egg": egg}, false)
	EventBus.inventory_changed.emit()
	if chips:
		EventBus.chips_changed.emit()
		bump_stat("chips_spent", price, p.id)
	else:
		bump_stat("spent", price)
	r.ok = true
	r.sfx = "coin"
	r.note = tr("A Wildling Egg! Place it in the Hatchery.")
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
func sell(pid: String, uid: String, n: int = -1, shop_id: String = "") -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	var f := p.inventory.find(uid) if p else {}
	if f.is_empty():
		return r
	var price := sell_value(p, f.entry.id, int(f.entry.q), false, shop_id)
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
	if rng.randf() < Modifiers.value(p, "craft_extra") and p.inventory.can_add(recipe_id, 1):
		p.inventory.add(recipe_id, 1)
		r["extra"] = true
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
	p.add_friendship(b.from, 40)
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

func release_creature_act(pid: String, uid: String) -> Dictionary:
	return release_creature(uid, player(pid))

func feed_candy_act(pid: String, uid: String, until_level: bool = false) -> Dictionary:
	return feed_candy(uid, player(pid), until_level)

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

# --- Enchanting ---------------------------------------------------------------------

## Gentle Touch keeps crystals and gems whole: one extra of each.
func _gentle(p: PlayerData, drops: Array) -> void:
	if Enchanting.level(p, "pickaxe", "gentle") <= 0:
		return
	for dr in drops:
		if str(Data.get_item(str(dr[0])).get("cat", "")) == "gem":
			dr[1] = int(dr[1]) + 1

func _station_at(map_id: String, x: int, y: int, id: String) -> bool:
	var g := grid(map_id)
	return g != null and g.object_at(Vector2i(x, y)).get("id", "") == id

func _owns_tool(p: PlayerData, tool: String) -> bool:
	return tool in Enchanting.tools() and p.inventory.count(tool) > 0

## The three offers the table at (x, y) shows this player for a tool.
func enchant_offers(pid: String, map_id: String, x: int, y: int, tool: String) -> Array:
	var p := player(pid)
	if p == null or not _station_at(map_id, x, y, "enchanting_table"):
		return []
	return Enchanting.offers(p, tool, Enchanting.shelves_near(grid(map_id), Vector2i(x, y)), Modifiers.mult(p, "enchant_cost", 0.3))

func enchant_act(pid: String, map_id: String, x: int, y: int, tool: String, slot: int) -> Dictionary:
	var p := player(pid)
	if p == null or not _station_at(map_id, x, y, "enchanting_table"):
		return _res(false)
	if not _owns_tool(p, tool):
		return _res(false, tr("You need the tool in your pack."))
	if Enchanting.has_any(p, tool):
		return _res(false, tr("This tool is already enchanted. Use books at an anvil, or clear it at a grindstone."))
	var offers := enchant_offers(pid, map_id, x, y, tool)
	if slot < 0 or slot >= offers.size():
		return _res(false)
	var o: Dictionary = offers[slot]
	if p.inventory.count("arcane_essence") < int(o.essence) or p.inventory.count("glimmer_dust") < int(o.dust):
		return _res(false, tr("You need %d Arcane Essence and %d Glimmer Dust.") % [int(o.essence), int(o.dust)])
	p.inventory.remove("arcane_essence", int(o.essence))
	p.inventory.remove("glimmer_dust", int(o.dust))
	p.tool_enchants[tool] = o.enchants.duplicate()
	p.flags["enchant_seed"] = int(p.flags.get("enchant_seed", 0)) + 1
	p.stat_add("enchant")
	EventBus.inventory_changed.emit()
	EventBus.hotbar_changed.emit()
	var r := _res(true)
	r["enchants"] = p.tool_enchants[tool]
	r.sfx = "sparkle"
	return r

## Anvil: "apply" a book to a tool, or "combine" two equal books into a stronger one.
func anvil_act(pid: String, map_id: String, x: int, y: int, mode: String, tool: String, book: String) -> Dictionary:
	var p := player(pid)
	if p == null or not _station_at(map_id, x, y, "anvil"):
		return _res(false)
	var b := Enchanting.parse_book(book)
	if b.is_empty() or p.inventory.count(book) < (2 if mode == "combine" else 1):
		return _res(false, tr("You don't have that book."))
	var cost := Enchanting.anvil_cost(int(b[1]))
	if p.inventory.count("arcane_essence") < cost:
		return _res(false, tr("You need %d Arcane Essence.") % cost)
	var r := _res(true)
	match mode:
		"apply":
			if not _owns_tool(p, tool):
				return _res(false, tr("You need the tool in your pack."))
			var res := Enchanting.apply_book(Enchanting.on_tool(p, tool), tool, str(b[0]), int(b[1]))
			if not res.ok:
				return _res(false, str(res.reason))
			p.inventory.remove(book, 1)
			p.tool_enchants[tool] = res.enchants
			r["enchants"] = res.enchants
		"combine":
			var next := Enchanting.combine_books(book)
			if next == "":
				return _res(false, tr("That book is already as strong as it gets."))
			p.inventory.remove(book, 2)
			give_item(p, next, 1)
			r["book"] = next
		_:
			return _res(false)
	p.inventory.remove("arcane_essence", cost)
	EventBus.inventory_changed.emit()
	EventBus.hotbar_changed.emit()
	r.sfx = "sparkle"
	return r

## Grindstone: strips a tool's enchantments and gives back part of the essence.
func grindstone_act(pid: String, map_id: String, x: int, y: int, tool: String) -> Dictionary:
	var p := player(pid)
	if p == null or not _station_at(map_id, x, y, "grindstone"):
		return _res(false)
	if not Enchanting.has_any(p, tool):
		return _res(false, tr("That tool has no enchantments."))
	var back := Enchanting.refund(Enchanting.on_tool(p, tool))
	p.tool_enchants.erase(tool)
	if back > 0:
		give_item(p, "arcane_essence", back)
	EventBus.inventory_changed.emit()
	EventBus.hotbar_changed.emit()
	var r := _res(true)
	r["refund"] = back
	r.sfx = "rock"
	return r

## After a won battle: a chance of Arcane Essence, better against trainers.
func battle_spoils_act(pid: String, kind: String, level: int) -> Dictionary:
	var p := player(pid)
	var r := _res(true)
	if p == null:
		return r
	var chance := 0.35 if kind != "wild" else 0.06 + level / 500.0
	if rng.randf() < chance:
		var n := 1 + (1 if kind != "wild" and rng.randf() < 0.3 else 0)
		give_item(p, "arcane_essence", n)
		r["essence"] = n
	return r

# --- Casino -------------------------------------------------------------------------

func _casino_root() -> Dictionary:
	if not world.has("casino") or not world.casino is Dictionary:
		world["casino"] = {}
	var c: Dictionary = world.casino
	if not c.has("players"):
		c["players"] = {}
	if not c.has("tables"):
		c["tables"] = {}
	if not c.has("jackpot"):
		c["jackpot"] = int(Casino.cfg().get("slots", {}).get("jackpot_seed", 2000))
	return c

## A player's own game (blackjack, slots, poker, race) or the shared roulette table.
func casino_game(pid: String, game: String) -> CasinoGame:
	var c := _casino_root()
	if game == "roulette":
		if not c.tables.has("roulette"):
			c.tables["roulette"] = {}
		return Roulette.new(c.tables.roulette, int(world.get("seed", 0)))
	if not c.players.has(pid):
		c.players[pid] = {}
	if not c.players[pid].has(game):
		c.players[pid][game] = {}
	var st: Dictionary = c.players[pid][game]
	var base := hash([int(world.get("seed", 0)), pid])
	match game:
		"blackjack":
			return Blackjack.new(st, base)
		"slots":
			return Slots.new(st, base)
		"poker":
			return VideoPoker.new(st, base)
		"race":
			return WildlingRace.new(st, base)
	return null

func jackpot() -> int:
	return int(_casino_root().jackpot)

## Books a finished round: stats for quests, the big-win counter, the table feed and a save.
func _casino_round(pid: String, game: String, staked: int, back: int, news: String = "") -> void:
	bump_stat("casino_round", 1, pid)
	bump_stat("casino_round:" + game, 1, pid)
	if back > staked:
		bump_stat("casino_won", back - staked, pid)
	if back - staked >= int(Casino.cfg().get("big_win", 5000)):
		bump_stat("casino_big_win", 1, pid)
	if news != "":
		Coop.table_news(game, news)
	EventBus.chips_changed.emit()
	SaveManager.checkpoint()

func _casino_res(ok: bool, reason: String = "") -> Dictionary:
	var r := _res(ok, reason)
	r["chips"] = 0
	return r

func casino_exchange_act(pid: String, dir: String, n: int) -> Dictionary:
	var p := player(pid)
	if p == null or n <= 0:
		return _casino_res(false)
	if dir == "buy":
		if not spend(n * Casino.rate(), "Casino"):
			return _casino_res(false, tr("Not enough gold."))
		Casino.add_chips(p, n)
		bump_stat("casino_buy", 1, pid)
	elif dir == "sell":
		if not Casino.spend_chips(p, n):
			return _casino_res(false, tr("Not enough chips."))
		add_money(n * Casino.rate(), Vector2.INF, "Casino")
	else:
		return _casino_res(false)
	EventBus.chips_changed.emit()
	SaveManager.checkpoint()
	var r := _casino_res(true)
	r.sfx = "chips"
	return r

## The player's own daily cap from their settings (0 = none). Stored on the player so the host enforces it.
func casino_prefs_act(pid: String, daily_limit: int) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _casino_res(false)
	p.flags["casino_limit"] = maxi(0, daily_limit)
	return _casino_res(true)

func casino_bonus_act(pid: String) -> Dictionary:
	var p := player(pid)
	if p == null or not Casino.bonus_ready(p):
		return _casino_res(false, tr("You already collected today's chips. Come back tomorrow."))
	var n := Casino.daily_bonus(p)
	p.flags["casino_bonus_day"] = Casino.today()
	Casino.add_chips(p, n)
	EventBus.chips_changed.emit()
	SaveManager.checkpoint()
	var r := _casino_res(true)
	r.chips = n
	r.sfx = "chips"
	return r

func casino_wheel_act(pid: String) -> Dictionary:
	var p := player(pid)
	if p == null or not Casino.wheel_ready(p):
		return _casino_res(false, tr("The wheel is yours once a day. Come back tomorrow."))
	var g := RandomNumberGenerator.new()
	g.seed = hash([int(world.get("seed", 0)), pid, "wheel", Casino.today()])
	var i := Casino.spin_wheel(g)
	var seg: Dictionary = Casino.cfg().wheel[i]
	p.flags["casino_wheel_day"] = Casino.today()
	var r := _casino_res(true)
	r["segment"] = i
	if seg.has("chips"):
		Casino.add_chips(p, int(seg.chips))
		r.chips = int(seg.chips)
	elif str(seg.item) == "book":
		var book := Enchanting.random_book(g, 2)
		give_item(p, book, 1)
		r["item"] = book
	else:
		give_item(p, str(seg.item), int(seg.get("n", 1)))
		r["item"] = str(seg.item)
	bump_stat("casino_wheel", 1, pid)
	EventBus.chips_changed.emit()
	SaveManager.checkpoint()
	return r

func roulette_act(pid: String, bets: Array) -> Dictionary:
	var p := player(pid)
	if p == null or bets.is_empty():
		return _casino_res(false, tr("Place a bet first."))
	var vip := Casino.vip(p)
	var clean: Array = []
	for b in bets:
		if not b is Dictionary or not Roulette.valid(b):
			return _casino_res(false)
		clean.append(b)
	var stake := Roulette.total_stake(clean)
	if not CasinoGame.valid_bet("roulette", stake, vip):
		var l := CasinoGame.limits("roulette", vip)
		return _casino_res(false, tr("Table limits: %d to %d chips.") % [l.x, l.y])
	var block := Casino.stake_block(p, stake)
	if block != "":
		return _casino_res(false, block)
	Casino.stake(p, stake)
	var game: Roulette = casino_game(pid, "roulette")
	var n := game.spin()
	var back := 0
	for b in clean:
		back += Roulette.payout(b, n)
	Casino.add_chips(p, back)
	if n in [7, 17, 27] and back > 0:
		bump_stat("roulette_lucky", 1, pid)
	var r := _casino_res(true)
	r["number"] = n
	r["color"] = Roulette.color(n)
	r["staked"] = stake
	r.chips = back
	r["history"] = game.state.get("history", [])
	r.sfx = "wheel"
	_casino_round(pid, "roulette", stake, back, tr("%s spun %d at roulette%s.") % [p.name, n, tr(" and won %d chips") % back if back > 0 else ""])
	return r

## What the player may see of a blackjack hand: the dealer's hole card stays hidden until the end.
func _bj_view(h: Dictionary) -> Dictionary:
	var v := h.duplicate(true)
	if v.has("dealer") and str(v.get("phase", "")) != "done" and v.dealer.size() > 1:
		v.dealer[1] = -1
	return v

func blackjack_act(pid: String, op: String, bet: int = 0) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _casino_res(false)
	var game: Blackjack = casino_game(pid, "blackjack")
	var r := _casino_res(true)
	if op == "state":
		r["hand"] = _bj_view(game.hand())
		return r
	if op == "deal":
		if game.active():
			return _casino_res(false, tr("Finish this hand first."))
		var vip := Casino.vip(p)
		if not CasinoGame.valid_bet("blackjack", bet, vip):
			var l := CasinoGame.limits("blackjack", vip)
			return _casino_res(false, tr("Table limits: %d to %d chips.") % [l.x, l.y])
		var block := Casino.stake_block(p, bet)
		if block != "":
			return _casino_res(false, block)
		Casino.stake(p, bet)
		game.deal(bet)
		r.sfx = "deal"
	else:
		if not game.can(op):
			return _casino_res(false)
		var extra := game.cost(op)
		if op == "no_insurance":
			extra = 0
		if extra > 0:
			var block := Casino.stake_block(p, extra)
			if block != "":
				return _casino_res(false, block)
			Casino.stake(p, extra)
		game.act(op)
		r.sfx = "deal" if op != "stand" else "chips"
	var h := game.hand()
	r["hand"] = _bj_view(h)
	if h.phase == "done":
		var staked := int(h.insurance)
		for x in h.hands:
			staked += int(x.bet)
		var back := int(h.credit)
		Casino.add_chips(p, back)
		r.chips = back
		if "blackjack" in h.results:
			bump_stat("blackjack", 1, pid)
		if h.results.any(func(x): return x in ["win", "blackjack"]):
			bump_stat("blackjack_win", 1, pid)
		_casino_round(pid, "blackjack", staked, back, tr("%s won %d chips at blackjack.") % [p.name, back - staked] if back > staked else "")
	else:
		EventBus.chips_changed.emit()
		SaveManager.checkpoint()
	if bool(game.state.get("shuffled", false)):
		r["shuffled"] = true
	return r

func slots_act(pid: String, line_bet: int) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _casino_res(false)
	if not CasinoGame.valid_bet("slots", line_bet, false):
		return _casino_res(false)
	var stake := line_bet * Slots.LINES
	var block := Casino.stake_block(p, stake)
	if block != "":
		return _casino_res(false, block)
	Casino.stake(p, stake)
	var c := _casino_root()
	c.jackpot = int(c.jackpot) + maxi(1, int(round(stake * float(Casino.cfg().slots.get("jackpot_share", 0.01)))))
	var game: Slots = casino_game(pid, "slots")
	var res := game.spin(line_bet, int(c.jackpot))
	if int(res.jackpot) > 0:
		c.jackpot = int(c.jackpot) - int(res.jackpot)
		if int(c.jackpot) < int(Casino.cfg().slots.jackpot_seed):
			c.jackpot = int(Casino.cfg().slots.jackpot_seed)
		bump_stat("jackpot", 1, pid)
	Casino.add_chips(p, int(res.won))
	var r := _casino_res(true)
	r["spin"] = res
	r.chips = int(res.won)
	r["jackpot_pot"] = int(c.jackpot)
	r.sfx = "jackpot" if int(res.jackpot) > 0 else ("reels_win" if int(res.won) > 0 else "reels")
	var news := tr("%s hit the jackpot: %d chips!") % [p.name, int(res.jackpot)] if int(res.jackpot) > 0 else ""
	_casino_round(pid, "slots", stake, int(res.won), news)
	return r

func poker_act(pid: String, op: String, arg: Variant = null) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _casino_res(false)
	var game: VideoPoker = casino_game(pid, "poker")
	var coin := int(Casino.cfg().poker.get("coin", 5))
	var r := _casino_res(true)
	if op == "state":
		r["hand"] = _poker_view(game.hand())
		return r
	if op == "deal":
		var coins := int(arg)
		if game.active():
			return _casino_res(false, tr("Finish this hand first."))
		if not CasinoGame.valid_bet("poker", coins, false):
			return _casino_res(false)
		var block := Casino.stake_block(p, coins * coin)
		if block != "":
			return _casino_res(false, block)
		Casino.stake(p, coins * coin)
		game.deal(coins)
		r.sfx = "deal"
		EventBus.chips_changed.emit()
		SaveManager.checkpoint()
	elif op == "draw":
		if not game.active() or not arg is Array:
			return _casino_res(false)
		var h := game.draw(arg)
		var back := int(h.won) * coin
		Casino.add_chips(p, back)
		r.chips = back
		r.sfx = "reels_win" if back > 0 else "deal"
		if str(h.result) == "royal_flush":
			bump_stat("royal_flush", 1, pid)
		_casino_round(pid, "poker", int(h.coins) * coin, back, tr("%s drew a %s at video poker.") % [p.name, tr(VideoPoker.HAND_NAMES[h.result])] if str(h.result) in ["royal_flush", "straight_flush", "four_kind"] else "")
	else:
		return _casino_res(false)
	r["hand"] = _poker_view(game.hand())
	return r

func _poker_view(h: Dictionary) -> Dictionary:
	var v := h.duplicate(true)
	v.erase("spare")
	return v

func race_card(pid: String) -> Array:
	var game: WildlingRace = casino_game(pid, "race")
	return game.card()

func race_card_act(pid: String) -> Dictionary:
	var r := _casino_res(player(pid) != null)
	r["card"] = race_card(pid)
	return r

func race_act(pid: String, runner: int, bet: int) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _casino_res(false)
	var vip := Casino.vip(p)
	if not CasinoGame.valid_bet("race", bet, vip):
		var l := CasinoGame.limits("race", vip)
		return _casino_res(false, tr("Table limits: %d to %d chips.") % [l.x, l.y])
	var game: WildlingRace = casino_game(pid, "race")
	var card := game.card()
	if runner < 0 or runner >= card.size():
		return _casino_res(false)
	var block := Casino.stake_block(p, bet)
	if block != "":
		return _casino_res(false, block)
	Casino.stake(p, bet)
	var res := game.run()
	var back := int(floor(bet * float(card[runner].odds))) if int(res.winner) == runner else 0
	Casino.add_chips(p, back)
	if back > 0:
		bump_stat("race_win", 1, pid)
	var r := _casino_res(true)
	r["race"] = res
	r["runner"] = runner
	r.chips = back
	r.sfx = "race"
	_casino_round(pid, "race", bet, back, tr("%s won %d chips on %s.") % [p.name, back, Data.species_name(str(card[runner].species))] if back > 0 else "")
	return r

# --- Mining -------------------------------------------------------------------------

## Chip damage per map {map_id: {"x,y": 0..1}}; not saved. A half-cut tree or rock is whole again after a load.
var _cracks: Dictionary = {}

func _deep() -> Dictionary:
	var m: Dictionary = world.get("mining", {})
	for k in [["layers", {}], ["max", 0], ["museum", []]]:
		if not m.has(k[0]):
			m[k[0]] = k[1]
	world["mining"] = m
	return m

func deep_max() -> int:
	return int(_deep().max)

func crack(map_id: String, t: Vector2i) -> float:
	return float(_cracks.get(map_id, {}).get(Tiles.key(t), 0.0))

func _crack_clear(map_id: String, t: Vector2i) -> void:
	var cracks: Dictionary = _cracks.get(map_id, {})
	if cracks.erase(Tiles.key(t)) and cracks.is_empty():
		_cracks.erase(map_id)

func _deep_touch(map_id: String) -> void:
	if not map_id.begins_with("deep:"):
		return
	var info := map_info(map_id)
	if info.has("base"):
		_deep().layers[map_id.substr(5)] = Mining.encode_diff(info.base, info.grid)

func _mine_block(p: PlayerData, map_id: String, g: FarmGrid, info: Dictionary, t: Vector2i, lvl: int) -> Dictionary:
	var r := _res(false)
	var d := g.get_deco(t)
	var k := Tiles.key(t)
	var what := str(info.get("ore_types", {}).get(k, ""))
	var spec := Mining.block_spec(d, what)
	if lvl < int(spec.min):
		r.reason = tr("Too hard for your pickaxe. It needs %s or better.") % tr(Mining.tier_name(int(spec.min)))
		return r
	var speed := Modifiers.mult(p, "mine_speed")
	var cracks: Dictionary = _cracks.get(map_id, {})
	var dmg := float(cracks.get(k, 0.0)) + Mining.power(lvl) * speed / float(spec.hp)
	r.ok = true
	r.sfx = Mining.sound(d)
	if dmg < 0.999:
		cracks[k] = dmg
		_cracks[map_id] = cracks
		EventBus.shake.emit(0.3)
		return r
	cracks.erase(k)
	_break_block(p, map_id, g, info, t, r)
	_cave_in(map_id, g, info, t)
	return r

func _break_block(p: PlayerData, map_id: String, g: FarmGrid, info: Dictionary, t: Vector2i, r: Dictionary) -> void:
	var d := g.get_deco(t)
	var what := str(info.get("ore_types", {}).get(Tiles.key(t), ""))
	g.set_deco(t, 0)
	var drops := Mining.drops(d, what, rng, Modifiers.value(p, "ore_luck"), luck(), info.get("fossils", []))
	_gentle(p, drops)
	if d == Tiles.DECO.crystal and rng.randf() < 0.12:
		drops.append(["arcane_essence", 1])
	for dr in drops:
		give_item(p, dr[0], int(dr[1]))
		r.fx.append(["+%d %s" % [int(dr[1]), Data.item_name(dr[0])], Color.WHITE])
	p.stat_add("mined")
	bump_stat("blocks")
	add_farm_xp(Progression.XP.clear)
	_deep_touch(map_id)
	EventBus.shake.emit(1.0)

## Big open halls in the deeper layers shed rubble unless a support beam stands nearby.
func _cave_in(map_id: String, g: FarmGrid, info: Dictionary, t: Vector2i) -> void:
	if int(info.get("deep", 0)) < 2 or rng.randf() > 0.08:
		return
	var open := 0
	for y in range(t.y - 4, t.y + 5):
		for x in range(t.x - 4, t.x + 5):
			var q := Vector2i(x, y)
			if not g.in_bounds(q):
				continue
			if g.get_deco(q) == Tiles.DECO.support:
				return
			if g.get_deco(q) == 0:
				open += 1
	if open < 40:
		return
	var fell := 0
	for i in 6:
		var q := t + Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
		if q != t and g.in_bounds(q) and g.get_deco(q) == 0 and g.get_ground(q) == Tiles.GROUND.cave and not _player_on(map_id, q):
			g.set_deco(q, Tiles.DECO.rock)
			EventBus.tile_changed.emit(map_id, q)
			fell += 1
	if fell > 0:
		_deep_touch(map_id)
		EventBus.shake.emit(3.0)
		EventBus.toast.emit(tr("The ceiling crumbles! Support beams keep big halls stable."), "")

func _player_on(map_id: String, t: Vector2i) -> bool:
	for pid in players:
		var pl: PlayerData = players[pid]
		if pl.map_id == map_id and Vector2i(pl.pos / Tiles.TILE) == t:
			return true
	return false

## The drill bites a row of three: the target tile and the ones left and right of it.
func _drill(p: PlayerData, map_id: String, g: FarmGrid, info: Dictionary, t: Vector2i) -> Dictionary:
	var r := _res(false)
	var lvl := p.tool_level("pickaxe")
	for dx in [0, -1, 1]:
		var q := t + Vector2i(dx, 0)
		if not Mining.is_block(g.get_deco(q)):
			continue
		var one := _mine_block(p, map_id, g, info, q, lvl)
		if one.ok:
			r.ok = true
			r.sfx = one.sfx
			r.fx.append_array(one.fx)
			if q != t:
				EventBus.tile_changed.emit(map_id, q)
		elif r.reason == "":
			r.reason = one.reason
	return r

## Torches, ladders, beams, rails, carts and stone blocks go straight into the rock layer.
func _place_mining(p: PlayerData, map_id: String, g: FarmGrid, info: Dictionary, t: Vector2i, f: Dictionary, it: Dictionary) -> Dictionary:
	var r := _res(false)
	if not info.get("mine", false):
		r.reason = tr("That only works down in a mine.")
		return r
	var what := str(it.mine_place)
	var d := g.get_deco(t)
	var gr := g.get_ground(t)
	if what == "stoneblock" and gr in Tiles.BLOCKING_GROUND and d == 0:
		g.ground[g.idx(t)] = Tiles.GROUND.cave
	elif d != 0 or gr in Tiles.BLOCKING_GROUND or _player_on(map_id, t):
		r.reason = tr("Can't place that here.")
		return r
	elif what == "ladder":
		if int(info.get("deep", 0)) == 0 or int(info.deep) >= Mining.layer_count():
			r.reason = tr("There's nothing below to climb down to.")
			return r
		g.set_deco(t, Tiles.DECO.ladder)
	else:
		g.set_deco(t, Tiles.id_of(what))
	f.inv.take(f.entry.uid, 1)
	_deep_touch(map_id)
	r.ok = true
	r.sfx = "place"
	return r

## Bombs crack every block in reach that the strongest pickaxe tier could break.
func _blast(p: PlayerData, map_id: String, g: FarmGrid, info: Dictionary, t: Vector2i, f: Dictionary, it: Dictionary) -> Dictionary:
	var r := _res(false)
	if not info.get("mine", false):
		r.reason = tr("That only works down in a mine.")
		return r
	f.inv.take(f.entry.uid, 1)
	var rad := float(it.get("blast", 1.5))
	var reach := int(ceil(rad))
	for y in range(t.y - reach, t.y + reach + 1):
		for x in range(t.x - reach, t.x + reach + 1):
			var q := Vector2i(x, y)
			if Vector2(q - t).length() > rad or not g.in_bounds(q):
				continue
			var d := g.get_deco(q)
			if d == Tiles.DECO.rock or (Mining.is_block(d) and int(Mining.block_spec(d, str(info.get("ore_types", {}).get(Tiles.key(q), ""))).min) <= 3):
				if d == Tiles.DECO.rock:
					g.set_deco(q, 0)
					give_item(p, "stone", 1)
				else:
					_break_block(p, map_id, g, info, q, r)
				EventBus.tile_changed.emit(map_id, q)
	_deep_touch(map_id)
	EventBus.shake.emit(6.0)
	r.ok = true
	r.sfx = "boom"
	return r

## Ladder down from layer-1 at t, or the elevator straight to a layer's landing.
func deep_enter_act(pid: String, layer: int, x: int, y: int, via: String) -> Dictionary:
	var p := player(pid)
	if p == null or layer < 1 or layer > Mining.layer_count():
		return _res(false)
	var L := Mining.layer_spec(layer)
	var r := _res(true)
	var to := Vector2i(Mining.LANDING.x, Mining.LANDING.y + 1)
	match via:
		"elevator":
			if layer > maxi(1, deep_max()):
				return _res(false, tr("The lift doesn't go that deep yet."))
		"ladder":
			var t := Vector2i(x, y)
			var from := grid("deep:%d" % (layer - 1)) if layer > 1 else null
			if from == null or from.get_deco(t) != Tiles.DECO.ladder:
				return _res(false)
			if p.tool_level("pickaxe") < int(L.get("min_pick", 0)):
				return _res(false, tr("The rock below is too hard. Bring a %s pickaxe.") % tr(Mining.tier_name(int(L.min_pick))))
			var g := grid("deep:%d" % layer)
			Mining.carve_arrival(g, t, Tiles.DECO.ladder_up)
			_deep_touch("deep:%d" % layer)
			to = t + Vector2i(0, 1)
		"up":
			var t2 := Vector2i(x, y)
			var g2 := grid("deep:%d" % layer)
			Mining.carve_arrival(g2, t2, Tiles.DECO.ladder)
			_deep_touch("deep:%d" % layer)
			to = t2 + Vector2i(0, 1)
		_:
			return _res(false)
	if layer > deep_max():
		_deep().max = layer
		add_farm_xp(Progression.XP.mine_floor * 4)
		bump_stat("deep_layer", 1, pid)
		r["new_layer"] = true
		EventBus.quest_updated.emit()
	r["to"] = [to.x, to.y]
	return r

func deep_boss_act(pid: String) -> Dictionary:
	if world.flags.get("deep_boss", false):
		return _res(false)
	world.flags["deep_boss"] = true
	grant({"money": 20000, "glimmer_crystal": 3, "crystal_bar": 2}, player(pid))
	EventBus.quest_updated.emit()
	var r := _res(true)
	r["text"] = tr("The magma stills. Deep below Eisenkamm, the mountain finally rests. (+%s, 3 Glimmer Crystals, 2 Crystal Bars)") % CoinLabel.text(20000)
	return r

## The geologist splits geodes for a small fee.
func crack_geode_act(pid: String, n: int) -> Dictionary:
	var p := player(pid)
	var have := p.inventory.count("geode") if p else 0
	n = mini(n, have)
	if n <= 0:
		return _res(false, tr("You don't have any geodes."))
	if not spend(25 * n, "Geodes"):
		return _res(false, tr("Not enough gold."))
	p.inventory.remove("geode", n)
	p.stat_add("geodes", n)
	var got := {}
	for i in n:
		var id := Mining.pick(Mining.GEODE_LOOT, rng)
		got[id] = int(got.get(id, 0)) + 1
		give_item(p, id, 1)
	var r := _res(true)
	r["loot"] = got
	r.sfx = "chest"
	return r

## Hands every new mineral and fossil in your pack to the museum.
func donate_museum_act(pid: String) -> Dictionary:
	var p := player(pid)
	var m := _deep()
	var given: Array = []
	for id in Mining.MUSEUM:
		if not id in m.museum and p.inventory.count(id) > 0:
			p.inventory.remove(id, 1)
			m.museum.append(id)
			given.append(id)
	if given.is_empty():
		return _res(false, tr("Nothing new for the collection today."))
	var r := _res(true)
	r["given"] = given
	for need in Mining.MUSEUM_REWARDS:
		var before: int = m.museum.size() - given.size()
		if before < int(need) and m.museum.size() >= int(need):
			grant(Mining.MUSEUM_REWARDS[need], p)
			r["milestone"] = int(need)
	EventBus.inventory_changed.emit()
	EventBus.quest_updated.emit()
	r.sfx = "levelup"
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
	var cl := Modifiers.value(player(pid), "chest_luck")
	if cl > 0.0:
		for k in loot:
			if loot[k] is int:
				loot[k] = CropGrowth.roll_amount(float(loot[k]) * (1.0 + cl), trng)
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
				p.add_friendship(vid, int(fest.get("friendship", 20)))
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
	p.gain_xp(int(Skills.QUEST_XP.get(str(Quests.def_of(p, qid).get("type", "side")), 40)))
	if qid.begins_with("daily:"):
		var bonus := Quests.daily_finished(p)
		if not bonus.is_empty():
			grant_quest_reward(p, bonus)
			r["streak"] = int(st.daily.streak)
			r["bonus"] = bonus
	r.sfx = "levelup"
	EventBus.inventory_changed.emit()
	return r

## Buys the next rank of a skill node with a free point.
func invest_skill_act(pid: String, node_id: String) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _res(false)
	var why := Skills.blocker(p, world, node_id)
	if why != "":
		return _res(false, why)
	Skills.invest(p, world, node_id)
	EventBus.skills_changed.emit(pid)
	var r := _res(true)
	r.sfx = "levelup"
	return r

## Clears the skill tree for a rising gold fee.
func respec_skills_act(pid: String) -> Dictionary:
	var p := player(pid)
	if p == null or p.tree.is_empty():
		return _res(false)
	if not spend(Skills.respec_cost(p), "Skill reset"):
		return _res(false, tr("Not enough gold."))
	Skills.respec(p)
	EventBus.skills_changed.emit(pid)
	return _res(true)

# --- Fishing -----------------------------------------------------------------------------

## What each player has on the hook (host only, never saved).
var _hooked: Dictionary = {}

## Casts at a water tile. The host rolls the catch now; the client only learns how it fights.
func fish_cast_act(pid: String, map_id: String, t: Vector2i) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	if p == null:
		return r
	if p.inventory.count("fishing_rod") == 0:
		r.reason = tr("You need a fishing rod.")
		return r
	var info := map_info(map_id)
	var kind := Fishing.water_kind(info, t)
	if kind == "":
		r.reason = tr("Cast into water.")
		return r
	var rod := p.tool_level("fishing_rod")
	var bait := str(p.fishing.get("bait", ""))
	if bait != "":
		if p.inventory.remove(bait, 1):
			EventBus.inventory_changed.emit()
		else:
			p.fishing.erase("bait")
			r.fx.append([tr("Out of %s.") % Data.item_name(bait), Color("#ffb070")])
			bait = ""
	var tackle := str(p.fishing.get("tackle", "")) if Fishing.takes_tackle(rod) else ""
	var lv: Array = info.get("levels", [2 + int(world.farm.level), 6 + int(world.farm.level)])
	var c := Fishing.roll({
		"kind": kind, "map": map_id, "season": season(), "night": Calendar.is_night(minute()),
		"weather": str(world.get("weather", "sun")), "floor": int(info.get("floor", 0)), "dex": p.fishing.get("dex", {}),
		"rod": rod, "bait": bait, "tackle": tackle, "luck": Modifiers.value(p, "fish_luck") + luck() * 0.5,
		"bite": Modifiers.value(p, "fish_bite"), "levels": lv,
	}, rng)
	c["at"] = Time.get_ticks_msec() / 1000.0
	c["tackle"] = tackle
	_hooked[pid] = c
	r.ok = true
	r["bite"] = float(c.bite)
	r["hook"] = str(c.kind)
	r["diff"] = int(c.diff)
	r["move"] = str(c.move)
	r["treasure"] = bool(c.treasure)
	r["legendary"] = bool(Fishing.fish(str(c.id)).get("legendary", false))
	r["zone"] = Fishing.zone_size(rod, tackle, Modifiers.value(p, "fish_zone"))
	r["escape"] = Fishing.escape_mult(tackle)
	return r

## Ends a cast. outcome: "caught", "perfect", "easy" (auto-reeled), "lost" or "missed".
func fish_result_act(pid: String, outcome: String, got_treasure: bool = false) -> Dictionary:
	var p := player(pid)
	var c: Dictionary = _hooked.get(pid, {})
	_hooked.erase(pid)
	var r := _res(false)
	if p == null or c.is_empty():
		return r
	if outcome in ["lost", "missed"]:
		r.ok = true
		r["lost"] = true
		return r
	var fight := 0.0 if c.kind == "wild" else Fishing.MIN_FIGHT
	if Time.get_ticks_msec() / 1000.0 - float(c.at) < (float(c.bite) + fight) * 0.9:
		r.reason = tr("The fish got away.")
		return r
	r.ok = true
	match str(c.kind):
		"wild":
			r["wild"] = str(c.id)
			r["level"] = int(c.level)
			return r
		"junk":
			give_item(p, str(c.id), 1)
			r["id"] = str(c.id)
			r.fx.append(["+1 %s" % Data.item_name(str(c.id)), Color("#c0b090")])
		"fish":
			var id := str(c.id)
			var q := Fishing.quality(id, float(c.size), outcome == "perfect", outcome == "easy")
			var is_new: bool = not p.fishing.get("dex", {}).has(id)
			var rec := Fishing.record(p, id, float(c.size))
			give_item(p, id, 1, q)
			r["id"] = id
			r["size"] = float(c.size)
			r["q"] = q
			r["new"] = is_new
			r["record"] = rec and not is_new
			r.fx.append(["+1 %s" % Data.item_name(id, q), [Color.WHITE, Color("#d8e0f0"), Color("#ffd447"), Color("#c890ff")][q]])
			bump_stat("fish", 1, pid)
			p.stat_add("fish:" + id)
			if is_new:
				p.stat_add("fish_new")
			if Fishing.fish(id).get("legendary", false):
				p.stat_add("fish_legend")
				EventBus.toast.emit(tr("You caught the legendary %s!") % Data.item_name(id), "star")
				give_item(p, "arcane_essence", 3)
				r.fx.append(["+3 %s" % Data.item_name("arcane_essence"), Color("#c890ff")])
			elif int(Fishing.fish(id).get("price", 0)) >= 250 and rng.randf() < 0.2:
				give_item(p, "arcane_essence", 1)
				r.fx.append(["+1 %s" % Data.item_name("arcane_essence"), Color("#c890ff")])
			add_farm_xp(Progression.XP.harvest * 2)
			if got_treasure and c.treasure:
				var loot := Fishing.treasure_loot(rng, Modifiers.value(p, "fish_luck"))
				r["treasure"] = loot
				for e in loot:
					give_item(p, str(e[0]), int(e[1]))
					r.fx.append(["+%d %s" % [int(e[1]), Data.item_name(str(e[0]))], Color("#ffd447")])
	var tackle := str(c.get("tackle", ""))
	if tackle != "" and str(p.fishing.get("tackle", "")) == tackle:
		var uses := int(p.fishing.get("tackle_uses", Fishing.TACKLE_USES)) - 1
		if uses <= 0:
			p.fishing.erase("tackle")
			p.fishing.erase("tackle_uses")
			r.fx.append([tr("Your %s wore out.") % Data.item_name(tackle), Color("#ffb070")])
		else:
			p.fishing["tackle_uses"] = uses
	r.sfx = "harvest"
	EventBus.inventory_changed.emit()
	return r

## Puts bait or tackle on the rod (the same item again takes it off).
func equip_tackle_act(pid: String, uid: String) -> Dictionary:
	var p := player(pid)
	var r := _res(false)
	var f := p.inventory.find(uid) if p else {}
	if f.is_empty():
		return r
	var id: String = f.entry.id
	match str(Data.get_item(id).get("cat", "")):
		"bait":
			if str(p.fishing.get("bait", "")) == id:
				p.fishing.erase("bait")
				r.fx.append([tr("Took the %s off the rod.") % Data.item_name(id), Color.WHITE])
			else:
				p.fishing["bait"] = id
				r.fx.append([tr("%s on the rod.") % Data.item_name(id), Color("#a0e080")])
		"tackle":
			if not Fishing.takes_tackle(p.tool_level("fishing_rod")):
				r.reason = tr("Tackle needs a Gold rod or better.")
				return r
			var taken: Dictionary = f.inv.take(uid, 1)
			var old := str(p.fishing.get("tackle", ""))
			if old != "":
				give_item(p, old, 1, 0, {"uses": int(p.fishing.get("tackle_uses", Fishing.TACKLE_USES))})
			p.fishing["tackle"] = id
			p.fishing["tackle_uses"] = int(taken.get("meta", {}).get("uses", Fishing.TACKLE_USES))
			r.fx.append([tr("%s on the rod.") % Data.item_name(id), Color("#a0e080")])
		_:
			return r
	r.ok = true
	r.sfx = "pickup"
	EventBus.inventory_changed.emit()
	return r

## Takes tackle off the rod and back into the pack.
func unequip_tackle_act(pid: String) -> Dictionary:
	var p := player(pid)
	if p == null or not p.fishing.has("tackle"):
		return _res(false)
	give_item(p, str(p.fishing.tackle), 1, 0, {"uses": int(p.fishing.get("tackle_uses", Fishing.TACKLE_USES))})
	p.fishing.erase("tackle")
	p.fishing.erase("tackle_uses")
	return _res(true)

func upgrade_rod_act(pid: String) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _res(false)
	var lvl := p.tool_level("fishing_rod")
	var spec := Fishing.rod_spec(lvl + 1)
	if spec.is_empty():
		return _res(false, tr("Your rod is already the best there is."))
	var req := str(spec.get("requires", ""))
	if not Economy.meets(req, {"fish": Fishing.species_caught(p)}):
		return _res(false, Economy.req_text(req))
	if not spend(buy_value(p, int(spec.price)), "Rod upgrade"):
		return _res(false, tr("Not enough gold."))
	p.tool_levels["fishing_rod"] = lvl + 1
	var r := _res(true)
	r.sfx = "levelup"
	r["note"] = tr("Your rod is now a %s.") % Fishing.rod_name(lvl + 1)
	return r

## A villager's one-time welcome gift (Ansel's first rod).
func first_gift_act(pid: String, vid: String) -> Dictionary:
	var p := player(pid)
	var gift: Dictionary = Data.villagers.get(vid, {}).get("first_gift", {})
	if p == null or gift.is_empty() or p.flags.has("gift:" + vid):
		return _res(false)
	p.flags["gift:" + vid] = true
	grant(gift, p)
	return _res(true)

## Collects whatever a crab pot caught.
func _collect_crab_pot(p: PlayerData, map_id: String, t: Vector2i, o: Dictionary, r: Dictionary) -> void:
	var now := TimeService.now()
	var was_full: bool = o.get("catch", []).size() >= Fishing.CRAB_HOLD
	Fishing.crab_step(o, now, Fishing.water_kind(map_info(map_id), t), rng)
	var got: Array = o.get("catch", [])
	if got.is_empty():
		r.reason = tr("Nothing in the pot yet. Next catch in %s.") % TimeService.duration_text(maxf(0.0, float(o.next_at) - now))
		return
	for id in got:
		give_item(p, str(id), 1)
		r.fx.append(["+1 %s" % Data.item_name(str(id)), Color.WHITE])
	o["catch"] = []
	if was_full or float(o.next_at) < now:
		o.next_at = now + Fishing.crab_period(o)
	bump_stat("crab", got.size(), p.id)
	r.ok = true
	r.sfx = "harvest"
	EventBus.objects_changed.emit(map_id)

## Quest rewards: money, items, recipe, friendship {villager: points}, skill points, emotes, chips, world flags, player flags.
func grant_quest_reward(p: PlayerData, reward: Dictionary) -> void:
	var rest := {}
	for k in reward:
		match k:
			"friendship":
				for vid in reward[k]:
					p.add_friendship(vid, int(reward[k][vid]))
			"skill_points":
				p.skill_points += int(reward[k])
			"emote":
				if not reward[k] in p.emotes:
					p.emotes.append(reward[k])
			"chips":
				Casino.add_chips(p, int(reward[k]))
			"flag":
				world.flags[str(reward[k])] = true
			"player_flag":
				p.flags[str(reward[k])] = true
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
		parts.append("%s:%s:%d" % [c.uid, c.species_id, c.level])
	for c: Creature in sanctuary:
		parts.append("s:%s:%s:%d" % [c.uid, c.species_id, c.level])
	return ",".join(parts)

## Puts a hat from the pack on (the old one goes back into the pack); uid "" takes the hat off.
func wear_hat_act(pid: String, uid: String) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _res(false)
	var new_id := ""
	if uid != "":
		var f := p.inventory.find(uid)
		if f.is_empty() or str(Data.get_item(f.entry.id).get("hat", "")) == "":
			return _res(false)
		new_id = str(f.entry.id)
		f.inv.take(uid, 1)
	if p.hat != "":
		if p.inventory.add(p.hat, 1, 0, {}, false) > 0:
			if new_id != "":
				p.inventory.add(new_id, 1, 0, {}, false)
			return _res(false, tr("Your pack is full."))
	p.hat = new_id
	EventBus.inventory_changed.emit()
	var r := _res(true)
	r.sfx = "equip"
	return r

const HOTEL_PRICE := 500

## A night at the Hôtel Lumière: the party is healed, without ending the day.
func hotel_act(pid: String) -> Dictionary:
	var p := player(pid)
	if p == null:
		return _res(false)
	if not spend(HOTEL_PRICE, "Hotel"):
		return _res(false, tr("Not enough gold."))
	p.heal_party()
	EventBus.party_changed.emit()
	var r := _res(true)
	r.sfx = "heal"
	return r

## Tracks the farm jukebox can play: one per record in the player's pack or the farm chest.
func record_tracks(p: PlayerData) -> Array:
	var out: Array = []
	for inv: Inventory in [p.inventory, farm_chest]:
		for e in inv.all_entries():
			var track := str(Data.get_item(e.id).get("track", ""))
			if track != "" and not track in out:
				out.append(track)
	return out

## Sets the farm music to a record's track ("" goes back to the farm tune).
func jukebox_act(pid: String, track: String) -> Dictionary:
	var p := player(pid)
	if p == null or (track != "" and not track in record_tracks(p)):
		return _res(false)
	if track == "":
		world.flags.erase("jukebox")
	else:
		world.flags["jukebox"] = track
	EventBus.jukebox_changed.emit()
	var r := _res(true)
	r.sfx = "tick"
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
	_cracks.clear()
	for m in PERSISTENT_MAPS:
		if d.grids.has(m):
			grids[m] = FarmGrid.from_dict(d.grids[m])
			for patch in Data.get_map(m).get("patches", []):
				if not world.flags.has("patch:" + str(patch.id)):
					MapBuilder.apply_patch(grids[m], patch.ops)
		else:
			grids[m] = MapBuilder.build_authored(Data.get_map(m)).grid
		_mark_patches(m)
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
