class_name Fishing
extends RefCounted
## Fishing rules: which water holds which fish, what bites, sizes and quality, treasure,
## rods, bait and tackle, and crab pots. Pure functions; GameState runs them on the host.

const BITE_MIN := 1.5
const BITE_MAX := 6.0
const WILD_CHANCE := 0.06
const TREASURE_CHANCE := 0.1
const TACKLE_USES := 20
const MAX_ROD := 3
## Seconds a hooked fish needs at least (anything faster than this is not a real catch).
const MIN_FIGHT := 1.2
const CRAB_SECONDS := 4.0 * 3600.0
const CRAB_BAIT_SECONDS := 2.5 * 3600.0
const CRAB_HOLD := 3
const BIOME_WATER := {
	"grass": "pond", "forest": "pond", "beach": "sea", "canyon": "river", "cliffs": "river",
	"marsh": "pond", "snow": "ice", "twilight": "pond",
}
const BAIT := {
	"bait": {"bite": 0.75},
	"wild_bait": {"bite": 0.7, "rare": 0.6},
	"magic_bait": {"bite": 0.8, "any": true},
}
const TACKLE := {
	"spinner": {"bite": 0.8},
	"cork_bobber": {"zone": 0.06},
	"trap_bobber": {"escape": 0.6},
	"treasure_lure": {"treasure": 2.5},
}
const WATER_LABELS := {"pond": "Pond", "river": "River", "sea": "Sea", "mine": "Cave lake", "ice": "Ice hole"}
const TIME_LABELS := {"day": "Day", "night": "Night", "any": "Any time"}
const WEATHER_LABELS := {"rain": "Rain", "sun": "Sunny", "any": "Any weather"}

static func fish(id: String) -> Dictionary:
	return Data.fish.get(id, {})

static func is_fish(id: String) -> bool:
	return Data.fish.has(id)

## Fishable water at a tile: "pond", "river", "sea", "mine", "ice" or "".
static func water_kind(info: Dictionary, t: Vector2i) -> String:
	var g: FarmGrid = info.get("grid")
	if g == null or not g.in_bounds(t):
		return ""
	var biome := str(info.get("biome", "grass"))
	var gr := g.get_ground(t)
	if gr == Tiles.GROUND.ice and biome == "snow":
		return "ice"
	if not gr in Tiles.WATER_TILES:
		return ""
	if info.get("mine", false):
		return "mine"
	for z in info.get("water_zones", []):
		if Rect2i(int(z[1]), int(z[2]), int(z[3]), int(z[4])).has_point(t):
			return str(z[0])
	if info.has("water"):
		return str(info.water)
	return str(BIOME_WATER.get(biome, "pond"))

## Fish that can bite here and now. `dex` excludes legendaries already caught.
static func pool(kind: String, map_id: String, season: String, night: bool, weather: String, floor_n: int, dex: Dictionary, any_time := false) -> Array:
	var out: Array = []
	var place := map_id.split(":")[1] if map_id.begins_with("mine:") else "deep" if map_id.begins_with("deep:") else map_id
	for id in Data.fish:
		var f: Dictionary = Data.fish[id]
		if not kind in f.where:
			continue
		if f.has("maps") and not place in f.maps:
			continue
		if kind == "mine" and int(f.get("min_floor", 0)) > floor_n:
			continue
		if f.get("legendary", false) and dex.has(id):
			continue
		if not any_time:
			if not season in f.seasons:
				continue
			if f.time == "day" and night or f.time == "night" and not night:
				continue
			if f.weather == "rain" and not weather in ["rain", "storm"]:
				continue
			if f.weather == "sun" and weather in ["rain", "storm", "snow"]:
				continue
		out.append(id)
	return out

