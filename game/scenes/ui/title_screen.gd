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
var _load_btn: Button
var _account: Button
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
	panel.offset_top = -20
	panel.offset_bottom = -20
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
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
	_load_btn = UITheme.button("Load", _open_load)
	_load_btn.disabled = latest < 0 and not Net.has_session()
	_menu.add_child(_load_btn)
	_menu.add_child(UITheme.button("Co-op", func():
		if Net.has_session():
			coop_requested.emit()
		else:
			ui.open(AccountPanel.new())))
	_menu.add_child(UITheme.button("Settings", func(): ui.open(SettingsPanel.new())))
	if OS.get_name() != "Web":
		_menu.add_child(UITheme.button("Quit", func(): get_tree().quit()))
	var ver := UITheme.label("v%s" % ProjectSettings.get_setting("application/config/version"), 8, UITheme.CREAM, true)
	ver.anchor_top = 1
	ver.anchor_bottom = 1
	ver.offset_left = 6
	ver.offset_top = -14
	add_child(ver)
	_account = UITheme.button("", func(): ui.open(AccountPanel.new()))
	_account.add_theme_font_size_override("font_size", 9)
	_account.anchor_left = 1
	_account.anchor_right = 1
	_account.offset_left = -6
	_account.offset_right = -6
	_account.offset_top = 6
	_account.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(_account)
	Net.session_changed.connect(_on_session)
	_on_session(Net.has_session())
	if not Net.has_session():
		Net.try_restore_session()
	Audio.music("title")

func _on_session(signed_in: bool) -> void:
	_account.text = ("● %s" % Net.display_name) if signed_in else "Sign in"
	if signed_in:
		_load_btn.disabled = false

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
	if _saves().is_empty() and not Net.has_session():
		v.add_child(UITheme.label("No farms yet.", 10, UITheme.MUTED))
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
	var cloud_box := VBoxContainer.new()
	v.add_child(cloud_box)
	v.add_child(UITheme.button("Back", func(): ui.close(p)))
	ui.open(p)
	if Net.has_session():
		_fill_cloud(cloud_box, p)

func _fill_cloud(box: VBoxContainer, p: Control) -> void:
	var wait := UITheme.label("Checking the cloud...", 9, UITheme.MUTED)
	box.add_child(wait)
	var newer: Array = SaveManager.newer_in_cloud(await Net.cloud_list())
	if not is_instance_valid(box):
		return
	wait.queue_free()
	if newer.is_empty():
		box.add_child(UITheme.label("Cloud backups are up to date.", 9, UITheme.LEAF))
		return
	box.add_child(UITheme.label("Newer in the cloud", 10, UITheme.WOOD_DK))
	for c: Dictionary in newer:
		var m: Dictionary = c.meta
		var s := int(c.slot)
		var payload: Dictionary = c.payload
		var txt := "● %s · %s Farm\n%s · %dg" % [m.get("player", "?"), m.get("farm", "?"), Calendar.date_string(int(m.get("day", 0))), int(m.get("money", 0))]
		var b := UITheme.button(txt, func():
			if SaveManager.install_payload(s, payload):
				ui.close(p)
				load_requested.emit(s))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		box.add_child(b)

func _process(delta: float) -> void:
	_t += delta
	_logo.offset_top = 16 + roundf(sin(_t * 1.4) * 2.0)
	_logo.offset_bottom = _logo.offset_top + 81
