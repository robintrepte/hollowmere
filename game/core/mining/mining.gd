class_name Mining
extends RefCounted
## Breakable rock: block hardness, pickaxe power, drops, the five Deep Mine layers
## (data/mine_layers.json) and the compact per-layer diffs they save as.

const DEEP_W := 64
const DEEP_H := 48
const LANDING := Vector2i(5, 4)
const LADDER_UP := Vector2i(3, 3)
const ELEVATOR := Vector2i(7, 3)
const TIER_NAMES := ["Basic", "Copper", "Iron", "Gold", "Mystic", "Crystal"]

## Plain rock: hit points, lowest pickaxe level, energy per swing, tint for the wall sprite.
const BLOCKS := {
	43: {"hp": 1.0, "min": 0, "energy": 0.6, "tint": "#b08a62"},
	44: {"hp": 2.0, "min": 0, "energy": 1.0, "tint": "#c9c3d6"},
	45: {"hp": 3.5, "min": 1, "energy": 1.2, "tint": "#8a8aa8"},
	46: {"hp": 5.0, "min": 2, "energy": 1.4, "tint": "#6a5f68"},
	47: {"hp": 8.0, "min": 3, "energy": 1.6, "tint": "#4a3a6a"},
	50: {"hp": 2.0, "min": 0, "energy": 1.0, "tint": "#d8c8a0"},
}
## What a vein or crystal yields decides how hard it is.
const ORES := {
	"coal": {"hp": 2.0, "min": 0}, "copper_ore": {"hp": 2.5, "min": 0}, "iron_ore": {"hp": 3.5, "min": 1},
	"silver_ore": {"hp": 4.0, "min": 1}, "gold_ore": {"hp": 5.0, "min": 2}, "mithril_ore": {"hp": 6.5, "min": 3},
	"mystic_ore": {"hp": 8.0, "min": 4},
	"quartz": {"hp": 2.0, "min": 0}, "topaz": {"hp": 2.5, "min": 1}, "amethyst": {"hp": 3.0, "min": 1},
	"aquamarine": {"hp": 3.5, "min": 2}, "emerald": {"hp": 4.0, "min": 2}, "ruby": {"hp": 5.0, "min": 3},
	"diamond": {"hp": 6.0, "min": 4}, "glimmer_crystal": {"hp": 6.0, "min": 4},
}
const GEODE_LOOT := [["quartz", 30], ["topaz", 18], ["amethyst", 16], ["aquamarine", 10], ["emerald", 7],
	["ruby", 6], ["diamond", 2], ["glimmer_crystal", 2], ["amber_drop", 5], ["ancient_coin", 4]]
const MUSEUM := ["quartz", "topaz", "amethyst", "aquamarine", "emerald", "ruby", "diamond", "star_shard",
	"glimmer_crystal", "ammonite", "trilobite", "fern_fossil", "amber_drop", "ancient_coin", "sunken_idol", "obsidian"]
const MUSEUM_REWARDS := {4: {"money": 1000}, 8: {"geode": 5, "money": 2500}, 12: {"glimmer_crystal": 2, "money": 5000}, 16: {"crystal_bar": 3, "money": 10000}}

## Sound and debris style when a pick hits this block.
static func sound(deco: int) -> String:
	match deco:
		Tiles.DECO.dirtblock, Tiles.DECO.fossil:
			return "dig"
		Tiles.DECO.vein:
			return "clink"
		Tiles.DECO.crystal:
			return "crystal"
	return "rock"

static func is_block(deco: int) -> bool:
	return BLOCKS.has(deco) or deco == Tiles.DECO.vein or deco == Tiles.DECO.crystal

## Swing strength of a pickaxe level; a block breaks once the swings add up to its hp.
static func power(level: int) -> float:
	return 1.0 + 0.6 * level

static func tier_name(level: int) -> String:
	return TIER_NAMES[clampi(level, 0, TIER_NAMES.size() - 1)]

## {hp, min, energy} for the block at a tile; `what` is the vein/crystal item from ore_types.
static func block_spec(deco: int, what: String) -> Dictionary:
	if deco == Tiles.DECO.vein or deco == Tiles.DECO.crystal:
		var o: Dictionary = ORES.get(what, {"hp": 3.0, "min": 0})
		return {"hp": float(o.hp), "min": int(o.min), "energy": 1.2}
	return BLOCKS.get(deco, {})

