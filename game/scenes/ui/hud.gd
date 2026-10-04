class_name Hud
extends CanvasLayer
## Day ribbon (sun arc, date, weather, time) top right; energy, hotbar and coins docked along the bottom;
## farm level, party lead and quest tracker top left; toasts below them.

const SLOT := 34

var _date: Label
var _time: Label
var _weather: Label
var _dial: DayDial
var _money: Label
var _chip_row: HBoxContainer
var _chip_label: Label
var _money_shown := 0.0
var _coin_icon: TextureRect
var _energy: EnergyPips
var _level: Label
var _plevel: Label
var _pxp: ProgressBar
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
var _hint: PanelContainer
var _hint_text: Label
var _hint_qid := ""
var _hotbar_panel: PanelContainer

func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.theme()
	add_child(root)

	# Day ribbon (top right)
	var day := PanelContainer.new()
	day.add_theme_stylebox_override("panel", _pill(4))
	day.anchor_left = 1
	day.anchor_right = 1
	day.offset_left = -6
	day.offset_right = -6
	day.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	day.offset_top = 6
	day.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(day)
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 6)
	day.add_child(drow)
	_dial = DayDial.new()
	_dial.custom_minimum_size = Vector2(36, 20)
	_dial.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	drow.add_child(_dial)
	var dcol := VBoxContainer.new()
	dcol.add_theme_constant_override("separation", 0)
	drow.add_child(dcol)
	_date = UITheme.label("", 9)
	dcol.add_child(_date)
	_weather = UITheme.label("", 8, UITheme.MUTED)
	dcol.add_child(_weather)
	_time = UITheme.label("", 14, UITheme.WOOD_DK)
	_time.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	drow.add_child(_time)

	# Farm level, party lead, quest (top left)
	var lv := PanelContainer.new()
	lv.add_theme_stylebox_override("panel", _pill(5))
	lv.position = Vector2(6, 6)
	lv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(lv)
	_lv_panel = lv
	var lvv := VBoxContainer.new()
	lvv.add_theme_constant_override("separation", 2)
	lv.add_child(lvv)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 4)
	lvv.add_child(prow)
	_plevel = UITheme.label("Level 1", 9)
	prow.add_child(_plevel)
	_pxp = _bar(UITheme.LEAF)
	_pxp.custom_minimum_size = Vector2(60, 4)
	_pxp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	prow.add_child(_pxp)
	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 4)
	lvv.add_child(lrow)
	_level = UITheme.label("Farm Lv 1", 9)
	lrow.add_child(_level)
	_xp = _bar(UITheme.COIN)
	_xp.custom_minimum_size = Vector2(60, 4)
	_xp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lrow.add_child(_xp)
	var lead := HBoxContainer.new()
	lvv.add_child(lead)
	_lead_icon = UITheme.icon_rect(null, 32)
	lead.add_child(_lead_icon)
	var lcol := VBoxContainer.new()
	lcol.add_theme_constant_override("separation", 2)
	lcol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lead.add_child(lcol)
	_lead_name = UITheme.label("", 8)
	lcol.add_child(_lead_name)
	_lead_hp = _bar(UITheme.LEAF)
	_lead_hp.custom_minimum_size = Vector2(56, 4)
	lcol.add_child(_lead_hp)
	_quest = UITheme.label("", 8, UITheme.WOOD)
	_quest.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quest.custom_minimum_size = Vector2(150, 0)
	lvv.add_child(_quest)

	# Bottom dock: energy | hotbar | coins
	var w := PlayerData.HOTBAR_SIZE * (SLOT + 2) + 6
	var en := _dock_pill(root, -w / 2.0 - 4, Control.GROW_DIRECTION_BEGIN)
	var erow := HBoxContainer.new()
	erow.add_theme_constant_override("separation", 4)
	en.add_child(erow)
	erow.add_child(UITheme.icon_rect(Art.item("_energy"), 16))
	_energy = EnergyPips.new()
	_energy.custom_minimum_size = Vector2(EnergyPips.PIPS * 9 - 2, 7)
	_energy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	erow.add_child(_energy)
	var co := _dock_pill(root, w / 2.0 + 4, Control.GROW_DIRECTION_END)
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 3)
	co.add_child(mrow)
	_coin_icon = UITheme.icon_rect(Art.item("_coin"), 16)
	mrow.add_child(_coin_icon)
	_money = UITheme.label("0", 12, UITheme.WOOD_DK)
	mrow.add_child(_money)
	_chip_row = HBoxContainer.new()
	_chip_row.add_theme_constant_override("separation", 3)
	_chip_row.add_child(UITheme.icon_rect(Art.item("_chip"), 16))
	_chip_label = UITheme.label("0", 12, UITheme.WOOD_DK)
	_chip_row.add_child(_chip_label)
	mrow.add_child(_chip_row)
	_refresh_chips()

	var hb := PanelContainer.new()
	hb.add_theme_stylebox_override("panel", UITheme.wood(3))
	hb.anchor_left = 0.5
	hb.anchor_right = 0.5
	hb.anchor_top = 1
	hb.anchor_bottom = 1
	hb.offset_left = -w / 2.0
	hb.offset_right = w / 2.0
	hb.offset_top = -SLOT - 12
	hb.offset_bottom = -4
	root.add_child(hb)
	_hotbar_panel = hb
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
	var emote_btn := UITheme.button("", func():
		var main := get_tree().get_first_node_in_group("main")
		if main and main.has_method("_toggle_emote_wheel"):
			main._toggle_emote_wheel())
	emote_btn.icon = Art.item("emote_wave")
	emote_btn.expand_icon = true
	emote_btn.tooltip_text = tr("Emotes")
	emote_btn.custom_minimum_size = Vector2(28, 28)
	emote_btn.anchor_left = 0.5
	emote_btn.anchor_right = 0.5
	emote_btn.anchor_top = 1
	emote_btn.anchor_bottom = 1
	emote_btn.offset_left = w / 2.0 + 8
	emote_btn.offset_right = w / 2.0 + 36
	emote_btn.offset_top = -SLOT - 10
	emote_btn.offset_bottom = -SLOT + 18
	root.add_child(emote_btn)

	# Tutorial hint (above the hotbar)
	_hint = PanelContainer.new()
	_hint.add_theme_stylebox_override("panel", UITheme.box(Color(0.12, 0.09, 0.1, 0.88), UITheme.COIN, 1, 4, 6, false))
	_hint.anchor_left = 0.5
	_hint.anchor_right = 0.5
	_hint.anchor_top = 1
	_hint.anchor_bottom = 1
	_hint.offset_left = -140
	_hint.offset_right = 140
	_hint.offset_bottom = -SLOT - 34
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.mouse_filter = Control.MOUSE_FILTER_PASS
	_hint.visible = false
	root.add_child(_hint)
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 6)
	_hint.add_child(hrow)
	_hint_text = UITheme.label("", 8, UITheme.CREAM)
	_hint_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint_text.custom_minimum_size = Vector2(230, 0)
	hrow.add_child(_hint_text)
	var hx := UITheme.button("×", _dismiss_hint)
	hx.tooltip_text = tr("Hide this hint")
	hx.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hrow.add_child(hx)

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
			Juice.pop(_money)
			_fly_coins(d))
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
	EventBus.skills_changed.connect(func(_pid): _refresh_quest())
	EventBus.player_leveled.connect(func(pid: String, lvl: int):
		var me := GameState.local_player()
		if me and pid == me.id:
			Audio.sfx("levelup")
			toast(tr("Level %d! You earned a skill point.") % lvl, "star")
			_refresh_level()
			_refresh_quest())
	EventBus.story_advanced.connect(func(_c): _refresh_quest())
	EventBus.creature_befriended.connect(func(_c): _refresh_quest.call_deferred())
	EventBus.map_changed.connect(func(_m): _refresh_quest(); _refresh_chips())
	EventBus.chips_changed.connect(_refresh_chips)
	var spec := PanelContainer.new()
	spec.add_theme_stylebox_override("panel", UITheme.box(Color(0.1, 0.08, 0.12, 0.82), UITheme.COIN, 1, 4, 6, false))
	spec.anchor_left = 0.5
	spec.anchor_right = 0.5
	spec.offset_left = -160
	spec.offset_right = 160
	spec.offset_top = 8
	spec.visible = false
	spec.name = "SpectatorBanner"
	root.add_child(spec)
	var spec_v := VBoxContainer.new()
	spec.add_child(spec_v)
	spec_v.add_child(UITheme.label("An agent is playing. You are watching.", 9, UITheme.CREAM))
	spec_v.add_child(UITheme.button("Take control back", func(): AgentBridge.take_back()))
	AgentBridge.mode_changed.connect(func(): spec.visible = AgentBridge.spectator)
	_refresh_all()

