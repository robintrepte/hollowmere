class_name RouletteTable
extends Control
## The European layout. Click a number for a straight bet, its edge for a split, a corner for a
## corner bet, the bottom edge for a street and a bottom corner for a six line. Right-click removes.

signal changed()

const X0 := 16.0
const CW := 20.0
const CH := 18.0
const EDGE := 0.28
const FELT := Color("#2f7a4a")
const LINE := Color("#e8d8a0")

var bets: Dictionary = {}       # key -> {bet, at}
var chip_value := 10
var winner := -1
var _hover: Dictionary = {}

func _init() -> void:
	custom_minimum_size = Vector2(X0 + CW * 12 + 22, CH * 3 + 34)
	mouse_filter = Control.MOUSE_FILTER_STOP

static func num_at(c: int, r: int) -> int:
	return 3 * c + 3 - r

func _cell_center(c: int, r: int) -> Vector2:
	return Vector2(X0 + c * CW + CW / 2.0, r * CH + CH / 2.0)

static func _key(bet: Dictionary) -> String:
	var nums: Array = bet.get("nums", []).duplicate()
	nums.sort()
	return "%s:%s:%d" % [bet.kind, ",".join(nums.map(func(x): return str(x))), int(bet.get("n", 0))]

## The bet spot under a point: {bet: {kind, nums|n}, at: Vector2}, or {}.
func spot_at(pos: Vector2) -> Dictionary:
	var grid_w := CW * 12
	if pos.y < 0:
		return {}
	if pos.y < CH * 3:
		if pos.x < 0:
			return {}
		if pos.x < X0:
			return {"bet": {"kind": "straight", "nums": [0]}, "at": Vector2(X0 / 2.0, CH * 1.5)}
		if pos.x >= X0 + grid_w:
			if pos.x > X0 + grid_w + 22:
				return {}
			var row := clampi(int(pos.y / CH), 0, 2)
			return {"bet": {"kind": "column", "n": 3 - row}, "at": Vector2(X0 + grid_w + 11, row * CH + CH / 2.0)}
		return _inside(pos)
	var yd := CH * 3
	if pos.x < X0 or pos.x >= X0 + grid_w:
		return {}
	if pos.y < yd + 16:
		var d := int((pos.x - X0) / (CW * 4))
		return {"bet": {"kind": "dozen", "n": d + 1}, "at": Vector2(X0 + CW * 4 * d + CW * 2, yd + 8)}
	if pos.y < yd + 32:
		var i := int((pos.x - X0) / (CW * 2))
		var kinds := ["low", "even", "red", "black", "odd", "high"]
		return {"bet": {"kind": kinds[i]}, "at": Vector2(X0 + CW * 2 * i + CW, yd + 24)}
	return {}

func _inside(pos: Vector2) -> Dictionary:
	var lx := (pos.x - X0) / CW
	var ly := pos.y / CH
	var c := int(lx)
	var r := int(ly)
	var fx := lx - c
	var fy := ly - r
	var n := num_at(c, r)
	var left := fx < EDGE
	var right := fx > 1.0 - EDGE
	var top := fy < EDGE
	var bot := fy > 1.0 - EDGE
	var corner_x := X0 + (c if left else c + 1) * CW
	if bot and r == 2:
		if (left and c > 0) or (right and c < 11):
			var c0 := c - 1 if left else c
			return {"bet": {"kind": "sixline", "nums": range(3 * c0 + 1, 3 * c0 + 7)}, "at": Vector2(corner_x, CH * 3)}
		if left and c == 0:
			return {"bet": {"kind": "corner", "nums": [0, 1, 2, 3]}, "at": Vector2(X0, CH * 3)}
		return {"bet": {"kind": "street", "nums": [3 * c + 1, 3 * c + 2, 3 * c + 3]}, "at": Vector2(X0 + c * CW + CW / 2.0, CH * 3)}
	if (left or right) and (top or bot):
		var c2 := c - 1 if left else c + 1
		var r2 := r - 1 if top else r + 1
		var y := (r if top else r + 1) * CH
		if r2 >= 0 and r2 <= 2:
			if c2 == -1:
				var trio := [0, n, num_at(0, r2)]
				return {"bet": {"kind": "street", "nums": trio}, "at": Vector2(X0, y)}
			if c2 <= 11:
				return {"bet": {"kind": "corner", "nums": [n, num_at(c2, r), num_at(c, r2), num_at(c2, r2)]}, "at": Vector2(corner_x, y)}
	if left or right:
		var c2 := c - 1 if left else c + 1
		if c2 == -1:
			return {"bet": {"kind": "split", "nums": [0, n]}, "at": Vector2(X0, r * CH + CH / 2.0)}
		if c2 <= 11:
			return {"bet": {"kind": "split", "nums": [n, num_at(c2, r)]}, "at": Vector2(corner_x, r * CH + CH / 2.0)}
	if top or bot:
		var r2 := r - 1 if top else r + 1
		if r2 >= 0 and r2 <= 2:
			return {"bet": {"kind": "split", "nums": [n, num_at(c, r2)]}, "at": Vector2(X0 + c * CW + CW / 2.0, (r if top else r + 1) * CH)}
	return {"bet": {"kind": "straight", "nums": [n]}, "at": _cell_center(c, r)}

func total() -> int:
	var s := 0
	for k in bets:
		s += int(bets[k].bet.amount)
	return s

