class_name RaceTrack
extends Control
## Six lanes of turf; each runner follows the checkpoint path the host rolled.

signal finished()

const LANE := 22.0
const DURATION := 6.0

var runners: Array = []
var paths: Array = []
var pick := -1
var t := 0.0
var running := false
var _tex: Array = []

func _init() -> void:
	custom_minimum_size = Vector2(300, LANE * 6 + 8)

func set_runners(list: Array) -> void:
	runners = list
	paths = []
	t = 0.0
	_tex = []
	for r in list:
		_tex.append(Art.creature(str(r.species), true))
	queue_redraw()

func start(p: Array) -> void:
	paths = p
	t = 0.0
	running = true
	Audio.sfx("race")

func progress(i: int) -> float:
	if paths.is_empty() or i >= paths.size():
		return 0.0
	var path: Array = paths[i]
	var x := clampf(t / DURATION, 0.0, 1.0) * path.size()
	var k := int(floor(x))
	var a := 0.0 if k == 0 else float(path[mini(k - 1, path.size() - 1)])
	var b := float(path[mini(k, path.size() - 1)])
	return lerpf(a, b, smoothstep(0.0, 1.0, x - k))

func _process(delta: float) -> void:
	if not running:
		return
	t += delta
	if t >= DURATION:
		t = DURATION
		running = false
		finished.emit()
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#5aa04a"))
	var x0 := 26.0
	var x1 := size.x - 14.0
	for i in 6:
		var y := 4.0 + i * LANE
		draw_rect(Rect2(0, y, size.x, LANE), Color("#68b056") if i % 2 == 0 else Color("#5ea64e"))
		if i == pick:
			draw_rect(Rect2(0, y, size.x, LANE), Color(1, 0.85, 0.3, 0.25))
		draw_string(UITheme.font(), Vector2(4, y + 15), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color.WHITE)
	draw_line(Vector2(x0, 4), Vector2(x0, size.y - 4), Color(1, 1, 1, 0.7), 1.0)
	for k in 8:
		var y := 4.0 + k * (size.y - 8) / 8.0
		draw_rect(Rect2(x1, y, 4, (size.y - 8) / 16.0), Color.WHITE)
		draw_rect(Rect2(x1 + 4, y + (size.y - 8) / 16.0, 4, (size.y - 8) / 16.0), Color.WHITE)
		draw_rect(Rect2(x1, y + (size.y - 8) / 16.0, 4, (size.y - 8) / 16.0), Color("#222"))
		draw_rect(Rect2(x1 + 4, y, 4, (size.y - 8) / 16.0), Color("#222"))
	for i in runners.size():
		var px := lerpf(x0 - 10.0, x1 - 10.0, progress(i))
		var y := 4.0 + i * LANE
		var bob := absf(sin(t * 14.0 + i)) * 2.0 if running else 0.0
		if i < _tex.size() and _tex[i]:
			draw_texture_rect(_tex[i], Rect2(px - 10, y + 1 - bob, 20, 20), false)
