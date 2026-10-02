class_name PartyPanel
extends PanelContainer
## Party + farm Wildlings: details, lead order, moving between party and the Den, farm jobs.

signal closed

var player: PlayerData
var tab := "party"
var _sel: Creature
var _list: VBoxContainer
var _detail: VBoxContainer
var _tabs: HBoxContainer

func _init(p: PlayerData = null, start_tab: String = "party") -> void:
	player = p
	tab = start_tab

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -280
	offset_right = 280
	offset_top = -160
	offset_bottom = 150
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	_tabs = HBoxContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_tabs)
	head.add_child(UITheme.button("Close", func(): closed.emit()))
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 10)
	v.add_child(cols)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(210, 0)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cols.add_child(sc)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 2)
	sc.add_child(_list)
	var dsc := ScrollContainer.new()
	dsc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dsc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cols.add_child(dsc)
	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 3)
	dsc.add_child(_detail)
	_refresh()

func _creatures() -> Array:
	return player.party if tab == "party" else GameState.ranch

func _refresh() -> void:
	for c in _tabs.get_children():
		c.queue_free()
	for t in [["party", "Party %d/%d" % [player.party.size(), PlayerData.PARTY_MAX]], ["farm", "Farm %d/%d" % [GameState.ranch.size(), GameState.den_capacity()]]]:
		var b := UITheme.button(t[1], func(): tab = t[0]; _sel = null; _refresh())
		b.disabled = tab == t[0]
		_tabs.add_child(b)
	for c in _list.get_children():
		c.queue_free()
	var arr := _creatures()
	if _sel == null or not _sel in arr:
		_sel = arr[0] if arr.size() > 0 else null
	if arr.is_empty():
		_list.add_child(UITheme.label("No Wildlings live on the farm yet.\nMove some here from your party.", 9, UITheme.MUTED))
	for c in arr:
		_list.add_child(_row(c))
	_show_detail()

func _row(c: Creature) -> Control:
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = c == _sel
	b.custom_minimum_size = Vector2(200, 36)
	var normal := UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 2, false)
	var picked := UITheme.box(UITheme.CREAM, Color("#ffd447"), 2, 3, 2, false)
	b.add_theme_stylebox_override("normal", picked if c == _sel else normal)
	b.add_theme_stylebox_override("hover", picked)
	b.add_theme_stylebox_override("pressed", picked)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func(): _sel = c; Audio.sfx("tick", 0.0); _refresh())
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 4
	b.add_child(h)
	var ic := UITheme.icon_rect(Art.creature(c.species_id, true), 32)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(ic)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 0)
	h.add_child(v)
	var nl := UITheme.label("%s%s  Lv%d" % ["★ " if c.starry else "", c.display_name(), c.level], 10, UITheme.WOOD_DK)
	nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nl)
	var sub := ""
	if tab == "farm":
		sub = ("Job: " + Data.job_info(c.job).get("job_name", "Worker") if c.job != "" else "Resting") + "  ·  energy %d" % c.energy
	else:
		sub = "HP %d/%d%s" % [c.hp, c.max_hp(), "  ·  fainted" if c.is_fainted() else ""]
	var sl := UITheme.label(sub, 8, UITheme.MUTED)
	sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(sl)
	var hp := ProgressBar.new()
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp.show_percentage = false
	hp.custom_minimum_size = Vector2(0, 3)
	hp.max_value = c.max_hp()
	hp.value = c.hp
	v.add_child(hp)
	return b

func _chip(text: String, col: Color) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.box(col, col.darkened(0.4), 1, 2, 2, false))
	p.add_child(UITheme.label(text, 8, Color.WHITE, true))
	return p

