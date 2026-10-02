class_name ItemSlot
extends Control
## Draws one item stack: icon (2x), count, quality star, optional key hint.

const QUALITY_COLORS := [Color(0, 0, 0, 0), Color("#d8e0f0"), Color("#ffd447"), Color("#c890ff")]

var item_id := ""
var count := 0
var quality := 0
var selected := false
var hint := ""
var dim := false
var bar := -1.0
var bg := true

func set_item(id: String, n: int = 1, q: int = 0) -> void:
	item_id = id
	count = n
	quality = q
	tooltip_text = _tooltip()
	queue_redraw()

func _tooltip() -> String:
	if item_id == "":
		return ""
	var it: Dictionary = Data.get_item(item_id)
	var s := Data.item_name(item_id, quality)
	if it.has("desc"):
		s += "\n" + str(it.desc)
	var price := Data.sell_price(item_id, quality)
	if price > 0:
		s += "\nSells for %dg" % price
	if float(it.get("energy", 0)) > 0:
		s += "\n+%d energy" % int(it.energy)
	return s

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if bg:
		draw_style_box(UITheme.slot(selected), r)
	if item_id != "":
		var tex := Art.item(item_id)
		if tex:
			var isz := Vector2(32, 32) if size.x >= 32 and size.y >= 32 else Vector2(16, 16)
			var pos := (size - isz) / 2.0
			draw_texture_rect(tex, Rect2(pos.floor(), isz), false, Color(1, 1, 1, 0.45 if dim else 1.0))
		var f := UITheme.font()
		if count > 1:
			var t := str(count)
			var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
			var p := Vector2(size.x - w - 2, size.y - 2)
			for o in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
				draw_string(f, p + o, t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UITheme.OUTLINE)
			draw_string(f, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UITheme.CREAM)
		if quality > 0:
			var c: Color = QUALITY_COLORS[clampi(quality, 0, 3)]
			var sp := Vector2(3, size.y - 4)
			draw_rect(Rect2(sp + Vector2(-1, -4), Vector2(5, 5)), UITheme.OUTLINE)
			draw_rect(Rect2(sp + Vector2(0, -3), Vector2(3, 3)), c)
	if bar >= 0.0:
		draw_rect(Rect2(3, size.y - 5, size.x - 6, 3), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(3, size.y - 5, (size.x - 6) * clampf(bar, 0, 1), 3), Color("#7ac8ff"))
	if hint != "":
		draw_string(UITheme.font(), Vector2(3, 9), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(0.3, 0.2, 0.2, 0.7))
