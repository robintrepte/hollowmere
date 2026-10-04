class_name Quests
extends RefCounted
## Data-driven quests from data/quests.json: side quests from villagers, three daily quests per real
## day, the tutorial chain, and seasonal / event quests bound to real dates. The main story keeps
## running through Adventure chapters (farm-wide, host); the quest log lists it as the "main" entry.
##
## Every quest here belongs to one player (PlayerData.quests):
##   active:   {qid: {step: int, base: {stat: int}, at: float, reached: bool, def?: Dictionary}}
##   done:     {qid: {at: float, claimed: bool}}
##   tracked:  [qid]
##   daily:    {date: "YYYY-MM-DD", ids: [qid], rerolled: bool, streak: int, last: "YYYY-MM-DD"}
##   tutorial: "" | "playing" | "skipped" | "done"
##
## Step goals (one key each, plus "n"):
##   stat: key           counter in PlayerData.stats that has to grow by n while the step is open
##   have: item          n of an item in the pack
##   deliver: item, to   hand n of an item to a villager (talk to them)
##   talk: villager      talk to a villager
##   visit: map          step onto a map (region id, "town", "farm", ...)
##   tile: [map, x, y]   reach a spot (within 2 tiles)
##   flag: name          a farm flag is set
##   dex / farm_level / shrines: n
##   hearts: [villager, n]

const TYPES := ["main", "side", "daily", "tutorial", "seasonal", "event", "weekly"]
const DAILY_COUNT := 3
const TRACK_MAX := 3
const STREAK_EVERY := 5
const TILE_RADIUS := 2

static func state(p: PlayerData) -> Dictionary:
	var q: Dictionary = p.quests
	for k in ["active", "done"]:
		if not q.has(k):
			q[k] = {}
	if not q.has("tracked"):
		q.tracked = []
	if not q.has("daily"):
		q.daily = {"date": "", "ids": [], "rerolled": false, "streak": 0, "last": ""}
	if not q.has("tutorial"):
		q.tutorial = ""
	return q

static func def_of(p: PlayerData, qid: String) -> Dictionary:
	var a: Dictionary = state(p).active.get(qid, {})
	if a.has("def"):
		return a.def
	return Data.quests.get(qid, {})

static func is_active(p: PlayerData, qid: String) -> bool:
	return state(p).active.has(qid)

static func is_done(p: PlayerData, qid: String) -> bool:
	return state(p).done.has(qid)

static func step_of(p: PlayerData, qid: String) -> Dictionary:
	var d := def_of(p, qid)
	var a: Dictionary = state(p).active.get(qid, {})
	var steps: Array = d.get("steps", [])
	var i := int(a.get("step", 0))
	return steps[i] if i < steps.size() else {}

# --- Availability ---------------------------------------------------------------------

## True when every requirement of a quest definition holds.
## Story requirements name a chapter id ("coast") or, in older data, its index.
static func story_index(v: Variant) -> int:
	return Adventure.chapter_index(v) if v is String else int(v)

static func requirements_met(p: PlayerData, world: Dictionary, req: Dictionary, unix: float) -> bool:
	for k in req:
		var v: Variant = req[k]
		match k:
			"quests":
				for qid in v:
					if not is_done(p, str(qid)):
						return false
			"flag":
				if not world.flags.get(str(v), false):
					return false
			"farm_level":
				if int(world.farm.level) < int(v):
					return false
			"shrines":
				if world.shrines.size() < int(v):
					return false
			"story":
				if int(world.quest) < story_index(v):
					return false
			"hearts":
				var h := p.hearts_dict()
				for vid in v:
					if int(h.get(vid, 0)) < int(v[vid]):
						return false
			"season":
				if Seasons.current(unix, Settings.hemisphere) != str(v):
					return false
			"dates":
				if not in_dates(unix, v):
					return false
			"region":
				if not GameState.region_unlocked(str(v)):
					return false
			"casino":
				if Casino.hidden():
					return false
	return true

