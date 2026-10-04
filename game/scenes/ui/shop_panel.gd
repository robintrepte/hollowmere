class_name ShopPanel
extends PanelContainer
## Buy list (seasonal, gated by unlocks) + sell list from the backpack.

signal closed

var shop_id := ""
var _list: VBoxContainer
var _sell_list: VBoxContainer
var _money: CoinLabel
var _tab := "buy"
var _tabs: HBoxContainer
var _buying := false

func _init(id: String = "") -> void:
	shop_id = id

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -220
	offset_right = 220
	offset_top = -150
	offset_bottom = 140
	var shop: Dictionary = Data.shops.get(shop_id, {})
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var owner_id: String = shop.get("owner", "")
	if owner_id != "":
		head.add_child(UITheme.icon_rect(Art.portrait(owner_id), 40))
	var hv := VBoxContainer.new()
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(hv)
	hv.add_child(UITheme.label(shop.get("name", "Shop"), 13, UITheme.WOOD_DK))
	var mrow := HBoxContainer.new()
	hv.add_child(mrow)
	_money = CoinLabel.new(GameState.money(), 11, UITheme.WOOD_DK)
	mrow.add_child(_money)
	if Casino.chips(GameState.local_player()) > 0:
		mrow.add_child(CoinLabel.new(Casino.chips(GameState.local_player()), 11, UITheme.WOOD_DK, "_chip"))
	var close := UITheme.button("Close", func(): closed.emit())
	close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	head.add_child(close)
	_tabs = HBoxContainer.new()
	v.add_child(_tabs)
	_tabs.add_child(UITheme.button("Buy", func(): _tab = "buy"; _refresh()))
	_tabs.add_child(UITheme.button("Sell", func(): _tab = "sell"; _refresh()))
	if shop_id == "carpenter":
		_tabs.add_child(UITheme.button("Build", func(): _tab = "build"; _refresh()))
	if shop.get("upgrades", false):
		_tabs.add_child(UITheme.button("Upgrade tools", func(): _tab = "upgrades"; _refresh()))
	if shop.get("backpacks", false):
		_tabs.add_child(UITheme.button("Backpacks", func(): _tab = "backpacks"; _refresh()))
	if shop.get("rods", false):
		_tabs.add_child(UITheme.button("Rods", func(): _tab = "rods"; _refresh()))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 2)
	sc.add_child(_list)
	v.add_child(UITheme.label("Shift-click to buy 5 · Prices rise with quality when selling", 8, UITheme.MUTED))
	EventBus.money_changed.connect(func(_m, _d): _refresh_money())
	_refresh()

func _refresh_money() -> void:
	if is_instance_valid(_money):
		_money.set_amount(GameState.money())

func _refresh() -> void:
	if _list == null or not is_inside_tree() or is_queued_for_deletion():
		return
	_refresh_money()
	# Drop the old rows now. queue_free would leave them in the layout until the
	# end of the frame, and a click that lands on a freshly built button would
	# rebuild again before those rows were gone.
	for c in _list.get_children():
		_list.remove_child(c)
		c.free()
	if _tab == "buy":
		var stock := Economy.shop_stock(shop_id, GameState.season(), GameState.ctx(), GameState.day(), int(GameState.world.seed))
		if stock.is_empty():
			_list.add_child(UITheme.label("Sold out for today.", 10, UITheme.MUTED))
		for s in stock:
			_list.add_child(_row(s.id, GameState.buy_value(GameState.local_player(), int(s.price)), bool(s.locked), str(s.get("req", "")), true))
	elif _tab == "build":
		_build_list()
	elif _tab == "upgrades":
		_upgrade_list()
	elif _tab == "backpacks":
		_backpack_list()
	elif _tab == "rods":
		_rod_list()
	else:
		var p := GameState.local_player()
		var seen := {}
		for e in p.inventory.all_entries():
			if Data.sell_price(e.id, int(e.q)) <= 0 or Data.get_item(e.id).get("cat", "") in ["tool", "key", "container"]:
				continue
			var key: String = tr("%s:%d") % [e.id, int(e.q)]
			if seen.has(key):
				continue
			seen[key] = true
			_list.add_child(_sell_row(e))

func _row(id: String, price: int, locked: bool, req: String, buying: bool) -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK if not locked else Color("#cfc2a8"), Color("#b09060"), 1, 3, 3, false))
	var h := HBoxContainer.new()
	pc.add_child(h)
	h.add_child(UITheme.icon_rect(Art.item(id), 32))
	var nv := VBoxContainer.new()
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.add_theme_constant_override("separation", 0)
	h.add_child(nv)
	nv.add_child(UITheme.label(Data.item_name(id), 10, UITheme.INK if not locked else UITheme.MUTED))
	var d := UITheme.label(Economy.req_text(req) if locked else Data.item_desc(id), 8, UITheme.MUTED)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(180, 0)
	nv.add_child(d)
	var b := CoinLabel.button(price)
	b.disabled = locked or GameState.money() < price
	b.pressed.connect(func():
		if b.disabled or _buying:
			return
		_buy(id, 5 if Input.is_physical_key_pressed(KEY_SHIFT) else 1))
	h.add_child(b)
	pc.tooltip_text = Data.item_name(id)
	return pc

