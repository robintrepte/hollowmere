class_name RouletteWheel
extends Control
## The wheel: 37 pockets in real order, turning one way while the ball runs the other and drops in.

signal settled(number: int)

var wheel_angle := 0.0
var ball_angle := 0.0
var ball_radius := 1.0          # 1 = outer track, 0 = pocket ring
var number := -1
var spinning := false

func _init() -> void:
	custom_minimum_size = Vector2(124, 124)

func _pocket_angle(i: int) -> float:
	return TAU * i / Roulette.WHEEL.size() - PI / 2.0

## Spins to land on n. Emits settled when the ball rests.
func spin_to(n: int, seconds: float = 3.6) -> void:
	spinning = true
	number = -1
	var idx := Roulette.WHEEL.find(n)
	var w0 := wheel_angle
	var w1 := w0 + TAU * 2.0 + randf() * TAU
	var b0 := ball_angle
	var b1 := w1 + _pocket_angle(idx) - TAU * 5.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "wheel_angle", w1, seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(t: float):
		ball_angle = lerpf(b0, b1, 1.0 - pow(1.0 - t, 3.0))
		ball_radius = clampf(1.0 - (t - 0.55) / 0.35, 0.0, 1.0)
		queue_redraw(), 0.0, 1.0, seconds)
	tw.set_parallel(false)
	tw.tween_callback(func():
		spinning = false
		number = n
		Audio.sfx("ball")
		queue_redraw()
		settled.emit(n))
	Audio.sfx("wheel")

func _process(_dt: float) -> void:
	if spinning:
		queue_redraw()

func _draw() -> void:
	var c := size / 2.0
	var R := minf(size.x, size.y) / 2.0 - 2.0
	draw_circle(c, R + 2, UITheme.OUTLINE)
	draw_circle(c, R, Color("#6a3a1e"))
	draw_circle(c, R * 0.86, Color("#3a2010"))
	var n := Roulette.WHEEL.size()
	var outer := R * 0.84
	var inner := R * 0.62
	for i in n:
		var a0 := wheel_angle + _pocket_angle(i) - PI / n
		var a1 := a0 + TAU / n
		var num: int = Roulette.WHEEL[i]
		var col := Color("#2a9a5a") if num == 0 else (Color("#c03038") if Roulette.color(num) == "red" else Color("#26202a"))
		if num == number:
			col = col.lightened(0.35)
		var pts := PackedVector2Array([c + Vector2(cos(a0), sin(a0)) * inner, c + Vector2(cos(a0), sin(a0)) * outer,
			c + Vector2(cos(a1), sin(a1)) * outer, c + Vector2(cos(a1), sin(a1)) * inner])
		draw_colored_polygon(pts, col)
		draw_line(c + Vector2(cos(a0), sin(a0)) * inner, c + Vector2(cos(a0), sin(a0)) * outer, Color("#d8b860"), 1.0)
	draw_circle(c, inner, Color("#8a5a2a"))
	draw_circle(c, inner * 0.55, Color("#b08040"))
	for k in 4:
		var a := wheel_angle + TAU * k / 4.0
		draw_line(c, c + Vector2(cos(a), sin(a)) * inner * 0.8, Color("#e8c870"), 2.0)
	draw_circle(c, 4, Color("#e8c870"))
	if number >= 0 or spinning:
		var br := lerpf((outer + inner) / 2.0, R * 0.93, ball_radius)
		var bp := c + Vector2(cos(ball_angle), sin(ball_angle)) * br
		draw_circle(bp + Vector2(0.5, 1), 3.0, Color(0, 0, 0, 0.4))
		draw_circle(bp, 3.0, Color("#fffaf0"))
	if number >= 0 and not spinning:
		var f := UITheme.font()
		var t := str(number)
		var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_circle(c, 12, Color(0, 0, 0, 0.6))
		draw_string(f, c + Vector2(-w / 2.0, 5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
