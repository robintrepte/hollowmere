class_name MapBuilder
extends RefCounted
## Builds map layouts: hand-authored op lists (farm, town) and procedural
## regions / mine floors. Output: {grid: FarmGrid, warps, objects, spawn, ...}

const BIOMES := {
	"grass":    {"base": "grass",     "tree": "tree",        "accent": "tallgrass", "border": "tree",    "water": "water", "extra": "flowers", "rock": "rock"},
	"forest":   {"base": "darkgrass", "tree": "tree",        "accent": "tallgrass", "border": "tree",    "water": "water", "extra": "bush",    "rock": "stump"},
	"beach":    {"base": "sand",      "tree": "palm",        "accent": "tallgrass", "border": "palm",    "water": "water", "extra": "rock",    "rock": "rock"},
	"volcanic": {"base": "ash",       "tree": "deadtree",    "accent": "tallgrass", "border": "cliff",   "water": "lava",  "extra": "rock",    "rock": "boulder"},
	"canyon":   {"base": "canyon",    "tree": "boulder",     "accent": "tallgrass", "border": "cliff",   "water": "water", "extra": "rock",    "rock": "rock"},
	"cliffs":   {"base": "grass",     "tree": "pine",        "accent": "tallgrass", "border": "cliff",   "water": "water", "extra": "rock",    "rock": "boulder"},
	"marsh":    {"base": "marsh",     "tree": "deadtree",    "accent": "tallgrass", "border": "tree",    "water": "water", "extra": "bush",    "rock": "stump"},
	"snow":     {"base": "snow",      "tree": "pine",        "accent": "tallgrass", "border": "pine",    "water": "ice",   "extra": "iceblock","rock": "rock"},
	"twilight": {"base": "twilight",  "tree": "crystaltree", "accent": "tallgrass", "border": "crystaltree", "water": "water", "extra": "flowers", "rock": "rock"},
}
const RETURN_POINTS := {
	"whisperwood": ["town", 23, 1], "tidecove": ["town", 46, 16], "meadow": ["town", 23, 32],
}

static func build(map_id: String, world_seed: int) -> Dictionary:
	if Data.regions.has(map_id):
		return build_region(map_id, world_seed)
	if map_id.begins_with("deep:"):
		return Mining.build_layer(Mining.layer_of(map_id), world_seed)
	if map_id.begins_with("mine:"):
		var parts := map_id.split(":")
		return build_mine(parts[1], int(parts[2]), world_seed, int(parts[3]) if parts.size() > 3 else 0)
	return build_authored(Data.get_map(map_id))

static func _put(g: FarmGrid, p: Vector2i, name: String) -> void:
	if not g.in_bounds(p):
		return
	var id := Tiles.id_of(name)
	if id < 0:
		return
	if Tiles.is_deco(id):
		g.deco[g.idx(p)] = id
	else:
		g.ground[g.idx(p)] = id

