class_name EmoteWheel
extends Control
## Eight-slot radial picker. G / right stick / the HUD button opens it; a click or a second
## press on a slot plays that emote. Dragging a known emote onto a slot from the Emotes tab
## is how the wheel is rearranged.

signal closed

const R := 78.0
const SLOT_R := 22.0

var _slots: Array = []
var _hover := -1
var _hold := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 40
	_slots = Emotes.wheel(GameState.local_player())
	draw.connect(_draw_wheel)
	queue_redraw()

func _draw_wheel() -> void:
	var c := size * 0.5
	draw_circle(c, R + 28.0, Color(0.08, 0.06, 0.07, 0.55))
	for i in Emotes.WHEEL_SLOTS:
		var p: Vector2 = c + _dir(i) * R
		var id := str(_slots[i]) if i < _slots.size() else ""
		var on := i == _hover
		var col := Color("#ffd23f") if on else UITheme.WOOD
		draw_circle(p, SLOT_R + (2.0 if on else 0.0), col)
		draw_circle(p, SLOT_R - 2.0, UITheme.CREAM)
		if id != "" and Emotes.exists(id):
			var tex := Emotes.icon(id)
			if tex:
				var s := Vector2(20, 20)
				draw_texture_rect(tex, Rect2(p - s * 0.5, s), false)
		else:
			draw_circle(p, 3.0, UITheme.MUTED)
	draw_circle(c, 18.0, UITheme.PARCHMENT)
	var hint := tr("Emote")
	draw_string(UITheme.font(), c + Vector2(-hint.length() * 3.0, 4), hint, HORIZONTAL_ALIGNMENT_CENTER, -1, UITheme.fs(8), UITheme.INK)

func _dir(i: int) -> Vector2:
	var a := -PI * 0.5 + i * TAU / float(Emotes.WHEEL_SLOTS)
	return Vector2(cos(a), sin(a))

func _slot_at(pos: Vector2) -> int:
	var c := size * 0.5
	for i in Emotes.WHEEL_SLOTS:
		if pos.distance_to(c + _dir(i) * R) <= SLOT_R + 4.0:
			return i
	return -1

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = _slot_at(event.position)
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var i := _slot_at(event.position)
		if i >= 0:
			_play(i)
		else:
			closed.emit()
		accept_event()
	elif event.is_action_pressed("ui_cancel") or event.is_action_pressed("emote"):
		if not _hold:
			closed.emit()
		accept_event()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_released("emote") and _hold:
		if _hover >= 0:
			_play(_hover)
		else:
			closed.emit()
		accept_event()
	elif event is InputEventJoypadMotion:
		var x := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
		var y := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
		if Vector2(x, y).length() > 0.45:
			var a := Vector2(x, y).angle() + PI * 0.5
			if a < 0.0:
				a += TAU
			_hover = int(round(a / (TAU / float(Emotes.WHEEL_SLOTS)))) % Emotes.WHEEL_SLOTS
			queue_redraw()

func _play(i: int) -> void:
	var id := str(_slots[i]) if i < _slots.size() else ""
	if id != "" and Emotes.knows(GameState.local_player(), id):
		Coop.send_emote(id)
	closed.emit()
