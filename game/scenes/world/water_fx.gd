class_name WaterFx
extends Node2D
## Slow shimmer on water, the occasional leaping fish, and a short reflection of
## whatever stands on the north bank. Reflections only fall southward, into the water.

## COLOR in a canvas_item fragment() is already texture * modulate. Sampling TEXTURE
## and multiplying again squares every pixel on that layer, so ground (and the foam
## ribbon) read as a darker filter than the unshaded shore caps beside them.
const SHIMMER := "shader_type canvas_item;
uniform float u_time;
varying vec2 wp;
void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}
void fragment() {
	vec4 c = COLOR;
	float rows = vec2(textureSize(TEXTURE, 0)).y / 32.0;
	float row = floor(UV.y * rows + 0.001);
	if ((row == 4.0 || row == 19.0) && c.a > 0.5) {
		vec2 px = floor(wp);
		float glide = sin(px.x * 0.16 - u_time * 0.9 + px.y * 0.05);
		float lift = 0.5 + 0.5 * glide;
		c.rgb += vec3(0.025, 0.035, 0.04) * lift;
		float spark = fract(sin(dot(floor(px / 4.0) + vec2(floor(u_time * 1.2), 0.0), vec2(12.9898, 78.233))) * 43758.5453);
		if (spark > 0.93 && glide > 0.2) {
			c.rgb += vec3(0.14, 0.18, 0.2);
		}
	}
	COLOR = c;
}
"

const FOAM := "shader_type canvas_item;
uniform float u_time;
varying vec2 wp;
void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}
void fragment() {
	vec4 c = COLOR;
	if (c.a > 0.15 && c.r > 0.72 && c.b > 0.82) {
		float pulse = 0.5 + 0.5 * sin(u_time * 1.8 + wp.x * 0.22 + wp.y * 0.08);
		c.a *= 0.78 + 0.22 * pulse;
	}
	COLOR = c;
}
"

var world: World
var _time := 0.0
var _fish_wait := 4.0
var _water: Array[Vector2i] = []
var _mirrors: Dictionary = {}
var _leaps: Array[Node] = []
var _shimmer: ShaderMaterial
var _foam: ShaderMaterial
var _fish_tex: Texture2D
var _dot_tex: Texture2D
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	z_index = -6
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_rng.randomize()
	_fish_tex = ImageTexture.create_from_image(_fish_image())
	_dot_tex = ImageTexture.create_from_image(_dot_image())
	_shimmer = _material(SHIMMER)
	_foam = _material(FOAM)

func setup(w: World) -> void:
	clear()
	world = w
	if world.ground:
		world.ground.material = _shimmer
	if world.edge_layer:
		world.edge_layer.material = _foam
	_scan()
	_fish_wait = _rng.randf_range(3.0, 7.0)

func clear() -> void:
	for n in _mirrors.values():
		if is_instance_valid(n):
			n.queue_free()
	_mirrors.clear()
	for n in _leaps:
		if is_instance_valid(n):
			n.queue_free()
	_leaps.clear()
	if is_inside_tree():
		for n in get_tree().get_nodes_in_group("water_leap"):
			n.queue_free()
	_water.clear()

func _material(code: String) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = code
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

func _scan() -> void:
	_water.clear()
	if world == null or world.grid == null:
		return
	for y in world.grid.h:
		for x in world.grid.w:
			var p := Vector2i(x, y)
			if world.grid.get_ground(p) in Tiles.WATER_TILES:
				_water.append(p)

func _process(delta: float) -> void:
	if world == null or world.grid == null:
		return
	_time += delta
	_shimmer.set_shader_parameter("u_time", _time)
	_foam.set_shader_parameter("u_time", _time)
	_reflect()
	if _water.is_empty():
		return
	_fish_wait -= delta
	if _fish_wait <= 0.0:
		_fish_wait = _rng.randf_range(9.0, 18.0)
		_try_leap()
	_reap_leaps()

# --- Reflections (north bank only) ---------------------------------------------------

