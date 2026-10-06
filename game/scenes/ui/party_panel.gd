class_name PartyPanel
extends PanelContainer
## Party, farm and Shelter Wildlings: details, lead order, moving between party, Den and Shelter, farm jobs.

signal closed

## Shown as a tab inside the MenuShell: no frame and no close button of its own.
var embedded := false

var player: PlayerData
var tab := "party"
var _sel: Creature
var _swap_slot := -1
var _picking_mate := false
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
	if not embedded:
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

func _open_tab(id: String) -> void:
	tab = id
	_sel = null
	_refresh()

func _creatures() -> Array:
	match tab:
		"party": return player.party
		"farm": return GameState.ranch
		_: return GameState.sanctuary

func _refresh() -> void:
	for c in _tabs.get_children():
		c.queue_free()
	for t in [
		["party", tr("Party %d/%d") % [player.party.size(), PlayerData.PARTY_MAX]],
		["farm", tr("Farm %d/%d") % [GameState.ranch.size(), GameState.den_capacity()]],
		["sanctuary", tr("Shelter %d") % GameState.sanctuary.size()],
	]:
		var b := UITheme.button(t[1], _open_tab.bind(t[0]))
		b.disabled = tab == t[0]
		_tabs.add_child(b)
	for c in _list.get_children():
		c.queue_free()
	var arr := _creatures()
	if _sel == null or not _sel in arr:
		_sel = arr[0] if arr.size() > 0 else null
	if tab == "farm" and not arr.is_empty():
		_list.add_child(_farm_overview(arr))
	elif tab == "sanctuary" and not arr.is_empty():
		var note := UITheme.label(tr("Safe here until your party or the Den has room."), 8, UITheme.WOOD)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(190, 0)
		_list.add_child(note)
	if arr.is_empty():
		var empty_l: Label
		if tab == "sanctuary":
			empty_l = UITheme.label("No Wildlings are waiting in the Shelter.\nSend some here from your party, or they land here when your party and the Den are full.", 9, UITheme.MUTED)
		elif tab == "party":
			empty_l = UITheme.label("Your party is empty.", 9, UITheme.MUTED)
		else:
			empty_l = UITheme.label("No Wildlings live on the farm yet.\nMove some here from your party.", 9, UITheme.MUTED)
		empty_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty_l.custom_minimum_size = Vector2(190, 0)
		_list.add_child(empty_l)
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
	b.pressed.connect(func(): _sel = c; _swap_slot = -1; _picking_mate = false; Audio.sfx("tick", 0.0); _refresh())
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
	var nl := UITheme.label(tr("%s%s  Lv%d") % ["★ " if c.starry else "", c.display_name(), c.level], 10, UITheme.WOOD_DK)
	nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nl)
	var sub := ""
	if tab == "farm":
		var name := tr(str(Data.job_info(c.job).get("job_name", tr("Worker"))))
		if c.napping:
			sub = tr("%s · taking a break · energy %d") % [name, int(c.energy)]
		else:
			sub = (tr("Job: %s") % name) + (tr("  ·  energy %d") % int(c.energy))
	elif tab == "sanctuary":
		sub = tr("Waiting  ·  HP %d/%d") % [c.hp, c.max_hp()]
	else:
		sub = tr("HP %d/%d%s") % [c.hp, c.max_hp(), tr("  ·  fainted") if c.is_fainted() else ""]
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

