class_name Hud
extends CanvasLayer
## Clock + date + weather, money, energy, farm level, hotbar, party lead, toasts.

const SLOT := 34

var _date: Label
var _time: Label
var _weather: Label
var _money: Label
var _money_shown := 0.0
var _energy: ProgressBar
var _energy_lbl: Label
var _level: Label
var _xp: ProgressBar
var _slots: Array = []
var _toasts: VBoxContainer
var _lead_icon: TextureRect
var _lead_hp: ProgressBar
var _lead_name: Label
var _hotbar_name: Label
var _name_t := 0.0
var _quest: Label
var _lv_panel: PanelContainer

func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.theme()
	add_child(root)

	# Clock panel (top right)
	var clock := PanelContainer.new()
	clock.add_theme_stylebox_override("panel", UITheme.parchment(5))
	clock.anchor_left = 1
	clock.anchor_right = 1
	clock.offset_left = -112
	clock.offset_right = -6
	clock.offset_top = 6
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(clock)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 0)
	clock.add_child(cv)
	_date = UITheme.label("", 10)
	_date.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_date)
	_time = UITheme.label("", 14, UITheme.WOOD_DK)
	_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_time)
	_weather = UITheme.label("", 8, UITheme.MUTED)
	_weather.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_weather)
	var mrow := HBoxContainer.new()
	mrow.alignment = BoxContainer.ALIGNMENT_CENTER
	cv.add_child(mrow)
	mrow.add_child(UITheme.icon_rect(Art.item("_coin"), 16))
	_money = UITheme.label("0", 12, UITheme.WOOD_DK)
	mrow.add_child(_money)

	# Farm level (top left)
	var lv := PanelContainer.new()
	lv.add_theme_stylebox_override("panel", UITheme.parchment(4))
	lv.position = Vector2(6, 6)
	lv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(lv)
	_lv_panel = lv
	var lvv := VBoxContainer.new()
	lvv.add_theme_constant_override("separation", 1)
	lv.add_child(lvv)
	_level = UITheme.label("Farm Lv 1", 9)
	lvv.add_child(_level)
	_xp = ProgressBar.new()
	_xp.custom_minimum_size = Vector2(80, 5)
	_xp.show_percentage = false
	lvv.add_child(_xp)
	var lead := HBoxContainer.new()
	lvv.add_child(lead)
	_lead_icon = UITheme.icon_rect(null, 32)
	lead.add_child(_lead_icon)
	var lcol := VBoxContainer.new()
	lcol.add_theme_constant_override("separation", 1)
	lead.add_child(lcol)
	_lead_name = UITheme.label("", 8)
	lcol.add_child(_lead_name)
	_lead_hp = ProgressBar.new()
	_lead_hp.custom_minimum_size = Vector2(44, 5)
	_lead_hp.show_percentage = false
	lcol.add_child(_lead_hp)
	_quest = UITheme.label("", 8, UITheme.WOOD)
	_quest.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quest.custom_minimum_size = Vector2(150, 0)
	lvv.add_child(_quest)

	# Energy (bottom right)
	var en := PanelContainer.new()
	en.add_theme_stylebox_override("panel", UITheme.parchment(4))
	en.anchor_left = 1
	en.anchor_right = 1
	en.anchor_top = 1
	en.anchor_bottom = 1
	en.offset_left = -30
	en.offset_right = -6
	en.offset_top = -96
	en.offset_bottom = -6
	en.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(en)
	var ev := VBoxContainer.new()
	en.add_child(ev)
	_energy_lbl = UITheme.label("E", 9, UITheme.WOOD_DK)
	_energy_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ev.add_child(_energy_lbl)
	_energy = ProgressBar.new()
	_energy.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP
	_energy.show_percentage = false
	_energy.custom_minimum_size = Vector2(12, 64)
	_energy.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_energy.add_theme_stylebox_override("fill", UITheme.box(UITheme.ENERGY, Color(0, 0, 0, 0), 0, 2, 0, false))
	ev.add_child(_energy)

	# Hotbar (bottom center)
	var hb := PanelContainer.new()
	hb.add_theme_stylebox_override("panel", UITheme.wood(3))
	hb.anchor_left = 0.5
	hb.anchor_right = 0.5
	hb.anchor_top = 1
	hb.anchor_bottom = 1
	var w := PlayerData.HOTBAR_SIZE * (SLOT + 2) + 6
	hb.offset_left = -w / 2.0
	hb.offset_right = w / 2.0
	hb.offset_top = -SLOT - 12
	hb.offset_bottom = -4
	root.add_child(hb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	hb.add_child(row)
	for i in PlayerData.HOTBAR_SIZE:
		var s := ItemSlot.new()
		s.custom_minimum_size = Vector2(SLOT, SLOT)
		s.hint = str((i + 1) % 10)
		s.gui_input.connect(_on_slot_input.bind(i))
		row.add_child(s)
		_slots.append(s)
	_hotbar_name = UITheme.label("", 10, UITheme.CREAM, true)
	_hotbar_name.anchor_left = 0.5
	_hotbar_name.anchor_right = 0.5
	_hotbar_name.anchor_top = 1
	_hotbar_name.anchor_bottom = 1
	_hotbar_name.offset_left = -120
	_hotbar_name.offset_right = 120
	_hotbar_name.offset_top = -SLOT - 28
	_hotbar_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_hotbar_name)

	# Toasts (left)
	_toasts = VBoxContainer.new()
	_toasts.position = Vector2(6, 118)
	_toasts.custom_minimum_size = Vector2(220, 0)
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_toasts)

	EventBus.time_changed.connect(func(_m): _refresh_clock())
	EventBus.day_started.connect(func(_d, _r): _refresh_all())
	EventBus.money_changed.connect(func(_m, d: int):
		if d > 0:
			Juice.pop(_money))
	EventBus.energy_changed.connect(func(_e, _mx): _refresh_energy())
	EventBus.inventory_changed.connect(_refresh_hotbar)
	EventBus.hotbar_changed.connect(_refresh_hotbar)
	EventBus.party_changed.connect(_refresh_lead)
	EventBus.toast.connect(toast)
	EventBus.farm_level_up.connect(func(lv2, _i):
		toast(tr("Farm level %d!") % lv2, "star")
		_refresh_level()
		Juice.burst(self, _lv_panel.position + Vector2(_lv_panel.size.x / 2.0, _lv_panel.size.y), "levelup"))
	EventBus.weather_changed.connect(func(_w): _refresh_clock())
	EventBus.quest_updated.connect(_refresh_quest)
	EventBus.story_advanced.connect(func(_c): _refresh_quest())
	EventBus.creature_befriended.connect(func(_c): _refresh_quest.call_deferred())
	EventBus.map_changed.connect(func(_m): _refresh_quest())
	_refresh_all()