func _reflect() -> void:
	var seen := {}
	for raw in _sources():
		var src := raw as Node2D
		if src == null or not is_instance_valid(src):
			continue
		var id: int = src.get_instance_id()
		seen[id] = true
		var shore := _shore(src.position)
		var mirror := _mirror_for(src)
		if shore.x < 0.0:
			mirror.visible = false
			continue
		var dist: float = shore.y - src.position.y
		var person := src is Player or src is Npc or src is WildCreature
		var alpha := clampf((28.0 - maxf(dist, 0.0)) / 20.0, 0.0, 1.0) * (0.42 if person else 0.28)
		if alpha < 0.04:
			mirror.visible = false
			continue
		mirror.visible = true
		var bob := sin(_time * 1.5 + src.position.x * 0.07) * 0.7
		mirror.position = Vector2(src.position.x + sin(_time * 1.2 + float(id % 17)) * 0.45, shore.y + 2.0 + bob)
		mirror.scale = Vector2(1, -0.36 if person else -0.2)
		mirror.modulate = Color(0.55, 0.75, 0.92, alpha)
		_sync(src, mirror)
	var drop: Array = []
	for id in _mirrors:
		if not seen.has(id):
			drop.append(id)
	for id in drop:
		if is_instance_valid(_mirrors[id]):
			_mirrors[id].queue_free()
		_mirrors.erase(id)

func _sources() -> Array:
	var out: Array = []
	if get_tree() == null:
		return out
	for n in get_tree().get_nodes_in_group("players"):
		out.append(n)
	for n in get_tree().get_nodes_in_group("npcs"):
		out.append(n)
	for n in world.creatures:
		out.append(n)
	for n in world._deco_nodes.values():
		out.append(n)
	return out

## Shore point on the water just south of `pos`, or (-1, -1) when nothing is reflecting.
func _shore(pos: Vector2) -> Vector2:
	var t := GameState.to_tile(pos)
	var below := Vector2i(t.x, t.y + 1)
	if world._is_water_ground(below) and not world._is_water_ground(t):
		var shore_y := float(below.y * Tiles.TILE)
		var dist := shore_y - pos.y
		if dist >= -2.0 and dist <= 30.0:
			return Vector2(pos.x, shore_y)
	# Trees and such place their origin on the bottom edge, which is already the water tile.
	if world._is_water_ground(t) and pos.y - float(t.y * Tiles.TILE) <= 4.0:
		return Vector2(pos.x, float(t.y * Tiles.TILE))
	return Vector2(-1, -1)

func _mirror_for(src: Node) -> Node2D:
	var id := src.get_instance_id()
	if _mirrors.has(id) and is_instance_valid(_mirrors[id]):
		return _mirrors[id]
	var n := Node2D.new()
	n.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if src is Player or src is Npc:
		for l in PaperDoll.LAYERS:
			var s := Sprite2D.new()
			s.name = l
			s.centered = false
			s.hframes = Art.DOLL_COLS
			s.vframes = 3
			n.add_child(s)
		n.set_meta("kind", "doll")
	else:
		var s := Sprite2D.new()
		s.name = "body"
		s.centered = false
		n.add_child(s)
		n.set_meta("kind", "sprite")
	add_child(n)
	_mirrors[id] = n
	return n

func _sync(src: Node, mirror: Node2D) -> void:
	if str(mirror.get_meta("kind")) == "doll":
		var doll: PaperDoll = null
		if src is Player:
			doll = (src as Player).doll
		elif src is Npc:
			doll = (src as Npc).doll
		if doll == null or doll._sprites.is_empty():
			mirror.visible = false
			return
		for l in PaperDoll.LAYERS:
			var a: Sprite2D = doll._sprites[l]
			var b := mirror.get_node(l) as Sprite2D
			b.texture = a.texture
			b.frame = a.frame
			b.flip_h = a.flip_h
			b.modulate = a.modulate
			b.visible = a.visible
			b.offset = a.offset
			b.hframes = a.hframes
			b.vframes = a.vframes
		return
	var spr: Sprite2D = null
	if src is WildCreature:
		spr = (src as WildCreature).sprite
	elif src is Sprite2D:
		spr = src as Sprite2D
	if spr == null or spr.texture == null:
		mirror.visible = false
		return
	var body := mirror.get_node("body") as Sprite2D
	body.texture = spr.texture
	body.offset = spr.offset
	body.flip_h = spr.flip_h
	body.flip_v = spr.flip_v
	body.hframes = spr.hframes
	body.vframes = spr.vframes
	body.frame = spr.frame
	body.centered = spr.centered
	body.scale = spr.scale
	body.modulate = spr.modulate

