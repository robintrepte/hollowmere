class_name FarmGrid
extends RefCounted
## Persistent state of a farmable map: terrain, debris, soil, crops, fruit trees
## and placed objects (chests, machines, sprinklers, decor).

var map_id: String = ""
var w: int = 0
var h: int = 0
var ground: PackedInt32Array = PackedInt32Array()
var deco: PackedInt32Array = PackedInt32Array()
var soil: Dictionary = {}      # key -> {watered, watered_until, tilled_at, fert, crop:{id, progress, tier, harvests, quality_boost, pollinated}}
var objects: Dictionary = {}   # key -> {id, kind, ...}
var fences: Dictionary = {}    # expansion id -> Array of keys
var tillable: Array = []
var greenhouse: bool = false
var trenches: Dictionary = {}  # key -> true for tiles dug with the shovel (dry dirt or flowing water)
var bucket_until: Dictionary = {}  # dry trench key -> unix time a poured bucket keeps it wet
## Tiles this close (Manhattan) to water or a wet trench never need watering.
const WATER_RANGE := 4
## How far water flows along a dug trench from its source.
const TRENCH_REACH := 8
const BUCKET_SECONDS := 24 * 3600
var _wet: Dictionary = {}
var _wet_dirty := true

func setup(width: int, height: int) -> void:
	w = width
	h = height
	ground.resize(w * h)
	deco.resize(w * h)
	ground.fill(0)
	deco.fill(0)

func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < w and p.y < h

func idx(p: Vector2i) -> int:
	return p.y * w + p.x

func get_ground(p: Vector2i) -> int:
	return ground[idx(p)] if in_bounds(p) else 35

func get_deco(p: Vector2i) -> int:
	return deco[idx(p)] if in_bounds(p) else 35

func set_deco(p: Vector2i, id: int) -> void:
	if in_bounds(p):
		deco[idx(p)] = id

func is_tilled(p: Vector2i) -> bool:
	return soil.has(Tiles.key(p))

func soil_at(p: Vector2i) -> Dictionary:
	return soil.get(Tiles.key(p), {})

func crop_at(p: Vector2i) -> Dictionary:
	return soil_at(p).get("crop", {})

func object_at(p: Vector2i) -> Dictionary:
	return objects.get(Tiles.key(p), {})

func is_blocked(p: Vector2i) -> bool:
	if Tiles.blocks(get_ground(p), get_deco(p)):
		return true
	var o := object_at(p)
	return not o.is_empty()

func can_till(p: Vector2i) -> bool:
	if not in_bounds(p) or is_tilled(p) or get_deco(p) != 0 or not object_at(p).is_empty():
		return false
	var gname := ""
	for n in Tiles.GROUND:
		if Tiles.GROUND[n] == get_ground(p):
			gname = n
	return gname in tillable

func till(p: Vector2i, now: float = -1.0) -> bool:
	if not can_till(p):
		return false
	var k := Tiles.key(p)
	soil[k] = {"watered": _wet_tiles().has(k), "watered_until": 0.0, "tilled_at": _now(now), "fert": ""}
	return true

static func _now(now: float) -> float:
	return now if now >= 0.0 else TimeService.now()

## Clears tilled soil that has nothing planted. A crop stays put.
func until(p: Vector2i) -> bool:
	if not is_tilled(p) or not crop_at(p).is_empty():
		return false
	soil.erase(Tiles.key(p))
	return true

## Waters a tile for CropGrowth.WATER_SECONDS. False if it's still wet or never dries out.
func water(p: Vector2i, now: float = -1.0, seconds: float = CropGrowth.WATER_SECONDS) -> bool:
	if not is_tilled(p):
		return false
	now = _now(now)
	var k := Tiles.key(p)
	var s: Dictionary = soil[k]
	if _wet_tiles().has(k) or float(s.get("watered_until", 0.0)) - now > seconds * 0.5:
		return false
	s.watered_until = now + seconds
	s.watered = true
	return true

func is_watered(p: Vector2i, now: float = -1.0) -> bool:
	var k := Tiles.key(p)
	if not soil.has(k):
		return false
	return _wet_tiles().has(k) or float(soil[k].get("watered_until", 0.0)) > _now(now)

## Near water, a flowing trench or a sprinkler: stays watered on its own.
func is_always_wet(p: Vector2i) -> bool:
	return _wet_tiles().has(Tiles.key(p))

## Every crop grows in every season now; the season only changes speed and yield.
func can_plant(p: Vector2i, seed_id: String, _season: String = "") -> bool:
	if not is_tilled(p) or not crop_at(p).is_empty():
		return false
	var it: Dictionary = Data.get_item(seed_id)
	return it.has("crop") and Data.crops.has(it.crop)

