class_name TargetCursor
extends Node2D
## Pulsing outline on the tile the player will act on.

var tile := Vector2i(-99, -99)
var active := false
var ok := true
var _t := 0.0

func show_at(t: Vector2i, can_act: bool) -> void:
	tile = t
	ok = can_act
	active = true
	position = Vector2(t.x * Tiles.TILE, t.y * Tiles.TILE)
	queue_redraw()

func hide_cursor() -> void:
	if active:
		active = false
		queue_redraw()

func _process(delta: float) -> void:
	if active:
		_t += delta
		queue_redraw()

func _draw() -> void:
	if not active:
		return
	var a := 0.55 + 0.25 * sin(_t * 6.0)
	var c := Color(1, 1, 1, a) if ok else Color(1, 0.5, 0.4, a * 0.7)
	var s := float(Tiles.TILE)
	var l := 7.0
	for corner in [Vector2(0, 0), Vector2(s, 0), Vector2(0, s), Vector2(s, s)]:
		var dx := 1.0 if corner.x == 0 else -1.0
		var dy := 1.0 if corner.y == 0 else -1.0
		draw_line(corner + Vector2(dx, dy), corner + Vector2(dx * l, dy), c, 2)
		draw_line(corner + Vector2(dx, dy), corner + Vector2(dx, dy * l), c, 2)