static func build_authored(m: Dictionary) -> Dictionary:
	var g := FarmGrid.new()
	g.map_id = m.id
	g.setup(int(m.w), int(m.h))
	g.tillable = m.get("tillable", [])
	g.greenhouse = bool(m.get("greenhouse", false))
	var base_id := Tiles.id_of(m.get("base", "grass"))
	g.ground.fill(base_id)
	var border := Tiles.id_of(m.get("border", "tree"))
	for x in g.w:
		for y in g.h:
			if x == 0 or y == 0 or x == g.w - 1 or y == g.h - 1:
				if Tiles.is_deco(border):
					g.deco[g.idx(Vector2i(x, y))] = border
				else:
					g.ground[g.idx(Vector2i(x, y))] = border
	for op in m.get("ops", []):
		match op[0]:
			"rect":
				for x in range(int(op[2]), int(op[2]) + int(op[4])):
					for y in range(int(op[3]), int(op[3]) + int(op[5])):
						var p := Vector2i(x, y)
						_put(g, p, op[1])
						if not Tiles.is_deco(Tiles.id_of(op[1])) and g.in_bounds(p):
							var d := g.get_deco(p)
							if d != border or (x > 0 and y > 0 and x < g.w - 1 and y < g.h - 1):
								g.set_deco(p, 0)
			"open":
				_open_side(g, op[1], int(op[2]), int(op[3]), base_id)
			"scatter":
				var rng := RandomNumberGenerator.new()
				rng.seed = int(op[7])
				for x in range(int(op[2]), int(op[2]) + int(op[4])):
					for y in range(int(op[3]), int(op[3]) + int(op[5])):
						var p2 := Vector2i(x, y)
						if not g.in_bounds(p2) or x == 0 or y == 0 or x >= g.w - 1 or y >= g.h - 1:
							continue
						if g.get_ground(p2) != base_id or g.get_deco(p2) != 0:
							continue
						if rng.randf() < float(op[6]):
							_put(g, p2, op[1])
			"clear":
				for x in range(int(op[1]), int(op[1]) + int(op[3])):
					for y in range(int(op[2]), int(op[2]) + int(op[4])):
						g.set_deco(Vector2i(x, y), 0)
			"fence":
				var keys: Array = g.fences.get(op[1], [])
				for x in range(int(op[2]), int(op[2]) + int(op[4])):
					for y in range(int(op[3]), int(op[3]) + int(op[5])):
						var p3 := Vector2i(x, y)
						g.set_deco(p3, Tiles.DECO.fence)
						keys.append(Tiles.key(p3))
				g.fences[op[1]] = keys
			"pier":
				_pier(g, int(op[1]), int(op[2]), int(op[3]), int(op[4]))
			"clearpath":
				for i in g.ground.size():
					if g.ground[i] != base_id and g.ground[i] != Tiles.GROUND.flowers:
						if g.deco[i] != border or true:
							var px := i % g.w
							var py := int(i / g.w)
							if px > 0 and py > 0 and px < g.w - 1 and py < g.h - 1:
								g.deco[i] = 0
	var objects: Array = m.get("objects", []).duplicate(true)
	_clear_object_areas(g, objects)
	for wp in m.get("warps", []):
		for x in range(int(wp.x), int(wp.x) + int(wp.get("w", 1))):
			for y in range(int(wp.y), int(wp.y) + int(wp.get("h", 1))):
				g.set_deco(Vector2i(x, y), 0)
	for patch in m.get("patches", []):
		apply_patch(g, patch.ops)
	var out := {
		"id": m.id, "name": m.get("name", m.id), "grid": g, "warps": m.get("warps", []), "objects": objects,
		"spawn": m.get("spawn", [2, 2]), "music": m.get("music", "town"), "farm": bool(m.get("farm", false)),
		"seasonal": bool(m.get("seasonal", false)), "indoor": bool(m.get("indoor", false)), "biome": m.get("biome", "grass"), "region": "",
	}
	for k in ["spawns", "levels", "water", "water_zones", "guests", "guest_count", "guest_lines"]:
		if m.has(k):
			out[k] = m[k]
	return out

## Wooden walkway over water (the pier rails and posts are drawn by the world).
static func _pier(g: FarmGrid, x0: int, y0: int, w: int, h: int) -> void:
	for x in range(x0, x0 + w):
		for y in range(y0, y0 + h):
			var p := Vector2i(x, y)
			if g.in_bounds(p):
				g.ground[g.idx(p)] = Tiles.GROUND.bridge
				g.set_deco(p, 0)

## Later map changes for saved grids: water and piers, skipping tiles the player has built on.
static func apply_patch(g: FarmGrid, ops: Array) -> void:
	for op in ops:
		for x in range(int(op[2]), int(op[2]) + int(op[4])):
			for y in range(int(op[3]), int(op[3]) + int(op[5])):
				var p := Vector2i(x, y)
				if not g.in_bounds(p) or g.is_tilled(p) or not g.object_at(p).is_empty() or g.get_deco(p) == Tiles.DECO.fence:
					continue
				var gid := Tiles.id_of(str(op[1]))
				if gid < 0 or Tiles.is_deco(gid):
					continue
				g.ground[g.idx(p)] = gid
				g.set_deco(p, 0)

static func _open_side(g: FarmGrid, side: String, start: int, length: int, base_id: int) -> void:
	for i in range(start, start + length):
		var p: Vector2i
		match side:
			"n": p = Vector2i(i, 0)
			"s": p = Vector2i(i, g.h - 1)
			"w": p = Vector2i(0, i)
			"e": p = Vector2i(g.w - 1, i)
		g.set_deco(p, 0)
		var gr := g.get_ground(p)
		if gr == Tiles.GROUND.cave or gr in Tiles.BLOCKING_GROUND or not Tiles.is_deco(gr) and gr != base_id and gr != Tiles.GROUND.path and gr != Tiles.GROUND.wood:
			pass
		var inner := p
		match side:
			"n": inner = Vector2i(i, 1)
			"s": inner = Vector2i(i, g.h - 2)
			"w": inner = Vector2i(1, i)
			"e": inner = Vector2i(g.w - 2, i)
		g.ground[g.idx(p)] = g.get_ground(inner)

