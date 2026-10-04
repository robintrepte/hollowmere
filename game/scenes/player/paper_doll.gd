class_name PaperDoll
extends Node2D
## Layered, tinted character sprite. Origin is at the feet.
## Sheet: 7 columns (idle, walk0..3, tool0..1) x 3 rows (down, up, side).

const LAYERS := ["shoes", "pants", "shirt", "pack", "body", "face", "hair", "hat"]
const WALK_FPS := 8.0
const RUN_FPS := 14.0

var facing := Vector2.DOWN
var moving := false
var running := false
var _sprites: Dictionary = {}
var _t := 0.0
var _tool_t := -1.0
var _look: Dictionary = {}
## The emote playing right now ("" for none) and how long it has been going.
var emote := ""
var _emote_t := 0.0

signal emote_finished

func _ready() -> void:
	for l in LAYERS:
		var s := Sprite2D.new()
		s.centered = false
		s.offset = Vector2(-16, -46)
		s.hframes = Art.DOLL_COLS
		s.vframes = 3
		s.texture = Art.hair_layer(0) if l == "hair" else (null if l == "hat" else Art.doll_layer(l))
		add_child(s)
		_sprites[l] = s
	_sprites.pack.visible = false
	if not _look.is_empty():
		set_look(_look)
	if _hat != "":
		set_hat(_hat)

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

var _hat := ""

## Puts on a hat item (its "hat" style, tinted with the item color); "" takes it off.
func set_hat(item_id: String) -> void:
	_hat = item_id
	if _sprites.is_empty():
		return
	var it: Dictionary = Data.get_item(item_id) if item_id != "" else {}
	var style := str(it.get("hat", ""))
	_sprites.hat.texture = Art.hat_layer(style) if style != "" else null
	_sprites.hat.modulate = Art.color(str(it.get("hat_tint", it.get("color", "#ffffff"))))

## Shows a worn pack in the given color; a transparent color hides it.
func set_pack(tint: Color) -> void:
	if _sprites.is_empty():
		return
	_sprites.pack.visible = tint.a > 0.0
	_sprites.pack.modulate = tint

## Plays an emote from the catalogue; walking or swinging a tool ends it.
func play_emote(id: String) -> void:
	emote = id if Emotes.exists(id) else ""
	_emote_t = 0.0

func stop_emote() -> void:
	if emote == "":
		return
	emote = ""
	emote_finished.emit()

func swing() -> void:
	stop_emote()
	_tool_t = 0.0

func is_swinging() -> bool:
	return _tool_t >= 0.0

func _process(delta: float) -> void:
	_t += delta
	if emote != "" and moving:
		stop_emote()
	var col := 0
	if _tool_t >= 0.0:
		_tool_t += delta
		col = 5 if _tool_t < 0.12 else 6
		if _tool_t > 0.28:
			_tool_t = -1.0
	elif moving:
		col = 1 + int(_t * (RUN_FPS if running else WALK_FPS)) % 4
	var face := facing
	var hop := 0.0
	var lean := 0.0
	var hat_lift := 0.0
	if emote != "" and _tool_t < 0.0:
		_emote_t += delta
		var e := Emotes.info(emote)
		var fps := float(e.get("fps", 1.0))
		col = Emotes.frame_col(emote, _emote_t)
		match str(e.get("motion", "")):
			"hop":
				hop = -absf(sin(_emote_t * fps * PI)) * 3.0
			"giggle":
				hop = -absf(sin(_emote_t * 18.0)) * 1.5
			"bow", "tip":
				var dip := minf(1.0, _emote_t * 5.0) * minf(1.0, maxf(0.0, Emotes.duration(emote) - _emote_t) * 5.0)
				if absf(face.x) > absf(face.y):
					lean = signf(face.x) * 0.22 * dip
				if e.motion == "tip":
					hat_lift = -4.0 * dip
			"spin":
				face = [Vector2.DOWN, Vector2.RIGHT, Vector2.UP, Vector2.LEFT][int(_emote_t * fps * 0.5) % 4]
				lean = sin(_emote_t * PI) * 0.08
				hop = -absf(sin(_emote_t * fps * PI * 0.5)) * 2.0
		if _emote_t >= Emotes.duration(emote):
			stop_emote()
	var row := 0
	var flip := false
	if absf(face.x) > absf(face.y) + 0.01:
		row = 2
		flip = face.x < 0
	elif face.y < 0:
		row = 1
	if moving and running and _tool_t < 0.0:
		hop = -absf(sin(_t * RUN_FPS * PI * 0.5)) * 3.0
		if absf(face.x) > absf(face.y):
			lean = signf(face.x) * 0.1
	rotation = lean
	for l in _sprites:
		var s: Sprite2D = _sprites[l]
		s.frame = row * Art.DOLL_COLS + col
		s.flip_h = flip
		s.offset = Vector2(-16, -46.0 + hop + (hat_lift if l == "hat" else 0.0))
