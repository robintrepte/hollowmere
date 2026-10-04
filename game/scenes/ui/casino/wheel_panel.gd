class_name WheelPanel
extends CasinoPanel
## The free daily prize wheel by the entrance: one spin per day for chips, dust, essence or a book.

var _wheel: PrizeWheel
var _btn: Button
var _msg: Label

class PrizeWheel extends Control:
	signal settled()
	var angle := 0.0
	var segs: Array = []
	var _icons: Array = []

	func _init(list: Array) -> void:
		segs = list
		custom_minimum_size = Vector2(170, 170)
		for s in segs:
			_icons.append(null if s.has("chips") else Art.item("enchanted_book" if str(s.item) == "book" else str(s.item)))

	func spin_to(i: int) -> void:
		var step := TAU / segs.size()
		var target := -(i + 0.5) * step
		var end := angle + TAU * 5 + fposmod(target - angle, TAU)
		var tw := create_tween()
		tw.tween_property(self, "angle", end, 4.0).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tw.tween_callback(func(): settled.emit())

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) / 2.0 - 6.0
		var step := TAU / segs.size()
		draw_circle(c + Vector2(0, 2), r + 4, Color(0, 0, 0, 0.3))
		draw_circle(c, r + 4, Color("#d8a040"))
		for i in segs.size():
			var a0 := angle + i * step - PI / 2.0
			var pts := PackedVector2Array([c])
			for k in 9:
				var a := a0 + step * k / 8.0
				pts.append(c + Vector2(cos(a), sin(a)) * r)
			var col := Color("#c03038") if i % 2 == 0 else Color("#f4ead0")
			if not segs[i].has("chips"):
				col = Color("#7a4ab0")
			draw_colored_polygon(pts, col)
			var mid := a0 + step / 2.0
			var at := c + Vector2(cos(mid), sin(mid)) * r * 0.68
			if _icons[i]:
				draw_texture_rect(_icons[i], Rect2(at - Vector2(9, 9), Vector2(18, 18)), false)
			else:
				var t := Num.short(int(segs[i].chips))
				var f := UITheme.font()
				var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
				draw_string(f, at + Vector2(-w / 2.0, 3), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color.WHITE if i % 2 == 0 else UITheme.INK)
		draw_circle(c, 10, Color("#d8a040"))
		draw_circle(c, 5, Color("#fff2c0"))
		draw_colored_polygon(PackedVector2Array([c + Vector2(-7, -r - 8), c + Vector2(7, -r - 8), c + Vector2(0, -r + 6)]), Color("#ffd447"))
		draw_polyline(PackedVector2Array([c + Vector2(-7, -r - 8), c + Vector2(7, -r - 8), c + Vector2(0, -r + 6), c + Vector2(-7, -r - 8)]), UITheme.OUTLINE, 1.0)

func _init() -> void:
	super("wheel")

func title() -> String:
	return tr("Wheel of Fortune")

func rules() -> String:
	return tr("One free spin every day. Every prize is shown on the wheel; the purple fields hold items instead of chips. Nothing to stake, nothing to lose.")

func panel_size() -> Vector2:
	return Vector2(320, 300)

func build() -> void:
	_wheel = PrizeWheel.new(Casino.cfg().wheel)
	_wheel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	body.add_child(_wheel)
	_msg = UITheme.label("", 9, UITheme.WOOD_DK)
	_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_msg)
	_btn = UITheme.button("Spin", _spin)
	_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	body.add_child(_btn)
	_sync()

func _sync() -> void:
	var ready := Casino.wheel_ready(me())
	_btn.disabled = not ready or _busy
	if not ready and _msg.text == "":
		_msg.text = tr("Come back tomorrow for your next spin.")

func _spin() -> void:
	_btn.disabled = true
	hold_chips = true
	var r := await act("casino_wheel_act", [])
	if not r.get("ok", false):
		hold_chips = false
		_sync()
		return
	_busy = true
	Audio.sfx("wheel")
	_wheel.spin_to(int(r.segment))
	await _wheel.settled
	_busy = false
	hold_chips = false
	if not is_inside_tree():
		return
	refresh_chips()
	Audio.sfx("jackpot" if int(r.get("chips", 0)) >= 500 or r.has("item") else "chips")
	if r.has("item"):
		_msg.text = tr("You won %s!") % Data.item_name(str(r.item))
	else:
		_msg.text = tr("You won %s chips!") % Num.group(int(r.chips))
	_sync()
