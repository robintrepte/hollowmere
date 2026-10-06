class_name World
extends Node2D
## Renders one map (ground, soil, water edges, y-sorted deco/objects/buildings/actors)
## and answers spatial questions: collision, interactables, warps.

const T := Tiles.TILE
const DECO_SPRITES := {
	24: "tree", 25: "pine", 26: "palm", 27: "deadtree", 28: "crystaltree", 29: "rock", 30: "boulder",
	31: "weed", 32: "branch", 33: "stump", 34: "fence", 35: "cliff", 36: "cavewall", 37: "bush",
	38: "iceblock", 39: "ore_copper", 40: "ladder", 41: "cave_entrance", 42: "ladder_up",
	43: "block_dirt", 44: "block_stone", 45: "block_deep", 46: "block_basalt", 47: "block_obsidian",
	48: "block_stone", 49: "crystal", 50: "block_fossil", 51: "torch", 52: "support", 53: "rail", 54: "minecart", 55: "elevator",
	56: "wallpaper",
}
const FLAT_DECO := [40, 31, 53]
## Drawn by MineFx when there is no sprite for them.
const MINE_FX := {49: "crystal", 51: "torch", 52: "support", 53: "rail", 54: "minecart", 55: "elevator"}
const TRELLIS := ["green_bean", "tomato", "grape", "hot_pepper", "snowpea", "cranberry"]
const STALK := ["corn", "wheat", "sunflower", "amaranth"]
const FLOWERS := ["tulip", "blue_jazz", "fairy_rose", "ice_lily", "moonbloom"]
const BIG := ["melon", "pumpkin", "winter_squash", "glacier_melon"]
## Row block in grass_edge_<season>.png. Tallgrass and flowers are grass with
## something on top, so they share its rank and never fringe against the lawn.
## A higher rank creeps onto a lower one; the lip is the same ragged edge as path-to-grass.
const SPILL_BLOCK := {
	0: 0, 1: 0, 11: 0,
	18: 1,
	3: 2,
	9: 3,
	7: 4,
	12: 5,
	13: 6,
	14: 7,
	15: 8,
	2: 9,
	21: 10,
}
const SPILL_RANK := {
	0: 50, 1: 50, 11: 50, 18: 48,
	7: 40,
	3: 36, 9: 36, 12: 36, 13: 36, 14: 36, 15: 36,
	2: 30,
	21: 24,
	5: 20, 17: 18, 20: 16, 10: 14,
	8: 10, 16: 6,
}
const SPILL_BLOCKS := 11
## Row block in shore_cap_<season>.png for the land a pond corner should continue.
const CAP_OF := {
	0: 0, 1: 0, 11: 0, 7: 0,
	18: 1,
	3: 2,
	9: 3, 2: 3, 5: 3, 17: 3,
	13: 4,
	15: 5, 12: 5,
	6: 6,
}
const NEIGHBORS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const DIAGONALS := [Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1)]
const OBJECT_FOOTPRINT := {"ferry": Vector2i(2, 1), "fountain": Vector2i(2, 2), "wayshrine": Vector2i(1, 1), "board": Vector2i(1, 1), "show_ring": Vector2i(0, 0)}

var map_id := ""
var info: Dictionary = {}
var grid: FarmGrid
var season := "spring"

var ground: TileMapLayer
var shore_cap: TileMapLayer
var soil_layer: TileMapLayer
var edge_layer: TileMapLayer
var spill_layers: Array[TileMapLayer] = []
var decals: Node2D
var ysort: Node2D
var overlay: Node2D
var cursor: TargetCursor
var day_tint: CanvasModulate
var weather: WeatherFx
var water_fx: WaterFx

var _deco_nodes: Dictionary = {}     # key -> Sprite2D
var _object_nodes: Dictionary = {}   # key -> Node2D (grid objects + crops)
var _static_nodes: Array = []
var blockers: Dictionary = {}        # Vector2i -> true
var interactables: Dictionary = {}   # Vector2i -> Dictionary (authored map objects)
var npcs: Dictionary = {}            # vid -> Npc
var guests: Array = []               # unnamed ambience Npcs (casino guests, strollers)
var creatures: Array = []            # WildCreature nodes (wild + ranch)
var actors: Node2D
var astar: AStarGrid2D
var darkness: DarknessFx

func _ready() -> void:
	y_sort_enabled = false
	ground = TileMapLayer.new()
	ground.z_index = -10
	add_child(ground)
	shore_cap = TileMapLayer.new()
	shore_cap.z_index = -10
	add_child(shore_cap)
	edge_layer = TileMapLayer.new()
	edge_layer.z_index = -9
	add_child(edge_layer)
	for _i in SPILL_BLOCKS:
		var layer := TileMapLayer.new()
		layer.z_index = -9
		add_child(layer)
		spill_layers.append(layer)
	soil_layer = TileMapLayer.new()
	soil_layer.z_index = -8
	add_child(soil_layer)
	decals = Node2D.new()
	decals.z_index = -7
	add_child(decals)
	ysort = Node2D.new()
	ysort.y_sort_enabled = true
	add_child(ysort)
	actors = ysort
	overlay = Node2D.new()
	overlay.z_index = 50
	add_child(overlay)
	cursor = TargetCursor.new()
	cursor.z_index = 40
	add_child(cursor)
	day_tint = CanvasModulate.new()
	add_child(day_tint)
	weather = WeatherFx.new()
	add_child(weather)
	water_fx = WaterFx.new()
	add_child(water_fx)
	EventBus.tile_changed.connect(_on_tile_changed)
	EventBus.objects_changed.connect(_on_objects_changed)
	EventBus.time_changed.connect(_on_time)
	EventBus.popup.connect(_on_popup)
	EventBus.weather_changed.connect(func(_w): _apply_weather())
	EventBus.party_changed.connect(func():
		if map_id == "farm":
			_spawn_creatures())

# --- Loading --------------------------------------------------------------------------

