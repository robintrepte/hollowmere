class_name JournalPanel
extends PanelContainer
## Journal: villagers (hearts, birthdays, gifts), Village Board requests, the Wildling dex and weekly challenges.

signal closed

const TABS := [["people", "Villagers"], ["board", "Requests"], ["dex", "Wildlings"], ["weekly", "This week"]]

var player: PlayerData
var tab := "people"
var _tabs: HBoxContainer
var _body: VBoxContainer
var _scroll: ScrollContainer

func _init(p: PlayerData = null, start_tab: String = "people") -> void:
	player = p
	tab = start_tab

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -260
	offset_right = 260
	offset_top = -155
	offset_bottom = 145
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	_tabs = HBoxContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_tabs)
	head.add_child(UITheme.button("Close", func(): closed.emit()))
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 3)
	_scroll.add_child(_body)
	_refresh()

func _refresh() -> void:
	for c in _tabs.get_children():
		c.queue_free()
	for t in TABS:
		var b := UITheme.button(t[1], func(): tab = t[0]; Audio.sfx("tick", 0.0); _refresh())
		b.disabled = tab == t[0]
		_tabs.add_child(b)
	for c in _body.get_children():
		c.queue_free()
	_scroll.scroll_vertical = 0
	match tab:
		"people": _people()
		"board": _board()
		"dex": _dex()
		"weekly": _weekly()

func _card() -> HBoxContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 3, false))
	_body.add_child(pc)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	pc.add_child(h)
	return h

func _people() -> void:
	var ids: Array = Data.villagers.keys()
	ids.sort_custom(func(a, b): return int(player.relationship(a).pts) > int(player.relationship(b).pts))
	for vid in ids:
		var v: Dictionary = Data.villagers[vid]
		var st := player.relationship(vid)
		var h := _card()
		h.add_child(UITheme.icon_rect(Art.portrait(vid), 32))
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 0)
		h.add_child(col)
		var name_line := "%s%s" % [v.name, "  ♥ dating" if st.get("dating", false) else ("  ♥ married" if st.get("married", false) else "")]
		col.add_child(UITheme.label(name_line, 10, UITheme.INK))
		var hearts := Relationships.hearts(st)
		var cap := Relationships.MAX_HEARTS if not v.get("romance", false) or st.get("dating", false) else Relationships.MAX_HEARTS_FRIEND
		col.add_child(UITheme.label("♥".repeat(hearts) + "♡".repeat(maxi(0, cap - hearts)), 9, UITheme.HEART))
		var bits: Array = []
		var bd: Array = v.get("birthday", [])
		if bd.size() == 2:
			bits.append("Birthday: %s %d" % [str(bd[0]).capitalize(), int(bd[1])])
		bits.append("Gifts this week %d/2" % int(st.gifts_week))
		if v.get("romance", false):
			bits.append("Romanceable")
		col.add_child(UITheme.label("  ·  ".join(bits), 8, UITheme.MUTED))
		var today := VBoxContainer.new()
		h.add_child(today)
		today.add_child(UITheme.label("Talked ✓" if st.talked else "Not talked", 8, UITheme.LEAF.darkened(0.3) if st.talked else UITheme.MUTED))
		today.add_child(UITheme.label("Gift ✓" if st.gifted_today else "No gift yet", 8, UITheme.LEAF.darkened(0.3) if st.gifted_today else UITheme.MUTED))

func _board() -> void:
	_body.add_child(UITheme.label("Village Board · new requests every Monday", 9, UITheme.MUTED))
	var board: Array = GameState.world.board
	if board.is_empty():
		_body.add_child(UITheme.label("No requests pinned up right now.", 10, UITheme.MUTED))
	for i in board.size():
		var b: Dictionary = board[i]
		var h := _card()
		h.add_child(UITheme.icon_rect(Art.item(b.item), 32))
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(col)
		col.add_child(UITheme.label("%s wants %d %s" % [Data.villager_name(b.get("from", "")), int(b.n), Data.item_name(b.item)], 10, UITheme.INK))
		var have := player.inventory.count(b.item)
		col.add_child(UITheme.label("Reward %dg + friendship  ·  You have %d" % [int(b.money), have], 8, UITheme.MUTED))
		if b.get("done", false):
			h.add_child(UITheme.label("Done ✓", 9, UITheme.LEAF.darkened(0.3)))
		else:
			var idx := i
			var btn := UITheme.button("Deliver", func():
				var r: Dictionary = Coop.act("deliver_board", [idx])
				if r.ok:
					Audio.sfx("coin")
					EventBus.toast.emit("Delivered! +%dg" % int(b.money), "")
				elif r.reason != "":
					EventBus.toast.emit(r.reason, "")
				await get_tree().process_frame
				_refresh())
			btn.disabled = have < int(b.n)
			h.add_child(btn)

func _dex() -> void:
	var dex: Dictionary = GameState.world.dex
	var owned := Progression.owned_count(dex)
	var seen := 0
	for k in dex:
		if dex[k].seen:
			seen += 1
	_body.add_child(UITheme.label("Befriended %d · Seen %d · Total %d" % [owned, seen, Data.species_order.size()], 10, UITheme.WOOD))
	var next_m := {}
	for m in Data.progression.dex_milestones:
		if owned < int(m.n):
			next_m = m
			break
	if not next_m.is_empty():
		_body.add_child(UITheme.label("Next reward at %d befriended" % int(next_m.n), 8, UITheme.MUTED))
	var grid := GridContainer.new()
	grid.columns = 12
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	_body.add_child(grid)
	for i in Data.species_order.size():
		var sid: String = Data.species_order[i]
		var e: Dictionary = dex.get(sid, {})
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel", UITheme.box(UITheme.CREAM if e.get("owned", false) else UITheme.PARCHMENT_DK, Color("#b09060"), 1, 2, 1, false))
		var ic := UITheme.icon_rect(Art.creature(sid, true), 32)
		if not e.get("seen", false):
			ic.modulate = Color(0, 0, 0, 0.18)
		elif not e.get("owned", false):
			ic.modulate = Color(0.1, 0.1, 0.15, 0.7)
		cell.add_child(ic)
		cell.tooltip_text = "#%03d %s%s" % [i + 1, Data.species[sid].name if e.get("seen", false) else "???", "  ★" if e.get("starry", false) else ""]
		grid.add_child(cell)

func _weekly() -> void:
	_body.add_child(UITheme.label("Weekly challenges · reset every Monday", 9, UITheme.MUTED))
	for c in GameState.world.weekly:
		var h := _card()
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(col)
		col.add_child(UITheme.label(c.text, 10, UITheme.INK))
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 5)
		bar.max_value = maxi(1, int(c.n))
		bar.value = int(c.progress)
		col.add_child(bar)
		col.add_child(UITheme.label("%d / %d  ·  Reward %dg" % [int(c.progress), int(c.n), int(c.reward_money)], 8, UITheme.MUTED))
		if c.done:
			h.add_child(UITheme.label("Done ✓", 9, UITheme.LEAF.darkened(0.3)))