func _refresh_all() -> void:
	_refresh_clock()
	_refresh_energy()
	_refresh_hotbar()
	_refresh_lead()
	_refresh_level()
	_refresh_quest()
	_money_shown = GameState.money()

func _refresh_quest() -> void:
	if not GameState.started:
		return
	var bits: Array = []
	var fest := Adventure.festival_today(GameState.day())
	if not fest.is_empty():
		bits.append(tr("Today: %s at the Show Ring") % fest.name)
	elif Endless.show_open(GameState.day()):
		bits.append("Today: Creature Show at the Show Ring")
	var t := Adventure.tracker(GameState.world, GameState.local_player())
	if t != "":
		bits.append("» " + t)
	_quest.text = "\n".join(bits)
	_quest.visible = not bits.is_empty()

func _refresh_clock() -> void:
	if not GameState.started:
		return
	_date.text = Calendar.date_string(GameState.day())
	_time.text = Calendar.time_string(GameState.minute(), Settings.twelve_hour)
	_weather.text = Calendar.weather_name(GameState.world.get("weather", "sun"))
	_refresh_level()

func _refresh_level() -> void:
	if not GameState.started:
		return
	var f: Dictionary = GameState.world.farm
	_level.text = tr("Farm Lv %d") % int(f.level)
	var need := Progression.farm_xp_for(int(f.level))
	_xp.max_value = need
	_xp.value = int(f.xp)

