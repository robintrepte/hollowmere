class_name Relationships
extends RefCounted
## Friendship points, gifts, heart events, dialogue and schedules.
## Per-villager state: {pts:int, talked:bool, gifts_week:int, gifted_today:bool, events:Array, dating:bool, married:bool}

const PTS_PER_HEART := 250
const MAX_HEARTS := 10
const MAX_HEARTS_FRIEND := 8

static func new_state() -> Dictionary:
	return {"pts": 0, "talked": false, "gifts_week": 0, "gifted_today": false, "events": [], "dating": false, "married": false}

static func hearts(st: Dictionary) -> int:
	return clampi(int(st.get("pts", 0)) / PTS_PER_HEART, 0, MAX_HEARTS)

static func max_pts(vid: String, st: Dictionary) -> int:
	var v: Dictionary = Data.villagers.get(vid, {})
	if v.get("romance", false) and not st.get("dating", false):
		return MAX_HEARTS_FRIEND * PTS_PER_HEART + PTS_PER_HEART - 1
	return MAX_HEARTS * PTS_PER_HEART

static func add_points(vid: String, st: Dictionary, n: int) -> void:
	st.pts = clampi(int(st.pts) + n, 0, max_pts(vid, st))

static func gift_taste(vid: String, item_id: String) -> String:
	var v: Dictionary = Data.villagers.get(vid, {})
	if item_id in v.get("loves", []):
		return "love"
	if item_id in v.get("likes", []):
		return "like"
	if item_id in v.get("dislikes", []):
		return "dislike"
	var cat: String = Data.get_item(item_id).get("cat", "")
	if cat in ["gift", "food"]:
		return "like"
	if cat in ["material", "ore"]:
		return "dislike"
	return "neutral"

## Returns {ok, taste, pts, line}
static func give_gift(vid: String, st: Dictionary, item_id: String, q: int, is_birthday: bool) -> Dictionary:
	if st.gifted_today:
		return {"ok": false, "line": "You've already given %s a gift today." % Data.villager_name(vid)}
	if int(st.gifts_week) >= 2 and not is_birthday:
		return {"ok": false, "line": "%s has received enough gifts this week." % Data.villager_name(vid)}
	if item_id == "bouquet":
		var v: Dictionary = Data.villagers[vid]
		if not v.get("romance", false):
			return {"ok": false, "line": "%s smiles politely, but doesn't take the bouquet." % v.name}
		if hearts(st) < 8:
			return {"ok": false, "line": "%s blushes. \"Maybe when we know each other better...\"" % v.name}
		st.dating = true
		st.gifted_today = true
		add_points(vid, st, 100)
		return {"ok": true, "taste": "love", "pts": 100, "line": "%s: \"Yes! I'd love to.\"" % v.name, "dating": true}
	if item_id == "hollow_pendant":
		if not st.get("dating", false) or hearts(st) < 10:
			return {"ok": false, "line": "This isn't the right moment."}
		st.married = true
		st.gifted_today = true
		return {"ok": true, "taste": "love", "pts": 0, "line": "%s: \"Of course I'll marry you!\"" % Data.villager_name(vid), "married": true}
	var taste := gift_taste(vid, item_id)
	var pts := {"love": 80, "like": 45, "neutral": 20, "dislike": -20}[taste] as int
	pts = int(pts * (1.0 + 0.1 * q))
	if is_birthday:
		pts *= 8 if taste != "dislike" else 1
	add_points(vid, st, pts)
	st.gifted_today = true
	st.gifts_week = int(st.gifts_week) + 1
	var lines := {
		"love": "\"Oh! I love this! Thank you so much!\"",
		"like": "\"How thoughtful. Thank you!\"",
		"neutral": "\"Thanks.\"",
		"dislike": "\"Um... I'll find a use for it, I guess.\"",
	}
	return {"ok": true, "taste": taste, "pts": pts, "line": "%s: %s" % [Data.villager_name(vid), lines[taste]]}

static func talk(vid: String, st: Dictionary, season: String, rng: RandomNumberGenerator) -> String:
	var v: Dictionary = Data.villagers.get(vid, {})
	if not st.talked:
		st.talked = true
		add_points(vid, st, 20)
	var h := hearts(st)
	var tier := "0"
	for t in ["9", "6", "3"]:
		if h >= int(t):
			tier = t
			break
	var pool: Array = v.get("lines", {}).get(tier, []).duplicate()
	if v.get("season", {}).has(season):
		pool.append(v.season[season])
	if st.get("married", false):
		pool.append("I'm so glad we're together. Let's make today a good one.")
	if pool.is_empty():
		return "..."
	return pool[rng.randi() % pool.size()]

## Returns heart-event id ("2"/"5"/"8") ready to trigger, or "".
static func pending_event(vid: String, st: Dictionary) -> String:
	var v: Dictionary = Data.villagers.get(vid, {})
	for e in ["2", "5", "8"]:
		if v.get("events", {}).has(e) and not e in st.events and hearts(st) >= int(e):
			return e
	return ""

static func daily_reset(st: Dictionary, new_week: bool) -> void:
	if not st.talked and int(st.pts) > 0 and hearts(st) < 8:
		st.pts = maxi(0, int(st.pts) - 2)
	st.talked = false
	st.gifted_today = false
	if new_week:
		st.gifts_week = 0

## Returns [map, x, y] where the villager is at `minute` (and season/weather).
static func location(vid: String, minute: int, weather: String) -> Array:
	var v: Dictionary = Data.villagers.get(vid, {})
	var sched: Array = v.get("schedule", [])
	if sched.is_empty():
		return ["", 0, 0]
	var cur: Array = sched[0]
	for e in sched:
		if minute >= Calendar.hhmm(int(e[0])):
			cur = e
	if weather in ["rain", "storm"] and v.get("rain_spot", []).size() == 3:
		return v.rain_spot
	return [cur[1], int(cur[2]), int(cur[3])]

static func is_birthday(vid: String, season: String, day_of_season: int) -> bool:
	var b: Array = Data.villagers.get(vid, {}).get("birthday", [])
	return b.size() == 2 and b[0] == season and int(b[1]) == day_of_season