func _move_chip(mid: String, picked: bool, on_press: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(140, 16)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", UITheme.fs(9))
	b.add_theme_color_override("font_color", UITheme.INK)
	b.add_theme_color_override("font_hover_color", UITheme.INK)
	b.add_theme_color_override("font_pressed_color", UITheme.INK)
	var base := UITheme.CREAM
	var edge := Color("#b09060")
	if mid != "":
		var m: Dictionary = Data.get_move(mid)
		base = Data.type_color(m.type).lightened(0.35)
		edge = Data.type_color(m.type).darkened(0.3)
		b.text = tr("%s  %s%s") % [tr(str(m.name)), tr("[%s] ") % Data.type_name(m.type) if Settings.colorblind else "", (tr("· %d") % int(m.power)) if int(m.power) > 0 else tr("· status")]
		b.tooltip_text = tr("%s · %s\n%s") % [Data.type_name(m.type), tr("Physical") if m.cat == "phys" else tr("Special") if m.cat == "spec" else tr("Status"), tr(str(m.get("desc", "")))]
	else:
		b.text = "+ empty slot"
	var normal := UITheme.box(base, Color("#ffd447") if picked else edge, 2 if picked else 1, 3, 3, false)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", UITheme.box(base.lightened(0.15), Color("#ffd447"), 1, 3, 3, false))
	b.add_theme_stylebox_override("pressed", normal)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(on_press)
	return b

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
	info.add_child(UITheme.label(tr("%s%s") % [tr("★ Starry ") if c.starry else "", c.display_name()], 13, UITheme.WOOD_DK))
	var types := HBoxContainer.new()
	for t in c.types():
		types.add_child(_chip(Data.type_name(t), Data.type_color(t)))
	types.add_child(UITheme.label(tr("  Lv%d") % c.level, 10))
	info.add_child(types)
	var nat: Dictionary = Data.natures.get(c.nature, {})
	var trd: Dictionary = Data.traits.get(c.trait_id, {})
	info.add_child(UITheme.label(tr("%s nature · %s") % [str(nat.get("name", c.nature)).capitalize(), trd.get("name", c.trait_id)], 9, UITheme.INK))
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
	info.add_child(UITheme.label(tr("Grooming %d%%  ·  Show class %s%s") % [c.grooming, Endless.rank_name(c.show_rank),
		tr("  ·  %d ribbons") % c.ribbons if c.ribbons > 0 else ""], 8, UITheme.MUTED))
	if trd.has("desc"):
		var td := UITheme.label(trd.desc, 8, UITheme.MUTED)
		td.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_detail.add_child(td)
	# Stats
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 10)
	_detail.add_child(grid)
	for s in Data.STATS:
		grid.add_child(UITheme.label(tr(s.capitalize()), 8, UITheme.MUTED))
	for s in Data.STATS:
		var val := c.max_hp() if s == "hp" else c.stat(s)
		var mult := c.nature_mult(s)
		grid.add_child(UITheme.label(str(val), 10, Color("#3a8a3a") if mult > 1.0 else (Color("#b04040") if mult < 1.0 else UITheme.INK)))
	for s in Data.STATS:
		var g := Breeding.gene_grade(int(c.genes[s]))
		var gl := UITheme.label("Gene " + g, 8, Breeding.grade_color(g))
		gl.mouse_filter = Control.MOUSE_FILTER_PASS
		gl.tooltip_text = tr("Genes are inherited when breeding. S is the best.")
		grid.add_child(gl)
	# Moves
	_detail.add_child(UITheme.label("Moves", 10, UITheme.WOOD))
	var mg := GridContainer.new()
	mg.columns = 2
	mg.add_theme_constant_override("h_separation", 4)
	mg.add_theme_constant_override("v_separation", 3)
	_detail.add_child(mg)
	var spare := c.spare_moves()
	for slot in 4:
		if slot >= c.moves.size() and (spare.is_empty() or slot > c.moves.size()):
			break
		var mid: String = c.moves[slot] if slot < c.moves.size() else ""
		mg.add_child(_move_chip(mid, slot == _swap_slot, func():
			_swap_slot = -1 if _swap_slot == slot else slot
			Audio.sfx("tick", 0.0)
			_show_detail()))
	if not spare.is_empty():
		if _swap_slot < 0:
			_detail.add_child(UITheme.label(tr("%d more known moves. Click a slot to swap.") % spare.size(), 8, UITheme.MUTED))
		else:
			_detail.add_child(UITheme.label("Swap in:", 9, UITheme.WOOD))
			var sg := GridContainer.new()
			sg.columns = 2
			sg.add_theme_constant_override("h_separation", 4)
			sg.add_theme_constant_override("v_separation", 3)
			_detail.add_child(sg)
			for sm in spare:
				sg.add_child(_move_chip(sm, false, func():
					if c.equip_move(_swap_slot, sm):
						Audio.sfx("open")
						EventBus.party_changed.emit()
					_swap_slot = -1
					_show_detail()))
	# Farm job. Shelter Wildlings are stored, not working.
	if tab == "sanctuary":
		var wait := UITheme.label(tr("Resting in the Shelter. They can rejoin your party when there's room."), 9, UITheme.LEAF.darkened(0.35))
		wait.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_detail.add_child(wait)
	else:
		var job_t: Dictionary = Data.job_info(c.job_type())
		_detail.add_child(UITheme.label(tr("Farm job: %s. %s") % [job_t.job_name, job_t.job_desc], 9, UITheme.LEAF.darkened(0.35)))
		if tab == "farm" and c.job != "":
			_detail.add_child(UITheme.label(FarmJobs.hourly_text(c.job, c.job_power(c.job)), 8, UITheme.MUTED))
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
			if Coop.act("move_creature_act", [c.uid, "den"]).ok:
				EventBus.toast.emit(tr("%s moved to the farm and started working: %s.") % [c.display_name(), tr(str(Data.job_info(c.job_type()).get("job_name", "")))], "")
				_sel = null
				_refresh()
			else:
				EventBus.toast.emit(tr("The Den is full, or this is your last party member."), ""))
		send.disabled = player.party.size() <= 1
		acts.add_child(send)
		var shelter := UITheme.button("Send to Shelter", func():
			if Coop.act("move_creature_act", [c.uid, "sanctuary"]).ok:
				EventBus.toast.emit(tr("%s is waiting in the Shelter.") % c.display_name(), "")
				_sel = null
				_refresh()
			else:
				EventBus.toast.emit(tr("This is your last party member."), ""))
		shelter.disabled = player.party.size() <= 1
		acts.add_child(shelter)
	elif tab == "farm":
		var join := UITheme.button("Join party", func():
			if Coop.act("move_creature_act", [c.uid, "party"]).ok:
				_sel = null
				_refresh())
		join.disabled = player.party.size() >= PlayerData.PARTY_MAX
		acts.add_child(join)
		_job_cards(c)
		_breeding_section(c)
	else:
		var take := UITheme.button("Join party", func():
			if Coop.act("move_creature_act", [c.uid, "party"]).ok:
				_sel = null
				_refresh()
			else:
				EventBus.toast.emit(tr("There's no room there."), ""))
		take.disabled = player.party.size() >= PlayerData.PARTY_MAX
		acts.add_child(take)
		var to_farm := UITheme.button("Send to farm", func():
			if Coop.act("move_creature_act", [c.uid, "den"]).ok:
				EventBus.toast.emit(tr("%s moved to the farm and started working: %s.") % [c.display_name(), tr(str(Data.job_info(c.job_type()).get("job_name", "")))], "")
				_sel = null
				_refresh()
			else:
				EventBus.toast.emit(tr("There's no room there."), ""))
		to_farm.disabled = GameState.ranch.size() >= GameState.den_capacity()
		acts.add_child(to_farm)