func load_map(id: String) -> void:
	map_id = id
	info = GameState.map_info(id)
	grid = info.grid
	season = GameState.season() if info.get("seasonal", false) or info.get("region", "") != "" else "summer"
	if info.get("indoor", false):
		season = "summer"
	GameState.spawn_forage(id)
	for n in _deco_nodes.values():
		n.queue_free()
	for n in _object_nodes.values():
		n.queue_free()
	for n in _static_nodes:
		n.queue_free()
	for n in npcs.values():
		n.queue_free()
	for n in guests:
		n.queue_free()
	guests.clear()
	_deco_nodes.clear()
	_object_nodes.clear()
	_static_nodes.clear()
	_treasure_sprites.clear()
	npcs.clear()
	blockers.clear()
	interactables.clear()
	for c in decals.get_children():
		c.queue_free()
	var ts := Art.tileset(season)
	ground.tile_set = ts
	soil_layer.tile_set = ts
	edge_layer.tile_set = ts
	shore_cap.tile_set = ts
	for layer in spill_layers:
		layer.tile_set = ts
		layer.clear()
	ground.clear()
	edge_layer.clear()
	shore_cap.clear()
	soil_layer.clear()
	for y in grid.h:
		for x in grid.w:
			_draw_ground(Vector2i(x, y))
			_draw_deco(Vector2i(x, y))
	for k in grid.soil:
		_draw_soil(Tiles.parse_key(k))
	_build_static_objects()
	decals.add_child(PierRails.new(grid))
	for k in grid.objects:
		_draw_object(Tiles.parse_key(k))
	for k in grid.soil:
		_draw_crop(Tiles.parse_key(k))
	_build_astar()
	if darkness:
		darkness.queue_free()
		darkness = null
	if info.has("dark"):
		darkness = DarknessFx.new(self, float(info.dark))
		add_child(darkness)
	_spawn_npcs()
	_spawn_guests()
	_spawn_creatures()
	_on_time(GameState.minute())
	_apply_weather()
	if water_fx:
		water_fx.setup(self)

func map_size_px() -> Vector2:
	return Vector2(grid.w * T, grid.h * T)

func _variant(p: Vector2i) -> int:
	var hsh := (p.x * 73856093) ^ (p.y * 19349663)
	var r := absi(hsh) % 10
	return 0 if r < 4 else (1 if r < 7 else (2 if r < 9 else 3))

func _is_water_ground(p: Vector2i) -> bool:
	return grid.in_bounds(p) and grid.get_ground(p) in Tiles.WATER_TILES

func _is_shore_land(p: Vector2i) -> bool:
	return grid.in_bounds(p) and not grid.get_ground(p) in Tiles.WATER_TILES and grid.get_ground(p) != Tiles.GROUND.bridge

## Cardinal bits N=1 E=2 S=4 W=8. On water, a bit means that side faces land.
## On land, a bit means that side faces water.
func _shore_sides(p: Vector2i, on_water: bool) -> int:
	var m := 0
	for i in 4:
		var n: Vector2i = p + NEIGHBORS[i]
		if on_water:
			if _is_shore_land(n):
				m |= 1 << i
		elif _is_water_ground(n):
			m |= 1 << i
	return m

## Diagonal bits NE=1 SE=2 SW=4 NW=8, only when neither adjacent cardinal already covers that corner.
func _shore_corners(p: Vector2i, on_water: bool) -> int:
	var m := 0
	for i in 4:
		var d: Vector2i = DIAGONALS[i]
		var diag := p + d
		var ax := p + Vector2i(d.x, 0)
		var ay := p + Vector2i(0, d.y)
		if on_water:
			if _is_shore_land(diag) and not _is_shore_land(ax) and not _is_shore_land(ay):
				m |= 1 << i
		elif _is_water_ground(diag) and not _is_water_ground(ax) and not _is_water_ground(ay):
			m |= 1 << i
	return m

func _draw_ground(p: Vector2i) -> void:
	var gid := grid.get_ground(p)
	if gid >= Art.SEASON_ROW_COUNT or gid < 0:
		gid = 0
	ground.set_cell(p, 0, Vector2i(_variant(p), gid))
	shore_cap.erase_cell(p)
	_clear_spill(p)
	if gid in Tiles.WATER_TILES:
		var sides := _shore_sides(p, true)
		var corners := _shore_corners(p, true)
		if sides or corners:
			edge_layer.set_cell(p, 2, Vector2i(sides, corners + _variant(p) * 16))
			var cap := _shore_cap_row(p, sides, corners)
			if cap >= 0:
				shore_cap.set_cell(p, 5, Vector2i(sides, cap))
		else:
			edge_layer.erase_cell(p)
		return
	# No dirt fringe. The shore on the water tile is already the neighbor's ground color,
	# and a brown strip here was the dark ring that didn't match the grass.
	edge_layer.erase_cell(p)
	if SPILL_RANK.has(gid):
		_paint_spill(p, gid)


func _clear_spill(p: Vector2i) -> void:
	for layer in spill_layers:
		layer.erase_cell(p)


## Higher ground creeps onto this tile: grass onto a path, snow onto a path, a path onto plaza.
func _paint_spill(p: Vector2i, gid: int) -> void:
	var here := int(SPILL_RANK[gid])
	var sides := {}
	var corners := {}
	for i in 4:
		var b := _spill_block(p + NEIGHBORS[i], here)
		if b >= 0:
			sides[b] = int(sides.get(b, 0)) | (1 << i)
	for i in 4:
		var d: Vector2i = DIAGONALS[i]
		var b := _spill_block(p + d, here)
		if b < 0:
			continue
		if _spill_block(p + Vector2i(d.x, 0), here) == b or _spill_block(p + Vector2i(0, d.y), here) == b:
			continue
		corners[b] = int(corners.get(b, 0)) | (1 << i)
	var blocks := {}
	for b in sides:
		blocks[b] = true
	for b in corners:
		blocks[b] = true
	for b in blocks:
		spill_layers[int(b)].set_cell(p, 3, Vector2i(int(sides.get(b, 0)), int(corners.get(b, 0)) + int(b) * 16))


func _spill_block(p: Vector2i, here_rank: int) -> int:
	if not grid.in_bounds(p):
		return -1
	var ng := grid.get_ground(p)
	if int(SPILL_RANK.get(ng, -1)) <= here_rank:
		return -1
	return int(SPILL_BLOCK.get(ng, -1))