## [[item, n], ...] for a broken block.
static func drops(deco: int, what: String, rng: RandomNumberGenerator, ore_luck: float, luck: float, fossils: Array = []) -> Array:
	var out: Array = []
	match deco:
		43:
			if rng.randf() < 0.3:
				out.append(["clay", 1])
			elif rng.randf() < 0.5:
				out.append(["stone", 1])
		44, 45, 46:
			out.append(["stone", 1 + (1 if deco >= 45 and rng.randf() < 0.5 else 0) + (1 if deco == 46 else 0)])
			if rng.randf() < 0.05 + 0.02 * (deco - 44):
				out.append(["coal", 1])
		47:
			out.append(["obsidian", 1])
		48:
			out.append([what, rng.randi_range(1, 2) + (1 if rng.randf() < ore_luck else 0)])
			if rng.randf() < 0.3:
				out.append(["stone", 1])
		49:
			out.append([what, 1 + (1 if rng.randf() < 0.15 + ore_luck * 0.5 else 0)])
		50:
			out.append([pick(fossils if not fossils.is_empty() else [["ammonite", 1]], rng), 1])
	if deco in [43, 44, 45, 46, 47] and rng.randf() < 0.025 + luck:
		out.append(["geode", 1])
	return out

static func pick(table: Array, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for e in table:
		total += float(e[1])
	var r := rng.randf() * total
	for e in table:
		r -= float(e[1])
		if r <= 0.0:
			return str(e[0])
	return str(table[-1][0]) if not table.is_empty() else ""

# --- Deep Mine ------------------------------------------------------------------

static func layer_count() -> int:
	return Data.mine_layers.size()

static func layer_spec(layer: int) -> Dictionary:
	return Data.mine_layers[layer - 1] if layer >= 1 and layer <= Data.mine_layers.size() else {}

static func layer_of(map_id: String) -> int:
	return int(map_id.substr(5)) if map_id.begins_with("deep:") else 0

static func build_layer(layer: int, world_seed: int) -> Dictionary:
	var L := layer_spec(layer)
	var g := FarmGrid.new()
	g.map_id = "deep:%d" % layer
	g.setup(DEEP_W, DEEP_H)
	g.ground.fill(Tiles.GROUND.cave)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, "deep", layer])
	var caves := FastNoiseLite.new()
	caves.seed = rng.randi()
	caves.frequency = 0.075
	caves.fractal_octaves = 3
	var mats := FastNoiseLite.new()
	mats.seed = rng.randi()
	mats.frequency = 0.04
	var materials: Array = L.get("materials", ["stoneblock", "stoneblock"])
	var values := PackedFloat32Array()
	values.resize(g.w * g.h)
	for i in values.size():
		values[i] = caves.get_noise_2d(i % g.w, int(i / g.w))
	var sorted := values.duplicate()
	sorted.sort()
	var open_at := sorted[clampi(int(sorted.size() * (1.0 - float(L.get("open", 0.35)))), 0, sorted.size() - 1)]
	for y in g.h:
		for x in g.w:
			var i := g.idx(Vector2i(x, y))
			if x == 0 or y == 0 or x == g.w - 1 or y == g.h - 1:
				g.deco[i] = Tiles.DECO.cavewall
			elif values[i] < open_at:
				g.deco[i] = Tiles.id_of(materials[0] if mats.get_noise_2d(x, y) < 0.12 else materials[1])
	var lake: Array = L.get("lake", [])
	if lake.size() == 4:
		var c := Vector2(float(lake[0]), float(lake[1]))
		for y in range(1, g.h - 1):
			for x in range(1, g.w - 1):
				var d := Vector2((x - c.x) / float(lake[2]), (y - c.y) / float(lake[3]))
				if d.length() < 1.0:
					g.deco[g.idx(Vector2i(x, y))] = 0
					g.ground[g.idx(Vector2i(x, y))] = Tiles.GROUND.water if d.length() < 0.85 else Tiles.GROUND.cave
	var liquid := Tiles.id_of(str(L.get("liquid", "water")))
	for n in int(L.get("pools", 0)):
		var pc := Vector2i(rng.randi_range(12, g.w - 6), rng.randi_range(6, g.h - 6))
		var rad := rng.randf_range(1.6, 3.2)
		for y in range(pc.y - 4, pc.y + 5):
			for x in range(pc.x - 4, pc.x + 5):
				var p := Vector2i(x, y)
				if x > 1 and y > 1 and x < g.w - 2 and y < g.h - 2 and Vector2(p - pc).length() < rad:
					g.deco[g.idx(p)] = 0
					g.ground[g.idx(p)] = liquid
	_room(g, LANDING, 3)
	g.set_deco(LADDER_UP, Tiles.DECO.ladder_up)
	g.set_deco(ELEVATOR, Tiles.DECO.elevator)
	var shaft := Vector2i(-1, -1)
	var boss: Dictionary = L.get("boss", {})
	if not boss.is_empty():
		var at := Vector2i(int(boss.at[0]), int(boss.at[1]))
		_room(g, at, 5)
		for y in range(at.y - 7, at.y + 8):
			for x in range(at.x - 7, at.x + 8):
				var p := Vector2i(x, y)
				var dist := Vector2(p - at).length()
				if g.in_bounds(p) and x > 0 and y > 0 and x < g.w - 1 and y < g.h - 1 and dist >= 5.5 and dist < 6.5:
					g.deco[g.idx(p)] = 0
					g.ground[g.idx(p)] = Tiles.GROUND.lava
		for x in range(at.x - 7, at.x + 1):
			g.ground[g.idx(Vector2i(x, at.y))] = Tiles.GROUND.cave
	elif layer < layer_count():
		shaft = Vector2i(rng.randi_range(44, g.w - 5), rng.randi_range(30, g.h - 5))
		_room(g, shaft, 1)
		g.set_deco(shaft, Tiles.DECO.ladder)
	var ore_types := {}
	var veins: Array = L.get("veins", [])
	var crystals: Array = L.get("crystals", [])
	for y in range(1, g.h - 1):
		for x in range(1, g.w - 1):
			var p := Vector2i(x, y)
			var i := g.idx(p)
			var d := int(g.deco[i])
			if BLOCKS.has(d) and d != 50:
				var near_open := _touches_open(g, p)
				if rng.randf() < float(L.get("vein_rate", 0.05)) * (1.0 if near_open else 0.5):
					g.deco[i] = Tiles.DECO.vein
					ore_types[Tiles.key(p)] = pick(veins, rng)
				elif rng.randf() < float(L.get("fossil_rate", 0.005)):
					g.deco[i] = Tiles.DECO.fossil
			elif d == 0 and g.get_ground(p) == Tiles.GROUND.cave and Vector2(p - LANDING).length() > 4.0:
				if _touches_wall(g, p) and rng.randf() < float(L.get("crystal_rate", 0.015)):
					g.deco[i] = Tiles.DECO.crystal
					ore_types[Tiles.key(p)] = pick(crystals, rng)
				elif rng.randf() < 0.03:
					g.deco[i] = Tiles.DECO.rock
	var info := {
		"id": g.map_id, "name": TranslationServer.translate(str(L.get("name", "Deep Mine"))), "grid": g, "warps": [], "objects": [],
		"spawn": [LANDING.x, LANDING.y + 1], "music": "deep", "farm": false, "seasonal": false, "indoor": true,
		"biome": "cave", "spawns": L.get("spawns", []), "levels": L.get("levels", [20, 25]), "mine": true, "deep": layer,
		"floor": layer * 5, "ore_types": ore_types, "dark": float(L.get("dark", 0.6)), "fossils": L.get("fossils", []),
		"shaft": [shaft.x, shaft.y],
	}
	if not boss.is_empty():
		info["boss"] = boss
	return info