# --- Fish --------------------------------------------------------------------------------

func _try_leap() -> void:
	var near: Array[Vector2i] = []
	var focus := _focus_tile()
	for p in _water:
		var d := p - focus
		if focus.x < 0 or (absi(d.x) <= 11 and absi(d.y) <= 6):
			near.append(p)
	if near.is_empty():
		return
	var at: Vector2i = near[_rng.randi() % near.size()]
	var leap := Leap.new()
	leap.tex = _fish_tex
	leap.origin = GameState.tile_center(at) + Vector2(0, 4)
	leap.side = -1.0 if _rng.randf() < 0.5 else 1.0
	leap.hop = _rng.randf_range(11.0, 18.0)
	leap.span = _rng.randf_range(4.0, 9.0)
	leap.dur = _rng.randf_range(0.55, 0.75)
	leap.dot = _dot_tex
	world.ysort.add_child(leap)
	_leaps.append(leap)

func _focus_tile() -> Vector2i:
	if get_tree() == null:
		return Vector2i(-1, -1)
	for n in get_tree().get_nodes_in_group("players"):
		if n is Player and (n as Player).local:
			return GameState.to_tile((n as Node2D).position)
	return Vector2i(-1, -1)

func _reap_leaps() -> void:
	var keep: Array[Node] = []
	for n in _leaps:
		if is_instance_valid(n):
			keep.append(n)
	_leaps = keep

static func _fish_image() -> Image:
	var img := Image.create(11, 7, false, Image.FORMAT_RGBA8)
	var rows := [
		"..####.....",
		".######....",
		"########...",
		"######o##..",
		".########..",
		"..######...",
		"....##.....",
	]
	var body := Color("#e8c078")
	var shade := Color("#c08048")
	var belly := Color("#fff0d0")
	var eye := Color("#24180e")
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var ch := row[x]
			if ch == "#":
				img.set_pixel(x, y, body if y < 4 else belly)
			elif ch == "o":
				img.set_pixel(x, y, eye)
	img.set_pixel(0, 2, shade)
	img.set_pixel(0, 3, shade)
	img.set_pixel(1, 1, shade)
	return img

static func _dot_image() -> Image:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.9, 0.96, 1.0, 0.9))
	return img


class Leap extends Node2D:
	var age := 0.0
	var dur := 0.65
	var side := 1.0
	var hop := 14.0
	var span := 6.0
	var origin := Vector2.ZERO
	var tex: Texture2D
	var dot: Texture2D
	var spr: Sprite2D
	var _splashed := false

	func _ready() -> void:
		add_to_group("water_leap")
		spr = Sprite2D.new()
		spr.texture = tex
		spr.centered = true
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(spr)

	func _process(delta: float) -> void:
		age += delta
		var u := age / dur
		if u >= 1.0:
			if not _splashed:
				_splashed = true
				_splash()
			queue_free()
			return
		var arc := sin(u * PI)
		# Position stays on the water so y-sort doesn't yank the fish behind the bank.
		position = origin
		spr.position = Vector2(side * u * span, -arc * hop)
		spr.rotation = side * (0.5 - u) * 0.8
		spr.flip_h = side < 0.0

	func _splash() -> void:
		var parent := get_parent()
		if parent == null:
			return
		var rip := WaterFx.Ripple.new()
		rip.position = origin + Vector2(side * span, 2)
		for i in 6:
			var s := Sprite2D.new()
			s.texture = dot
			s.centered = true
			s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			s.set_meta("ang", float(i) / 6.0 * TAU)
			rip.add_child(s)
		parent.add_child(rip)


class Ripple extends Node2D:
	var age := 0.0

	func _ready() -> void:
		add_to_group("water_leap")

	func _process(delta: float) -> void:
		age += delta
		var u := clampf(age / 0.4, 0.0, 1.0)
		for s in get_children():
			var ang := float(s.get_meta("ang"))
			s.position = Vector2(cos(ang), sin(ang) * 0.45) * (1.5 + u * 6.0)
			s.modulate.a = 1.0 - u
		if age >= 0.4:
			queue_free()