func _refresh_energy() -> void:
	var p := GameState.local_player()
	if p == null:
		return
	_energy.max_value = p.max_energy
	_energy.value = p.energy
	var low := p.energy < p.max_energy * 0.2
	_energy.add_theme_stylebox_override("fill", UITheme.box(Color("#e07050") if low else UITheme.ENERGY, Color(0, 0, 0, 0), 0, 2, 0, false))

func _refresh_hotbar() -> void:
	var p := GameState.local_player()
	if p == null:
		return
	for i in _slots.size():
		var s: ItemSlot = _slots[i]
		var e := p.hotbar_entry(i)
		s.selected = i == p.selected
		if e.is_empty():
			s.set_item("", 0, 0)
			s.bar = -1.0
		else:
			var inv_e: Dictionary = p.inventory.find(e.uid).get("entry", {})
			var n := p.inventory.count(e.id) if Data.stack_max(e.id) > 1 else 1
			s.set_item(e.id, n, int(inv_e.get("q", 0)))
			s.bar = float(p.water_left) / float(p.water_capacity()) if e.id == "watering_can" else -1.0
		s.queue_redraw()
	var sel := p.selected_id()
	_hotbar_name.text = Data.item_name(sel) if sel != "" else ""
	_name_t = 2.0

func _refresh_lead() -> void:
	var p := GameState.local_player()
	if p == null or p.party.is_empty():
		_lead_icon.texture = null
		_lead_name.text = ""
		_lead_hp.visible = false
		return
	var c: Creature = p.party[0]
	_lead_icon.texture = Art.creature(c.species_id, true)
	_lead_name.text = tr("%s Lv%d") % [c.display_name(), c.level]
	_lead_hp.visible = true
	_lead_hp.max_value = c.max_hp()
	_lead_hp.value = c.hp

func _on_slot_input(ev: InputEvent, i: int) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		select_slot(i)
		get_viewport().set_input_as_handled()

func select_slot(i: int) -> void:
	var p := GameState.local_player()
	if p == null:
		return
	p.selected = clampi(i, 0, PlayerData.HOTBAR_SIZE - 1)
	Audio.sfx("tick", 0.0)
	_refresh_hotbar()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var p := GameState.local_player()
	if p == null:
		return
	for i in PlayerData.HOTBAR_SIZE:
		if event.is_action_pressed(tr("hotbar_%d") % i):
			select_slot(i)
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("hotbar_next"):
		select_slot((p.selected + 1) % PlayerData.HOTBAR_SIZE)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("hotbar_prev"):
		select_slot((p.selected + PlayerData.HOTBAR_SIZE - 1) % PlayerData.HOTBAR_SIZE)
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	_toasts.position.y = _lv_panel.position.y + _lv_panel.size.y + 6
	var target := float(GameState.money()) if GameState.started else 0.0
	if absf(_money_shown - target) > 0.5:
		_money_shown = lerpf(_money_shown, target, minf(1.0, delta * 8.0))
		if absf(_money_shown - target) < 1.0:
			_money_shown = target
	_money.text = str(int(round(_money_shown)))
	if _name_t > 0:
		_name_t -= delta
		_hotbar_name.modulate.a = clampf(_name_t, 0, 1)
	if Engine.get_process_frames() % 30 == 0:
		_refresh_lead()

func toast(text: String, _icon: String = "") -> void:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.box(Color(0.13, 0.1, 0.12, 0.85), Color("#ffd447"), 1, 3, 4, false))
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.label(text, 9, UITheme.CREAM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(200, 0)
	pc.add_child(l)
	_toasts.add_child(pc)
	while _toasts.get_child_count() > 5:
		_toasts.get_child(0).queue_free()
	pc.modulate.a = 0
	var tw := pc.create_tween()
	tw.tween_property(pc, "modulate:a", 1.0, 0.2)
	tw.tween_interval(3.5)
	tw.tween_property(pc, "modulate:a", 0.0, 0.5)
	tw.tween_callback(pc.queue_free)