## dates = ["MM-DD", "MM-DD"] (inclusive, may wrap over new year), in local time.
static func in_dates(unix: float, dates: Array) -> bool:
	if dates.size() < 2:
		return false
	var md := local_date(unix).substr(5)
	var a := str(dates[0])
	var b := str(dates[1])
	if a <= b:
		return md >= a and md <= b
	return md >= a or md <= b

## Side, seasonal and event quests this player could pick up now (optionally from one villager).
static func offers(p: PlayerData, world: Dictionary, unix: float, giver: String = "") -> Array:
	var out: Array = []
	var st := state(p)
	for qid in Data.quest_order:
		var d: Dictionary = Data.quests[qid]
		if not str(d.get("type", "side")) in ["side", "seasonal", "event"]:
			continue
		if giver != "" and str(d.get("giver", "")) != giver:
			continue
		if st.active.has(qid):
			continue
		if st.done.has(qid) and not _repeat_ready(d, st.done[qid], unix):
			continue
		if requirements_met(p, world, d.get("requires", {}), unix):
			out.append(qid)
	return out

## Seasonal and event quests come back every year.
static func _repeat_ready(d: Dictionary, done: Dictionary, unix: float) -> bool:
	if not str(d.get("type", "")) in ["seasonal", "event"]:
		return false
	return local_date(unix).substr(0, 4) != local_date(float(done.get("at", 0.0))).substr(0, 4)

# --- Progress -------------------------------------------------------------------------

static func start(p: PlayerData, qid: String, unix: float, def: Dictionary = {}) -> bool:
	var st := state(p)
	var d: Dictionary = def if not def.is_empty() else Data.quests.get(qid, {})
	if d.is_empty() or st.active.has(qid):
		return false
	var entry := {"step": 0, "base": {}, "at": unix, "reached": false}
	if not def.is_empty():
		entry.def = def
	st.active[qid] = entry
	st.done.erase(qid)
	_snapshot(p, qid)
	if st.tracked.size() < TRACK_MAX and str(d.get("type", "")) != "daily":
		st.tracked.append(qid)
	return true

static func _snapshot(p: PlayerData, qid: String) -> void:
	var entry: Dictionary = state(p).active[qid]
	var g: Dictionary = step_of(p, qid).get("goal", {})
	entry.base = {}
	entry.reached = false
	if g.has("stat"):
		entry.base[g.stat] = int(p.stats.get(g.stat, 0))

## [have, need] for the open step of a quest.
static func progress(p: PlayerData, world: Dictionary, qid: String) -> Array:
	var entry: Dictionary = state(p).active.get(qid, {})
	var g: Dictionary = step_of(p, qid).get("goal", {})
	var n := int(g.get("n", 1))
	if g.has("stat"):
		return [mini(n, int(p.stats.get(g.stat, 0)) - int(entry.get("base", {}).get(g.stat, 0))), n]
	if g.has("have"):
		return [mini(n, p.inventory.count(str(g.have))), n]
	if g.has("deliver"):
		return [mini(n, p.inventory.count(str(g.deliver))), n]
	if g.has("visit"):
		return [1 if int(p.stats.get("visit:" + str(g.visit), 0)) > 0 else 0, 1]
	if g.has("tile"):
		return [1 if entry.get("reached", false) else 0, 1]
	if g.has("flag"):
		return [1 if world.flags.get(str(g.flag), false) else 0, 1]
	if g.has("depth"):
		return [mini(int(g.depth), int(world.get("mining", {}).get("max", 0))), int(g.depth)]
	if g.has("museum"):
		return [mini(int(g.museum), world.get("mining", {}).get("museum", []).size()), int(g.museum)]
	if g.has("dex"):
		return [mini(int(g.dex), Progression.owned_count(world.dex)), int(g.dex)]
	if g.has("farm_level"):
		return [mini(int(g.farm_level), int(world.farm.level)), int(g.farm_level)]
	if g.has("shrines"):
		return [mini(int(g.shrines), world.shrines.size()), int(g.shrines)]
	if g.has("hearts"):
		var need := int(g.hearts[1])
		return [mini(need, int(p.hearts_dict().get(str(g.hearts[0]), 0))), need]
	return [0, 1]