static func _room(g: FarmGrid, c: Vector2i, r: int) -> void:
	for y in range(c.y - r, c.y + r + 1):
		for x in range(c.x - r, c.x + r + 1):
			var p := Vector2i(x, y)
			if x > 0 and y > 0 and x < g.w - 1 and y < g.h - 1 and Vector2(p - c).length() <= r + 0.5:
				g.deco[g.idx(p)] = 0
				g.ground[g.idx(p)] = Tiles.GROUND.cave

static func _touches_open(g: FarmGrid, p: Vector2i) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if g.in_bounds(p + d) and g.get_deco(p + d) == 0 and not g.get_ground(p + d) in Tiles.BLOCKING_GROUND:
			return true
	return false

static func _touches_wall(g: FarmGrid, p: Vector2i) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if g.in_bounds(p + d) and (BLOCKS.has(g.get_deco(p + d)) or g.get_deco(p + d) == Tiles.DECO.cavewall):
			return true
	return false

## Clears a 3x3 landing so a ladder between layers always has somewhere to arrive.
static func carve_arrival(g: FarmGrid, t: Vector2i, ladder: int) -> void:
	for y in range(t.y - 1, t.y + 2):
		for x in range(t.x - 1, t.x + 2):
			var p := Vector2i(x, y)
			if x > 0 and y > 0 and x < g.w - 1 and y < g.h - 1:
				if g.get_deco(p) != Tiles.DECO.elevator and g.get_deco(p) != Tiles.DECO.ladder:
					g.set_deco(p, 0)
				if g.get_ground(p) in Tiles.BLOCKING_GROUND:
					g.ground[g.idx(p)] = Tiles.GROUND.cave
	g.set_deco(t, ladder)

## A layer saves only what differs from its generated layout: XOR, deflate, base64.
static func encode_diff(base: FarmGrid, now: FarmGrid) -> String:
	var raw := PackedByteArray()
	raw.resize(now.ground.size() * 2)
	var dirty := false
	for i in now.ground.size():
		raw[i] = (int(now.ground[i]) ^ int(base.ground[i])) & 0xff
		raw[now.ground.size() + i] = (int(now.deco[i]) ^ int(base.deco[i])) & 0xff
		dirty = dirty or raw[i] != 0 or raw[now.ground.size() + i] != 0
	if not dirty:
		return ""
	return Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_DEFLATE))

static func apply_diff(g: FarmGrid, diff: String) -> void:
	if diff == "":
		return
	var n := g.ground.size()
	var raw := Marshalls.base64_to_raw(diff).decompress(n * 2, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != n * 2:
		return
	for i in n:
		g.ground[i] = int(g.ground[i]) ^ raw[i]
		g.deco[i] = int(g.deco[i]) ^ raw[n + i]
