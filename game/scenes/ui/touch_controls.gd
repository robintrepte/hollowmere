class_name TouchControls
extends CanvasLayer
## On-screen controls for phones and tablets: a floating joystick on the left, Use / Talk / Bag buttons
## on the right and a menu button under the clock (it turns into a back button while a menu is open).
## Taps elsewhere still reach the game as clicks, so tapping a tile uses the tool on it and menus,
## hotbar slots and inventory cells work by tapping.

const STICK_R := 26.0
const KNOB_R := 11.0
const DEAD := 0.22
const LONG_PRESS := 0.45
const MOVES := ["move_left", "move_right", "move_up", "move_down"]
## Emulated mouse from a finger (iOS Safari often never sends ScreenTouch / ScreenDrag).
const MOUSE_ID := 100

## Touch controls are switched on (setting, or Auto on a touchscreen).
static var active := false
## A finger is on the joystick or a button, so the game should ignore the pointer.
static var owns_pointer := false

var main: Node
var _pad: Control
var _stick_index := -1
var _stick_origin := Vector2.ZERO
var _stick_pos := Vector2.ZERO
var _held: Dictionary = {}      # touch index -> button
var _long: Dictionary = {}      # touch index -> {pos, t}

static func refresh_active() -> void:
	match Settings.touch_controls:
		"on": active = true
		"off": active = false
		_: active = DisplayServer.is_touchscreen_available()

func _init(m: Node = null) -> void:
	main = m

func _ready() -> void:
	layer = 25
	refresh_active()
	_pad = TouchPad.new()
	_pad.owner_controls = self
	add_child(_pad)

## The joystick and action buttons show while walking around; only the back button shows over menus.
func in_world() -> bool:
	return active and main != null and main.get("player") != null and is_instance_valid(main.hud) and main.hud.visible

func menu_open() -> bool:
	return main != null and main.ui != null and main.ui.is_open()

func dialogue_open() -> bool:
	return main != null and main.ui != null and main.ui.dialogue.visible

func buttons() -> Array:
	if not in_world() or dialogue_open():
		return []
	var s := _pad.size
	var btm := _safe_bottom()
	var menu := {"id": "menu", "action": "menu", "c": Vector2(s.x - 20, 58), "r": 12.0}
	if menu_open():
		return [menu]
	return [
		{"id": "use", "action": "use_tool", "c": Vector2(s.x - 40, s.y - 88 - btm), "r": 22.0},
		{"id": "talk", "action": "interact", "c": Vector2(s.x - 92, s.y - 66 - btm), "r": 16.0},
		{"id": "bag", "action": "inventory", "c": Vector2(s.x - 94, s.y - 116 - btm), "r": 14.0},
		menu,
	]

func idle_stick() -> Vector2:
	return Vector2(64, _pad.size.y - 104 - _safe_bottom())

## Home-indicator / notch room. Portrait uses more; landscape keeps a sliver.
func _safe_bottom() -> float:
	var s := _pad.size
	return 22.0 if s.y > s.x else 8.0

func in_stick_zone(p: Vector2) -> bool:
	if not in_world() or menu_open():
		return false
	if p.distance_to(idle_stick()) <= STICK_R + 16.0:
		return true
	var s := _pad.size
	var hotbar_left := s.x / 2.0 - Hud.SLOT * 5.5 - 10
	if p.x > s.x * 0.42 or p.y < 84:
		return false
	return not (p.x > hotbar_left and p.y > s.y - 52)

## ScreenTouch on a phone is often in window pixels; the pad lives in the stretched canvas.
func _to_pad(pos: Vector2) -> Vector2:
	var pad_rect := Rect2(Vector2.ZERO, _pad.size)
	if pad_rect.has_point(pos):
		return pos
	var via: Vector2 = get_viewport().get_final_transform().affine_inverse() * pos
	return via if pad_rect.grow(8).has_point(via) or not pad_rect.has_point(pos) else pos

