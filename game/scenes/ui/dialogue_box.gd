class_name DialogueBox
extends Control
## Bottom dialogue panel with portrait, name plate, typewriter text and optional choices.

signal advanced
signal chosen(index: int)
signal closed

const CPS := 55.0

var _panel: PanelContainer
var _portrait: TextureRect
var _name: Label
var _text: RichTextLabel
var _choices: VBoxContainer
var _arrow: Label
var _typing := false
var _t := 0.0
var _choice_buttons: Array = []
var busy := false

## Hides the box and drops any conversation still waiting on it.
func dismiss() -> void:
	while busy:
		if not _choice_buttons.is_empty():
			chosen.emit(-1)
		else:
			_typing = false
			advanced.emit()
		await get_tree().process_frame

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.parchment(8))
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1
	_panel.anchor_bottom = 1
	_panel.offset_left = -250
	_panel.offset_right = 250
	_panel.offset_top = -104
	_panel.offset_bottom = -8
	add_child(_panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_panel.add_child(row)
	var pcol := VBoxContainer.new()
	row.add_child(pcol)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", UITheme.box(Color("#c9e3ec"), UITheme.OUTLINE, 2, 3, 2, false))
	pcol.add_child(frame)
	_portrait = UITheme.icon_rect(null, 64)
	frame.add_child(_portrait)
	_name = UITheme.label("", 10, UITheme.CREAM)
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", UITheme.wood(2))
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.add_child(_name)
	pcol.add_child(plate)
	var tcol := VBoxContainer.new()
	tcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(tcol)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_text.fit_content = false
	_text.scroll_active = false
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.add_theme_font_size_override("normal_font_size", UITheme.fs(11))
	tcol.add_child(_text)
	_choices = VBoxContainer.new()
	_choices.add_theme_constant_override("separation", 2)
	tcol.add_child(_choices)
	_arrow = UITheme.label("v", 10, UITheme.WOOD)
	_arrow.anchor_left = 0.5
	_arrow.anchor_right = 0.5
	_arrow.anchor_top = 1
	_arrow.anchor_bottom = 1
	_arrow.offset_left = 236
	_arrow.offset_top = -22
	add_child(_arrow)

## Conversations queue: a second run (e.g. a co-op invite mid-chat) waits for the first to close.
func run(lines: Array, speaker: String, portrait: Texture2D, choices: Array) -> int:
	while busy:
		await closed
	busy = true
	visible = true
	_text.add_theme_font_size_override("normal_font_size", UITheme.fs(11))
	_name.add_theme_font_size_override("font_size", UITheme.fs(10))
	_name.text = speaker
	_name.get_parent().visible = speaker != ""
	_portrait.texture = portrait
	_portrait.get_parent().visible = portrait != null
	var result := -1
	for i in lines.size():
		var last := i == lines.size() - 1
		_show_line(str(lines[i]))
		if last and not choices.is_empty():
			await _finish_typing()
			result = await _ask(choices)
		else:
			await advanced
	visible = false
	_clear_choices()
	busy = false
	closed.emit()
	return result

func _show_line(s: String) -> void:
	_text.text = tr(s)
	_text.visible_characters = 0
	_typing = true
	_t = 0.0
	_arrow.visible = false
	Audio.sfx("blip", 0.1)

func _finish_typing() -> void:
	while _typing:
		await get_tree().process_frame

func _ask(choices: Array) -> int:
	_clear_choices()
	for i in choices.size():
		var b := UITheme.button(str(choices[i]))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func(): chosen.emit(i))
		_choices.add_child(b)
		_choice_buttons.append(b)
	_panel.offset_top = -104 - choices.size() * 20
	_choice_buttons[0].grab_focus()
	var idx: int = await chosen
	_panel.offset_top = -104
	return idx

func _clear_choices() -> void:
	for b in _choice_buttons:
		b.queue_free()
	_choice_buttons.clear()

func _process(delta: float) -> void:
	if not visible:
		return
	if _typing:
		_t += delta * CPS
		_text.visible_characters = int(_t)
		if int(_t) % 6 == 0 and int(_t) != int(_t - delta * CPS):
			Audio.sfx("blip", 0.2)
		if _text.visible_characters >= _text.get_total_character_count():
			_text.visible_characters = -1
			_typing = false
	else:
		_arrow.visible = _choice_buttons.is_empty()
		_arrow.modulate.a = 0.55 + 0.45 * sin(Time.get_ticks_msec() / 150.0)

func _advance() -> void:
	if _typing:
		_text.visible_characters = -1
		_typing = false
	elif _choice_buttons.is_empty():
		Audio.sfx("tick", 0.0)
		advanced.emit()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_advance()
		accept_event()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("interact") or event.is_action_pressed("use_tool") or event.is_action_pressed("ui_accept") or event.is_action_pressed("chat"):
		if _choice_buttons.is_empty() or _typing:
			_advance()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("menu") and not _choice_buttons.is_empty():
		chosen.emit(_choice_buttons.size() - 1)
		get_viewport().set_input_as_handled()
