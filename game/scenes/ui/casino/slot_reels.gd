class_name SlotReels
extends Control
## Five reels of three symbols. Spinning scrolls each strip and stops them left to right;
## winning lines are traced over the symbols afterwards.

signal stopped()

const CELL := 34.0
const LINE_COLORS := ["#ffd447", "#ff7a7a", "#7ac8ff", "#8fe36b", "#d8a8ff", "#ffb040", "#40e0d0", "#ff8fb0", "#c0c0ff", "#f0f0a0"]

var theme_id := "orchard"
var stops: Array = [0, 0, 0, 0, 0]
var offsets: Array = [0.0, 0.0, 0.0, 0.0, 0.0]
var wins: Array = []
var spinning := false
var _tex_cache: Dictionary = {}

func _init() -> void:
	custom_minimum_size = Vector2(CELL * 5 + 8, CELL * 3 + 8)
	clip_contents = true

func tex(sym: String) -> Texture2D:
	var key := theme_id + sym
	if not _tex_cache.has(key):
		var id: String = Slots.cfg().themes[theme_id].symbols.get(sym, "_star")
		_tex_cache[key] = Art.creature(id.substr(9), true) if id.begins_with("creature:") else Art.item(id)
	return _tex_cache[key]

func spin_to(final: Array, line_hits: Array) -> void:
	spinning = true
	wins = []
	var s := Slots.strip()
	var tw := create_tween().set_parallel(true)
	for reel in 5:
		var start := float(stops[reel])
		var turns := float(s.length() * (2 + reel))
		var target := float(final[reel])
		var end := start + turns + fposmod(target - start, s.length())
		tw.tween_method(func(x: float): offsets[reel] = x; queue_redraw(), start, end, 0.9 + reel * 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.set_parallel(false)
	tw.tween_callback(func():
		stops = final.duplicate()
		for i in 5:
			offsets[i] = float(stops[i])
		wins = line_hits
		spinning = false
		queue_redraw()
		stopped.emit())
	Audio.sfx("reels")

func _draw() -> void:
	var s := Slots.strip()
	draw_rect(Rect2(Vector2.ZERO, size), Color("#1e1420"))
	for reel in 5:
		var x := 4.0 + reel * CELL
		draw_rect(Rect2(x + 1, 4, CELL - 2, CELL * 3), Color("#fff6e0"))
		var off: float = offsets[reel]
		var base := int(floor(off))
		var frac := off - base
		for row in range(-1, 4):
			var sym := s[posmod(base + row, s.length())]
			var y := 4.0 + (row - frac) * CELL
			var t := tex(sym)
			if t:
				draw_texture_rect(t, Rect2(x + 1, y + 1, CELL - 2, CELL - 2), false, Color(1, 1, 1, 0.7 if spinning else 1.0))
		draw_rect(Rect2(x + 1, 4, CELL - 2, CELL * 3), UITheme.OUTLINE, false, 1.0)
	if not spinning:
		var lines: Array = Slots.cfg().lines
		for h in wins:
			var li := int(h[0])
			var col := Color(LINE_COLORS[li % LINE_COLORS.size()])
			var pts := PackedVector2Array()
			for reel in 5:
				pts.append(Vector2(4.0 + reel * CELL + CELL / 2.0, 4.0 + int(lines[li][reel]) * CELL + CELL / 2.0))
			draw_polyline(pts, Color(0, 0, 0, 0.5), 4.0)
			draw_polyline(pts, col, 2.0)
			for reel in int(h[2]):
				draw_rect(Rect2(4.0 + reel * CELL + 1, 4.0 + int(lines[li][reel]) * CELL, CELL - 2, CELL), col, false, 2.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color("#d8a040"), false, 3.0)