func _shore_cap_row(p: Vector2i, sides: int, corners: int) -> int:
	var gid := -1
	for i in 4:
		if sides & (1 << i) and CAP_OF.has(grid.get_ground(p + NEIGHBORS[i])):
			gid = grid.get_ground(p + NEIGHBORS[i])
			break
	if gid < 0:
		for i in 4:
			if corners & (1 << i) and CAP_OF.has(grid.get_ground(p + DIAGONALS[i])):
				gid = grid.get_ground(p + DIAGONALS[i])
				break
	if gid < 0:
		gid = 0
	return corners + _variant(p) * 16 + int(CAP_OF[gid]) * 64

func _draw_soil(p: Vector2i) -> void:
	if not grid.is_tilled(p):
		soil_layer.erase_cell(p)
		return
	var m := 0
	for i in 4:
		if grid.is_tilled(p + NEIGHBORS[i]):
			m |= 1 << i
	# Inner corners: both adjacent plots are tilled, the diagonal one is not. That notch gets rounded off.
	var corners := 0
	for i in 4:
		var d: Vector2i = DIAGONALS[i]
		if grid.is_tilled(p + Vector2i(d.x, 0)) and grid.is_tilled(p + Vector2i(0, d.y)) and not grid.is_tilled(p + d):
			corners |= 1 << i
	var row := corners + (16 if grid.soil_at(p).get("watered", false) else 0)
	soil_layer.set_cell(p, 1, Vector2i(m, row))

func _deco_sprite_name(p: Vector2i, d: int) -> String:
	var n: String = DECO_SPRITES.get(d, "")
	if d == Tiles.DECO.ore:
		var ore: String = info.get("ore_types", {}).get(Tiles.key(p), "copper_ore")
		n = "ore_" + ore.replace("_ore", "")
		if not ResourceLoader.exists("res://assets/world/%s.png" % n):
			n = "rock"
	elif d == Tiles.DECO.vein:
		for dir in NEIGHBORS:
			var nd := grid.get_deco(p + dir) if grid.in_bounds(p + dir) else 0
			if nd in [43, 44, 45, 46, 47]:
				return DECO_SPRITES[nd]
	elif d == Tiles.DECO.fence:
		n = "fence_%d" % _link_mask(p, "fence")
	return n

func _draw_deco(p: Vector2i) -> void:
	var k := Tiles.key(p)
	if _deco_nodes.has(k):
		_deco_nodes[k].queue_free()
		_deco_nodes.erase(k)
	var d := grid.get_deco(p)
	if d <= 0:
		return
	var tex := Art.world(_deco_sprite_name(p, d))
	var tint := Color.WHITE
	if tex == null and Mining.BLOCKS.has(d):
		tex = Art.world("cavewall")
		tint = Color(str(Mining.BLOCKS[d].tint))
	elif tex == null and d == Tiles.DECO.vein:
		tex = Art.world("cavewall")
		tint = Color(str(Mining.BLOCKS[44].tint))
	if tex == null and not MINE_FX.has(d):
		return
	var s := Sprite2D.new()
	s.texture = tex
	s.self_modulate = tint
	s.centered = false
	var sz := tex.get_size() if tex else Vector2.ZERO
	s.offset = Vector2(-sz.x / 2.0, -sz.y)
	s.position = Vector2(p.x * T + T / 2.0, p.y * T + T)
	_add_mine_fx(s, p, d, tex == null)
	if d in [24, 25, 37] and season != "summer":
		s.modulate = {"spring": Color(1, 1, 1), "fall": Color(1.0, 0.78, 0.5), "winter": Color(0.86, 0.9, 1.0)}.get(season, Color.WHITE)
	if d in FLAT_DECO:
		s.position.y -= 1
	if d == Tiles.DECO.ladder or d == Tiles.DECO.rail:
		decals.add_child(s)
	else:
		ysort.add_child(s)
	_deco_nodes[k] = s

func _add_mine_fx(s: Sprite2D, p: Vector2i, d: int, stand_in: bool) -> void:
	var what := str(info.get("ore_types", {}).get(Tiles.key(p), ""))
	var hsh := p.x * 7919 + p.y * 104729
	if d == Tiles.DECO.ore and s.texture == Art.world("rock"):
		s.add_child(MineFx.new("vein", Color(str(Data.get_item(what).get("color", "#d8804a"))), 1.0, hsh))
	elif d == Tiles.DECO.rail and not stand_in:
		s.centered = true
		s.offset = Vector2.ZERO
		s.position = Vector2(p.x * T + T / 2.0, p.y * T + T / 2.0)
		if grid.get_deco(p + Vector2i(0, -1)) == d or grid.get_deco(p + Vector2i(0, 1)) == d:
			s.rotation = PI / 2.0
	elif d == Tiles.DECO.vein:
		s.add_child(MineFx.new("vein", Color(str(Data.get_item(what).get("color", "#d8804a"))), 0.0, hsh))
	elif d == Tiles.DECO.crystal and stand_in:
		s.add_child(MineFx.new("crystal", Color(str(Data.get_item(what).get("color", "#f0f0f8"))), 0.0, hsh))
	elif d == Tiles.DECO.crystal:
		s.self_modulate = Color(str(Data.get_item(what).get("color", "#f0f0f8")))
	elif d == Tiles.DECO.rail and stand_in:
		var vertical := grid.get_deco(p + Vector2i(0, -1)) == d or grid.get_deco(p + Vector2i(0, 1)) == d
		s.add_child(MineFx.new("rail", Color.WHITE, 1.0 if vertical else 0.0))
	elif stand_in and MINE_FX.has(d):
		s.add_child(MineFx.new(MINE_FX[d]))
	var c := GameState.crack(map_id, p)
	if c > 0.0:
		s.add_child(MineFx.new("crack", Color.WHITE, c, hsh))

func _object_sprite_name(o: Dictionary, p: Vector2i) -> String:
	if o.kind == "tree":
		var frac := FarmGrid.tree_growth(o, TimeService.now())
		if frac >= 1.0:
			return "fruit_tree"
		return ["tree_stage0", "tree_stage1", "tree_stage2"][clampi(int(frac * 3.0), 0, 2)]
	if o.id == "picket_fence":
		return "picket_%d" % _link_mask(p, "picket_fence")
	return o.id