static func _clear_object_areas(g: FarmGrid, objects: Array) -> void:
	for o in objects:
		var ow := int(o.get("w", 1))
		var oh := int(o.get("h", 1))
		if o.type == "fountain" or o.type == "wayshrine" or o.type == "shrine":
			ow = 2
			oh = 2
		for x in range(int(o.x) - 1, int(o.x) + ow + 1):
			for y in range(int(o.y), int(o.y) + oh + 1):
				var p := Vector2i(x, y)
				if g.in_bounds(p) and x > 0 and y > 0 and x < g.w - 1 and y < g.h - 1:
					if g.get_deco(p) != Tiles.DECO.fence:
						g.set_deco(p, 0)

# --- Procedural regions --------------------------------------------------------

static func build_region(region_id: String, world_seed: int) -> Dictionary:
	var r: Dictionary = Data.regions[region_id]
	var bio: Dictionary = BIOMES.get(r.biome, BIOMES.grass)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([int(r.seed), world_seed, "region"])
	var g := FarmGrid.new()
	g.map_id = region_id
	g.setup(48, 34)
	var base := Tiles.id_of(bio.base)
	var border := Tiles.id_of(bio.border)
	var tree := Tiles.id_of(bio.tree)
	g.ground.fill(base)
	# Value-noise style blobs for trees, water and tall grass.
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = 0.09
	var noise2 := FastNoiseLite.new()
	noise2.seed = rng.randi()
	noise2.frequency = 0.12
	for x in g.w:
		for y in g.h:
			var p := Vector2i(x, y)
			var edge: bool = x <= 1 or y <= 1 or x >= g.w - 2 or y >= g.h - 2
			if edge:
				if Tiles.is_deco(border):
					g.set_deco(p, border)
				else:
					g.ground[g.idx(p)] = border
				continue
			var n := noise.get_noise_2d(x, y)
			var n2 := noise2.get_noise_2d(x, y)
			if n > 0.35:
				g.set_deco(p, tree)
			elif n < -0.45:
				_put(g, p, bio.water)
			elif n2 > 0.25:
				g.ground[g.idx(p)] = Tiles.GROUND.tallgrass
			elif rng.randf() < 0.03:
				_put(g, p, bio.extra)
			elif rng.randf() < 0.02:
				_put(g, p, bio.rock)
	if r.biome == "beach":
		for x in range(2, g.w - 2):
			for y in range(26, g.h - 2):
				g.ground[g.idx(Vector2i(x, y))] = Tiles.GROUND.water
				g.set_deco(Vector2i(x, y), 0)
	# Main path from west entrance to east shrine, meandering.
	var y_cur := 17
	var path_tile := Tiles.GROUND.path if r.biome != "beach" else Tiles.GROUND.sand
	if r.biome in ["snow", "volcanic", "canyon", "twilight"]:
		path_tile = Tiles.GROUND.path
	for x in range(0, g.w - 1):
		if x % 6 == 0 and x > 4 and x < 36:
			y_cur = clampi(y_cur + rng.randi_range(-2, 2), 10, 22)
		for dy in [0, 1]:
			var p2 := Vector2i(x, y_cur + dy)
			g.ground[g.idx(p2)] = path_tile
			g.set_deco(p2, 0)
		if x < 4:
			y_cur = 17
	var zones: Array = []
	if r.has("river"):
		var rx := int(r.river)
		for x in range(rx, rx + 3):
			for y in range(2, g.h - 2):
				var pr := Vector2i(x, y)
				g.ground[g.idx(pr)] = Tiles.GROUND.bridge if g.get_ground(pr) == path_tile else Tiles.GROUND.water
				g.set_deco(pr, 0)
		zones.append(["river", rx, 0, 3, g.h])
	if r.has("lake"):
		_lake(g, Vector2i(int(r.lake[0]), int(r.lake[1])), 4.2, 2.7)
	# Entrance clearing
	for x in range(0, 5):
		for y in range(15, 20):
			var p3 := Vector2i(x, y)
			if x == 0 and (y < 16 or y > 17):
				continue
			g.set_deco(p3, 0)
			if g.get_ground(p3) in Tiles.BLOCKING_GROUND or g.get_ground(p3) == Tiles.GROUND.ice:
				g.ground[g.idx(p3)] = base
	var objects: Array = []
	var warps: Array = []
	var ret: Array = RETURN_POINTS.get(region_id, ["town", 21, 15])
	warps.append({"x": 0, "y": 16, "w": 1, "h": 2, "to": ret[0], "tx": ret[1], "ty": ret[2]})
	# Shrine clearing at the east
	if r.has("warden"):
		for x in range(36, 46):
			for y in range(12, 23):
				var p4 := Vector2i(x, y)
				g.set_deco(p4, 0)
				g.ground[g.idx(p4)] = Tiles.GROUND.plaza if (x >= 40 and x <= 44 and y >= 14 and y <= 19) else (base if g.get_ground(p4) != Tiles.GROUND.path else Tiles.GROUND.path)
		objects.append({"type": "shrine", "x": 42, "y": 14, "region": region_id})
	else:
		for x in range(40, 46):
			for y in range(14, 21):
				g.set_deco(Vector2i(x, y), 0)
	# Wayshrine near entrance for fast travel
	objects.append({"type": "wayshrine", "x": 3, "y": 13})
	for x in range(2, 6):
		for y in range(12, 16):
			g.set_deco(Vector2i(x, y), 0)
			if g.get_ground(Vector2i(x, y)) in Tiles.BLOCKING_GROUND:
				g.ground[g.idx(Vector2i(x, y))] = base
	# Cave entrance
	if r.has("mine"):
		var cx := rng.randi_range(18, 30)
		var cy := 5 if rng.randf() < 0.5 else 28
		if r.biome == "beach":
			cy = 5
		for x in range(cx - 2, cx + 3):
			for y in range(cy - 1, cy + 3):
				var p5 := Vector2i(x, y)
				g.set_deco(p5, 0)
				if g.get_ground(p5) in Tiles.BLOCKING_GROUND:
					g.ground[g.idx(p5)] = base
		g.set_deco(Vector2i(cx, cy), Tiles.DECO.cave_entrance)
		_carve_path(g, Vector2i(cx, cy + (1 if cy < 17 else -1)), y_cur, base)
		objects.append({"type": "cave", "x": cx, "y": cy, "region": region_id})
	return {
		"id": region_id, "name": r.name, "grid": g, "warps": warps, "objects": objects, "spawn": [1, 17],
		"music": r.get("music", "route"), "farm": false, "seasonal": r.biome in ["grass", "forest", "cliffs"],
		"indoor": false, "biome": r.biome, "region": region_id, "spawns": r.spawns, "levels": r.levels,
		"water_zones": zones,
	}

