class_name TitleScreen
extends Control
## Title: rotating seasonal key art with ambient animation, logo, splash tips,
## continue / new / load / co-op / settings / quit.

signal new_game_requested(opts: Dictionary)
signal load_requested(slot: int)
signal coop_requested

const SCENES := [
	{"bg": "title_bg", "fx": "pollen"},
	{"bg": "title_spring", "fx": "petals"},
	{"bg": "title_night", "fx": "fireflies"},
	{"bg": "title_fall", "fx": "leaves"},
	{"bg": "title_winter", "fx": "snow"},
]
const SCENE_SECONDS := 45.0
const TIP_SECONDS := 7.0
const LAST_SCENE_FILE := "user://title.cfg"

var ui: UIRoot
var _menu: VBoxContainer
var _bg: TextureRect
var _bg_next: TextureRect
var _ambience: TitleAmbience
var _logo: TextureRect
var _splash: Control
var _splash_label: Label
var _splash_k := 1.0
var _tips: Array = []
var _tip_i := 0
var _tip_t := 0.0
var _scene := 0
var _scene_t := 0.0
var _load_btn: Button
var _account: Button
var _t := 0.0

func _init(u: UIRoot = null) -> void:
	ui = u

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.theme()
	_bg = _backdrop()
	_bg_next = _backdrop()
	_bg_next.modulate.a = 0.0
	_ambience = TitleAmbience.new()
	add_child(_ambience)
	_scene = _pick_scene()
	_show_scene(_scene, false)
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
	_build_splash()
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
	_menu.minimum_size_changed.connect(func(): panel.set_deferred("offset_top", panel.offset_bottom))
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
	var ver := UITheme.label(tr("v%s") % ProjectSettings.get_setting("application/config/version"), 8, UITheme.CREAM, true)
	ver.anchor_top = 1
	ver.anchor_bottom = 1
	ver.offset_left = 6
	ver.offset_top = -14
	add_child(ver)
	_account = UITheme.button("", func(): ui.open(AccountPanel.new()))
	_account.add_theme_font_size_override("font_size", UITheme.fs(9))
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
	_account.text = (tr("● %s") % Net.display_name) if signed_in else "Sign in"
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
		var txt := tr("%s · %s Farm\n%s · %dg") % [m.get("player", "?"), m.get("farm", "?"), Calendar.date_string(int(m.get("day", 0))), int(m.get("money", 0))]
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
		var txt := tr("● %s · %s Farm\n%s · %dg") % [m.get("player", "?"), m.get("farm", "?"), Calendar.date_string(int(m.get("day", 0))), int(m.get("money", 0))]
		var b := UITheme.button(txt, func():
			if SaveManager.install_payload(s, payload):
				ui.close(p)
				load_requested.emit(s))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		box.add_child(b)

func _backdrop() -> TextureRect:
	var r := TextureRect.new()
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(r)
	return r

## A random scene, never the one shown at the previous launch.
func _pick_scene() -> int:
	var cfg := ConfigFile.new()
	cfg.load(LAST_SCENE_FILE)
	var last := int(cfg.get_value("title", "scene", -1))
	var i := randi() % (SCENES.size() - 1)
	if i >= last and last >= 0:
		i += 1
	cfg.set_value("title", "scene", i)
	cfg.save(LAST_SCENE_FILE)
	return i

func _show_scene(i: int, fade: bool) -> void:
	var tex := Art.tex("res://assets/ui/%s.png" % SCENES[i].bg)
	if not fade:
		_bg.texture = tex
		_ambience.set_fx(SCENES[i].fx)
		return
	_bg_next.texture = tex
	var tw := create_tween()
	tw.tween_property(_ambience, "modulate:a", 0.0, 0.8)
	tw.parallel().tween_property(_bg_next, "modulate:a", 1.0, 2.0)
	tw.tween_callback(func():
		_bg.texture = tex
		_bg_next.modulate.a = 0.0
		_ambience.set_fx(SCENES[i].fx))
	tw.tween_property(_ambience, "modulate:a", 1.0, 0.8)

func _build_splash() -> void:
	var d: Dictionary = Data._load_json("res://data/title_tips.json")
	_tips = d.get("lines", []).duplicate()
	_tips.shuffle()
	_splash = Control.new()
	_splash.anchor_left = 0.5
	_splash.anchor_right = 0.5
	_splash.offset_top = 104
	_splash.offset_bottom = 104
	_splash.rotation = deg_to_rad(-2.0)
	_splash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_splash)
	_splash_label = UITheme.label("", 12, Color("#ffe14a"), true)
	_splash_label.add_theme_constant_override("outline_size", 6)
	_splash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_splash_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_splash_label.offset_left = -220
	_splash_label.offset_right = 220
	_splash_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_splash_label.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			Audio.sfx("blip")
			_next_tip())
	_splash.add_child(_splash_label)
	_next_tip()

func _next_tip() -> void:
	if _tips.is_empty():
		return
	_splash_label.text = tr(_tips[_tip_i % _tips.size()])
	_tip_i += 1
	_tip_t = 0.0
	_splash_k = 0.0
	create_tween().tween_property(self, "_splash_k", 1.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _process(delta: float) -> void:
	_t += delta
	_logo.offset_top = 16 + roundf(sin(_t * 1.4) * 2.0)
	_logo.offset_bottom = _logo.offset_top + 81
	_splash.scale = Vector2.ONE * _splash_k * (1.0 + 0.04 * sin(_t * 6.0))
	_tip_t += delta
	if _tip_t >= TIP_SECONDS:
		_next_tip()
	_scene_t += delta
	if _scene_t >= SCENE_SECONDS:
		_scene_t = 0.0
		_scene = (_scene + 1) % SCENES.size()
		_show_scene(_scene, true)
