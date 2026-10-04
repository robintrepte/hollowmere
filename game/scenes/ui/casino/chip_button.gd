class_name ChipButton
extends BaseButton
## One chip in the chip picker.

var value := 1
var color := Color.WHITE
var selected := false

func _init(v: int = 1, c: Color = Color.WHITE) -> void:
	value = v
	color = c
	custom_minimum_size = Vector2(22, 22)
	focus_mode = Control.FOCUS_ALL
	tooltip_text = TranslationServer.translate("%s chips") % Num.group(v)

func _draw() -> void:
	var c := size / 2.0 + Vector2(0, -2 if selected else 0)
	CasinoPanel.draw_chip(self, c, 9.0, value, selected)