func _show_detail() -> void:
	for c in _detail.get_children():
		c.queue_free()
	var c := _sel
	if c == null:
		return
	var sp: Dictionary = c.species()
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_detail.add_child(top)
	var art := PanelContainer.new()
	art.add_theme_stylebox_override("panel", UITheme.box(Color("#cfe6a8"), UITheme.OUTLINE, 2, 4, 2, false))
	art.add_child(UITheme.icon_rect(Art.creature(c.species_id), 64))
	top.add_child(art)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 2)
	top.add_child(info)
	info.add_child(UITheme.label("%s%s" % ["★ Starry " if c.starry else "", c.display_name()], 13, UITheme.WOOD_DK))
	var types := HBoxContainer.new()
	for t in c.types():
		types.add_child(_chip(Data.type_name(t), Data.type_color(t)))
	types.add_child(UITheme.label("  Lv%d" % c.level, 10))
	info.add_child(types)
	var nat: Dictionary = Data.natures.get(c.nature, {})
	var tr: Dictionary = Data.traits.get(c.trait_id, {})
	info.add_child(UITheme.label("%s nature · %s" % [str(nat.get("name", c.nature)).capitalize(), tr.get("name", c.trait_id)], 9, UITheme.INK))
	var lo := Creature.xp_for_level(c.level)
	var hi := Creature.xp_for_level(c.level + 1)
	var xp := ProgressBar.new()
	xp.show_percentage = false
	xp.custom_minimum_size = Vector2(140, 4)
	xp.max_value = maxi(1, hi - lo)
	xp.value = c.xp - lo
	info.add_child(xp)
	var hearts := int(c.happiness / 51)
	info.add_child(UITheme.label("Happiness " + "♥".repeat(hearts) + "♡".repeat(5 - hearts), 9, UITheme.HEART))
	if tr.has("desc"):
		var td := UITheme.label(tr.desc, 8, UITheme.MUTED)
		td.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_detail.add_child(td)
	# Stats
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 10)
	_detail.add_child(grid)
	for s in Data.STATS:
		grid.add_child(UITheme.label(s.capitalize(), 8, UITheme.MUTED))
	for s in Data.STATS:
		var val := c.max_hp() if s == "hp" else c.stat(s)
		var mult := c.nature_mult(s)
		grid.add_child(UITheme.label(str(val), 10, Color("#3a8a3a") if mult > 1.0 else (Color("#b04040") if mult < 1.0 else UITheme.INK)))
	# Moves
	_detail.add_child(UITheme.label("Moves", 10, UITheme.WOOD))
	var mg := GridContainer.new()
	mg.columns = 2
	mg.add_theme_constant_override("h_separation", 4)
	mg.add_theme_constant_override("v_separation", 3)
	_detail.add_child(mg)
	for mid in c.moves:
		var m: Dictionary = Data.get_move(mid)
		var chip := PanelContainer.new()
		chip.custom_minimum_size = Vector2(140, 0)
		chip.add_theme_stylebox_override("panel", UITheme.box(Data.type_color(m.type).lightened(0.35), Data.type_color(m.type).darkened(0.3), 1, 3, 3, false))
		chip.tooltip_text = m.get("desc", "")
		chip.add_child(UITheme.label("%s  %s" % [m.name, ("· %d" % int(m.power)) if int(m.power) > 0 else "· status"], 9, UITheme.INK))
		mg.add_child(chip)
	# Farm job
	var job_t: Dictionary = Data.job_info(c.job_type())
	_detail.add_child(UITheme.label("Farm job: %s. %s" % [job_t.job_name, job_t.job_desc], 9, UITheme.LEAF.darkened(0.35)))
	# Actions
	var acts := HFlowContainer.new()
	acts.add_theme_constant_override("h_separation", 4)
	acts.add_theme_constant_override("v_separation", 4)
	_detail.add_child(acts)
	if tab == "party":
		var idx := player.party.find(c)
		if idx > 0:
			acts.add_child(UITheme.button("Make lead", func():
				player.party.erase(c)
				player.party.insert(0, c)
				EventBus.party_changed.emit()
				_refresh()))
		var send := UITheme.button("Send to farm", func():
			if GameState.move_creature(c.uid, "den", player):
				EventBus.toast.emit("%s moved to the farm." % c.display_name(), "")
				_sel = null
				_refresh()
			else:
				EventBus.toast.emit("The Den is full, or this is your last party member.", ""))
		send.disabled = player.party.size() <= 1
		acts.add_child(send)
	else:
		var join := UITheme.button("Join party", func():
			if GameState.move_creature(c.uid, "party", player):
				_sel = null
				_refresh())
		join.disabled = player.party.size() >= PlayerData.PARTY_MAX
		acts.add_child(join)
		var jobs := OptionButton.new()
		jobs.add_theme_font_size_override("font_size", 9)
		jobs.add_item("Rest (no job)")
		jobs.set_item_metadata(0, "")
		var sel_i := 0
		for t in c.types():
			var jid: String = Data.types[t].job
			if c.can_do_job(jid):
				jobs.add_item("%s (power %d)" % [Data.types[t].job_name, c.job_power(jid)])
				jobs.set_item_metadata(jobs.item_count - 1, jid)
				if c.job == jid:
					sel_i = jobs.item_count - 1
		jobs.select(sel_i)
		jobs.item_selected.connect(func(i: int):
			GameState.set_job(c.uid, jobs.get_item_metadata(i))
			Audio.sfx("tick", 0.0)
			_refresh())
		acts.add_child(jobs)