## An oval lake with a short pier from its north shore.
static func _lake(g: FarmGrid, c: Vector2i, rx: float, ry: float) -> void:
	for x in range(c.x - ceili(rx), c.x + ceili(rx) + 1):
		for y in range(c.y - ceili(ry), c.y + ceili(ry) + 1):
			var p := Vector2i(x, y)
			var d := pow((x - c.x) / rx, 2) + pow((y - c.y) / ry, 2)
			if d <= 1.0 and g.in_bounds(p) and x > 1 and y > 1 and x < g.w - 2 and y < g.h - 2:
				g.ground[g.idx(p)] = Tiles.GROUND.water
				g.set_deco(p, 0)
	var top := c.y - floori(ry)
	for y in range(top - 1, c.y + 1):
		var p := Vector2i(c.x, y)
		g.ground[g.idx(p)] = Tiles.GROUND.bridge
		g.set_deco(p, 0)
	for x in range(c.x - 1, c.x + 2):
		g.set_deco(Vector2i(x, top - 2), 0)

static func _carve_path(g: FarmGrid, from: Vector2i, target_y: int, base: int) -> void:
	var p := from
	var guard := 0
	while guard < 60:
		guard += 1
		g.set_deco(p, 0)
		if g.get_ground(p) in Tiles.BLOCKING_GROUND or g.get_ground(p) == Tiles.GROUND.ice:
			g.ground[g.idx(p)] = base
		if g.get_ground(p) == Tiles.GROUND.path:
			break
		p.y += 1 if p.y < target_y else -1
		if p.y <= 1 or p.y >= g.h - 2:
			break