## Steps that finish by talking to someone instead of on their own.
static func needs_talk(step: Dictionary) -> String:
	var g: Dictionary = step.get("goal", {})
	if g.has("talk"):
		return str(g.talk)
	if g.has("deliver"):
		return str(g.get("to", ""))
	return ""

## Moves every quest on whose open step is done. Returns [{qid, event: "step"|"done"}].
static func update(p: PlayerData, world: Dictionary, unix: float) -> Array:
	var out: Array = []
	var st := state(p)
	for qid in st.active.keys():
		var guard := 0
		while st.active.has(qid) and guard < 16:
			guard += 1
			var step := step_of(p, qid)
			if step.is_empty() or needs_talk(step) != "":
				break
			var pr := progress(p, world, qid)
			if int(pr[0]) < int(pr[1]):
				break
			out.append({"qid": qid, "event": _advance(p, qid, unix)})
	return out

static func _advance(p: PlayerData, qid: String, unix: float) -> String:
	var st := state(p)
	var entry: Dictionary = st.active[qid]
	entry.step = int(entry.step) + 1
	if int(entry.step) < def_of(p, qid).get("steps", []).size():
		_snapshot(p, qid)
		return "step"
	st.done[qid] = {"at": unix, "claimed": false}
	if entry.has("def"):
		st.done[qid].def = entry.def
	st.active.erase(qid)
	st.tracked.erase(qid)
	return "done"

## Talking to a villager: finishes talk / deliver steps aimed at them (takes delivered items).
## Returns [{qid, lines, event}] for each step it finished.
static func talk(p: PlayerData, world: Dictionary, vid: String, unix: float) -> Array:
	var out: Array = []
	var st := state(p)
	for qid in st.active.keys():
		var step := step_of(p, qid)
		if needs_talk(step) != vid:
			continue
		var g: Dictionary = step.goal
		if g.has("deliver"):
			if p.inventory.count(str(g.deliver)) < int(g.get("n", 1)):
				continue
			p.inventory.remove(str(g.deliver), int(g.get("n", 1)))
		var lines: Array = step.get("done", [])
		out.append({"qid": qid, "lines": lines, "event": _advance(p, qid, unix)})
	if not out.is_empty():
		update(p, world, unix)
	return out

## Something for this villager to hand in right now ("?" over their head).
static func turn_in_ready(p: PlayerData, vid: String) -> bool:
	for qid in state(p).active:
		var step := step_of(p, qid)
		if needs_talk(step) != vid:
			continue
		var g: Dictionary = step.goal
		if not g.has("deliver") or p.inventory.count(str(g.deliver)) >= int(g.get("n", 1)):
			return true
	return false

## Marks tile goals reached when the player stands near them.
static func at_tile(p: PlayerData, map_id: String, t: Vector2i) -> bool:
	var hit := false
	for qid in state(p).active:
		var g: Dictionary = step_of(p, qid).get("goal", {})
		if not g.has("tile") or str(g.tile[0]) != map_id:
			continue
		var entry: Dictionary = state(p).active[qid]
		if not entry.get("reached", false) and Vector2i(int(g.tile[1]), int(g.tile[2])).distance_to(t) <= TILE_RADIUS:
			entry.reached = true
			hit = true
	return hit