func _farm_overview(arr: Array) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var working := 0
	var napping := 0
	for c in arr:
		if c.napping:
			napping += 1
		elif c.job != "":
			working += 1
	var line := tr("On the farm: %d working") % working
	if napping > 0:
		line = tr("On the farm: %d working, %d taking a break") % [working, napping]
	box.add_child(UITheme.label(line, 8, UITheme.WOOD))
	return box

func _job_cards(c: Creature) -> void:
	_detail.add_child(UITheme.label("Assign a job", 10, UITheme.WOOD))
	var note := UITheme.label("They keep this job and rest on their own when they need to.", 8, UITheme.MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(200, 0)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_child(note)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 4)
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_child(stack)
	for t in c.types():
		var jid: String = Data.types[t].job
		if c.can_do_job(jid):
			var native := jid == c.job_type()
			stack.add_child(_job_card(c, jid, Data.types[t].job_name, FarmJobs.hourly_text(jid, c.job_power(jid)), native))

func _job_card(c: Creature, jid: String, title: String, desc: String, native: bool) -> Control:
	var on := c.job == jid
	var bg := UITheme.CREAM if on else UITheme.PARCHMENT_DK
	var edge := Color("#ffd23f") if on else Color("#b09060")
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var paint := func(hot: bool) -> void:
		var fill := bg.lightened(0.08) if hot and not on else bg
		card.add_theme_stylebox_override("panel", UITheme.box(fill, Color("#ffd23f") if hot or on else edge, 2 if hot or on else 1, 3, 6, false))
	paint.call(false)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 2)
	card.add_child(v)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 4)
	v.add_child(row)
	var title_l := UITheme.label(title, 10, UITheme.WOOD_DK)
	title_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(title_l)
	if native:
		row.add_child(Badge.new("Fits the type", Color("#c8e6a0")))
	if on:
		row.add_child(Badge.new("On duty", UITheme.COIN))
	var stars := ""
	for i in mini(5, maxi(1, c.job_power(jid))):
		stars += "★"
	var star := UITheme.label(stars, 8, UITheme.COIN)
	star.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(star)
	var d := UITheme.label(desc, 8, UITheme.MUTED)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(200, 0)
	d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(d)
	card.mouse_entered.connect(func(): paint.call(true))
	card.mouse_exited.connect(func(): paint.call(false))
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			Coop.act("set_job_act", [c.uid, jid])
			Audio.sfx("tick", 0.0)
			card.accept_event()
			_refresh())
	return card