## `tier` 1..4 (Common .. Everlasting) sets how many harvests the plant gives before it's spent.
func plant(p: Vector2i, seed_id: String, _season: String = "", tier: int = 1) -> bool:
	if not can_plant(p, seed_id):
		return false
	var it: Dictionary = Data.get_item(seed_id)
	tier = clampi(tier, 1, 4)
	soil[Tiles.key(p)]["crop"] = {"id": it.crop, "progress": 0.0, "tier": tier, "harvests": CropGrowth.harvests_for_tier(tier), "pollinated": false, "quality_boost": 0}
	return true

func fertilize(p: Vector2i, fert: String) -> bool:
	if not is_tilled(p):
		return false
	var s: Dictionary = soil[Tiles.key(p)]
	if s.fert != "" or (not crop_at(p).is_empty() and float(crop_at(p).progress) > 0.05):
		return false
	s.fert = fert
	return true

func crop_ready(p: Vector2i) -> bool:
	var c := crop_at(p)
	if c.is_empty():
		return false
	return float(c.progress) >= 1.0

## 0..4 growth stage (4 = ready) for rendering.
func crop_stage(p: Vector2i) -> int:
	var c := crop_at(p)
	if c.is_empty():
		return -1
	return stage_of(float(c.progress))

static func stage_of(progress: float) -> int:
	if progress >= 1.0:
		return 4
	return clampi(int(progress * 4.0), 0, 3)

## Seconds until the crop on `p` is ripe if conditions stay as they are now.
func crop_eta(p: Vector2i, season: String, mult: float = 1.0, now: float = -1.0) -> float:
	var c := crop_at(p)
	if c.is_empty():
		return 0.0
	return CropGrowth.eta(c.id, float(c.progress), season, is_watered(p, now), str(soil_at(p).get("fert", "")), greenhouse, mult)

## Harvests a ready crop. The plant stays and grows again until its seed tier's harvests are used up.
## Returns {id, n, q, spent} or {}.
func harvest(p: Vector2i, rng: RandomNumberGenerator, luck: float = 0.0, skill: int = 0, season: String = "", yield_mult: float = 1.0) -> Dictionary:
	if not crop_ready(p):
		return {}
	var s: Dictionary = soil[Tiles.key(p)]
	var c: Dictionary = s.crop
	var yf := CropGrowth.season_yield(c.id, season, greenhouse) if season != "" else 1.0
	var q := roll_quality(s.fert, bool(c.pollinated), int(c.get("quality_boost", 0)), (luck + 0.02) * yf - 0.02, skill, rng)
	var n := CropGrowth.roll_amount((1.0 + 0.1 + luck) * yf * yield_mult, rng)
	var left := int(c.get("harvests", -1))
	var spent := false
	if left > 0:
		left -= 1
		c.harvests = left
		spent = left == 0
	if spent:
		s.erase("crop")
	else:
		c.progress = CropGrowth.regrow_progress(c.id)
		c.pollinated = false
	return {"id": c.id, "n": n, "q": q, "spent": spent}

static func roll_quality(fert: String, pollinated: bool, boost: int, luck: float, skill: int, rng: RandomNumberGenerator) -> int:
	var lvl: int = int({"": 0, "speed": 0, "quality1": 1, "quality2": 2}.get(fert, 0))
	var gold := 0.02 + 0.12 * lvl + (0.15 if pollinated else 0.0) + 0.05 * boost + luck + 0.01 * skill
	var r := rng.randf()
	if lvl >= 2 and r < gold * 0.25:
		return 3
	if r < gold:
		return 2
	if r < gold * 2.0 + 0.1:
		return 1
	return 0

## Clears debris on a tile with a tool. Returns {ok, drops:[[id,n]], energy} or {ok:false, reason}
func clear_debris(p: Vector2i, tool: String, tool_level: int, rng: RandomNumberGenerator) -> Dictionary:
	var d := get_deco(p)
	if not Tiles.DEBRIS.has(d):
		return {"ok": false, "reason": ""}
	var info: Dictionary = Tiles.DEBRIS[d]
	if info.tool != tool and not (d == 31):
		return {"ok": false, "reason": ""}
	if tool_level < int(info.min):
		return {"ok": false, "reason": tr("Your %s isn't strong enough. Upgrade it at the Forge.") % Data.item_name(tool)}
	var drops: Array = []
	for dr in info.drops:
		var n := rng.randi_range(int(dr[1]), int(dr[2]))
		if n > 0:
			drops.append([dr[0], n])
	set_deco(p, 0)
	return {"ok": true, "drops": drops, "energy": int(info.energy)}