func stick_vector() -> Vector2:
	if _stick_index < 0:
		return Vector2.ZERO
	var v := (_stick_pos - _stick_origin) / STICK_R
	return v.limit_length(1.0)

func is_held(id: String) -> bool:
	for b in _held.values():
		if b.id == id:
			return true
	return false

func _input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_down(event.index, _to_pad(event.position))
		else:
			_touch_up(event.index)
	elif event is InputEventScreenDrag:
		_drag(event.index, _to_pad(event.position))

func _drag(index: int, pos: Vector2) -> void:
	if index == _stick_index:
		_stick_pos = pos
		var off := _stick_pos - _stick_origin
		if off.length() > STICK_R * 1.5:
			_stick_origin = _stick_pos - off.normalized() * STICK_R * 1.5
		_apply_stick()
		get_viewport().set_input_as_handled()
	if _long.has(index) and pos.distance_to(_long[index].pos) > 8.0:
		_long.erase(index)

func _touch_down(index: int, pos: Vector2) -> void:
	if index == _stick_index or _held.has(index):
		return
	for b in buttons():
		if pos.distance_to(b.c) <= b.r + 5.0:
			var already := is_held(b.id)
			_held[index] = b
			if not already:
				_send(b.action, true)
				Audio.sfx("tick", 0.0)
			_sync()
			get_viewport().set_input_as_handled()
			return
	if _stick_index < 0 and in_stick_zone(pos):
		_stick_index = index
		_stick_origin = pos
		_stick_pos = pos
		_sync()
		get_viewport().set_input_as_handled()
		return
	if menu_open():
		_long[index] = {"pos": pos, "t": 0.0}

func _touch_up(index: int) -> void:
	if index == _stick_index:
		_stick_index = -1
		for a in MOVES:
			Input.action_release(a)
	if _held.has(index):
		_send(_held[index].action, false)
		_held.erase(index)
	_long.erase(index)
	_sync()

func _apply_stick() -> void:
	var v := stick_vector()
	if v.length() < DEAD:
		v = Vector2.ZERO
	var strengths := [maxf(0.0, -v.x), maxf(0.0, v.x), maxf(0.0, -v.y), maxf(0.0, v.y)]
	for i in 4:
		if strengths[i] > 0.0:
			Input.action_press(MOVES[i], strengths[i])
		else:
			Input.action_release(MOVES[i])

func _send(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)

func _sync() -> void:
	owns_pointer = _stick_index >= 0 or not _held.is_empty()
	_pad.queue_redraw()

## Drops every finger, e.g. when a menu opens mid-press.
func release_all() -> void:
	for i in _held.keys():
		_touch_up(i)
	if _stick_index >= 0:
		_touch_up(_stick_index)

func _process(delta: float) -> void:
	visible = active and in_world()
	if not visible:
		if _stick_index >= 0 or not _held.is_empty():
			release_all()
		return
	if _stick_index >= 0 and menu_open():
		_touch_up(_stick_index)
	# iOS / some mobile browsers drop drag events after the first touch; the emulated
	# mouse still tracks the finger, so poll it while the stick is held.
	if _stick_index == MOUSE_ID:
		var mp := _pad.get_local_mouse_position()
		if _pad.get_rect().grow(120).has_point(mp):
			_drag(MOUSE_ID, mp)
	for i in _long.keys():
		_long[i].t += delta
		if _long[i].t >= LONG_PRESS:
			var top: Control = main.ui.stack[-1] if not main.ui.stack.is_empty() else null
			if top and top.has_method("touch_long_press"):
				top.touch_long_press(_long[i].pos)
			_long.erase(i)
	_pad.queue_redraw()