func _sell_row(e: Dictionary) -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 3, false))
	var h := HBoxContainer.new()
	pc.add_child(h)
	h.add_child(UITheme.icon_rect(Art.item(e.id), 32))
	var n := UITheme.label(tr("%s  x%d") % [Data.item_name(e.id, int(e.q)), int(e.n)], 10)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(n)
	var price := GameState.sell_value(GameState.local_player(), e.id, int(e.q), false, shop_id)
	var sell := CoinLabel.button(price, func(): _sell(e.uid, 1), tr("Sell 1"))
	sell.remove_theme_color_override("font_color")
	h.add_child(sell)
	if int(e.n) > 1:
		h.add_child(UITheme.button("All", func(): _sell(e.uid, -1)))
	return pc

## One row: icon, title, description lines, cost lines (green if met), and an action button.
func _offer(icon: Texture2D, title: String, desc: String, costs: Array, label: String, enabled: bool, on_press: Callable, done_text: String = "") -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 3, false))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	pc.add_child(h)
	h.add_child(UITheme.icon_rect(icon, 32))
	var nv := VBoxContainer.new()
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.add_theme_constant_override("separation", 0)
	h.add_child(nv)
	nv.add_child(UITheme.label(title, 10, UITheme.INK))
	var d := UITheme.label(desc, 8, UITheme.MUTED)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(170, 0)
	nv.add_child(d)
	var cl := HFlowContainer.new()
	cl.add_theme_constant_override("h_separation", 6)
	nv.add_child(cl)
	for c in costs:
		var col := UITheme.LEAF.darkened(0.35) if c[1] else Color("#b04040")
		cl.add_child(CoinLabel.new(c[0], 8, col) if c[0] is int else UITheme.label(c[0], 8, col))
	if done_text != "":
		h.add_child(UITheme.label(done_text, 9, UITheme.LEAF.darkened(0.3)))
	else:
		var b := UITheme.button(label, on_press)
		b.disabled = not enabled
		h.add_child(b)
	return pc

func _act(action: String, args: Array) -> void:
	if _buying:
		return
	_buying = true
	var r: Dictionary = await Coop.act_async(action, args)
	if r.ok:
		Audio.sfx(r.get("sfx", "coin") if r.get("sfx", "") != "" else "coin")
		if str(r.get("note", "")) != "":
			EventBus.toast.emit(str(r.note), "star")
	elif r.reason != "":
		Audio.sfx("error")
		EventBus.toast.emit(r.reason, "")
	await get_tree().process_frame
	_finish_purchase()

func _build_list() -> void:
	var p := GameState.local_player()
	var srcs := GameState.craft_sources(p)
	var ids: Array = Data.buildings.keys()
	ids.sort_custom(func(a, b): return int(Data.buildings[a].price) < int(Data.buildings[b].price))
	for id in ids:
		var b: Dictionary = Data.buildings[id]
		var built := GameState.has_building(id)
		var req_ok := Economy.meets(b.requires, GameState.ctx())
		if not req_ok and not built and b.requires != "" and Data.buildings.has(b.requires) and not GameState.has_building(b.requires):
			continue
		var costs: Array = [[int(b.price), GameState.money() >= int(b.price)]]
		for k in b.materials:
			costs.append([tr("%s %d/%d") % [Data.item_name(k), Economy.count_in(srcs, k), int(b.materials[k])], Economy.count_in(srcs, k) >= int(b.materials[k])])
		if not req_ok:
			costs.append([Economy.req_text(b.requires), false])
		var chk := Economy.building_ok(id, GameState.ctx(), GameState.money(), srcs)
		var art: String = {"kitchen": "farmhouse", "big_den": "den", "deluxe_den": "den", "big_hatchery": "hatchery", "wildling_spa": "spa"}.get(id, id)
		var icon: Texture2D = Art.building(art)
		if icon == null:
			icon = Art.item("_sapling" if b.kind == "expansion" else "wood")
		_list.add_child(_offer(icon, tr(str(b.name)), tr(str(b.desc)), costs, tr("Build"), chk.ok,
			func(): _act("construct", [id]), tr("Built ✓") if built else ""))