func place_object(p: Vector2i, item_id: String) -> bool:
	if not in_bounds(p) or is_blocked(p) or is_tilled(p) and Data.get_item(item_id).get("place", "") != "sprinkler":
		return false
	var it: Dictionary = Data.get_item(item_id)
	var kind: String = it.get("place", "")
	if it.get("cat", "") == "sapling":
		kind = "tree"
	if kind == "":
		return false
	if kind == "tree":
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				var o := object_at(p + Vector2i(dx, dy))
				if o.get("kind", "") == "tree":
					return false
	var obj := {"id": item_id, "kind": kind}
	match kind:
		"chest":
			obj["inv"] = Inventory.new(8, 6).to_dict()
		"machine":
			obj["input"] = ""
			obj["output"] = {}
			obj["ready_at"] = 0
		"tree":
			obj["tree"] = it.tree
			obj["planted_at"] = TimeService.now()
			obj["fruit_at"] = 0.0
			obj["fruit"] = 0
	if is_tilled(p):
		if not crop_at(p).is_empty():
			return false
		soil.erase(Tiles.key(p))
	objects[Tiles.key(p)] = obj
	if kind == "sprinkler":
		_wet_dirty = true
	return true

func remove_object(p: Vector2i) -> Dictionary:
	var k := Tiles.key(p)
	if not objects.has(k):
		return {}
	var o: Dictionary = objects[k]
	objects.erase(k)
	if o.get("kind", "") == "sprinkler":
		_wet_dirty = true
	return o

func sprinkler_tiles(p: Vector2i, item_id: String) -> Array:
	var it: Dictionary = Data.get_item(item_id)
	var r: int = int(it.get("radius", 1))
	var out: Array = []
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			if dx == 0 and dy == 0:
				continue
			if it.get("shape", "square") == "plus" and abs(dx) + abs(dy) > 1:
				continue
			out.append(p + Vector2i(dx, dy))
	return out

func open_expansion(exp_id: String) -> void:
	for k in fences.get(exp_id, []):
		var p := Tiles.parse_key(k)
		if get_deco(p) == Tiles.DECO.fence:
			set_deco(p, 0)
	fences.erase(exp_id)

func planted_tiles() -> Array:
	var out: Array = []
	for k in soil:
		if soil[k].has("crop"):
			out.append(Tiles.parse_key(k))
	return out

## Real-time update from `from_t` to `to_t` (unix seconds). Growth is integrated piece by piece:
## watered then dry, and across real season changes. Returns the keys of tiles whose look changed.
## `ctx` = {season_at: Callable(unix) -> String, mult: float}
func advance(from_t: float, to_t: float, ctx: Dictionary) -> Array:
	var changed: Array = []
	if to_t <= from_t:
		return changed
	var season_at: Callable = ctx.season_at
	var mult := float(ctx.get("mult", 1.0))
	var wet := _wet_tiles()
	_refresh_trenches(to_t)
	for k in soil.keys():
		var s: Dictionary = soil[k]
		var always := wet.has(k)
		var until := float(s.get("watered_until", 0.0))
		if s.has("crop"):
			var c: Dictionary = s.crop
			var before := stage_of(float(c.progress))
			var prog := float(c.progress)
			var t := from_t
			while t < to_t and prog < 1.0:
				var seg_end := minf(to_t, Seasons.next_change(t) if Seasons.override == "" else to_t)
				var season: String = season_at.call(t)
				var wet_s := (seg_end - t) if always else clampf(until - t, 0.0, seg_end - t)
				prog += CropGrowth.rate(c.id, season, true, s.fert, greenhouse, mult) * wet_s
				prog += CropGrowth.rate(c.id, season, false, s.fert, greenhouse, mult) * (seg_end - t - wet_s)
				t = seg_end
			c.progress = minf(1.0, prog)
			if stage_of(float(c.progress)) != before:
				changed.append(k)
		elif not always and not greenhouse and s.fert == "" and to_t - maxf(float(s.get("tilled_at", 0.0)), until) > CropGrowth.BARE_SOIL_SECONDS:
			soil.erase(k)
			changed.append(k)
			continue
		var w := always or until > to_t
		if bool(s.get("watered", false)) != w:
			s.watered = w
			if not k in changed:
				changed.append(k)
	for k in objects:
		var o: Dictionary = objects[k]
		if o.kind != "tree":
			continue
		var td: Dictionary = Data.trees.get(o.tree, {})
		var ripe_at := float(o.get("planted_at", 0.0)) + float(td.get("days", 10)) * CropGrowth.TREE_DAY_SECONDS
		if to_t < ripe_at:
			continue
		if float(o.get("fruit_at", 0.0)) <= 0.0:
			o.fruit_at = ripe_at + CropGrowth.FRUIT_SECONDS
		var bearing: bool = greenhouse or str(season_at.call(to_t)) in td.get("seasons", [])
		if not bearing:
			o.fruit_at = to_t + CropGrowth.FRUIT_SECONDS
			continue
		var before_f := int(o.get("fruit", 0))
		while int(o.fruit) < 3 and float(o.fruit_at) <= to_t:
			o.fruit = int(o.fruit) + 1
			o.fruit_at = float(o.fruit_at) + CropGrowth.FRUIT_SECONDS
		if int(o.fruit) >= 3:
			o.fruit_at = maxf(float(o.fruit_at), to_t)
		if int(o.fruit) != before_f:
			changed.append(k)
	return changed

