class_name FarmGrid
extends RefCounted
## Persistent state of a farmable map: terrain, debris, soil, crops, fruit trees
## and placed objects (chests, machines, sprinklers, decor).

var map_id: String = ""
var w: int = 0
var h: int = 0
var ground: PackedInt32Array = PackedInt32Array()
var deco: PackedInt32Array = PackedInt32Array()
var soil: Dictionary = {}      # key -> {watered, fert, crop:{id, age, quality_boost, pollinated}}
var objects: Dictionary = {}   # key -> {id, kind, ...}
var fences: Dictionary = {}    # expansion id -> Array of keys
var tillable: Array = []
var greenhouse: bool = false
## Chance an empty, unwatered, unfertilized tile reverts overnight (not in the greenhouse, and not on a rainy night).
const BARE_SOIL_REVERT := 0.5

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

func till(p: Vector2i) -> bool:
	if not can_till(p):
		return false
	soil[Tiles.key(p)] = {"watered": false, "fert": ""}
	return true

## Clears tilled soil that has nothing planted. A crop stays put.
func until(p: Vector2i) -> bool:
	if not is_tilled(p) or not crop_at(p).is_empty():
		return false
	soil.erase(Tiles.key(p))
	return true

func water(p: Vector2i) -> bool:
	if not is_tilled(p):
		return false
	var s: Dictionary = soil[Tiles.key(p)]
	if s.watered:
		return false
	s.watered = true
	return true

func can_plant(p: Vector2i, seed_id: String, season: String) -> bool:
	if not is_tilled(p) or not crop_at(p).is_empty():
		return false
	var it: Dictionary = Data.get_item(seed_id)
	if not it.has("crop"):
		return false
	var c: Dictionary = Data.crops[it.crop]
	return greenhouse or season in c.seasons

func plant(p: Vector2i, seed_id: String, season: String) -> bool:
	if not can_plant(p, seed_id, season):
		return false
	var it: Dictionary = Data.get_item(seed_id)
	soil[Tiles.key(p)]["crop"] = {"id": it.crop, "age": 0.0, "pollinated": false, "quality_boost": 0}
	return true

func fertilize(p: Vector2i, fert: String) -> bool:
	if not is_tilled(p):
		return false
	var s: Dictionary = soil[Tiles.key(p)]
	if s.fert != "" or (not crop_at(p).is_empty() and crop_at(p).age > 0):
		return false
	s.fert = fert
	return true

func crop_ready(p: Vector2i) -> bool:
	var c := crop_at(p)
	if c.is_empty():
		return false
	return float(c.age) >= float(Data.crops[c.id].days)

## 0..4 growth stage (4 = ready) for rendering.
func crop_stage(p: Vector2i) -> int:
	var c := crop_at(p)
	if c.is_empty():
		return -1
	var days := float(Data.crops[c.id].days)
	if float(c.age) >= days:
		return 4
	return clampi(int(float(c.age) / days * 4.0), 0, 3)

## Harvests a ready crop. Returns {id, n, q} or {}.
func harvest(p: Vector2i, rng: RandomNumberGenerator, luck: float = 0.0, skill: int = 0) -> Dictionary:
	if not crop_ready(p):
		return {}
	var s: Dictionary = soil[Tiles.key(p)]
	var c: Dictionary = s.crop
	var cd: Dictionary = Data.crops[c.id]
	var q := roll_quality(s.fert, bool(c.pollinated), int(c.get("quality_boost", 0)), luck, skill, rng)
	var n := 1
	if rng.randf() < 0.1 + luck:
		n += 1
	if cd.regrow > 0:
		c.age = float(cd.days - cd.regrow)
		c.pollinated = false
	else:
		s.erase("crop")
	return {"id": c.id, "n": n, "q": q}

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
			obj["age"] = 0
			obj["fruit"] = 0
	if is_tilled(p):
		if not crop_at(p).is_empty():
			return false
		soil.erase(Tiles.key(p))
	objects[Tiles.key(p)] = obj
	return true

func remove_object(p: Vector2i) -> Dictionary:
	var k := Tiles.key(p)
	if not objects.has(k):
		return {}
	var o: Dictionary = objects[k]
	objects.erase(k)
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

## Overnight update. Returns a report with crows and dead crop counts.
func new_day(season: String, prev_season: String, weather: String, rng: RandomNumberGenerator, protect_frost: int, guarded: bool) -> Dictionary:
	var report := {"crow": 0, "withered": 0, "fruit": 0}
	var season_changed := season != prev_season
	var rained := not greenhouse and Calendar.weather_waters(weather)
	var keys := soil.keys()
	keys.sort()
	for k in keys:
		var s: Dictionary = soil[k]
		if s.has("crop"):
			var c: Dictionary = s.crop
			if s.watered:
				var inc := 1.0
				if s.fert == "speed":
					inc = 1.25
				c.age = float(c.age) + inc
			if season_changed and not greenhouse and not (season in Data.crops[c.id].seasons):
				if protect_frost > 0:
					protect_frost -= 1
				else:
					s.erase("crop")
					report.withered += 1
		elif not s.watered and not rained and s.fert == "" and rng.randf() < BARE_SOIL_REVERT and not greenhouse:
			soil.erase(k)
			continue
		s.watered = false
	if rained:
		for k in soil:
			soil[k].watered = true
	for k in objects:
		var o: Dictionary = objects[k]
		if o.kind == "sprinkler":
			for t in sprinkler_tiles(Tiles.parse_key(k), o.id):
				water(t)
	# Crows
	if not greenhouse and not guarded:
		var planted := planted_tiles()
		if planted.size() >= 16 and rng.randf() < 0.5:
			var target: Vector2i = planted[rng.randi() % planted.size()]
			var protected := false
			for k in objects:
				if objects[k].kind == "scarecrow":
					var sp := Tiles.parse_key(k)
					if sp.distance_to(target) <= float(Data.get_item(objects[k].id).get("radius", 8)):
						protected = true
						break
			if not protected:
				soil[Tiles.key(target)].erase("crop")
				report.crow += 1
	# Fruit trees
	for k in objects:
		var o: Dictionary = objects[k]
		if o.kind == "tree":
			var td: Dictionary = Data.trees[o.tree]
			o.age = int(o.age) + 1
			if int(o.age) >= int(td.days) and (season in td.seasons or greenhouse):
				if int(o.fruit) < 3:
					o.fruit = int(o.fruit) + 1
					report.fruit += 1
			elif season_changed and not (season in td.seasons):
				o.fruit = 0
	# Weeds slowly creep back on open grass
	if not greenhouse:
		var grass_id: int = Tiles.GROUND.grass
		for i in 6:
			var p := Vector2i(rng.randi_range(1, w - 2), rng.randi_range(1, h - 2))
			if get_ground(p) == grass_id and get_deco(p) == 0 and not is_tilled(p) and object_at(p).is_empty() and rng.randf() < 0.5:
				set_deco(p, Tiles.DECO.weed)
	return report

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
		"tillable": tillable, "greenhouse": greenhouse,
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
			g.soil[k].crop.age = float(g.soil[k].crop.age)
	g.objects = d.get("objects", {}).duplicate(true)
	g.fences = d.get("fences", {}).duplicate(true)
	g.tillable = d.get("tillable", [])
	g.greenhouse = bool(d.get("greenhouse", false))
	return g