## Full-screen drawing surface. It only claims the pointer over the joystick zone and the buttons,
## so the emulated mouse click of a finger on the controls never reaches the world or the HUD.
class TouchPad extends Control:
	var owner_controls: TouchControls

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _has_point(p: Vector2) -> bool:
		if owner_controls == null:
			return false
		for b in owner_controls.buttons():
			if p.distance_to(b.c) <= b.r + 5.0:
				return true
		return owner_controls.in_stick_zone(p)

	func _gui_input(event: InputEvent) -> void:
		# Local coords are already canvas-space. Drive the stick here so a swallowed
		# emulated mouse click still moves the character.
		if owner_controls == null:
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				owner_controls._touch_down(TouchControls.MOUSE_ID, event.position)
			else:
				owner_controls._touch_up(TouchControls.MOUSE_ID)
			accept_event()
		elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			owner_controls._drag(TouchControls.MOUSE_ID, event.position)
			accept_event()
		elif event is InputEventMouse:
			accept_event()

	func _draw() -> void:
		var tc := owner_controls
		if tc == null or not tc.in_world():
			return
		if not tc.menu_open() and not tc.dialogue_open():
			_draw_stick(tc)
		for b in tc.buttons():
			_draw_button(b, tc.is_held(b.id), tc)

	func _draw_stick(tc: TouchControls) -> void:
		var origin := tc._stick_origin if tc._stick_index >= 0 else tc.idle_stick()
		var alpha := 0.9 if tc._stick_index >= 0 else 0.45
		draw_circle(origin, STICK_R + 2, Color(0, 0, 0, 0.18 * alpha))
		draw_arc(origin, STICK_R, 0, TAU, 32, Color(UITheme.PARCHMENT, 0.7 * alpha), 2.0)
		var knob := origin + tc.stick_vector() * STICK_R
		draw_circle(knob + Vector2(0, 2), KNOB_R, Color(0, 0, 0, 0.25 * alpha))
		draw_circle(knob, KNOB_R, Color(UITheme.PARCHMENT, alpha))
		draw_arc(knob, KNOB_R, 0, TAU, 24, Color(UITheme.OUTLINE, alpha), 2.0)

	func _draw_button(b: Dictionary, held: bool, tc: TouchControls) -> void:
		var c: Vector2 = b.c + (Vector2(0, 1) if held else Vector2.ZERO)
		var r: float = b.r
		draw_circle(b.c + Vector2(0, 2), r, Color(0, 0, 0, 0.25))
		draw_circle(c, r, UITheme.PARCHMENT_DK if held else Color(UITheme.PARCHMENT, 0.92))
		draw_arc(c, r, 0, TAU, 32, UITheme.OUTLINE, 2.0)
		match b.id:
			"use":
				var p := GameState.local_player()
				var id := p.selected_id() if p else ""
				var tex := Art.item(id) if id != "" else Art.item("_star")
				draw_texture_rect(tex, Rect2(c - Vector2(16, 16), Vector2(32, 32)), false)
			"bag":
				draw_texture_rect(Art.item("_backpack"), Rect2(c - Vector2(8, 8), Vector2(16, 16)), false)
			"talk":
				draw_rect(Rect2(c + Vector2(-8, -7), Vector2(16, 11)), UITheme.CREAM)
				draw_rect(Rect2(c + Vector2(-8, -7), Vector2(16, 11)), UITheme.OUTLINE, false, 1.0)
				draw_rect(Rect2(c + Vector2(-4, 4), Vector2(3, 3)), UITheme.OUTLINE)
				for k in 3:
					draw_rect(Rect2(c + Vector2(-5 + k * 4, -2), Vector2(2, 2)), UITheme.WOOD_DK)
			"menu":
				if tc.menu_open():
					for k in 5:
						draw_rect(Rect2(c + Vector2(-5 + k * 2, -5 + k * 2), Vector2(2, 2)), UITheme.WOOD_DK)
						draw_rect(Rect2(c + Vector2(3 - k * 2, -5 + k * 2), Vector2(2, 2)), UITheme.WOOD_DK)
				else:
					for k in 3:
						draw_rect(Rect2(c + Vector2(-6, -5 + k * 4), Vector2(12, 2)), UITheme.WOOD_DK)