func _breeding_section(c: Creature) -> void:
	_detail.add_child(UITheme.label("Breeding", 10, UITheme.WOOD))
	var mate := GameState.find_creature(GameState.pair_of(c.uid))
	if mate:
		var row := HBoxContainer.new()
		row.add_child(UITheme.icon_rect(Art.creature(mate.species_id, true), 24))
		row.add_child(UITheme.label(tr("Paired with %s · %d%% egg chance each night") % [mate.display_name(), int(Breeding.egg_chance(c, mate) * 100.0)], 9, UITheme.INK))
		_detail.add_child(row)
		_detail.add_child(UITheme.button("Unpair", func():
			Coop.act("clear_pair_act", [c.uid])
			Audio.sfx("close")
			_show_detail()))
		return
	var options := Breeding.partners(c, GameState.ranch)
	if "none" in c.species().egg:
		_detail.add_child(UITheme.label("This Wildling can't have eggs.", 8, UITheme.MUTED))
		return
	if options.is_empty():
		_detail.add_child(UITheme.label(tr("No compatible partner in the Den. Egg groups: %s.") % ", ".join(c.species().egg), 8, UITheme.MUTED))
		return
	if not _picking_mate:
		_detail.add_child(UITheme.button("Pair for eggs...", func():
			_picking_mate = true
			_show_detail()))
		return
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	_detail.add_child(flow)
	for o in options:
		var b: Creature = o.creature
		var btn := UITheme.button(tr("%s  %d%%") % [b.display_name(), int(o.chance * 100.0)], func():
			var res: Dictionary = Coop.act("set_pair_act", [c.uid, b.uid])
			_picking_mate = false
			if res.ok:
				Audio.sfx("gift")
				EventBus.toast.emit(tr("%s and %s are now a pair. Eggs will appear in the farm chest.") % [c.display_name(), b.display_name()], "")
			else:
				EventBus.toast.emit(res.reason, "")
			_show_detail())
		btn.icon = Art.creature(b.species_id, true)
		btn.add_theme_constant_override("icon_max_width", 20)
		flow.add_child(btn)
	flow.add_child(UITheme.button("Cancel", func():
		_picking_mate = false
		_show_detail()))