## Fence and picket pieces are numbered by Tiles.neighbor_mask (N=1 E=2 S=4 W=8).
func _link_mask(p: Vector2i, kind: String) -> int:
	return Tiles.neighbor_mask(p, _is_link.bind(kind))

func _is_link(n: Vector2i, kind: String) -> bool:
	if not grid.in_bounds(n):
		return false
	if kind == "fence":
		return grid.get_deco(n) == Tiles.DECO.fence
	return str(grid.object_at(n).get("id", "")) == kind

func _draw_object(p: Vector2i) -> void:
	var k := Tiles.key(p)
	if _object_nodes.has("o" + k):
		_object_nodes["o" + k].queue_free()
		_object_nodes.erase("o" + k)
	var o := grid.object_at(p)
	if o.is_empty():
		return
	var node := Node2D.new()
	node.position = Vector2(p.x * T + T / 2.0, p.y * T + T)
	if o.kind == "forage":
		var sh := Sprite2D.new()
		sh.texture = Art.item(o.id)
		sh.position = Vector2(0, -10)
		node.add_child(sh)
		var tw := node.create_tween().set_loops()
		tw.tween_property(sh, "position:y", -12.0, 0.8).set_trans(Tween.TRANS_SINE)
		tw.tween_property(sh, "position:y", -10.0, 0.8).set_trans(Tween.TRANS_SINE)
	else:
		var tex := Art.world(_object_sprite_name(o, p))
		if tex == null:
			tex = Art.item(o.id)
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		var sz := tex.get_size()
		s.offset = Vector2(-sz.x / 2.0, -sz.y)
		node.add_child(s)
		if o.kind == "tree" and int(o.get("fruit", 0)) > 0:
			var spots := [Vector2(-10, -40), Vector2(8, -46), Vector2(0, -30)]
			for i in mini(3, int(o.fruit)):
				var f := Sprite2D.new()
				f.texture = Art.item(o.tree)
				f.scale = Vector2(0.75, 0.75)
				f.position = spots[i]
				node.add_child(f)
		if o.kind == "crab_pot":
			s.offset.y += 6
			if not o.get("catch", []).is_empty() or TimeService.now() >= float(o.get("next_at", 0)):
				var pot_bubble := _bubble(Art.item("crab"))
				pot_bubble.position = Vector2(0, -sz.y)
				node.add_child(pot_bubble)
		if o.kind == "machine":
			if Machines.is_ready(o, TimeService.now()):
				var bubble := _bubble(Art.item(o.output.get("id", "")))
				bubble.position = Vector2(0, -sz.y - 6)
				node.add_child(bubble)
			elif Machines.is_busy(o):
				var puff := CPUParticles2D.new()
				puff.amount = 3
				puff.lifetime = 1.4
				puff.position = Vector2(0, -sz.y + 4)
				puff.direction = Vector2(0, -1)
				puff.initial_velocity_min = 6
				puff.initial_velocity_max = 10
				puff.gravity = Vector2.ZERO
				puff.scale_amount_min = 1.5
				puff.scale_amount_max = 2.5
				puff.color = Color(1, 1, 1, 0.5)
				node.add_child(puff)
	ysort.add_child(node)
	_object_nodes["o" + k] = node

func _bubble(icon: Texture2D) -> Node2D:
	var b := Node2D.new()
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", UITheme.box(UITheme.CREAM, UITheme.OUTLINE, 1, 4, 0, false))
	bg.size = Vector2(20, 20)
	bg.position = Vector2(-10, -20)
	b.add_child(bg)
	var s := Sprite2D.new()
	s.texture = icon
	s.position = Vector2(0, -10)
	b.add_child(s)
	var tw := b.create_tween().set_loops()
	tw.tween_property(b, "position:y", -2.0, 0.6).as_relative().set_trans(Tween.TRANS_SINE)
	tw.tween_property(b, "position:y", 2.0, 0.6).as_relative().set_trans(Tween.TRANS_SINE)
	return b

func _crop_sprite(cid: String, stage: int) -> String:
	if stage <= 0:
		return "crop_stage0"
	if cid in TRELLIS:
		return "vine_stage1" if stage < 3 else "vine_stage3"
	if cid in STALK:
		return ["crop_stage1", "crop_stage2", "stalk_stage3"][mini(stage, 3) - 1]
	if cid in FLOWERS and stage >= 2:
		return "flower_stage2"
	return ["crop_stage1", "crop_stage2", "crop_stage3"][mini(stage, 3) - 1]

func _draw_crop(p: Vector2i) -> void:
	var k := "c" + Tiles.key(p)
	if _object_nodes.has(k):
		_object_nodes[k].queue_free()
		_object_nodes.erase(k)
	var c := grid.crop_at(p)
	if c.is_empty():
		return
	var stage := grid.crop_stage(p)
	var node := Node2D.new()
	node.position = Vector2(p.x * T + T / 2.0, p.y * T + T - 4)
	var tex := Art.world(_crop_sprite(c.id, stage))
	if tex:
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		s.offset = Vector2(-tex.get_size().x / 2.0, -tex.get_size().y)
		if c.id in FLOWERS or c.id == "sunflower":
			s.modulate = Color(0.95, 1.0, 0.95)
		node.add_child(s)
	if stage >= 4:
		var fr := Sprite2D.new()
		fr.texture = Art.item(c.id)
		if c.id in BIG:
			fr.scale = Vector2(1.5, 1.5)
			fr.position = Vector2(0, -10)
		elif c.id in STALK or c.id in TRELLIS:
			fr.position = Vector2(4, -26)
		else:
			fr.position = Vector2(0, -16)
		node.add_child(fr)
		var tw := fr.create_tween().set_loops()
		tw.tween_property(fr, "rotation", 0.06, 0.9).set_trans(Tween.TRANS_SINE)
		tw.tween_property(fr, "rotation", -0.06, 0.9).set_trans(Tween.TRANS_SINE)
	ysort.add_child(node)
	_object_nodes[k] = node

