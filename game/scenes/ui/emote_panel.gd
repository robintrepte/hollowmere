class_name EmotePanel
extends PanelContainer
## Catalogue and the eight wheel slots. Click a known emote to play it; click a slot, then an
## emote, to put it on the wheel. Locked emotes show how they unlock.

signal closed

var embedded := false
var player: PlayerData
var _pick := -1
var _grid: GridContainer
var _wheel: HBoxContainer
var _hint: Label

func _init(p: PlayerData = null) -> void:
	player = p

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	head.add_child(UITheme.label("Emotes", 13, UITheme.WOOD_DK))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	if not embedded:
		head.add_child(UITheme.button("Close", func(): closed.emit()))
	_hint = UITheme.label(tr("Press %s for the wheel. Click a slot, then an emote, to change it.") % _key(), 8, UITheme.MUTED)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_hint)
	v.add_child(UITheme.label("Wheel", 10, UITheme.WOOD))
	_wheel = HBoxContainer.new()
	_wheel.add_theme_constant_override("separation", 4)
	v.add_child(_wheel)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	sc.add_child(_grid)
	_rebuild()

func _key() -> String:
	var evs := InputMap.action_get_events("emote")
	for e in evs:
		if e is InputEventKey:
			return OS.get_keycode_string(e.physical_keycode)
	return "G"

func _rebuild() -> void:
	for c in _wheel.get_children():
		c.queue_free()
	var slots := Emotes.wheel(player)
	for i in Emotes.WHEEL_SLOTS:
		var id := str(slots[i]) if i < slots.size() else ""
		var b := _slot_button(id, i)
		_wheel.add_child(b)
	for c in _grid.get_children():
		c.queue_free()
	for id in Emotes.ordered(player):
		_grid.add_child(_card(id))

func _slot_button(id: String, i: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(44, 44)
	b.tooltip_text = tr(str(Emotes.info(id).get("name", "Empty"))) if id != "" else tr("Empty slot")
	if id != "":
		b.icon = Emotes.icon(id)
		b.expand_icon = true
	if i == _pick:
		b.add_theme_stylebox_override("normal", UITheme.box(UITheme.CREAM, Color("#ffd23f"), 2, 3, 2, false))
	b.pressed.connect(func():
		_pick = -1 if _pick == i else i
		_hint.text = tr("Now pick an emote for slot %d.") % (i + 1) if _pick == i else tr("Press %s for the wheel.") % _key()
		_rebuild())
	return b

func _card(id: String) -> Control:
	var known := Emotes.knows(player, id)
	var e := Emotes.info(id)
	var b := Button.new()
	b.custom_minimum_size = Vector2(110, 52)
	b.disabled = not known
	b.tooltip_text = tr(str(e.get("unlock", ""))) if not known else tr(str(e.get("name", id)))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 4)
	b.add_child(h)
	var ic := UITheme.icon_rect(Emotes.icon(id), 28)
	ic.modulate.a = 1.0 if known else 0.35
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(ic)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 0)
	h.add_child(col)
	col.add_child(UITheme.label(str(e.get("name", id)), 9, UITheme.INK if known else UITheme.MUTED))
	if not known:
		var lock := UITheme.label(str(e.get("unlock", "Locked")), 7, UITheme.MUTED)
		lock.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lock.custom_minimum_size = Vector2(70, 0)
		col.add_child(lock)
	b.pressed.connect(func():
		if _pick >= 0:
			Emotes.set_slot(_pick, id)
			_pick = -1
			_hint.text = tr("Press %s for the wheel.") % _key()
			_rebuild()
		else:
			Coop.send_emote(id))
	return b