## 0..1 growth of a fruit tree; 1 = mature.
static func tree_growth(o: Dictionary, now: float) -> float:
	var td: Dictionary = Data.trees.get(o.get("tree", ""), {})
	return clampf((now - float(o.get("planted_at", now))) / (float(td.get("days", 10)) * CropGrowth.TREE_DAY_SECONDS), 0.0, 1.0)

## Rain soaks every outdoor tile for a while.
func rain(now: float) -> void:
	if greenhouse:
		return
	for k in soil:
		soil[k].watered_until = maxf(float(soil[k].get("watered_until", 0.0)), now + CropGrowth.WATER_SECONDS)
		soil[k].watered = true

## Once per game day: crows raid big unguarded fields.
func night(rng: RandomNumberGenerator, guarded: bool) -> Dictionary:
	var report := {"crow": 0}
	if greenhouse or guarded:
		return report
	var planted := planted_tiles()
	if planted.size() >= 16 and rng.randf() < 0.5:
		var target: Vector2i = planted[rng.randi() % planted.size()]
		for k in objects:
			if objects[k].kind == "scarecrow":
				var sp := Tiles.parse_key(k)
				if sp.distance_to(target) <= float(Data.get_item(objects[k].id).get("radius", 8)):
					return report
		soil[Tiles.key(target)].erase("crop")
		report.crow += 1
	return report

## Weeds slowly creep back on open grass.
func creep_weeds(rng: RandomNumberGenerator, tries: int) -> Array:
	var out: Array = []
	if greenhouse:
		return out
	var grass_id: int = Tiles.GROUND.grass
	for i in tries:
		var p := Vector2i(rng.randi_range(1, w - 2), rng.randi_range(1, h - 2))
		if get_ground(p) == grass_id and get_deco(p) == 0 and not is_tilled(p) and object_at(p).is_empty() and rng.randf() < 0.5:
			set_deco(p, Tiles.DECO.weed)
			out.append(p)
	return out

# --- Water ------------------------------------------------------------------------------

func invalidate_water() -> void:
	_wet_dirty = true

## Tiles that stay watered by themselves: within WATER_RANGE of water or a flowing trench,
## or covered by a sprinkler.
func _wet_tiles() -> Dictionary:
	if not _wet_dirty:
		return _wet
	_wet_dirty = false
	_wet = {}
	if greenhouse or w == 0:
		_add_sprinklers()
		return _wet
	var sources: Array = []
	for y in h:
		for x in w:
			if ground[y * w + x] in Tiles.WATER_TILES:
				sources.append(Vector2i(x, y))
	var r := WATER_RANGE
	for src in sources:
		for dy in range(-r, r + 1):
			var span := r - absi(dy)
			for dx in range(-span, span + 1):
				var q: Vector2i = src + Vector2i(dx, dy)
				if in_bounds(q):
					_wet[Tiles.key(q)] = true
	_add_sprinklers()
	return _wet

func _add_sprinklers() -> void:
	for k in objects:
		var o: Dictionary = objects[k]
		if o.get("kind", "") == "sprinkler":
			for t in sprinkler_tiles(Tiles.parse_key(k), o.id):
				_wet[Tiles.key(t)] = true

func is_natural_water(p: Vector2i) -> bool:
	return get_ground(p) in Tiles.WATER_TILES and not trenches.has(Tiles.key(p))

func can_dig_trench(p: Vector2i) -> bool:
	if not in_bounds(p) or greenhouse or trenches.has(Tiles.key(p)) or get_deco(p) != 0 or not object_at(p).is_empty() or is_tilled(p):
		return false
	return get_ground(p) in [Tiles.GROUND.grass, Tiles.GROUND.dirt, Tiles.GROUND.tallgrass, Tiles.GROUND.flowers, Tiles.GROUND.darkgrass]

