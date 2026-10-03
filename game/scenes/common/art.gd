class_name Art
extends RefCounted
## Cached texture lookups for every kind of game art, with graceful fallbacks.

const HAIR_STYLES := ["short", "long", "ponytail", "spiky", "bob", "buzz", "curly", "bun"]
const FRAME := Vector2i(32, 48)
const DOLL_COLS := 7
const SEASON_ROW_COUNT := 20

static var _cache: Dictionary = {}
static var _tilesets: Dictionary = {}

static func tex(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path)
	_cache[path] = t
	return t

static func item(id: String) -> Texture2D:
	var key := "item:" + id
	if _cache.has(key):
		return _cache[key]
	var t := tex("res://assets/items/%s.png" % id.replace(":", "__"))
	if t == null:
		var it: Dictionary = Data.get_item(id)
		var base: String = it.get("base", "")
		if base != "":
			t = tex("res://assets/items/%s.png" % base)
		if t == null:
			t = tex("res://assets/items/_star.png")
	_cache[key] = t
	return t

static func creature(species: String, small: bool = false) -> Texture2D:
	var t := tex("res://assets/creatures/%s%s.png" % ["small/" if small else "", species])
	return t if t else tex("res://assets/creatures/%segg.png" % ("small/" if small else ""))

static func portrait(vid: String) -> Texture2D:
	return tex("res://assets/portraits/%s.png" % vid)

static func world(name: String) -> Texture2D:
	return tex("res://assets/world/%s.png" % name)

static func building(name: String) -> Texture2D:
	return tex("res://assets/buildings/%s.png" % name)

static func backdrop(biome: String) -> Texture2D:
	var t := tex("res://assets/battle/%s.png" % biome)
	return t if t else tex("res://assets/battle/grass.png")

static func doll_layer(layer: String) -> Texture2D:
	return tex("res://assets/characters/%s.png" % layer)

static func hair_layer(style: int) -> Texture2D:
	return doll_layer("hair_" + HAIR_STYLES[clampi(style, 0, HAIR_STYLES.size() - 1)])

## Runtime TileSet: source 0 = ground (4 variants x 20 rows), 1 = soil (16 masks x dry/wet), 2 = water edges,
## 3 = grass spilling onto bare ground (16 side masks x 16 corner masks).
static func tileset(season: String) -> TileSet:
	if _tilesets.has(season):
		return _tilesets[season]
	var ts := TileSet.new()
	ts.tile_size = Vector2i(Tiles.TILE, Tiles.TILE)
	_add_atlas(ts, "res://assets/tiles/ground_%s.png" % season, 4, SEASON_ROW_COUNT, 0)
	_add_atlas(ts, "res://assets/tiles/soil.png", 16, 2, 1)
	_add_atlas(ts, "res://assets/tiles/water_edge.png", 16, 1, 2)
	_add_atlas(ts, "res://assets/tiles/grass_edge_%s.png" % season, 16, 16, 3)
	_tilesets[season] = ts
	return ts

static func _add_atlas(ts: TileSet, path: String, cols: int, rows: int, id: int) -> void:
	var src := TileSetAtlasSource.new()
	src.texture = tex(path)
	src.texture_region_size = Vector2i(Tiles.TILE, Tiles.TILE)
	for y in rows:
		for x in cols:
			src.create_tile(Vector2i(x, y))
	ts.add_source(src, id)

static func color(hex: String, fallback: Color = Color.WHITE) -> Color:
	if hex == "" or not Color.html_is_valid(hex):
		return fallback
	return Color(hex)
