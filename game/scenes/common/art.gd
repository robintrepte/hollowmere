class_name Art
extends RefCounted
## Cached texture lookups for every kind of game art, with graceful fallbacks.

const HAIR_STYLES := ["short", "long", "ponytail", "spiky", "bob", "buzz", "curly", "bun"]
const FRAME := Vector2i(32, 48)
const DOLL_COLS := 15
const SEASON_ROW_COUNT := 22

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

static func hat_layer(style: String) -> Texture2D:
	return doll_layer("hat_" + style)

static func hair_layer(style: int) -> Texture2D:
	return doll_layer("hair_" + HAIR_STYLES[clampi(style, 0, HAIR_STYLES.size() - 1)])

## Runtime TileSet: source 0 = ground (4 variants x 20 rows),
## 1 = soil (16 connected-side masks x 32 rows: inner corners, plus 16 when watered),
## 2 = water edges (16 land-side masks x 64 rows: diagonal corners + variant * 16),
## 3 = ground spilling onto a lower neighbor (16 side masks x 176 rows:
##     11 terrains x 16 corner masks; block order is World.SPILL_BLOCK),
## 4 = dirt bank spilling off water onto the neighboring land,
## 5 = shore caps (land color outside a rounded water corner; 6 terrains x 64 rows).
static func tileset(season: String) -> TileSet:
	if _tilesets.has(season):
		return _tilesets[season]
	var ts := TileSet.new()
	ts.tile_size = Vector2i(Tiles.TILE, Tiles.TILE)
	_add_atlas(ts, "res://assets/tiles/ground_%s.png" % season, 4, SEASON_ROW_COUNT, 0)
	_add_atlas(ts, "res://assets/tiles/soil.png", 16, 32, 1)
	_add_atlas(ts, "res://assets/tiles/water_edge.png", 16, 64, 2)
	_add_atlas(ts, "res://assets/tiles/grass_edge_%s.png" % season, 16, 176, 3)
	_add_atlas(ts, "res://assets/tiles/shore_fringe.png", 16, 16, 4)
	_add_atlas(ts, "res://assets/tiles/shore_cap_%s.png" % season, 16, 448, 5)
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

## 16×16 brand mark for the account panel (drawn, not shipped as a file). Only "tretu" draws a
## mark (the Tretu-Konto is the only account sign-in); other ids give an empty icon.
static func social_icon(id: String) -> Texture2D:
	var key := "social:" + id
	if _cache.has(key):
		return _cache[key]
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	if id == "tretu":
		_social_tretu(img)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex

static func _px(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < 16 and y < 16:
		img.set_pixel(x, y, c)

## Tretu-Konto: a rounded tile with a white T.
static func _social_tretu(img: Image) -> void:
	var bg := Color("#2f8f7a")
	var hi := Color("#45b39b")
	for y in range(2, 14):
		for x in range(2, 14):
			var corner := (x == 2 or x == 13) and (y == 2 or y == 13)
			if not corner:
				_px(img, x, y, hi if y < 4 else bg)
	for x in range(4, 12):
		_px(img, x, 4, Color.WHITE)
		_px(img, x, 5, Color.WHITE)
	for y in range(6, 12):
		_px(img, 7, y, Color.WHITE)
		_px(img, 8, y, Color.WHITE)

static func color(hex: String, fallback: Color = Color.WHITE) -> Color:
	if hex == "" or not Color.html_is_valid(hex):
		return fallback
	return Color(hex)