# --- Mines ---------------------------------------------------------------------

static func build_mine(region_id: String, floor_n: int, world_seed: int, day_index: int) -> Dictionary:
	var r: Dictionary = Data.regions[region_id]
	var mine: Dictionary = r.mine
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, region_id, floor_n, day_index, "mine"])
	var g := FarmGrid.new()
	g.map_id = "mine:%s:%d" % [region_id, floor_n]
	g.setup(32, 22)
	g.ground.fill(Tiles.GROUND.cave)
	# Cellular automata caves
	var solid := PackedByteArray()
	solid.resize(g.w * g.h)
	for i in solid.size():
		var x := i % g.w
		var y := int(i / g.w)
		solid[i] = 1 if (x == 0 or y == 0 or x == g.w - 1 or y == g.h - 1 or rng.randf() < 0.42) else 0
	for step in 4:
		var nxt := solid.duplicate()
		for y in range(1, g.h - 1):
			for x in range(1, g.w - 1):
				var c := 0
				for dy in [-1, 0, 1]:
					for dx in [-1, 0, 1]:
						if dx != 0 or dy != 0:
							c += solid[(y + dy) * g.w + x + dx]
				nxt[y * g.w + x] = 1 if c >= 5 else (0 if c <= 3 else solid[y * g.w + x])
		solid = nxt
	# Guarantee a connected corridor from entrance to ladder.
	var entry := Vector2i(2, g.h / 2)
	var ladder := Vector2i(g.w - 3, rng.randi_range(3, g.h - 4))
	var p := entry
	while p != ladder:
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var q := p + Vector2i(dx, dy)
				if q.x > 0 and q.y > 0 and q.x < g.w - 1 and q.y < g.h - 1:
					solid[q.y * g.w + q.x] = 0
		if rng.randf() < 0.6 and p.x != ladder.x:
			p.x += signi(ladder.x - p.x)
		elif p.y != ladder.y:
			p.y += signi(ladder.y - p.y)
		else:
			p.x += signi(ladder.x - p.x)
	var ore_types := {}
	var ores: Array = mine.ores
	var depth_bonus := float(floor_n) / 30.0
	var rock := _mine_rock(int(r.order), floor_n)
	for i in solid.size():
		var cell := Vector2i(i % g.w, int(i / g.w))
		if solid[i] == 1:
			if cell.x == 0 or cell.y == 0 or cell.x == g.w - 1 or cell.y == g.h - 1:
				g.deco[i] = Tiles.DECO.cavewall
			else:
				g.deco[i] = rock[0] if rng.randf() < 0.7 else rock[1]
		elif cell.distance_to(entry) > 2.5 and cell.distance_to(ladder) > 1.5:
			var roll := rng.randf()
			if roll < 0.03 + depth_bonus * 0.03:
				g.deco[i] = Tiles.DECO.ore
				var idx_o := mini(ores.size() - 1, int(pow(rng.randf(), 1.6 - minf(depth_bonus, 1.0)) * ores.size()))
				ore_types[Tiles.key(cell)] = ores[idx_o]
			elif roll < 0.16:
				g.deco[i] = Tiles.DECO.rock
	if floor_n % 5 == 0 or rng.randf() < 0.3:
		_cave_lake(g, rng, entry, ladder)
	_mine_veins(g, rng, ores, depth_bonus, ore_types)
	g.set_deco(entry, Tiles.DECO.ladder_up)
	var objects: Array = []
	var bottom := Adventure.is_bottom(region_id, floor_n)
	if bottom:
		g.set_deco(ladder, 0)
		objects.append({"type": "treasure", "x": ladder.x, "y": ladder.y, "grand": true})
	else:
		g.set_deco(ladder, Tiles.DECO.ladder)
	if rng.randf() < 0.35:
		for tries in 30:
			var tp := Vector2i(rng.randi_range(3, g.w - 4), rng.randi_range(2, g.h - 3))
			if g.get_deco(tp) == 0 and tp != ladder and tp.distance_to(entry) > 2.0:
				objects.append({"type": "treasure", "x": tp.x, "y": tp.y, "mimic": rng.randf() < 0.25 and int(r.order) >= 4})
				break
	var lv: Array = r.levels
	var lvl_min: int = int(lv[1]) + floor_n
	return {
		"id": g.map_id, "name": "%s B%d" % [mine.name, floor_n], "grid": g, "warps": [], "objects": objects,
		"spawn": [entry.x + 1, entry.y], "music": "cave", "farm": false, "seasonal": false, "indoor": true,
		"biome": "cave", "region": region_id, "spawns": mine.spawns, "levels": [lvl_min, lvl_min + 3],
		"mine": true, "floor": floor_n, "max_floor": int(mine.floors), "ore_types": ore_types, "ladder": [ladder.x, ladder.y], "entry": [entry.x, entry.y],
		"bottom": bottom,
	}

