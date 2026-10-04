class_name Badge
extends PanelContainer
## A small coloured tag: "Recommended", "New", "Fits the type".

func _init(text: String = "", col: Color = UITheme.COIN, ink: Color = UITheme.INK) -> void:
	add_theme_stylebox_override("panel", UITheme.box(col, UITheme.OUTLINE, 1, 3, 2, false))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.label(text, 8, ink)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
