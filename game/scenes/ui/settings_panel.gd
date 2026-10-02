class_name SettingsPanel
extends PanelContainer
## Audio, clock speed, display, accessibility and key rebinding.

signal closed

const REBINDABLE := ["move_up", "move_down", "move_left", "move_right", "use_tool", "interact", "inventory", "party", "journal", "map", "run", "rotate_item"]

var _waiting_action := ""
var _bind_buttons: Dictionary = {}

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -170
	offset_right = 170
	offset_top = -160
	offset_bottom = 160
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := UITheme.label("Settings", 14, UITheme.WOOD_DK)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(UITheme.button("Done", func(): Settings.save_settings(); closed.emit()))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 3)
	sc.add_child(body)
	body.add_child(UITheme.label("Audio", 11, UITheme.WOOD))
	_slider(body, "Master", Settings.master_volume, func(x): Settings.master_volume = x; Settings.apply())
	_slider(body, "Music", Settings.music_volume, func(x): Settings.music_volume = x; Settings.apply())
	_slider(body, "Sound effects", Settings.sfx_volume, func(x): Settings.sfx_volume = x; Settings.apply())
	body.add_child(UITheme.label("Game", 11, UITheme.WOOD))
	_slider(body, "Day length (relaxed ->)", inverse_lerp(0.7, 2.0, Settings.clock_speed), func(x): Settings.clock_speed = lerpf(0.7, 2.0, x))
	_check(body, "12-hour clock", Settings.twelve_hour, func(on): Settings.twelve_hour = on)
	_check(body, "Pause time while in menus (solo)", Settings.auto_pause_menus, func(on): Settings.auto_pause_menus = on)
	body.add_child(UITheme.label("Display & accessibility", 11, UITheme.WOOD))
	if OS.get_name() != "Web":
		_check(body, "Fullscreen", Settings.fullscreen, func(on): Settings.fullscreen = on; Settings.apply())
	_check(body, "Screen shake", Settings.screen_shake, func(on): Settings.screen_shake = on)
	_check(body, "Colorblind-friendly type markers", Settings.colorblind, func(on): Settings.colorblind = on)
	body.add_child(UITheme.label("Controls (click, then press a key)", 11, UITheme.WOOD))
	for a in REBINDABLE:
		var h := HBoxContainer.new()
		body.add_child(h)
		var l := UITheme.label(a.replace("_", " ").capitalize(), 9)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		var b := UITheme.button(Settings.key_name(a))
		b.custom_minimum_size = Vector2(90, 0)
		b.pressed.connect(func(): _waiting_action = a; b.text = "...")
		h.add_child(b)
		_bind_buttons[a] = b
	body.add_child(UITheme.button("Reset controls", func():
		Settings.reset_bindings()
		for a2 in _bind_buttons:
			_bind_buttons[a2].text = Settings.key_name(a2)))

func _slider(parent: Control, text: String, value: float, cb: Callable) -> void:
	var h := HBoxContainer.new()
	parent.add_child(h)
	var l := UITheme.label(text, 9)
	l.custom_minimum_size = Vector2(130, 0)
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = 0
	s.max_value = 1
	s.step = 0.05
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(cb)
	h.add_child(s)

func _check(parent: Control, text: String, value: bool, cb: Callable) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = value
	c.add_theme_font_size_override("font_size", 9)
	c.toggled.connect(cb)
	parent.add_child(c)

func _input(event: InputEvent) -> void:
	if _waiting_action != "" and event is InputEventKey and event.pressed:
		if event.keycode != KEY_ESCAPE:
			Settings.rebind(_waiting_action, event.keycode)
		_bind_buttons[_waiting_action].text = Settings.key_name(_waiting_action)
		_waiting_action = ""
		get_viewport().set_input_as_handled()