func _build_static_objects() -> void:
	for o in info.get("objects", []):
		var p := Vector2i(int(o.x), int(o.y))
		match o.type:
			"building":
				_add_building(o)
			"shipping_bin", "farm_chest", "sign", "board", "wayshrine", "stairs", "fountain", "ferry":
				var name: String = o.type
				var tex := Art.world(name)
				var fp: Vector2i = OBJECT_FOOTPRINT.get(name, Vector2i(1, 1))
				if tex:
					var s := Sprite2D.new()
					s.texture = tex
					s.centered = false
					s.offset = Vector2(-tex.get_size().x / 2.0, -tex.get_size().y)
					s.position = Vector2(p.x * T + fp.x * T / 2.0, (p.y + fp.y) * T)
					if name == "stairs" and not GameState.is_open_requirement(o.get("requires", "")):
						s.modulate = Color(0.5, 0.5, 0.5)
					ysort.add_child(s)
					_static_nodes.append(s)
				for dx in fp.x:
					for dy in fp.y:
						if name != "stairs":
							blockers[p + Vector2i(dx, dy)] = true
						interactables[p + Vector2i(dx, dy)] = o
			"show_ring":
				var tex2 := Art.world("show_ring")
				if tex2:
					var s2 := Sprite2D.new()
					s2.texture = tex2
					s2.centered = false
					s2.position = Vector2(p.x * T, p.y * T)
					decals.add_child(s2)
				interactables[p + Vector2i(2, 1)] = o
			"shrine":
				_add_shrine(o)
			"cave":
				interactables[p] = o
				interactables[p + Vector2i(0, 1)] = o
			"treasure":
				_add_treasure(o)
	if info.get("mine", false):
		var e: Array = info.get("entry", [])
		if e.size() == 2:
			interactables[Vector2i(int(e[0]), int(e[1]))] = {"type": "ladder_up"}
		var l: Array = info.get("ladder", [])
		if l.size() == 2 and not info.get("bottom", false):
			interactables[Vector2i(int(l[0]), int(l[1]))] = {"type": "ladder"}

func _add_shrine(o: Dictionary) -> void:
	var p := Vector2i(int(o.x), int(o.y))
	var region: String = o.get("region", "")
	var state := Adventure.shrine_state(GameState.world, region)
	var tex := Art.world("shrine" if state == "restored" else "shrine_ruined")
	var node := Node2D.new()
	node.position = Vector2((p.x + 1) * T, (p.y + 2) * T)
	ysort.add_child(node)
	_static_nodes.append(node)
	if tex:
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		s.offset = Vector2(-tex.get_size().x / 2.0, -tex.get_size().y)
		node.add_child(s)
	if state == "restored":
		var tcol: Color = Data.type_color(str(Data.regions.get(region, {}).get("type", "glow")))
		var glow := Sprite2D.new()
		glow.texture = _glow_texture()
		glow.modulate = Color(tcol, 0.55)
		glow.position = Vector2(0, -44)
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		glow.material = mat
		node.add_child(glow)
		var tw := glow.create_tween().set_loops()
		tw.tween_property(glow, "scale", Vector2(1.15, 1.15), 1.4).set_trans(Tween.TRANS_SINE)
		tw.tween_property(glow, "scale", Vector2(0.9, 0.9), 1.4).set_trans(Tween.TRANS_SINE)
	for dx in 2:
		for dy in 2:
			blockers[p + Vector2i(dx, dy)] = true
			interactables[p + Vector2i(dx, dy)] = o
	interactables[p + Vector2i(0, 2)] = o
	interactables[p + Vector2i(1, 2)] = o

static var _glow_tex: Texture2D

static func _glow_texture() -> Texture2D:
	if _glow_tex == null:
		var g := GradientTexture2D.new()
		g.width = 40
		g.height = 40
		g.fill = GradientTexture2D.FILL_RADIAL
		g.fill_from = Vector2(0.5, 0.5)
		g.fill_to = Vector2(0.5, 0.0)
		var grad := Gradient.new()
		grad.set_color(0, Color(1, 1, 1, 1))
		grad.set_color(1, Color(1, 1, 1, 0))
		g.gradient = grad
		_glow_tex = g
	return _glow_tex

func _add_treasure(o: Dictionary) -> void:
	var p := Vector2i(int(o.x), int(o.y))
	var tex := Art.world("treasure")
	if tex:
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		s.offset = Vector2(-tex.get_size().x / 2.0, -tex.get_size().y)
		s.position = Vector2(p.x * T + T / 2.0, (p.y + 1) * T)
		if o.get("grand", false):
			s.scale = Vector2(1.25, 1.25)
		if GameState.treasure_opened(map_id, p):
			s.modulate = Color(0.55, 0.5, 0.5)
		ysort.add_child(s)
		_static_nodes.append(s)
		_treasure_sprites[p] = s
	blockers[p] = true
	interactables[p] = o

var _treasure_sprites: Dictionary = {}

func mark_treasure_opened(t: Vector2i) -> void:
	if _treasure_sprites.has(t) and is_instance_valid(_treasure_sprites[t]):
		_treasure_sprites[t].modulate = Color(0.55, 0.5, 0.5)

func _add_building(o: Dictionary) -> void:
	var bid: String = o.id
	var built: bool = o.get("requires", "") == "" or GameState.has_building(o.requires)
	var ruined: bool = o.has("ruined_unless") and not GameState.has_building(o.ruined_unless)
	var p := Vector2i(int(o.x), int(o.y))
	var w := int(o.w)
	var h := int(o.h)
	if not built:
		var sign := Sprite2D.new()
		sign.texture = Art.world("sign")
		sign.centered = false
		sign.offset = Vector2(-16, -32)
		sign.position = Vector2((p.x + w / 2.0) * T, (p.y + h) * T)
		ysort.add_child(sign)
		_static_nodes.append(sign)
		var lot := {"type": "lot", "id": bid, "label": o.get("label", bid), "requires": o.requires}
		interactables[Vector2i(p.x + w / 2, p.y + h - 1)] = lot
		blockers[Vector2i(p.x + w / 2, p.y + h - 1)] = true
		return
	var tex := Art.building(bid + ("_ruined" if ruined else ""))
	if tex == null:
		tex = Art.world(bid)
	if tex:
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		s.offset = Vector2(-tex.get_size().x / 2.0, -tex.get_size().y)
		s.position = Vector2((p.x + w / 2.0) * T, (p.y + h) * T)
		ysort.add_child(s)
		_static_nodes.append(s)
	for dx in w:
		for dy in h:
			blockers[p + Vector2i(dx, dy)] = true
	var door := o.duplicate()
	if ruined:
		door["action"] = "ruined"
	for dx in range(maxi(0, w / 2 - 1), mini(w, w / 2 + 1)):
		interactables[Vector2i(p.x + dx, p.y + h - 1)] = door