func bet_list() -> Array:
	var out: Array = []
	for k in bets:
		out.append(bets[k].bet.duplicate())
	return out

func set_bets(list: Array) -> void:
	bets.clear()
	for b in list:
		var s := spot_for(b)
		if not s.is_empty():
			s.bet["amount"] = int(b.amount)
			bets[_key(b)] = s
	queue_redraw()
	changed.emit()

## Where a saved bet sits on the layout (for Rebet).
func spot_for(bet: Dictionary) -> Dictionary:
	for y in range(0, int(size.y), 3):
		for x in range(0, int(size.x), 3):
			var s := spot_at(Vector2(x, y))
			if not s.is_empty() and _key(s.bet) == _key(bet):
				return s
	return {}

func clear() -> void:
	bets.clear()
	winner = -1
	queue_redraw()
	changed.emit()

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var s := spot_at(e.position)
		if _key(s.get("bet", {"kind": ""})) != _key(_hover.get("bet", {"kind": ""})):
			_hover = s
			queue_redraw()
	elif e is InputEventMouseButton and e.pressed:
		var s := spot_at(e.position)
		if s.is_empty():
			return
		var k := _key(s.bet)
		if e.button_index == MOUSE_BUTTON_LEFT:
			if not bets.has(k):
				s.bet["amount"] = 0
				bets[k] = s
			bets[k].bet.amount = int(bets[k].bet.amount) + chip_value
			Audio.sfx("chips")
		elif e.button_index == MOUSE_BUTTON_RIGHT and bets.has(k):
			bets.erase(k)
			Audio.sfx("ui_back")
		winner = -1
		queue_redraw()
		changed.emit()
		accept_event()

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = {}
		queue_redraw()

func _num_color(n: int) -> Color:
	match Roulette.color(n):
		"red": return Color("#c03038")
		"black": return Color("#26202a")
	return Color("#2a9a5a")

func _draw() -> void:
	var f := UITheme.font()
	var grid_w := CW * 12
	var covered: Array = Roulette.covers(_hover.bet) if not _hover.is_empty() else []
	draw_rect(Rect2(Vector2(-4, -4), size + Vector2(8, 8)), FELT)
	var zr := Rect2(0, 0, X0, CH * 3)
	draw_rect(zr, _num_color(0).lightened(0.3 if 0 in covered else 0.0))
	_text(f, "0", zr, Color.WHITE)
	for c in 12:
		for r in 3:
			var n := num_at(c, r)
			var rr := Rect2(X0 + c * CW, r * CH, CW, CH)
			draw_rect(rr.grow(-1), _num_color(n).lightened(0.3 if n in covered else 0.0))
			_text(f, str(n), rr, Color.WHITE)
			if n == winner:
				draw_rect(rr.grow(-1), Color("#ffd447"), false, 2.0)
	if winner == 0:
		draw_rect(zr.grow(-1), Color("#ffd447"), false, 2.0)
	for r in 3:
		var cr := Rect2(X0 + grid_w, r * CH, 22, CH)
		var on: bool = not _hover.is_empty() and _hover.bet.kind == "column" and int(_hover.bet.n) == 3 - r
		draw_rect(cr.grow(-1), FELT.lightened(0.2 if on else 0.08))
		_text(f, "2:1", cr, LINE)
	var yd := CH * 3
	var dozens := ["1st 12", "2nd 12", "3rd 12"]
	for d in 3:
		var dr := Rect2(X0 + CW * 4 * d, yd, CW * 4, 16)
		var on: bool = not _hover.is_empty() and _hover.bet.kind == "dozen" and int(_hover.bet.n) == d + 1
		draw_rect(dr.grow(-1), FELT.lightened(0.2 if on else 0.08))
		_text(f, TranslationServer.translate(dozens[d]), dr, LINE)
	var outs := [["low", "1-18"], ["even", "Even"], ["red", ""], ["black", ""], ["odd", "Odd"], ["high", "19-36"]]
	for i in outs.size():
		var orr := Rect2(X0 + CW * 2 * i, yd + 16, CW * 2, 16)
		var on: bool = not _hover.is_empty() and _hover.bet.kind == outs[i][0]
		draw_rect(orr.grow(-1), FELT.lightened(0.2 if on else 0.08))
		if outs[i][0] in ["red", "black"]:
			var dc := orr.get_center()
			draw_colored_polygon(PackedVector2Array([dc + Vector2(0, -6), dc + Vector2(9, 0), dc + Vector2(0, 6), dc + Vector2(-9, 0)]), Color("#c03038") if outs[i][0] == "red" else Color("#26202a"))
		else:
			_text(f, TranslationServer.translate(outs[i][1]), orr, LINE)
	draw_rect(Rect2(0, 0, X0 + grid_w + 22, yd + 32), LINE, false, 1.0)
	for k in bets:
		var s: Dictionary = bets[k]
		CasinoPanel.draw_chip(self, s.at, 6.5, int(s.bet.amount))
	if not _hover.is_empty() and not bets.has(_key(_hover.bet)):
		draw_circle(_hover.at, 4.0, Color(1, 1, 1, 0.55))

func _text(f: Font, t: String, r: Rect2, col: Color) -> void:
	var fs := 8
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(f, r.get_center() + Vector2(-w / 2.0, fs * 0.36), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