func _upgrade_list() -> void:
	var p := GameState.local_player()
	var srcs := GameState.craft_sources(p)
	for tool in ["hoe", "watering_can", "pickaxe", "axe", "scythe", "shovel", "bucket"]:
		var lvl := p.tool_level(tool)
		var spec := Economy.upgrade_spec(lvl + 1)
		var cur_name: String = tr("Basic") if lvl == 0 else tr(str(Economy.upgrade_spec(lvl).get("name", "")))
		var next_name := tr(str(spec.get("name", "")))
		if spec.is_empty():
			_list.add_child(_offer(Art.item(tool), tr("%s %s") % [cur_name, Data.item_name(tool)], tr("Fully upgraded."), [], "", false, func(): pass, tr("Max ✓")))
			continue
		var have := Economy.count_in(srcs, spec.bar)
		var costs: Array = [[int(spec.price), GameState.money() >= int(spec.price)], [tr("%s %d/%d") % [Data.item_name(spec.bar), have, int(spec.n)], have >= int(spec.n)]]
		var desc := tr("%s → %s. Works a wider area and breaks tougher debris.") % [cur_name, next_name]
		if tool == "watering_can":
			desc = tr("%s → %s. Holds more water and soaks a wider area.") % [cur_name, next_name]
		elif tool == "pickaxe":
			desc = tr("%s → %s. Breaks rock faster and cracks harder ores and crystals.") % [cur_name, next_name]
		elif tool == "shovel":
			desc = tr("%s → %s. Digs trenches for less energy.") % [cur_name, next_name]
		elif tool == "bucket":
			desc = tr("%s → %s. A full bucket soaks a wider patch of soil.") % [cur_name, next_name]
		_list.add_child(_offer(Art.item(tool), tr("%s %s") % [next_name, Data.item_name(tool)], desc, costs, tr("Upgrade"),
			GameState.money() >= int(spec.price) and have >= int(spec.n), func(): _act("upgrade_tool", [tool])))

func _rod_list() -> void:
	var p := GameState.local_player()
	var lvl := p.tool_level("fishing_rod")
	for i in range(1, Fishing.MAX_ROD + 1):
		var spec := Fishing.rod_spec(i)
		var price := GameState.buy_value(p, int(spec.price))
		var req := str(spec.get("requires", ""))
		var req_ok := Economy.meets(req, GameState.ctx())
		var costs: Array = []
		if i > lvl:
			costs.append([price, GameState.money() >= price])
			if not req_ok:
				costs.append([Economy.req_text(req), false])
		var done := tr("Owned ✓") if i <= lvl else ""
		_list.add_child(_offer(Art.item("fishing_rod"), Fishing.rod_name(i), tr(str(spec.desc)), costs, tr("Upgrade"),
			i == lvl + 1 and req_ok and GameState.money() >= price, func(): _act("upgrade_rod_act", []), done))

func _backpack_list() -> void:
	var p := GameState.local_player()
	for bp in Data.progression.backpacks:
		var id: String = bp.id
		if str(bp.get("shop", shop_id)) != shop_id and not id in p.packs:
			continue
		var owned: bool = id in p.packs
		var req: String = bp.get("requires", "")
		var chips := int(bp.get("chips", 0))
		var affordable := Casino.chips(p) >= chips if chips > 0 else GameState.money() >= int(bp.price)
		var costs: Array = []
		if not owned:
			costs.append([tr("%d chips") % chips if chips > 0 else int(bp.price), affordable])
		if req != "" and not GameState.is_open_requirement(req) and not owned:
			costs.append([Economy.req_text(req), false])
		var desc := tr("A %d x %d grid pack.") % [int(bp.w), int(bp.h)] + " " + tr(str(bp.get("desc", "")))
		if owned:
			var equipped: bool = p.backpack == id
			_list.add_child(_offer(Art.item(id), tr(str(bp.name)), desc, costs, tr("Equip"), not equipped,
				func(): _act("equip_backpack", [id]), tr("Equipped ✓") if equipped else ""))
		else:
			_list.add_child(_offer(Art.item(id), tr(str(bp.name)), desc, costs, tr("Buy"),
				affordable and (req == "" or GameState.is_open_requirement(req)),
				func(): _act("buy_backpack", [id])))

func _buy(id: String, n: int) -> void:
	if _buying:
		return
	_buying = true
	var r: Dictionary = Coop.act("buy", [shop_id, id, n])
	if r.ok:
		Audio.sfx("coin")
		var msg := str(r.get("note", ""))
		if msg == "":
			msg = tr("Bought %d %s") % [n, Data.item_name(id)]
		EventBus.toast.emit(msg, "")
	elif r.reason != "":
		Audio.sfx("error")
		EventBus.toast.emit(r.reason, "")
	await get_tree().process_frame
	_finish_purchase()

func _finish_purchase() -> void:
	var alive := is_inside_tree() and not is_queued_for_deletion()
	if alive:
		_refresh()
	_buying = false

func _sell(uid: String, n: int) -> void:
	if _buying:
		return
	_buying = true
	var r: Dictionary = Coop.act("sell", [uid, n, shop_id])
	if r.ok:
		Audio.sfx("coin")
	await get_tree().process_frame
	_finish_purchase()