# --- Wildlings --------------------------------------------------------------------------

func _spawn_creatures() -> void:
	for c in creatures:
		if is_instance_valid(c):
			c.queue_free()
	creatures.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([int(GameState.world.seed), GameState.day(), map_id, int(GameState.minute() / 120)])
	var spawns: Array = info.get("spawns", [])
	var night := Calendar.is_night(GameState.minute())
	var levels: Array = info.get("levels", [2, 6])
	var bonus: Array = []
	var fest := Adventure.festival_today(GameState.day())
	if fest.get("kind", "") == "spawns" and night and not info.get("indoor", false) and not info.get("mine", false):
		bonus = fest.get("spawn_bonus", [])
		if spawns.is_empty():
			var sh: int = GameState.world.shrines.size()
			levels = [5 + sh * 4, 10 + sh * 5]
	var taken: Array[Vector2i] = []
	var region: String = info.get("region", "")
	if region != "" and not info.get("mine", false):
		if Adventure.guardian_free(GameState.world, region) and Data.species.has(Adventure.guardian_of(region)):
			taken.append(Vector2i(39, 20))
		if Adventure.legend_here(GameState.world, region, GameState.season()) != "":
			taken.append(Vector2i(38, 15))
	if not spawns.is_empty() or not bonus.is_empty():
		var starry_mult := 3.0 if GameState._anyone_has("starry_charm") else 1.0
		var chain := GameState.chain_of(Net.local_id())
		var lure := Endless.chain_lures(chain, spawns)
		for i in 7:
			var sid := MapBuilder.pick_spawn(spawns, GameState.season(), GameState.world.weather, night, rng, bonus)
			if lure and rng.randf() < 0.35:
				sid = chain.species
			if sid == "" or not Data.species.has(sid):
				continue
			var t := _random_open_tile(rng, true, Vector2i(-1, -1), taken)
			if t.x < 0:
				continue
			taken.append(t)
			var lvl := Trainers.wild_level(levels, rng, night)
			var starry := rng.randf() * float(Creature.STARRY_ODDS) / (starry_mult * Endless.chain_mult(chain, sid)) < 1.0
			_add_creature(sid, lvl, starry, t, null)
	if region != "" and not info.get("mine", false):
		if Adventure.guardian_free(GameState.world, region) and Data.species.has(Adventure.guardian_of(region)):
			_add_creature(Adventure.guardian_of(region), Adventure.guardian_level(region), false, Vector2i(39, 20), null, true)
		var lid := Adventure.legend_here(GameState.world, region, GameState.season())
		if lid != "" and Data.species.has(lid):
			_add_creature(lid, int(Data.legends[lid].level), false, Vector2i(38, 15), null, true)
	var boss: Dictionary = info.get("boss", {})
	if not boss.is_empty() and not GameState.world.flags.get("deep_boss", false) and Data.species.has(str(boss.species)):
		_add_creature(str(boss.species), int(boss.level), false, Vector2i(int(boss.at[0]), int(boss.at[1])), null, true)
	if map_id == "farm":
		var den := Vector2i(-1, -1)
		for o in info.get("objects", []):
			if o.get("id", "") == "den":
				den = Vector2i(int(o.x) + int(o.w) / 2, int(o.y) + int(o.h) + 3)
		for c in GameState.ranch.slice(0, 30):
			var t2 := _random_open_tile(rng, false, den, taken)
			if t2.x >= 0:
				taken.append(t2)
				_add_creature(c.species_id, c.level, c.starry, t2, c)

func _add_creature(sid: String, lvl: int, starry: bool, t: Vector2i, c: Creature, boss: bool = false) -> WildCreature:
	var w := WildCreature.new()
	w.species = sid
	w.level = lvl
	w.starry = starry
	w.boss = boss
	w.pet = c != null
	w.creature = c
	w.world = self
	w.position = GameState.tile_center(t) + Vector2(0, 6)
	ysort.add_child(w)
	creatures.append(w)
	return w

func _random_open_tile(rng: RandomNumberGenerator, prefer_grass: bool, near := Vector2i(-1, -1), avoid: Array = []) -> Vector2i:
	var sp: Array = info.get("spawn", [1, 1])
	var spawn_t := Vector2i(int(sp[0]), int(sp[1]))
	for i in 80:
		var t := Vector2i(rng.randi_range(3, grid.w - 4), rng.randi_range(3, grid.h - 4))
		if near.x >= 0 and i < 60:
			t = Vector2i(clampi(near.x + rng.randi_range(-6, 6), 1, grid.w - 2), clampi(near.y + rng.randi_range(-3, 3), 1, grid.h - 2))
		elif t.distance_to(spawn_t) < 6.0:
			continue
		if t in avoid or is_tile_solid(t) or not warp_at(t).is_empty() or interactables.has(t):
			continue
		if prefer_grass and i < 40 and grid.get_ground(t) != Tiles.GROUND.tallgrass:
			continue
		if not grid.crop_at(t).is_empty():
			continue
		return t
	return Vector2i(-1, -1)

func creature_at(t: Vector2i) -> WildCreature:
	var c := GameState.tile_center(t)
	for w in creatures:
		if is_instance_valid(w) and w.position.distance_to(c) < 20.0:
			return w
	return null

func remove_creature(w: WildCreature) -> void:
	creatures.erase(w)
	if is_instance_valid(w):
		w.queue_free()

# --- NPCs -------------------------------------------------------------------------------

func _spawn_npcs() -> void:
	for vid in Data.villagers:
		var loc := Relationships.location(vid, GameState.minute(), GameState.world.weather)
		if loc[0] != map_id:
			continue
		var n := Npc.new()
		n.vid = vid
		n.world = self
		n.position = GameState.tile_center(Vector2i(loc[1], loc[2]))
		ysort.add_child(n)
		npcs[vid] = n

