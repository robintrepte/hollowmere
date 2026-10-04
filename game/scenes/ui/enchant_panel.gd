class_name EnchantPanel
extends PanelContainer
## The enchanting table, anvil and grindstone: pick one of your tools on the left,
## then enchant it, apply or combine books, or strip it back to plain.

signal closed

var player: PlayerData
var station := "enchanting_table"
var map_id := ""
var tile := Vector2i.ZERO
var _tool := ""
var _list: VBoxContainer
var _detail: VBoxContainer

const TITLES := {"enchanting_table": "Enchanting Table", "anvil": "Anvil", "grindstone": "Grindstone"}

func _init(p: PlayerData = null, station_id: String = "enchanting_table", map: String = "", t: Vector2i = Vector2i.ZERO) -> void:
	player = p
	station = station_id
	map_id = map
	tile = t

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -260
	offset_right = 260
	offset_top = -150
	offset_bottom = 145
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := UITheme.label(TITLES.get(station, "Enchanting Table"), 14, UITheme.WOOD_DK)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_materials())
	head.add_child(UITheme.button("Close", func(): closed.emit()))
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 10)
	v.add_child(cols)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(190, 0)
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
	_detail.add_theme_constant_override("separation", 4)
	dsc.add_child(_detail)
	_refresh()

func _materials() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 3)
	h.name = "Materials"
	for id in Enchanting.MATERIALS:
		h.add_child(UITheme.icon_rect(Art.item(id), 16))
		var l := UITheme.label(str(player.inventory.count(id)) + "  ", 9, UITheme.INK)
		l.name = id
		h.add_child(l)
	return h

func _tools() -> Array:
	return Enchanting.tools().filter(func(tl): return player.inventory.count(tl) > 0)

func _refresh() -> void:
	var mats := find_child("Materials", true, false)
	if mats:
		for id in Enchanting.MATERIALS:
			var l: Label = mats.get_node_or_null(id)
			if l:
				l.text = str(player.inventory.count(id)) + "  "
	for c in _list.get_children():
		c.queue_free()
	var tools := _tools()
	if not _tool in tools:
		_tool = tools[0] if tools.size() > 0 else ""
	for tl in tools:
		_list.add_child(_row(tl))
	for c in _detail.get_children():
		c.queue_free()
	if _tool == "":
		_detail.add_child(UITheme.label("Bring a tool in your pack.", 10, UITheme.MUTED))
		return
	var cur := Enchanting.on_tool(player, _tool)
	_detail.add_child(UITheme.label(Data.item_name(_tool), 12, UITheme.WOOD_DK))
	_detail.add_child(_wrap(tr("Enchantments: %s") % (Enchanting.describe(cur) if not cur.is_empty() else tr("none")), 9, UITheme.INK))
	match station:
		"enchanting_table": _table(cur)
		"anvil": _anvil()
		"grindstone": _grindstone(cur)

func _row(tl: String) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(180, 30)
	var picked := tl == _tool
	var st := UITheme.box(UITheme.CREAM if picked else UITheme.PARCHMENT_DK, Color("#ffd447") if picked else Color("#b09060"), 2 if picked else 1, 3, 2, false)
	for s in ["normal", "hover", "pressed"]:
		b.add_theme_stylebox_override(s, st)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func(): _tool = tl; Audio.sfx("tick", 0.0); _refresh())
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 3
	b.add_child(h)
	var slot := ItemSlot.new()
	slot.bg = false
	slot.custom_minimum_size = Vector2(24, 24)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.set_item(tl)
	slot.glint = Enchanting.has_any(player, tl)
	h.add_child(slot)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", -2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(col)
	col.add_child(UITheme.label(Data.item_name(tl), 9, UITheme.INK))
	var ench := Enchanting.on_tool(player, tl)
	if not ench.is_empty():
		var e := UITheme.label(Enchanting.describe(ench), 7, Color("#7a4ab0"))
		e.clip_text = true
		e.custom_minimum_size = Vector2(140, 0)
		col.add_child(e)
	return b

