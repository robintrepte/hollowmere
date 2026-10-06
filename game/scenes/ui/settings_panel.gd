class_name SettingsPanel
extends PanelContainer
## Audio, clock speed, display, accessibility and key rebinding.

signal closed

## Shown as a tab inside the MenuShell: no frame and no close button of its own.
var embedded := false

const REBINDABLE := ["move_up", "move_down", "move_left", "move_right", "use_tool", "interact", "inventory", "party", "journal", "quests", "skills", "craft", "map", "menu", "coop", "chat", "emote", "hotbar_next", "hotbar_prev", "run", "rotate_item"]

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
	if not embedded:
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
	_slider(body, "Master volume", Settings.master_volume, func(x): Settings.master_volume = x; Settings.apply())
	_slider(body, "Music", Settings.music_volume, func(x): Settings.music_volume = x; Settings.apply())
	_slider(body, "Sound effects", Settings.sfx_volume, func(x): Settings.sfx_volume = x; Settings.apply())
	body.add_child(UITheme.label("Game", 11, UITheme.WOOD))
	_slider(body, "Day length (relaxed ->)", inverse_lerp(0.7, 2.0, Settings.clock_speed), func(x): Settings.clock_speed = lerpf(0.7, 2.0, x))
	_check(body, "12-hour clock", Settings.twelve_hour, func(on): Settings.twelve_hour = on)
	_check(body, "Pause time while in menus (solo)", Settings.auto_pause_menus, func(on): Settings.auto_pause_menus = on)
	_check(body, "Filter rude words in chat", Settings.chat_filter, func(on): Settings.chat_filter = on)
	_choice(body, "Seasons follow", ["Your region", "Northern hemisphere", "Southern hemisphere"], ["auto", "north", "south"].find(Settings.hemisphere), func(i: int):
		Settings.hemisphere = ["auto", "north", "south"][i])
	if Casino.built_in():
		body.add_child(UITheme.label("Casino", 11, UITheme.WOOD))
		var limits: Array = [0, 500, 1000, 2500, 5000, 10000]
		var limit_names: Array = [tr("No limit")] + limits.slice(1).map(func(n): return tr("%s chips a day") % Num.group(int(n)))
		_choice(body, "Daily stake limit", limit_names, maxi(0, limits.find(Settings.casino_daily_limit)), func(i: int):
			Settings.casino_daily_limit = limits[i]
			if GameState.started:
				Coop.act("casino_prefs_act", [Settings.casino_daily_limit]))
		_check(body, "Hide the casino (closes it and hides its quests)", Settings.hide_casino, func(on): Settings.hide_casino = on)
	body.add_child(UITheme.label("Display & accessibility", 11, UITheme.WOOD))
	if OS.get_name() != "Web":
		_check(body, "Fullscreen", Settings.fullscreen, func(on): Settings.fullscreen = on; Settings.apply())
	_check(body, "Screen shake", Settings.screen_shake, func(on): Settings.screen_shake = on)
	_choice(body, "Touch controls", ["Auto", "On", "Off"], ["auto", "on", "off"].find(Settings.touch_controls), func(i: int):
		Settings.touch_controls = ["auto", "on", "off"][i]
		TouchControls.refresh_active())
	var locs := Settings.available_locales()
	if locs.size() > 1:
		var names: Array = ["System"] + locs.map(func(l): return TranslationServer.get_locale_name(l))
		_choice(body, "Language", names, 0 if Settings.locale == "" else locs.find(Settings.locale) + 1, func(i: int):
			Settings.locale = "" if i == 0 else locs[i - 1]
			Settings.apply())
	_scale_slider(body, "UI size", Settings.ui_scale, Settings.set_ui_scale, true)
	_scale_slider(body, "HUD size", Settings.hud_scale, Settings.set_hud_scale, true)
	var note := UITheme.label("100% keeps the HUD the same size as the rest of the UI.", 8, UITheme.MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)
	_choice(body, "Text size", ["Normal", "Large", "Larger"], Settings.TEXT_SCALES.find(Settings.text_scale), func(i: int):
		Settings.set_text_scale(Settings.TEXT_SCALES[i]))
	_choice(body, tr("Font"), [tr("Pixel"), tr("Readable")], Settings.FONTS.find(Settings.ui_font), func(i: int):
		Settings.set_ui_font(Settings.FONTS[i]))
	_check(body, "Colorblind mode (type names on moves, quality pips)", Settings.colorblind, func(on): Settings.colorblind = on)
	_check(body, "Easy fishing (the rod reels by itself, slightly lower quality)", Settings.easy_fishing, func(on): Settings.easy_fishing = on)
	body.add_child(UITheme.label("Privacy", 11, UITheme.WOOD))
	_check(body, "Send crash and error reports (no personal data)", Settings.error_reports, func(on): Settings.error_reports = on)
	_check(body, "Share anonymous play stats (session length, progress)", Settings.analytics, func(on):
		Settings.analytics = on
		Settings.analytics_asked = true)
	body.add_child(UITheme.label("Controls (click, then press a key)", 11, UITheme.WOOD))
	for a in REBINDABLE:
		var h := HBoxContainer.new()
		body.add_child(h)
		var l := UITheme.label(_control_label(a), 9)
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