## Breakable rock for a regional mine: softer near the village, harder in later regions and deeper floors.
static func _mine_rock(order: int, floor_n: int) -> Array:
	var tier := order / 2 + floor_n / 10
	match clampi(tier, 0, 3):
		0:
			return [Tiles.DECO.stoneblock, Tiles.DECO.dirtblock]
		1:
			return [Tiles.DECO.stoneblock, Tiles.DECO.deepstone]
		2:
			return [Tiles.DECO.deepstone, Tiles.DECO.stoneblock]
	return [Tiles.DECO.deepstone, Tiles.DECO.basalt]

## Ore and gems show up as veins in the walls, mostly where the rock meets the open floor.
static func _mine_veins(g: FarmGrid, rng: RandomNumberGenerator, ores: Array, depth_bonus: float, ore_types: Dictionary) -> void:
	var minable: Array = []
	for o in ores:
		if Mining.ORES.has(o):
			minable.append(o)
	if minable.is_empty():
		return
	for y in range(1, g.h - 1):
		for x in range(1, g.w - 1):
			var p := Vector2i(x, y)
			var d := g.get_deco(p)
			if not d in [Tiles.DECO.stoneblock, Tiles.DECO.dirtblock, Tiles.DECO.deepstone, Tiles.DECO.basalt]:
				continue
			if not Mining._touches_open(g, p) or rng.randf() > 0.07 + depth_bonus * 0.04:
				continue
			var o: String = minable[mini(minable.size() - 1, int(pow(rng.randf(), 1.6 - minf(depth_bonus, 1.0)) * minable.size()))]
			g.set_deco(p, Tiles.DECO.vein)
			ore_types[Tiles.key(p)] = o

## Floods a pocket of cave wall next to open floor, so the paths through the floor stay as they were.
static func _cave_lake(g: FarmGrid, rng: RandomNumberGenerator, entry: Vector2i, ladder: Vector2i) -> void:
	for tries in 40:
		var c := Vector2i(rng.randi_range(3, g.w - 4), rng.randi_range(3, g.h - 4))
		if not Mining.BLOCKS.has(g.get_deco(c)) or c.distance_to(entry) < 5.0 or c.distance_to(ladder) < 4.0:
			continue
		var opens := false
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if g.get_deco(c + d) == 0:
				opens = true
		if not opens:
			continue
		for x in range(c.x - 2, c.x + 3):
			for y in range(c.y - 2, c.y + 3):
				var p := Vector2i(x, y)
				if x <= 0 or y <= 0 or x >= g.w - 1 or y >= g.h - 1 or Vector2(p - c).length() > 2.3:
					continue
				if Mining.BLOCKS.has(g.get_deco(p)):
					g.set_deco(p, 0)
					g.ground[g.idx(p)] = Tiles.GROUND.water
		return

## Picks a spawn entry for current conditions. Returns species id or "".
static func pick_spawn(spawns: Array, season: String, weather: String, night: bool, rng: RandomNumberGenerator, bonus: Array = []) -> String:
	var pool: Array = []
	var total := 0.0
	for e in spawns:
		var cond: Dictionary = e[2] if e.size() > 2 else {}
		if cond.has("s") and not season in cond.s:
			continue
		if cond.has("w") and not weather in cond.w:
			continue
		if cond.has("t"):
			if cond.t == "night" and not night:
				continue
			if cond.t == "day" and night:
				continue
		pool.append(e)
		total += float(e[1])
	for b in bonus:
		pool.append([b, 25])
		total += 25.0
	if pool.is_empty():
		return ""
	var r := rng.randf() * total
	for e in pool:
		r -= float(e[1])
		if r <= 0.0:
			return e[0]
	return pool[0][0]
