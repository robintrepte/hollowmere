class_name TitleScreen
extends Control
## Title: key art, logo, continue / new / load / co-op / settings / quit.

signal new_game_requested(opts: Dictionary)
signal load_requested(slot: int)
signal coop_requested

var ui: UIRoot
var _menu: VBoxContainer
var _bg: TextureRect
var _logo: TextureRect
var _t := 0.0

func _init(u: UIRoot = null) -> void:
	ui = u

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.theme()
	_bg = TextureRect.new()
	_bg.texture = Art.tex("res://assets/ui/title_bg.png")
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_bg)
	_logo = TextureRect.new()
	_logo.texture = Art.tex("res://assets/ui/logo.png")
	_logo.anchor_left = 0.5
	_logo.anchor_right = 0.5
	_logo.offset_left = -140
	_logo.offset_right = 140
	_logo.offset_top = 16
	_logo.offset_bottom = 16 + 81
	_logo.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_logo)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.box(Color(0.96, 0.9, 0.77, 0.92), UITheme.OUTLINE, 2, 4, 8))
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1
	panel.anchor_bottom = 1
	panel.offset_left = -70
	panel.offset_right = 70
	panel.offset_top = -200
	panel.offset_bottom = -20
	add_child(panel)
	_menu = VBoxContainer.new()
	_menu.add_theme_constant_override("separation", 5)
	panel.add_child(_menu)
	var latest := _latest_slot()
	if latest >= 0:
		var cont := UITheme.button("Continue", func(): load_requested.emit(latest))
		_menu.add_child(cont)
		cont.call_deferred("grab_focus")
	var ng := UITheme.button("New Farm", func(): ui.open(NewGamePanel.new(self)))
	_menu.add_child(ng)
	if latest < 0:
		ng.call_deferred("grab_focus")
	var ld := UITheme.button("Load", _open_load)
	ld.disabled = latest < 0
	_menu.add_child(ld)
	_menu.add_child(UITheme.button("Co-op", func(): coop_requested.emit()))
	_menu.add_child(UITheme.button("Settings", func(): ui.open(SettingsPanel.new())))
	if OS.get_name() != "Web":
		_menu.add_child(UITheme.button("Quit", func(): get_tree().quit()))
	var ver := UITheme.label("v%s" % ProjectSettings.get_setting("application/config/version"), 8, UITheme.CREAM, true)
	ver.anchor_top = 1
	ver.anchor_bottom = 1
	ver.offset_left = 6
	ver.offset_top = -14
	add_child(ver)
	Audio.music("title")

func _latest_slot() -> int:
	var best := -1
	var best_t := -1.0
	for m in _saves():
		if float(m.get("saved_at", 0)) > best_t:
			best_t = float(m.get("saved_at", 0))
			best = int(m.slot)
	return best

func _saves() -> Array:
	var out: Array = []
	for m in SaveManager.list_slots():
		if not m.is_empty() and not m.get("corrupt", false):
			out.append(m)
	return out

func _open_load() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.parchment(8))
	p.anchor_left = 0.5
	p.anchor_right = 0.5
	p.anchor_top = 0.5
	p.anchor_bottom = 0.5
	p.offset_left = -150
	p.offset_right = 150
	p.offset_top = -120
	p.offset_bottom = 120
	var v := VBoxContainer.new()
	p.add_child(v)
	v.add_child(UITheme.label("Load a farm", 13, UITheme.WOOD_DK))
	for m in _saves():
		var s := int(m.slot)
		var h := HBoxContainer.new()
		v.add_child(h)
		var txt := "%s · %s Farm\n%s · %dg" % [m.get("player", "?"), m.get("farm", "?"), Calendar.date_string(int(m.get("day", 0))), int(m.get("money", 0))]
		var b := UITheme.button(txt, func(): ui.close(p); load_requested.emit(int(s)))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(b)
		h.add_child(UITheme.button("X", func():
			var c: int = await ui.ask("Delete this farm forever?", ["Delete", "Keep"])
			if c == 0:
				SaveManager.delete_slot(int(s))
				ui.close(p)))
	v.add_child(UITheme.button("Back", func(): ui.close(p)))
	ui.open(p)

func _process(delta: float) -> void:
	_t += delta
	_logo.offset_top = 16 + roundf(sin(_t * 1.4) * 2.0)
	_logo.offset_bottom = _logo.offset_top + 81