const GUEST_SKIN := ["#f4d0b0", "#f0c8a0", "#e0b088", "#c08860", "#a06a48", "#7a4a30"]
const GUEST_HAIR := ["#1e1a22", "#5a4030", "#b0502a", "#e8d8a0", "#e8e8f0", "#7a3a2a", "#3a2a4a"]
const GUEST_SHIRT := ["#2a2430", "#7a2a36", "#2a3a6a", "#3a6a4a", "#e8e8f0", "#9a5ad0", "#c89a40"]

## A handful of nameless guests that stroll between the map's guest spots; same faces all day.
func _spawn_guests() -> void:
	var spots: Array = []
	for s in info.get("guests", []):
		spots.append(Vector2i(int(s[0]), int(s[1])))
	if spots.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([map_id, GameState.day(), "guests"])
	var count := mini(spots.size(), int(info.get("guest_count", ceili(spots.size() / 2.0))))
	var free := spots.duplicate()
	for i in count:
		var n := Npc.new()
		n.world = self
		n.guest_look = {"skin": GUEST_SKIN[rng.randi() % GUEST_SKIN.size()], "hair": GUEST_HAIR[rng.randi() % GUEST_HAIR.size()],
			"shirt": GUEST_SHIRT[rng.randi() % GUEST_SHIRT.size()], "style": rng.randi() % Art.HAIR_STYLES.size()}
		n.wander = spots
		var at: Vector2i = free.pop_at(rng.randi() % free.size())
		n.position = GameState.tile_center(_nearest_open(at))
		ysort.add_child(n)
		guests.append(n)

func _update_npcs() -> void:
	for vid in Data.villagers:
		var loc := Relationships.location(vid, GameState.minute(), GameState.world.weather)
		var here: bool = loc[0] == map_id
		if here and not npcs.has(vid):
			var n := Npc.new()
			n.vid = vid
			n.world = self
			n.position = GameState.tile_center(_nearest_open(Vector2i(loc[1], loc[2])))
			ysort.add_child(n)
			npcs[vid] = n
		elif not here and npcs.has(vid):
			npcs[vid].queue_free()
			npcs.erase(vid)
		elif here:
			npcs[vid].walk_to(Vector2i(loc[1], loc[2]))

func npc_at(t: Vector2i) -> Npc:
	for n in npcs.values() + guests:
		if GameState.to_tile(n.position) == t or GameState.to_tile(n.position + Vector2(0, -16)) == t:
			return n
	return null

# --- Pathing + collision ------------------------------------------------------------------

func _build_astar() -> void:
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, grid.w, grid.h)
	astar.cell_size = Vector2(T, T)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	for y in grid.h:
		for x in grid.w:
			var p := Vector2i(x, y)
			if is_tile_solid(p):
				astar.set_point_solid(p, true)

func path_between(a: Vector2i, b: Vector2i) -> Array:
	if astar == null or not grid.in_bounds(a) or not grid.in_bounds(b):
		return []
	var target := _nearest_open(b)
	if astar.is_point_solid(a):
		a = _nearest_open(a)
	return Array(astar.get_id_path(a, target))

func _nearest_open(p: Vector2i) -> Vector2i:
	if not is_tile_solid(p):
		return p
	for r in range(1, 4):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var q := p + Vector2i(dx, dy)
				if grid.in_bounds(q) and not is_tile_solid(q):
					return q
	return p

func is_tile_solid(t: Vector2i) -> bool:
	if not grid.in_bounds(t):
		return true
	if blockers.has(t):
		return true
	var d := grid.get_deco(t)
	if Tiles.blocks(grid.get_ground(t), d):
		return true
	var o := grid.object_at(t)
	if not o.is_empty() and o.kind != "forage":
		if o.kind == "tree":
			return FarmGrid.tree_growth(o, TimeService.now()) >= 1.0 / 3.0
		return true
	return false

## Feet-box collision in world pixels.
func is_solid_at(pos: Vector2, half: Vector2 = Vector2(6, 3)) -> bool:
	for c in [pos + Vector2(-half.x, -half.y), pos + Vector2(half.x, -half.y), pos + Vector2(-half.x, half.y), pos + Vector2(half.x, half.y)]:
		if is_tile_solid(GameState.to_tile(c)):
			return true
	return false

func warp_at(t: Vector2i) -> Dictionary:
	for wp in info.get("warps", []):
		if t.x >= int(wp.x) and t.x < int(wp.x) + int(wp.get("w", 1)) and t.y >= int(wp.y) and t.y < int(wp.y) + int(wp.get("h", 1)):
			return wp
	return {}

func interactable_at(t: Vector2i) -> Dictionary:
	return interactables.get(t, {})

## The tile talk / use should hit. The aimed tile wins when it already has something;
## otherwise a villager, door, chest or the like one step off still counts, if you're facing it.
func focus_tile(me: Vector2i, aim: Vector2i) -> Vector2i:
	if _worth_talking(aim):
		return aim
	var aim_dir := Vector2(aim - me)
	aim_dir = Vector2.DOWN if aim_dir.length() < 0.01 else aim_dir.normalized()
	var best := aim
	var best_steps := 99
	var best_kind := 99
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var c := aim + Vector2i(dx, dy)
			if absi(c.x - me.x) > 1 or absi(c.y - me.y) > 1:
				continue
			var kind := _talk_kind(c)
			if kind == 99:
				continue
			var dir := Vector2(c - me)
			if dir.length() < 0.01 or dir.normalized().dot(aim_dir) < 0.5:
				continue
			var steps := absi(dx) + absi(dy)
			if steps < best_steps or (steps == best_steps and kind < best_kind):
				best_steps = steps
				best_kind = kind
				best = c
	return best

## 0 villager, 1 pet, 2 door/sign/building, 3 placed object, 4 ripe crop, 99 nothing.
func _talk_kind(t: Vector2i) -> int:
	if npc_at(t):
		return 0
	var w := creature_at(t)
	if w and w.pet:
		return 1
	if not interactable_at(t).is_empty():
		return 2
	if grid and not grid.object_at(t).is_empty():
		return 3
	if grid and grid.crop_ready(t):
		return 4
	return 99

func _worth_talking(t: Vector2i) -> bool:
	return _talk_kind(t) < 99

# --- Refresh hooks ---------------------------------------------------------------------------

