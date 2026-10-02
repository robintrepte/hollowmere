class_name ShopPanel
extends PanelContainer
## Buy list (seasonal, gated by unlocks) + sell list from the backpack.

signal closed

var shop_id := ""
var _list: VBoxContainer
var _sell_list: VBoxContainer
var _money: Label
var _tab := "buy"
var _tabs: HBoxContainer

func _init(id: String = "") -> void:
	shop_id = id

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -190
	offset_right = 190
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
	mrow.add_child(UITheme.icon_rect(Art.item("_coin"), 16))
	_money = UITheme.label("", 11, UITheme.WOOD_DK)
	mrow.add_child(_money)
	head.add_child(UITheme.button("Close", func(): closed.emit()))
	_tabs = HBoxContainer.new()
	v.add_child(_tabs)
	_tabs.add_child(UITheme.button("Buy", func(): _tab = "buy"; _refresh()))
	_tabs.add_child(UITheme.button("Sell", func(): _tab = "sell"; _refresh()))
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
		_money.text = str(GameState.money())

func _refresh() -> void:
	_refresh_money()
	for c in _list.get_children():
		c.queue_free()
	if _tab == "buy":
		var stock := Economy.shop_stock(shop_id, GameState.season(), GameState.ctx(), GameState.day(), int(GameState.world.seed))
		if stock.is_empty():
			_list.add_child(UITheme.label("Sold out for today.", 10, UITheme.MUTED))
		for s in stock:
			_list.add_child(_row(s.id, int(s.price), bool(s.locked), str(s.get("req", "")), true))
	else:
		var p := GameState.local_player()
		var seen := {}
		for e in p.inventory.all_entries():
			if Data.sell_price(e.id, int(e.q)) <= 0 or Data.get_item(e.id).get("cat", "") in ["tool", "key", "container"]:
				continue
			var key: String = "%s:%d" % [e.id, int(e.q)]
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
	var d := UITheme.label(Economy.req_text(req) if locked else str(Data.get_item(id).get("desc", "")), 8, UITheme.MUTED)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(180, 0)
	nv.add_child(d)
	var b := UITheme.button("%dg" % price)
	b.disabled = locked or GameState.money() < price
	b.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and not b.disabled:
			_buy(id, 5 if ev.shift_pressed else 1)
			b.accept_event())
	h.add_child(b)
	pc.tooltip_text = Data.item_name(id)
	return pc

func _sell_row(e: Dictionary) -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 3, false))
	var h := HBoxContainer.new()
	pc.add_child(h)
	h.add_child(UITheme.icon_rect(Art.item(e.id), 32))
	var n := UITheme.label("%s  x%d" % [Data.item_name(e.id, int(e.q)), int(e.n)], 10)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(n)
	var price := Data.sell_price(e.id, int(e.q))
	h.add_child(UITheme.button("Sell 1 (%dg)" % price, func(): _sell(e.uid, 1)))
	if int(e.n) > 1:
		h.add_child(UITheme.button("All", func(): _sell(e.uid, -1)))
	return pc

func _buy(id: String, n: int) -> void:
	var r: Dictionary = Coop.act("buy", [shop_id, id, n])
	if r.ok:
		Audio.sfx("coin")
		EventBus.toast.emit("Bought %d %s" % [n, Data.item_name(id)], "")
	elif r.reason != "":
		Audio.sfx("error")
		EventBus.toast.emit(r.reason, "")
	await get_tree().process_frame
	_refresh()

func _sell(uid: String, n: int) -> void:
	var r: Dictionary = Coop.act("sell", [uid, n])
	if r.ok:
		Audio.sfx("coin")
	await get_tree().process_frame
	_refresh()