## What bites. ctx: {kind, map, season, night, weather, floor, dex, rod, bait, tackle, luck, bite, levels}
## Returns {kind: "fish"|"junk"|"wild", id, size, diff, move, treasure, bite, level}.
static func roll(ctx: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var bait: Dictionary = BAIT.get(str(ctx.get("bait", "")), {})
	var tackle: Dictionary = TACKLE.get(str(ctx.get("tackle", "")), {})
	var luck := float(ctx.get("luck", 0.0))
	var rod := int(ctx.get("rod", 0))
	var bite := rng.randf_range(BITE_MIN, BITE_MAX) * float(bait.get("bite", 1.0)) * float(tackle.get("bite", 1.0))
	bite = maxf(0.8, bite * (1.0 - clampf(float(ctx.get("bite", 0.0)), 0.0, 0.6)))
	var kind := str(ctx.kind)
	var wilds: Array = Data.fish_meta.get("wildlings", {}).get(kind, [])
	if not wilds.is_empty() and rng.randf() < WILD_CHANCE:
		var lv: Array = ctx.get("levels", [3, 8])
		return {"kind": "wild", "id": str(wilds[rng.randi() % wilds.size()]), "level": rng.randi_range(int(lv[0]), int(lv[1])), "bite": bite, "diff": 0, "move": "smooth", "treasure": false}
	var ids := pool(kind, str(ctx.get("map", "")), str(ctx.season), bool(ctx.night), str(ctx.weather), int(ctx.get("floor", 0)), ctx.get("dex", {}), bait.get("any", false))
	var junk_chance := maxf(0.02, 0.1 - luck * 0.5 - rod * 0.015)
	if ids.is_empty() or rng.randf() < junk_chance:
		return {"kind": "junk", "id": _weighted(Data.fish_meta.get("junk", []), rng), "bite": bite, "diff": 10, "move": "smooth", "treasure": false}
	var total := 0.0
	var weights: Array = []
	for id in ids:
		var w := float(Data.fish[id].w)
		if w <= 10.0:
			w *= 1.0 + luck * 4.0 + float(bait.get("rare", 0.0))
		weights.append(w)
		total += w
	var r := rng.randf() * total
	var pick: String = ids[0]
	for i in ids.size():
		r -= float(weights[i])
		if r <= 0.0:
			pick = ids[i]
			break
	var f: Dictionary = Data.fish[pick]
	var lo := float(f.size[0])
	var hi := float(f.size[1])
	var size := lo + (hi - lo) * pow(rng.randf(), maxf(0.4, 1.5 - 0.1 * rod - luck * 2.0))
	var treasure := rng.randf() < TREASURE_CHANCE * float(tackle.get("treasure", 1.0)) * (1.0 + luck * 2.0)
	return {"kind": "fish", "id": pick, "size": snappedf(size, 0.1), "diff": int(f.diff), "move": str(f.move), "treasure": treasure, "bite": bite}

static func _weighted(table: Array, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for e in table:
		total += float(e[1])
	var r := rng.randf() * total
	for e in table:
		r -= float(e[1])
		if r <= 0.0:
			return str(e[0])
	return str(table[0][0]) if not table.is_empty() else "driftwood"

## Quality from how big the fish is, one step up for a perfect catch and one down in Easy fishing.
static func quality(id: String, size: float, perfect: bool, easy: bool) -> int:
	var f := fish(id)
	if f.is_empty():
		return 0
	var lo := float(f.size[0])
	var hi := float(f.size[1])
	var frac := clampf((size - lo) / maxf(0.1, hi - lo), 0.0, 1.0)
	var q := 0 if frac < 0.5 else (1 if frac < 0.8 else (2 if frac < 0.95 else 3))
	if perfect:
		q += 1
	if easy:
		q -= 1
	return clampi(q, 0, 3)

## Height of the catch zone as a share of the bar.
static func zone_size(rod: int, tackle: String, bonus: float) -> float:
	return clampf(0.24 + 0.035 * rod + float(TACKLE.get(tackle, {}).get("zone", 0.0)) + bonus, 0.18, 0.6)

## How far a full-power cast reaches, in tiles.
static func cast_range(rod: int) -> int:
	return 3 + rod

static func escape_mult(tackle: String) -> float:
	return float(TACKLE.get(tackle, {}).get("escape", 1.0))

static func treasure_loot(rng: RandomNumberGenerator, luck: float) -> Array:
	var table: Array = Data.fish_meta.get("treasure", [])
	var out: Array = []
	var rolls := 1 + (1 if rng.randf() < 0.35 + luck else 0)
	for i in rolls:
		var id := _weighted(table, rng)
		for e in table:
			if e[0] == id:
				out.append([id, rng.randi_range(int(e[2]), int(e[3]))])
				break
	if rng.randf() < 0.08 + luck * 0.5:
		out.append([Enchanting.random_book(rng), 1])
	return out

static func energy_cost(rod: int) -> float:
	return maxf(1.0, 2.0 - 0.25 * rod)

static func rod_spec(level: int) -> Dictionary:
	var rods: Array = Data.fish_meta.get("rods", [])
	return rods[level] if level >= 0 and level < rods.size() else {}

static func rod_name(level: int) -> String:
	return TranslationServer.translate(str(rod_spec(level).get("name", "Fishing Rod")))

## Tackle can only go on a Gold rod or better.
static func takes_tackle(rod: int) -> bool:
	return rod >= 2

static func species_caught(p: PlayerData) -> int:
	return p.fishing.get("dex", {}).size() if p else 0

## Records a catch. Returns true if it's a new size record (or a new fish).
static func record(p: PlayerData, id: String, size: float) -> bool:
	var dex: Dictionary = p.fishing.get("dex", {})
	var e: Dictionary = dex.get(id, {"n": 0, "best": 0.0})
	var rec := size > float(e.best)
	e.n = int(e.n) + 1
	e.best = maxf(float(e.best), size)
	dex[id] = e
	p.fishing["dex"] = dex
	return rec

## Short "where and when" line for the Fishdex.
static func habitat_text(id: String) -> String:
	var f := fish(id)
	var wh: PackedStringArray = []
	for k in f.get("where", []):
		wh.append(TranslationServer.translate(WATER_LABELS.get(k, k)))
	var parts: PackedStringArray = [", ".join(wh)]
	if f.get("seasons", []).size() < 4:
		parts.append(Data.season_list(f.seasons))
	if f.get("time", "any") != "any":
		parts.append(TranslationServer.translate(TIME_LABELS[f.time]))
	if f.get("weather", "any") != "any":
		parts.append(TranslationServer.translate(WEATHER_LABELS[f.weather]))
	if f.has("maps"):
		var names: PackedStringArray = []
		for m in f.maps:
			names.append(Data.region_name(str(m)))
		parts.append(", ".join(names))
	if int(f.get("min_floor", 0)) > 0:
		parts.append(TranslationServer.translate("Floor %d and deeper") % int(f.min_floor))
	return " · ".join(parts)

# --- Crab pots ---------------------------------------------------------------------------

static func crab_catch(kind: String, rng: RandomNumberGenerator) -> String:
	if rng.randf() < 0.12:
		return _weighted(Data.fish_meta.get("junk", []), rng)
	var table: Array = []
	for id in Data.shellfish:
		if kind in Data.shellfish[id].where:
			table.append([id, Data.shellfish[id].w])
	return _weighted(table, rng) if not table.is_empty() else "snail"

## Fills a pot with whatever it caught since it was last checked. Returns true if anything changed.
static func crab_step(o: Dictionary, now: float, kind: String, rng: RandomNumberGenerator) -> bool:
	var catch_list: Array = o.get("catch", [])
	var changed := false
	while catch_list.size() < CRAB_HOLD and now >= float(o.get("next_at", now)):
		catch_list.append(crab_catch(kind, rng))
		var baited := int(o.get("bait", 0)) > 0
		if baited:
			o.bait = int(o.bait) - 1
		o.next_at = float(o.next_at) + (CRAB_BAIT_SECONDS if int(o.get("bait", 0)) > 0 else CRAB_SECONDS)
		changed = true
	o["catch"] = catch_list
	return changed

static func crab_period(o: Dictionary) -> float:
	return CRAB_BAIT_SECONDS if int(o.get("bait", 0)) > 0 else CRAB_SECONDS