## Where the open step happens: {map, vid?, tile?}, or {} if it can be done anywhere.
static func target(p: PlayerData, qid: String) -> Dictionary:
	var g: Dictionary = step_of(p, qid).get("goal", {})
	var vid := needs_talk(step_of(p, qid))
	if vid != "":
		var sched: Array = Data.villagers.get(vid, {}).get("schedule", [])
		return {"map": str(sched[0][1]) if not sched.is_empty() else "town", "vid": vid}
	if g.has("visit"):
		return {"map": str(g.visit)}
	if g.has("tile"):
		return {"map": str(g.tile[0]), "tile": Vector2i(int(g.tile[1]), int(g.tile[2]))}
	return {}

## Maps with something to do for a tracked quest.
static func tracked_maps(p: PlayerData) -> Array:
	var out: Array = []
	for qid in state(p).tracked:
		var t := target(p, qid)
		if not t.is_empty() and not t.map in out:
			out.append(t.map)
	return out

static func unclaimed(p: PlayerData) -> Array:
	var out: Array = []
	var st := state(p)
	for qid in st.done:
		if not st.done[qid].get("claimed", true):
			out.append(qid)
	return out

static func reward_of(p: PlayerData, qid: String) -> Dictionary:
	var d: Dictionary = state(p).done.get(qid, {}).get("def", Data.quests.get(qid, {}))
	return d.get("reward", {})

static func toggle_track(p: PlayerData, qid: String) -> bool:
	var st := state(p)
	if qid in st.tracked:
		st.tracked.erase(qid)
		return false
	if not st.active.has(qid) and qid != "main":
		return false
	if st.tracked.size() >= TRACK_MAX:
		st.tracked.pop_front()
	st.tracked.append(qid)
	return true

# --- Daily quests ---------------------------------------------------------------------

## "YYYY-MM-DD" in the player's time zone.
static func local_date(unix: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(unix) + TimeService.utc_offset())
	return "%04d-%02d-%02d" % [d.year, d.month, d.day]

static func _day_before(date: String) -> String:
	var u := Time.get_unix_time_from_datetime_string(date + "T12:00:00")
	return Time.get_date_string_from_unix_time(u - 86400)

## Hands out the day's three daily quests once per local day; yesterday's leftovers expire.
static func roll_daily(p: PlayerData, world: Dictionary, unix: float) -> bool:
	var st := state(p)
	var today := local_date(unix)
	if st.daily.date == today:
		return false
	for qid in st.daily.ids:
		st.active.erase(qid)
		st.tracked.erase(qid)
		st.done.erase(qid)
	st.daily.date = today
	st.daily.ids = []
	st.daily.rerolled = false
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(today + p.id)
	var pool := daily_pool(world, unix)
	for i in DAILY_COUNT:
		if pool.is_empty():
			break
		var t: Dictionary = pool.pop_at(rng.randi() % pool.size())
		var qid := "daily:%s:%d" % [today, i]
		start(p, qid, unix, make_daily(t, world, rng))
		st.daily.ids.append(qid)
	return true

static func daily_pool(world: Dictionary, unix: float) -> Array:
	var out: Array = []
	for t in Data.quest_daily:
		var req: Dictionary = t.get("requires", {})
		if req.has("shrines") and world.shrines.size() < int(req.shrines):
			continue
		if req.has("farm_level") and int(world.farm.level) < int(req.farm_level):
			continue
		if req.has("flag") and not world.flags.get(str(req.flag), false):
			continue
		if req.has("story") and int(world.quest) < story_index(req.story):
			continue
		out.append(t)
	return out

