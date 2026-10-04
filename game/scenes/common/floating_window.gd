class_name FloatingWindow
extends PanelContainer
## A small draggable window with a title bar and a close button (bags, chests, the shipping bin).
## Remembers where the player left it per `window_id` in the account profile, stays on screen
## and comes to the front when touched.

signal closed

const SNAP := 8.0

var window_id := ""
var title_label: Label
var body: VBoxContainer
var _dragging := false
var _drag_from := Vector2.ZERO

func _init(title: String = "", id: String = "") -> void:
	window_id = id
	add_theme_stylebox_override("panel", UITheme.parchment(6))
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	add_child(v)
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", UITheme.box(UITheme.WOOD, UITheme.OUTLINE, 1, 2, 3, false))
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	bar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	bar.gui_input.connect(_on_bar_input)
	v.add_child(bar)
	var h := HBoxContainer.new()
	bar.add_child(h)
	title_label = UITheme.label(title, 10, UITheme.CREAM)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(title_label)
	var x := Button.new()
	x.text = "×"
	x.focus_mode = Control.FOCUS_ALL
	x.custom_minimum_size = Vector2(22, 18)
	x.tooltip_text = TranslationServer.translate("Close")
	x.pressed.connect(close)
	h.add_child(x)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 3)
	v.add_child(body)

func _ready() -> void:
	gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			raise())
	_place.call_deferred()

func close() -> void:
	_remember()
	closed.emit()
	queue_free()

func raise() -> void:
	var p := get_parent()
	if p:
		p.move_child(self, p.get_child_count() - 1)

func _place() -> void:
	var saved = Settings.profile_get("win:" + window_id) if window_id != "" else null
	if saved is Array and saved.size() == 2:
		position = Vector2(float(saved[0]), float(saved[1]))
	elif position == Vector2.ZERO:
		position = (get_viewport_rect().size - size) * 0.5
	_keep_on_screen()

func _keep_on_screen() -> void:
	var view := get_viewport_rect().size
	var p := position
	p.x = clampf(p.x, 0.0, maxf(0.0, view.x - size.x))
	p.y = clampf(p.y, 0.0, maxf(0.0, view.y - size.y))
	if p.x < SNAP:
		p.x = 0.0
	if p.y < SNAP:
		p.y = 0.0
	if view.x - (p.x + size.x) < SNAP:
		p.x = maxf(0.0, view.x - size.x)
	if view.y - (p.y + size.y) < SNAP:
		p.y = maxf(0.0, view.y - size.y)
	position = p

func _on_bar_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_dragging = e.pressed
		_drag_from = e.global_position - global_position
		raise()
		if not e.pressed:
			_remember()
		accept_event()
	elif e is InputEventScreenTouch:
		_dragging = e.pressed
		_drag_from = e.position
		if not e.pressed:
			_remember()
		accept_event()
	elif (e is InputEventMouseMotion or e is InputEventScreenDrag) and _dragging:
		global_position = e.global_position - _drag_from if e is InputEventMouseMotion else global_position + e.relative
		_keep_on_screen()
		accept_event()

func _remember() -> void:
	if window_id != "" and is_inside_tree():
		Settings.profile_set("win:" + window_id, [roundi(position.x), roundi(position.y)])
