class_name CoinLabel
extends HBoxContainer
## A gold coin icon next to an amount. Replaces the old "123g" text everywhere money is shown.
## Also used for casino chips (icon "_chip").

var label: Label
var icon: TextureRect
var amount: int = 0
var compact := false
var _base_color: Color

func _init(n: int = 0, size: int = 10, col: Color = UITheme.INK, icon_id: String = "_coin", short_form: bool = false) -> void:
	add_theme_constant_override("separation", 2)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	compact = short_form
	_base_color = col
	icon = UITheme.icon_rect(Art.item(icon_id), UITheme.fs(size) + 2)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(icon)
	label = UITheme.label("", size, col)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(label)
	set_amount(n)

func set_amount(n: int) -> void:
	amount = n
	label.text = Num.short(n) if compact else Num.group(n)

## Red when the player can't pay this much.
func set_affordable(ok: bool) -> void:
	label.add_theme_color_override("font_color", _base_color if ok else UITheme.HEART)

## A price that turns red when the farm can't afford it.
static func price(n: int, size: int = 10, col: Color = UITheme.INK) -> CoinLabel:
	var c := CoinLabel.new(n, size, col)
	c.set_affordable(GameState.money() >= n)
	return c

## Text for places that can't hold a control (toasts, popups, tooltips): "1.234 Gold".
static func text(n: int) -> String:
	return TranslationServer.translate("%s gold") % Num.group(n)