## Turns a template into a quest. Targets grow with the farm level.
static func make_daily(t: Dictionary, world: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var scale := clampf((int(world.farm.level) - 1) / 9.0, 0.0, 1.0)
	var lo := int(t.n[0])
	var hi := int(t.n[1])
	var n := maxi(1, int(round(lerpf(lo, hi, scale) * rng.randf_range(0.85, 1.15))))
	var goal: Dictionary = t.goal.duplicate()
	goal.n = n
	var args: Array = [n]
	if goal.has("deliver"):
		var picks: Array = t.get("items", [])
		goal.deliver = picks[rng.randi() % picks.size()]
		var people: Array = t.get("to", ["mira"])
		goal.to = people[rng.randi() % people.size()]
		args = [n, goal.deliver, goal.to]
	var money := int(t.get("money", 0)) + int(round(float(t.get("money_per", 0.0)) * n))
	return {
		"type": "daily", "title": t.title, "template": t.id,
		"steps": [{"text": t.text, "args": args, "goal": goal}],
		"reward": {"money": money},
	}

## Swaps one unfinished daily for a fresh one, once per day.
static func reroll_daily(p: PlayerData, world: Dictionary, qid: String, unix: float) -> bool:
	var st := state(p)
	if st.daily.rerolled or not qid in st.daily.ids or not st.active.has(qid):
		return false
	var used: Array = []
	for id in st.daily.ids:
		used.append(def_of(p, id).get("template", ""))
	var pool := daily_pool(world, unix).filter(func(t): return not t.id in used)
	if pool.is_empty():
		return false
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(qid + "reroll")
	st.active.erase(qid)
	start(p, qid, unix, make_daily(pool[rng.randi() % pool.size()], world, rng))
	st.daily.rerolled = true
	return true

## After the last daily of the day: the streak grows if yesterday was finished too.
## Returns the streak bonus reward ({} if none).
static func daily_finished(p: PlayerData) -> Dictionary:
	var st := state(p)
	var today: String = st.daily.date
	if st.daily.last == today:
		return {}
	for qid in st.daily.ids:
		if not st.done.has(qid):
			return {}
	st.daily.streak = int(st.daily.streak) + 1 if st.daily.last == _day_before(today) else 1
	st.daily.last = today
	if int(st.daily.streak) % STREAK_EVERY == 0:
		return {"money": 500 + 100 * int(st.daily.streak), "great_charm": 2}
	return {}

# --- Tutorial -------------------------------------------------------------------------

static func tutorial_ids() -> Array:
	return Data.quest_order.filter(func(q): return str(Data.quests[q].get("type", "")) == "tutorial")

static func start_tutorial(p: PlayerData, unix: float) -> void:
	state(p).tutorial = "playing"
	next_tutorial(p, unix)

## Starts the next tutorial quest after one finishes.
static func next_tutorial(p: PlayerData, unix: float) -> String:
	if state(p).tutorial != "playing":
		return ""
	for qid in tutorial_ids():
		if is_done(p, qid) or is_active(p, qid):
			if is_active(p, qid):
				return ""
			continue
		start(p, qid, unix)
		return qid
	state(p).tutorial = "done"
	return ""

## Skipping marks every tutorial quest done; their rewards are still paid out (unclaimed).
static func skip_tutorial(p: PlayerData, unix: float) -> void:
	var st := state(p)
	for qid in tutorial_ids():
		st.active.erase(qid)
		st.tracked.erase(qid)
		if not st.done.has(qid):
			st.done[qid] = {"at": unix, "claimed": false}
	st.tutorial = "skipped"

# --- Text -----------------------------------------------------------------------------

static func title(p: PlayerData, qid: String) -> String:
	return TranslationServer.translate(str(def_of(p, qid).get("title", qid)))

## The open step's task, with numbers and names filled in.
static func step_text(p: PlayerData, qid: String) -> String:
	var step := step_of(p, qid)
	return format_step(step)

static func format_step(step: Dictionary) -> String:
	var text := str(TranslationServer.translate(str(step.get("text", ""))))
	var args: Array = step.get("args", [])
	if args.is_empty():
		return text
	var shown: Array = []
	for a in args:
		if a is String and Data.has_item(a):
			shown.append(Data.item_name(a))
		elif a is String and Data.villagers.has(a):
			shown.append(Data.villager_name(a))
		else:
			shown.append(a)
	return text % shown
