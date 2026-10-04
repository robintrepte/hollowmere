class_name Npc
extends Node2D
## A villager walking between schedule spots (A* over the map grid).

const SPEED := 46.0

var vid := ""
var world: World
var doll: PaperDoll
var _path: Array = []
var _bubble: Label
var _marker: Label
var _idle_t := 0.0

func _ready() -> void:
	add_to_group("npcs")
	doll = PaperDoll.new()
	add_child(doll)
	var v: Dictionary = Data.villagers.get(vid, {})
	var look: Dictionary = v.get("look", {}).duplicate()
	look["style"] = int(look.get("style", absi(hash(vid)) % Art.HAIR_STYLES.size()))
	look["pants"] = look.get("pants", "#4a4a5a")
	doll.set_look(look)
	var shadow := _shadow()
	add_child(shadow)
	move_child(shadow, 0)
	_bubble = UITheme.label("", 8, UITheme.CREAM, true)
	_bubble.position = Vector2(-40, -62)
	_bubble.size = Vector2(80, 10)
	_bubble.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_bubble)
	_marker = UITheme.label("", 14, UITheme.COIN, true)
	_marker.position = Vector2(-10, -74)
	_marker.size = Vector2(20, 16)
	_marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_marker.z_index = 50
	add_child(_marker)

static func _shadow() -> Sprite2D:
	var img := Image.create(16, 6, false, Image.FORMAT_RGBA8)
	for y in 6:
		for x in 16:
			var d := pow((x - 7.5) / 8.0, 2) + pow((y - 2.5) / 3.0, 2)
			if d <= 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 0.28))
	var s := Sprite2D.new()
	s.texture = ImageTexture.create_from_image(img)
	s.position = Vector2(0, -1)
	return s

func walk_to(t: Vector2i) -> void:
	if world == null:
		return
	_path = world.path_between(GameState.to_tile(position), t)
	if _path.size() > 0:
		_path.pop_front()

func show_heart_hint(text: String) -> void:
	_bubble.text = text
	var tw := create_tween()
	tw.tween_interval(2.0)
	tw.tween_callback(func(): _bubble.text = "")

## "!" for a new quest, "?" for something to hand in, "" for nothing.
func set_marker(m: String) -> void:
	if _marker == null or _marker.text == m:
		return
	_marker.text = m
	_marker.add_theme_color_override("font_color", UITheme.COIN if m == "!" else Color("#8fe3ff"))
	if m != "":
		var tw := _marker.create_tween().set_loops()
		tw.tween_property(_marker, "position:y", -77.0, 0.5).set_trans(Tween.TRANS_SINE)
		tw.tween_property(_marker, "position:y", -74.0, 0.5).set_trans(Tween.TRANS_SINE)

func face(dir: Vector2) -> void:
	doll.facing = dir

func _process(delta: float) -> void:
	if GameClock.is_paused() and not _path.is_empty():
		doll.moving = false
		return
	if _path.is_empty():
		doll.moving = false
		_idle_t += delta
		return
	var target := GameState.tile_center(_path[0]) + Vector2(0, 8)
	var d := target - position
	if d.length() < 2.0:
		position = target
		_path.pop_front()
		return
	var step := d.normalized() * SPEED * delta
	position += step if step.length() < d.length() else d
	doll.facing = d.normalized()
	doll.moving = true
