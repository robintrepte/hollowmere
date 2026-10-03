class_name Tiles
extends RefCounted
## Tile registry shared by map building, farming and rendering.
## Ground tiles live on layer 0; deco tiles (ids >= DECO_START) on layer 1.

const TILE := 32
const ATLAS_COLS := 8
const DECO_START := 24

const GROUND := {
	"grass": 0, "tallgrass": 1, "path": 2, "sand": 3, "water": 4, "plaza": 5, "cave": 6, "snow": 7,
	"ice": 8, "dirt": 9, "bridge": 10, "flowers": 11, "ash": 12, "marsh": 13, "twilight": 14,
	"canyon": 15, "lava": 16, "wood": 17, "darkgrass": 18, "deepwater": 19,
}
const DECO := {
	"tree": 24, "pine": 25, "palm": 26, "deadtree": 27, "crystaltree": 28, "rock": 29, "boulder": 30,
	"weed": 31, "branch": 32, "stump": 33, "fence": 34, "cliff": 35, "cavewall": 36, "bush": 37,
	"iceblock": 38, "ore": 39, "ladder": 40, "cave_entrance": 41, "ladder_up": 42,
}
const BLOCKING_GROUND := [4, 16, 19]
const NON_BLOCKING_DECO := [31, 40, 41, 42]
const WATER_TILES := [4, 19]
## Debris: deco id -> {tool, min_level, drops: [[item, min, max]], energy}
const DEBRIS := {
	31: {"tool": "scythe", "min": 0, "drops": [["fiber", 1, 1]], "energy": 0},
	32: {"tool": "axe", "min": 0, "drops": [["wood", 1, 2]], "energy": 2},
	33: {"tool": "axe", "min": 1, "drops": [["hardwood", 2, 2]], "energy": 4},
	29: {"tool": "pickaxe", "min": 0, "drops": [["stone", 1, 1]], "energy": 2},
	30: {"tool": "pickaxe", "min": 2, "drops": [["stone", 15, 15]], "energy": 6},
	24: {"tool": "axe", "min": 0, "drops": [["wood", 8, 12], ["sap", 1, 3]], "energy": 4},
	25: {"tool": "axe", "min": 0, "drops": [["wood", 8, 12], ["sap", 1, 3]], "energy": 4},
	27: {"tool": "axe", "min": 0, "drops": [["wood", 4, 6]], "energy": 3},
	37: {"tool": "axe", "min": 0, "drops": [["wood", 1, 2], ["wild_berry", 0, 1]], "energy": 2},
	39: {"tool": "pickaxe", "min": 0, "drops": [], "energy": 3},
	38: {"tool": "pickaxe", "min": 0, "drops": [["stone", 1, 2]], "energy": 2},
}

static func id_of(name: String) -> int:
	if GROUND.has(name):
		return GROUND[name]
	return DECO.get(name, -1)

static func is_deco(id: int) -> bool:
	return id >= DECO_START

static func blocks(ground: int, deco: int) -> bool:
	if ground in BLOCKING_GROUND:
		return true
	return deco > 0 and not (deco in NON_BLOCKING_DECO)

static func atlas_coords(id: int) -> Vector2i:
	return Vector2i(id % ATLAS_COLS, int(id / ATLAS_COLS))

## Neighbor bitmask in soil-tile order: north=1, east=2, south=4, west=8.
static func neighbor_mask(origin: Vector2i, linked: Callable) -> int:
	var mask := 0
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for i in 4:
		if linked.call(origin + dirs[i]):
			mask |= 1 << i
	return mask

static func key(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]

static func parse_key(k: String) -> Vector2i:
	var parts := k.split(",")
	return Vector2i(int(parts[0]), int(parts[1]))
