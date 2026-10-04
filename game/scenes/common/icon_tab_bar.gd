class_name IconTabBar
extends HBoxContainer
## A row of icon tabs for the menu shell. Each tab shows its icon, a short name and its hotkey.

signal tab_selected(id: String)

var current := ""
var _buttons: Dictionary = {}

func _init() -> void:
	add_theme_constant_override("separation", 3)
	alignment = BoxContainer.ALIGNMENT_CENTER

## icon is a Texture2D; hotkey is an input action name (shown as the bound key) or "".
func add_tab(id: String, title: String, icon: Texture2D, hotkey: String = "") -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.toggle_mode = true
	b.icon = icon
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", UITheme.fs(16))
	b.text = str(TranslationServer.translate(title))
	b.tooltip_text = b.text + (" (%s)" % Settings.key_name(hotkey) if hotkey != "" and InputMap.has_action(hotkey) else "")
	b.add_theme_font_size_override("font_size", UITheme.fs(9))
	b.pressed.connect(func(): select(id))
	_buttons[id] = b
	add_child(b)
	return b

func select(id: String) -> void:
	if not _buttons.has(id):
		return
	current = id
	for k in _buttons:
		_buttons[k].set_pressed_no_signal(k == id)
	tab_selected.emit(id)

func ids() -> Array:
	return _buttons.keys()

## Q / E (LB / RB) step through the tabs.
func step(dir: int) -> void:
	var keys := ids()
	if keys.is_empty():
		return
	var i := keys.find(current)
	select(keys[(i + dir + keys.size()) % keys.size()])

func button(id: String) -> Button:
	return _buttons.get(id)

## Narrow screens show icons only.
func set_compact(on: bool) -> void:
	for k in _buttons:
		var b: Button = _buttons[k]
		b.text = "" if on else b.tooltip_text.split(" (")[0]