func _wrap(text: String, size: int, col: Color) -> Label:
	var l := UITheme.label(text, size, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(250, 0)
	return l

func _table(cur: Dictionary) -> void:
	var shelves := Enchanting.shelves_near(GameState.grid(map_id), tile)
	_detail.add_child(_wrap(tr("Bookshelves nearby: %d · strongest level: %s") % [shelves, Enchanting.ROMAN[Enchanting.power(shelves)]], 8, UITheme.MUTED))
	if not cur.is_empty():
		_detail.add_child(_wrap(tr("Already enchanted. Add books at an anvil, or clear it at a grindstone first."), 9, UITheme.MUTED))
		return
	var offers := GameState.enchant_offers(player.id, map_id, tile.x, tile.y, _tool)
	for o in offers:
		var shown: Array = o.shown
		var more := " + ?" if o.enchants.size() > 1 else ""
		var can := player.inventory.count("arcane_essence") >= int(o.essence) and player.inventory.count("glimmer_dust") >= int(o.dust)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		_detail.add_child(h)
		var info := VBoxContainer.new()
		info.add_theme_constant_override("separation", -2)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(info)
		info.add_child(UITheme.label(Enchanting.title(shown[0], int(shown[1])) + more, 10, Color("#5a2a90")))
		info.add_child(UITheme.label(tr("%d Arcane Essence · %d Glimmer Dust") % [int(o.essence), int(o.dust)], 8, UITheme.INK if can else Color("#b04040")))
		var slot := int(o.slot)
		var b := UITheme.button("Enchant", func(): _do("enchant_act", [map_id, tile.x, tile.y, _tool, slot]))
		b.disabled = not can
		b.tooltip_text = tr(str(Enchanting.spec(shown[0]).get("desc", "")))
		h.add_child(b)
	_detail.add_child(_wrap(tr("Only the first enchantment is shown. Stronger offers may hold a surprise."), 7, UITheme.MUTED))

func _books() -> Array:
	var seen := {}
	for e in player.inventory.entries:
		if str(e.id).begins_with("book:"):
			seen[e.id] = true
	var out: Array = seen.keys()
	out.sort()
	return out

func _anvil() -> void:
	var books := _books()
	if books.is_empty():
		_detail.add_child(_wrap(tr("You have no enchanted books. Look for them in treasure chests and while fishing."), 9, UITheme.MUTED))
		return
	for book in books:
		var b := Enchanting.parse_book(book)
		var cost := Enchanting.anvil_cost(int(b[1]))
		var n := player.inventory.count(book)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		_detail.add_child(h)
		h.add_child(UITheme.icon_rect(Art.item(book), 20))
		var info := VBoxContainer.new()
		info.add_theme_constant_override("separation", -2)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(info)
		info.add_child(UITheme.label("%s ×%d" % [Enchanting.title(b[0], int(b[1])), n], 9, Color("#5a2a90")))
		info.add_child(UITheme.label(tr("%d Arcane Essence") % cost, 8, UITheme.INK if player.inventory.count("arcane_essence") >= cost else Color("#b04040")))
		var fits: bool = _tool in Enchanting.spec(b[0]).get("tools", [])
		var ab := UITheme.button("Apply", func(): _do("anvil_act", [map_id, tile.x, tile.y, "apply", _tool, book]))
		ab.disabled = not fits
		ab.tooltip_text = tr(str(Enchanting.spec(b[0]).get("desc", ""))) if fits else tr("That book doesn't work on this tool.")
		h.add_child(ab)
		if n >= 2 and Enchanting.combine_books(book) != "":
			h.add_child(UITheme.button("Combine", func(): _do("anvil_act", [map_id, tile.x, tile.y, "combine", _tool, book])))

func _grindstone(cur: Dictionary) -> void:
	if cur.is_empty():
		_detail.add_child(_wrap(tr("This tool has nothing to grind off."), 9, UITheme.MUTED))
		return
	_detail.add_child(_wrap(tr("Strip every enchantment from this tool and get %d Arcane Essence back.") % Enchanting.refund(cur), 9, UITheme.INK))
	_detail.add_child(UITheme.button("Grind it off", func(): _do("grindstone_act", [map_id, tile.x, tile.y, _tool])))

func _do(action: String, args: Array) -> void:
	var r: Dictionary = await Coop.act_async(action, args)
	if not r.get("ok", false):
		Audio.sfx("error")
		if str(r.get("reason", "")) != "":
			EventBus.toast.emit(str(r.reason), "")
	else:
		Audio.sfx(str(r.get("sfx", "sparkle")))
		if r.has("enchants"):
			EventBus.toast.emit(tr("%s: %s") % [Data.item_name(_tool), Enchanting.describe(r.enchants)], "star")
		elif r.has("book"):
			EventBus.toast.emit(tr("Made %s.") % Data.item_name(str(r.book)), "star")
		elif r.has("refund"):
			EventBus.toast.emit(tr("Ground clean. +%d Arcane Essence.") % int(r.refund), "")
	if is_inside_tree():
		_refresh()