func dig_trench(p: Vector2i, now: float = -1.0) -> bool:
	if not can_dig_trench(p):
		return false
	trenches[Tiles.key(p)] = int(ground[idx(p)])
	ground[idx(p)] = Tiles.GROUND.dirt
	_refresh_trenches(_now(now))
	return true

func fill_trench(p: Vector2i, now: float = -1.0) -> bool:
	var k := Tiles.key(p)
	if not trenches.has(k):
		return false
	ground[idx(p)] = int(trenches[k]) if int(trenches[k]) not in Tiles.WATER_TILES else Tiles.GROUND.grass
	trenches.erase(k)
	bucket_until.erase(k)
	_refresh_trenches(_now(now))
	return true

func pour_bucket(p: Vector2i, now: float = -1.0) -> bool:
	var k := Tiles.key(p)
	if not trenches.has(k) or get_ground(p) in Tiles.WATER_TILES:
		return false
	bucket_until[k] = _now(now) + BUCKET_SECONDS
	_refresh_trenches(_now(now))
	return true

func is_trench(p: Vector2i) -> bool:
	return trenches.has(Tiles.key(p))

## Water flows from natural water (and freshly poured buckets) along connected trenches up to
## TRENCH_REACH tiles. Trenches that lose their source dry out. Returns true if any tile changed.
func _refresh_trenches(now: float) -> bool:
	if trenches.is_empty():
		return false
	var dist: Dictionary = {}
	var queue: Array = []
	for k in trenches:
		var p := Tiles.parse_key(k)
		var fed := float(bucket_until.get(k, 0.0)) > now
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if is_natural_water(p + d):
				fed = true
		if fed:
			dist[k] = 1
			queue.append(p)
	while not queue.is_empty():
		var p: Vector2i = queue.pop_front()
		var dd: int = dist[Tiles.key(p)]
		if dd >= TRENCH_REACH:
			continue
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nk := Tiles.key(p + d)
			if trenches.has(nk) and not dist.has(nk):
				dist[nk] = dd + 1
				queue.append(p + d)
	var changed := false
	for k in trenches:
		var p := Tiles.parse_key(k)
		var want: int = Tiles.GROUND.water if dist.has(k) else Tiles.GROUND.dirt
		if ground[idx(p)] != want:
			ground[idx(p)] = want
			changed = true
	for k in bucket_until.keys():
		if float(bucket_until[k]) <= now:
			bucket_until.erase(k)
	if changed:
		_wet_dirty = true
	return changed

func shake_tree(p: Vector2i) -> Dictionary:
	var o := object_at(p)
	if o.get("kind", "") != "tree" or int(o.get("fruit", 0)) <= 0:
		return {}
	var n: int = int(o.fruit)
	o.fruit = 0
	return {"id": o.tree, "n": n}

func to_dict() -> Dictionary:
	return {
		"map_id": map_id, "w": w, "h": h, "ground": Array(ground), "deco": Array(deco),
		"soil": soil.duplicate(true), "objects": objects.duplicate(true), "fences": fences.duplicate(true),
		"tillable": tillable, "greenhouse": greenhouse, "trenches": trenches.duplicate(), "bucket_until": bucket_until.duplicate(),
	}

static func from_dict(d: Dictionary) -> FarmGrid:
	var g := FarmGrid.new()
	g.map_id = d.get("map_id", "")
	g.w = int(d.w)
	g.h = int(d.h)
	g.ground = PackedInt32Array(d.ground)
	g.deco = PackedInt32Array(d.deco)
	g.soil = d.get("soil", {}).duplicate(true)
	for k in g.soil:
		if g.soil[k].has("crop"):
			fix_crop_types(g.soil[k].crop)
	g.objects = d.get("objects", {}).duplicate(true)
	g.fences = d.get("fences", {}).duplicate(true)
	g.tillable = d.get("tillable", [])
	g.greenhouse = bool(d.get("greenhouse", false))
	g.trenches = d.get("trenches", {}).duplicate()
	g.bucket_until = d.get("bucket_until", {}).duplicate()
	return g

## JSON turns ints into floats; restores the crop's field types after a sync or load.
static func fix_crop_types(c: Dictionary) -> void:
	c.progress = float(c.get("progress", 0.0))
	c.tier = int(c.get("tier", 1))
	c.harvests = int(c.get("harvests", CropGrowth.harvests_for_tier(int(c.tier))))