func _pill(pad: int) -> StyleBoxFlat:
	var s := UITheme.parchment(pad)
	s.set_corner_radius_all(6)
	return s

func _bar(fill: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.show_percentage = false
	b.add_theme_stylebox_override("fill", UITheme.box(fill, Color(0, 0, 0, 0), 0, 1, 0, false))
	return b

## A pill beside the hotbar, vertically centered on it; `x` is its inner edge relative to screen center.
func _dock_pill(root: Control, x: float, grow: Control.GrowDirection) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _pill(4))
	p.anchor_left = 0.5
	p.anchor_right = 0.5
	p.anchor_top = 1
	p.anchor_bottom = 1
	p.offset_left = x
	p.offset_right = x
	p.offset_top = -SLOT / 2.0 - 8 - 13
	p.offset_bottom = -SLOT / 2.0 - 8 + 13
	p.grow_horizontal = grow
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(p)
	return p

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
		bits.append(tr("Today: %s at the Show Ring") % tr(str(fest.name)))
	elif Endless.show_open(GameState.day()):
		bits.append(tr("Today: Creature Show at the Show Ring"))
	var p := GameState.local_player()
	var free := Skills.points_free(p, GameState.world)
	if free > 0:
		bits.append("★ " + InputHints.fill(tr("%d skill points to spend ({skills})") % free if free != 1 else tr("1 skill point to spend ({skills})")))
	var t := Adventure.tracker(GameState.world, p)
	if t != "":
		bits.append("» " + t)
	var st := Quests.state(p)
	for qid in st.tracked:
		if not Quests.is_active(p, qid) or str(Quests.def_of(p, qid).get("type", "")) == "tutorial":
			continue
		var pr := Quests.progress(p, GameState.world, qid)
		var line := "» %s: %s" % [Quests.title(p, qid), InputHints.fill(Quests.step_text(p, qid))]
		if int(pr[1]) > 1:
			line += " (%d/%d)" % [int(pr[0]), int(pr[1])]
		bits.append(line)
	_quest.text = "\n".join(bits)
	_quest.visible = not bits.is_empty()
	_refresh_hint(p, st)

