class_name PaperDoll
extends Node2D
## Layered, tinted character sprite. Origin is at the feet.
## Sheet: 7 columns (idle, walk0..3, tool0..1) x 3 rows (down, up, side).

const LAYERS := ["shoes", "pants", "shirt", "body", "face", "hair"]
const WALK_FPS := 8.0

var facing := Vector2.DOWN
var moving := false
var _sprites: Dictionary = {}
var _t := 0.0
var _tool_t := -1.0
var _look: Dictionary = {}

func _ready() -> void:
	for l in LAYERS:
		var s := Sprite2D.new()
		s.centered = false
		s.offset = Vector2(-16, -46)
		s.hframes = Art.DOLL_COLS
		s.vframes = 3
		s.texture = Art.doll_layer(l) if l != "hair" else Art.hair_layer(0)
		add_child(s)
		_sprites[l] = s
	if not _look.is_empty():
		set_look(_look)

func set_look(look: Dictionary) -> void:
	_look = look
	if _sprites.is_empty():
		return
	_sprites.body.modulate = Art.color(look.get("skin", "#f0c8a0"))
	_sprites.hair.modulate = Art.color(look.get("hair", "#5a3a2a"))
	_sprites.hair.texture = Art.hair_layer(int(look.get("style", 0)))
	_sprites.shirt.modulate = Art.color(look.get("shirt", "#4a8ac0"))
	_sprites.pants.modulate = Art.color(look.get("pants", "#3a3a5a"))
	_sprites.shoes.modulate = Art.color(look.get("shoes", "#5a3a2a"))

func swing() -> void:
	_tool_t = 0.0

func is_swinging() -> bool:
	return _tool_t >= 0.0

func _process(delta: float) -> void:
	_t += delta
	var col := 0
	if _tool_t >= 0.0:
		_tool_t += delta
		col = 5 if _tool_t < 0.12 else 6
		if _tool_t > 0.28:
			_tool_t = -1.0
	elif moving:
		col = 1 + int(_t * WALK_FPS) % 4
	var row := 0
	var flip := false
	if absf(facing.x) > absf(facing.y) + 0.01:
		row = 2
		flip = facing.x < 0
	elif facing.y < 0:
		row = 1
	for l in _sprites:
		var s: Sprite2D = _sprites[l]
		s.frame = row * Art.DOLL_COLS + col
		s.flip_h = flip
		s.offset.x = -16