func _on_tile_changed(m: String, t: Vector2i) -> void:
	if m != map_id:
		return
	for d in NEIGHBORS + DIAGONALS + [Vector2i.ZERO]:
		if grid.in_bounds(t + d):
			_draw_ground(t + d)
	_draw_deco(t)
	for dir in NEIGHBORS:
		var n: Vector2i = t + dir
		if grid.in_bounds(n) and grid.get_deco(n) in [Tiles.DECO.fence, Tiles.DECO.rail, Tiles.DECO.vein]:
			_draw_deco(n)
	for d in NEIGHBORS + DIAGONALS + [Vector2i.ZERO]:
		_draw_soil(t + d)
	_draw_crop(t)
	_draw_object(t)
	if astar:
		astar.set_point_solid(t, is_tile_solid(t))
	if darkness:
		darkness.rebuild()

func _on_objects_changed(m: String) -> void:
	if m != map_id:
		return
	for k in _object_nodes.keys():
		if k.begins_with("o"):
			_object_nodes[k].queue_free()
			_object_nodes.erase(k)
	for k in grid.objects:
		_draw_object(Tiles.parse_key(k))
		if astar:
			astar.set_point_solid(Tiles.parse_key(k), is_tile_solid(Tiles.parse_key(k)))

func refresh_all() -> void:
	if map_id != "":
		var pl := get_tree().get_nodes_in_group("players")
		load_map(map_id)
		for p in pl:
			if p.get_parent() != ysort:
				p.reparent(ysort)

func _on_time(minute: int) -> void:
	if grid == null:
		return
	day_tint.color = sky_color(minute, info.get("indoor", false) or info.get("mine", false))
	if minute % 30 == 0:
		_update_npcs()
	if minute % 60 == 0:
		for k in grid.objects:
			if grid.objects[k].kind == "machine":
				_draw_object(Tiles.parse_key(k))

static func sky_color(minute: int, indoor: bool) -> Color:
	if indoor:
		return Color(1, 0.97, 0.92)
	var keys := [[360, Color(0.8, 0.82, 0.95)], [420, Color(1, 1, 1)], [1020, Color(1, 1, 1)], [1140, Color(1.0, 0.86, 0.72)],
		[1230, Color(0.62, 0.6, 0.82)], [1320, Color(0.42, 0.45, 0.7)], [1560, Color(0.36, 0.38, 0.62)]]
	for i in keys.size() - 1:
		if minute >= keys[i][0] and minute < keys[i + 1][0]:
			var f := float(minute - keys[i][0]) / float(keys[i + 1][0] - keys[i][0])
			return (keys[i][1] as Color).lerp(keys[i + 1][1], f)
	return keys[-1][1]

func _apply_weather() -> void:
	if info.get("indoor", false) or info.get("mine", false):
		weather.set_kind("")
	else:
		weather.set_kind(GameState.world.get("weather", "sun"))

func _on_popup(at: Vector2, text: String, col: Color, icon: String) -> void:
	if not is_inside_tree():
		return
	var l := UITheme.label(text, 9, col, true)
	l.position = at + Vector2(-40, -36)
	l.size = Vector2(80, 12)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.z_index = 60
	if icon != "":
		var ic := TextureRect.new()
		ic.texture = Art.item(icon)
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.size = Vector2(10, 10)
		ic.position = Vector2(40 - l.get_minimum_size().x / 2.0 - 12, 1)
		l.add_child(ic)
	overlay.add_child(l)
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y - 22, 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "modulate:a", 0.0, 0.4).set_delay(0.6)
	tw.chain().tween_callback(l.queue_free)


## Rails, posts and pilings along walkways over water (piers and bridges).
class PierRails extends Node2D:
	const WOOD := Color("#8a5a3a")
	const WOOD_LT := Color("#c08a50")
	const WOOD_DK := Color("#2a1810")
	var g: FarmGrid

	func _init(grid: FarmGrid) -> void:
		g = grid

	func _water(p: Vector2i) -> bool:
		return g.in_bounds(p) and g.get_ground(p) in Tiles.WATER_TILES

	func _bridge(p: Vector2i) -> bool:
		return g.in_bounds(p) and g.get_ground(p) == Tiles.GROUND.bridge

	func _draw() -> void:
		var t := float(Tiles.TILE)
		for y in g.h:
			for x in g.w:
				var p := Vector2i(x, y)
				if not _bridge(p):
					continue
				var o := Vector2(x * t, y * t)
				if _water(p + Vector2i(0, 1)):
					for px in [4.0, t - 8.0]:
						draw_rect(Rect2(o + Vector2(px - 1, t), Vector2(6, 8)), WOOD_DK)
						draw_rect(Rect2(o + Vector2(px, t), Vector2(4, 6)), WOOD)
						draw_rect(Rect2(o + Vector2(px - 2, t + 8), Vector2(8, 1)), Color(1, 1, 1, 0.45))
				var along_x := _bridge(p + Vector2i(1, 0)) or _bridge(p + Vector2i(-1, 0))
				var along_y := _bridge(p + Vector2i(0, 1)) or _bridge(p + Vector2i(0, -1))
				if _water(p + Vector2i(-1, 0)) and along_y:
					_rail(o + Vector2(1, 0), o + Vector2(1, t))
				if _water(p + Vector2i(1, 0)) and along_y:
					_rail(o + Vector2(t - 3, 0), o + Vector2(t - 3, t))
				if _water(p + Vector2i(0, -1)) and along_x and not along_y:
					_rail(o + Vector2(0, 1), o + Vector2(t, 1))
				if _water(p + Vector2i(0, 1)) and along_x and not along_y:
					_rail(o + Vector2(0, t - 4), o + Vector2(t, t - 4))

	func _rail(a: Vector2, b: Vector2) -> void:
		var vertical := absf(a.x - b.x) < 0.5
		var r := Rect2(a - Vector2(1, 0), Vector2(4, b.y - a.y)) if vertical else Rect2(a - Vector2(0, 1), Vector2(b.x - a.x, 4))
		draw_rect(r.grow(1), WOOD_DK)
		draw_rect(r, WOOD_LT)
		for k in 2:
			var at := a.lerp(b, 0.25 + 0.5 * k)
			draw_rect(Rect2(at - Vector2(3, 4), Vector2(7, 8)), WOOD_DK)
			draw_rect(Rect2(at - Vector2(2, 3), Vector2(5, 3)), WOOD)