## The open tutorial step as a short hint box, with the matching keys / buttons / touch controls.
func _refresh_hint(p: PlayerData, st: Dictionary) -> void:
	_hint_qid = ""
	if st.tutorial == "playing":
		for qid in st.active:
			if str(Quests.def_of(p, qid).get("type", "")) == "tutorial" and not st.get("hint_hidden", {}).has(qid):
				_hint_qid = qid
				break
	_hint.visible = _hint_qid != ""
	if _hint_qid == "":
		_spotlight("")
		return
	var pr := Quests.progress(p, GameState.world, _hint_qid)
	var text := "%s\n%s" % [Quests.title(p, _hint_qid), InputHints.fill(Quests.step_text(p, _hint_qid))]
	if int(pr[1]) > 1:
		text += "  (%d/%d)" % [int(pr[0]), int(pr[1])]
	_hint_text.text = text
	_spotlight(str(Quests.def_of(p, _hint_qid).get("spot", "")))

func _dismiss_hint() -> void:
	var st := Quests.state(GameState.local_player())
	if _hint_qid != "":
		st["hint_hidden"] = st.get("hint_hidden", {})
		st.hint_hidden[_hint_qid] = true
	_hint.visible = false
	_spotlight("")

var _spot_tween: Tween
var _spot_what := ""

