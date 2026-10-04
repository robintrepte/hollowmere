class_name SpeechBubble
extends Node2D
## A bubble over a character's head for chat lines and emote icons. Messages queue up; each stays
## for a few seconds plus reading time.

const MAX_W := 120.0
const BASE_Y := -62.0
const TEXT_TIME := 5.0
const PER_CHAR := 0.05
const MAX_QUEUE := 4

var _queue: Array = []
var _panel: PanelContainer
var _label: Label
var _icon: TextureRect
var _tail: Polygon2D
var _left := 0.0

func _ready() -> void:
	z_as_relative = false
	z_index = 90
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.box(UITheme.CREAM, UITheme.OUTLINE, 1, 3, 2, false))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(h)
	_icon = UITheme.icon_rect(null, 16)
	h.add_child(_icon)
	_label = UITheme.label("", 8, UITheme.INK)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	h.add_child(_label)
	_tail = Polygon2D.new()
	_tail.polygon = PackedVector2Array([Vector2(-3, 0), Vector2(3, 0), Vector2(0, 4)])
	_tail.color = UITheme.CREAM
	add_child(_tail)
	visible = false

## Queues a chat line; the oldest waiting line drops when too many pile up.
func say(text: String) -> void:
	_queue.append({"text": text})
	while _queue.size() > MAX_QUEUE:
		_queue.pop_front()
	if _left <= 0.0:
		_next()

## Shows an icon right away unless a chat line is up, then it waits its turn.
func show_icon(tex: Texture2D, seconds: float = 2.0) -> void:
	_queue.append({"icon": tex, "time": seconds})
	if _left <= 0.0:
		_next()

func busy() -> bool:
	return _left > 0.0 or not _queue.is_empty()

func _next() -> void:
	if _queue.is_empty():
		visible = false
		_left = 0.0
		return
	var m: Dictionary = _queue.pop_front()
	var text := str(m.get("text", ""))
	_icon.visible = m.has("icon")
	_icon.texture = m.get("icon")
	_label.visible = text != ""
	_label.text = text
	if text != "":
		var w := _label.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _label.get_theme_font_size("font_size")).x
		_label.custom_minimum_size = Vector2(minf(ceilf(w) + 1.0, MAX_W), 0)
		_left = TEXT_TIME + text.length() * PER_CHAR
	else:
		_left = float(m.get("time", 2.0))
	_panel.reset_size()
	visible = true
	scale = Vector2(0.6, 0.6)
	create_tween().tween_property(self, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _process(delta: float) -> void:
	if not visible:
		return
	_panel.position = Vector2(-roundf(_panel.size.x * 0.5), BASE_Y - _panel.size.y)
	_tail.position = Vector2(0, BASE_Y - 1)
	_left -= delta
	if _left <= 0.0:
		_next()