func _control_label(a: String) -> String:
	match a:
		"craft": return tr("Crafting")
		"quests": return tr("Quest log")
		"skills": return tr("Skill tree")
		"map": return tr("Valley map")
		"menu": return tr("Menu")
		"coop": return tr("Co-op")
		"chat": return tr("Chat")
		"emote": return tr("Emote wheel")
		"hotbar_next": return tr("Next item slot")
		"hotbar_prev": return tr("Previous item slot")
		_: return a.replace("_", " ").capitalize()

## `live` applies while the slider is dragged. Pass false to wait until release.
func _scale_slider(parent: Control, text: String, value: float, cb: Callable, live: bool) -> void:
	var h := HBoxContainer.new()
	parent.add_child(h)
	var l := UITheme.label(text, 9)
	l.custom_minimum_size = Vector2(130, 0)
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = Settings.UI_SCALE_MIN
	s.max_value = Settings.UI_SCALE_MAX
	s.step = Settings.UI_SCALE_STEP
	s.value = clampf(value, s.min_value, s.max_value)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(s)
	var pct := UITheme.label("", 9)
	pct.text = "%d%%" % int(round(s.value * 100.0))
	pct.custom_minimum_size = Vector2(40, 0)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(pct)
	var dragging := false
	s.drag_started.connect(func() -> void: dragging = true)
	s.drag_ended.connect(func(_changed: bool) -> void:
		dragging = false
		cb.call(s.value))
	s.value_changed.connect(func(x: float) -> void:
		pct.text = "%d%%" % int(round(x * 100.0))
		if live or not dragging:
			cb.call(x))

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

func _choice(parent: Control, text: String, options: Array, selected: int, cb: Callable) -> void:
	var h := HBoxContainer.new()
	parent.add_child(h)
	var l := UITheme.label(text, 9)
	l.custom_minimum_size = Vector2(130, 0)
	h.add_child(l)
	var ob := OptionButton.new()
	ob.add_theme_font_size_override("font_size", UITheme.fs(9))
	for o in options:
		ob.add_item(tr(str(o)))
	ob.select(maxi(0, selected))
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.item_selected.connect(cb)
	h.add_child(ob)

func _check(parent: Control, text: String, value: bool, cb: Callable) -> void:
	var c := CheckBox.new()
	c.text = tr(text)
	c.button_pressed = value
	c.add_theme_font_size_override("font_size", UITheme.fs(9))
	c.toggled.connect(cb)
	parent.add_child(c)

func _input(event: InputEvent) -> void:
	if _waiting_action != "" and event is InputEventKey and event.pressed:
		if event.keycode != KEY_ESCAPE:
			Settings.rebind(_waiting_action, event.keycode)
		_bind_buttons[_waiting_action].text = Settings.key_name(_waiting_action)
		_waiting_action = ""
		get_viewport().set_input_as_handled()

func on_tab_hidden() -> void:
	Settings.save_settings()