## Pulses the HUD element a tutorial step is about.
func _spotlight(what: String) -> void:
	if what == _spot_what:
		return
	_spot_what = what
	if _spot_tween:
		_spot_tween.kill()
		_spot_tween = null
	_hotbar_panel.modulate = Color.WHITE
	if what == "hotbar":
		_spot_tween = create_tween().set_loops()
		_spot_tween.tween_property(_hotbar_panel, "modulate", Color(1.35, 1.25, 0.8), 0.6).set_trans(Tween.TRANS_SINE)
		_spot_tween.tween_property(_hotbar_panel, "modulate", Color.WHITE, 0.6).set_trans(Tween.TRANS_SINE)

func _refresh_clock() -> void:
	if not GameState.started:
		return
	_date.text = Calendar.date_string(GameState.day())
	_time.text = Calendar.time_string(GameState.minute(), Settings.twelve_hour)
	_weather.text = Calendar.weather_name(GameState.world.get("weather", "sun"))
	_dial.minute = GameState.minute()
	_dial.queue_redraw()
	_refresh_level()

func _refresh_level() -> void:
	if not GameState.started:
		return
	var f: Dictionary = GameState.world.farm
	_level.text = tr("Farm Lv %d") % int(f.level)
	var need := Progression.farm_xp_for(int(f.level))
	_xp.max_value = need
	_xp.value = int(f.xp)
	var me := GameState.local_player()
	if me:
		_plevel.text = tr("Level %d") % me.level
		_pxp.max_value = Skills.xp_to_next(me.level)
		_pxp.value = me.xp if me.level < Skills.MAX_LEVEL else _pxp.max_value

func _refresh_energy() -> void:
	var p := GameState.local_player()
	if p == null:
		return
	_energy.frac = clampf(p.energy / maxf(1.0, p.energy_cap()), 0.0, 1.0)
	_energy.low = p.energy < p.energy_cap() * 0.2
	_energy.queue_redraw()

func _refresh_hotbar() -> void:
	var p := GameState.local_player()
	if p == null:
		return
	for i in _slots.size():
		var s: ItemSlot = _slots[i]
		var e := p.hotbar_entry(i)
		s.selected = i == p.selected
		s.glint = not e.is_empty() and Enchanting.has_any(p, e.id)
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

## Chips show next to the gold while the player is inside the casino.
func _refresh_chips() -> void:
	var me := GameState.local_player() if GameState.started else null
	_chip_row.visible = me != null and me.map_id in ["casino", "casino_vip"]
	if _chip_row.visible:
		_chip_label.text = Num.group(Casino.chips(me))

func _process(delta: float) -> void:
	_toasts.position.y = _lv_panel.position.y + _lv_panel.size.y + 6
	var target := float(GameState.money()) if GameState.started else 0.0
	if absf(_money_shown - target) > 0.5:
		_money_shown = lerpf(_money_shown, target, minf(1.0, delta * 8.0))
		if absf(_money_shown - target) < 1.0:
			_money_shown = target
	var shown := int(round(_money_shown))
	_money.text = Num.short(shown) if shown >= 1000000 else Num.group(shown)
	if _name_t > 0:
		_name_t -= delta
		_hotbar_name.modulate.a = clampf(_name_t, 0, 1)
	_energy.modulate.a = 0.55 + 0.45 * absf(sin(Time.get_ticks_msec() / 250.0)) if _energy.low else 1.0
	if Engine.get_process_frames() % 30 == 0:
		_refresh_lead()
	if Engine.get_process_frames() % 60 == 15:
		_refresh_quest()

## A few coins fly from the middle of the screen into the money counter.
func _fly_coins(amount: int) -> void:
	if not is_inside_tree() or not _coin_icon.is_visible_in_tree():
		return
	var view := get_viewport().get_visible_rect().size
	var to := _coin_icon.global_position
	for i in clampi(1 + int(log(float(amount)) / log(4.0)), 1, 7):
		var c := TextureRect.new()
		c.texture = _coin_icon.texture
		c.size = Vector2(12, 12)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.position = view / 2.0 + Vector2(randf_range(-18, 18), randf_range(-26, 6))
		add_child(c)
		var tw := c.create_tween()
		tw.tween_interval(i * 0.05)
		tw.tween_property(c, "position", to, 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_callback(c.queue_free)

func toast(text: String, _icon: String = "") -> void:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.box(Color(0.13, 0.1, 0.12, 0.85), Color("#ffd447"), 1, 3, 4, false))
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.label(text, 9, UITheme.CREAM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(200, 0)
	pc.add_child(l)
	_toasts.add_child(pc)
	# queue_free leaves the node in the tree until the frame ends, so a while on
	# get_child_count would spin forever once a sixth toast arrives.
	while _toasts.get_child_count() > 5:
		var old := _toasts.get_child(0)
		_toasts.remove_child(old)
		old.free()
	pc.modulate.a = 0
	var tw := pc.create_tween()
	tw.tween_property(pc, "modulate:a", 1.0, 0.2)
	tw.tween_interval(3.5)
	tw.tween_property(pc, "modulate:a", 0.0, 0.5)
	tw.tween_callback(pc.queue_free)


## The sun (or moon after dusk) travelling an arc from 6am to 2am, filling the arc behind it.
class DayDial extends Control:
	var minute := Calendar.DAY_START

	func _draw() -> void:
		var c := Vector2(size.x / 2.0, size.y - 2)
		var r := minf(size.x / 2.0, size.y) - 3.0
		var t := clampf(float(minute - Calendar.DAY_START) / float(Calendar.DAY_END - Calendar.DAY_START), 0.0, 1.0)
		var a := PI + t * PI
		var night := Calendar.is_night(minute)
		draw_line(Vector2(0, c.y + 1), Vector2(size.x, c.y + 1), UITheme.PARCHMENT_DK.darkened(0.25))
		draw_arc(c, r, PI, TAU, 20, UITheme.PARCHMENT_DK.darkened(0.1), 1.0)
		draw_arc(c, r, PI, a, 20, Color("#5a68a8") if night else Color("#e09a30"), 2.0)
		var p := c + Vector2(cos(a), sin(a)) * r
		draw_circle(p, 4.0, UITheme.OUTLINE)
		if night:
			draw_circle(p, 3.0, Color("#eef2ff"))
			draw_circle(p + Vector2(1.5, -1), 2.2, UITheme.PARCHMENT)
		else:
			draw_circle(p, 3.0, UITheme.COIN)


## Energy as a row of pips; the last one fills partially.
class EnergyPips extends Control:
	const PIPS := 10
	var frac := 1.0
	var low := false

	func _draw() -> void:
		var w := 7.0
		var fill := Color("#e07050") if low else UITheme.ENERGY
		for i in PIPS:
			var r := Rect2(i * (w + 2.0), 0, w, size.y)
			draw_rect(r, Color("#c8b088"))
			var f := clampf(frac * PIPS - i, 0.0, 1.0)
			if f > 0.0:
				var fw := maxf(1.0, roundf(w * f))
				draw_rect(Rect2(r.position, Vector2(fw, size.y)), fill)
				draw_rect(Rect2(r.position, Vector2(fw, 1)), fill.lightened(0.4))
