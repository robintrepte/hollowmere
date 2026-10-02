class_name InventoryPanel
extends PanelContainer
## Tarkov-style grid inventory: drag/drop, rotate (R), split, quick-move (Shift-click),
## open containers (pouches, cases, chests), bind to hotbar (hover + 1-0), ship mode.

signal closed

var player: PlayerData
var other: Inventory          # chest / farm chest
var other_title := ""
var mode := "pack"            # pack | chest | ship
var on_close: Callable

var held_uid := ""
var held_from: Inventory
var held_rot := false
var held_grab := Vector2i.ZERO
var held_id := ""

var _pack_view: GridView
var _other_view: GridView
var _container_view: GridView
var _container_uid := ""
var _right: VBoxContainer
var _container_box: VBoxContainer
var _info_name: Label
var _info_desc: Label
var _hotbar: Array = []
var _hover: Dictionary = {}
var _hover_inv: Inventory
var _ghost: Control
var _ship_total: Label
var _menu: PopupMenu
var _menu_entry: Dictionary = {}
var _menu_inv: Inventory

func _init(p: PlayerData = null, other_inv: Inventory = null, title: String = "", m: String = "pack") -> void:
	player = p
	other = other_inv
	other_title = title
	mode = m if other_inv != null or m == "ship" else "pack"

func blocks_escape() -> bool:
	if held_uid != "":
		_cancel_held()
		return true
	return false

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation", 6)
	add_child(main)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	main.add_child(cols)

	var left := VBoxContainer.new()
	cols.add_child(left)
	var title_row := HBoxContainer.new()
	left.add_child(title_row)
	title_row.add_child(UITheme.label("Backpack", 12, UITheme.WOOD_DK))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(sp)
	var sort_btn := UITheme.button("Sort", func(): player.inventory.auto_sort(); _changed())
	title_row.add_child(sort_btn)
	_pack_view = _make_view(player.inventory)
	left.add_child(_pack_view)
	left.add_child(UITheme.label("Hotbar  (hover an item + press 1-0, or drop it here)", 8, UITheme.MUTED))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 1)
	left.add_child(hb)
	for i in PlayerData.HOTBAR_SIZE:
		var s := ItemSlot.new()
		s.custom_minimum_size = Vector2(24, 24)
		s.hint = str((i + 1) % 10)
		s.gui_input.connect(_on_hotbar_input.bind(i))
		hb.add_child(s)
		_hotbar.append(s)

	_right = VBoxContainer.new()
	_right.add_theme_constant_override("separation", 4)
	cols.add_child(_right)
	if other != null:
		_right.add_child(UITheme.label(other_title, 12, UITheme.WOOD_DK))
		_other_view = _make_view(other)
		_right.add_child(_other_view)
	elif mode == "ship":
		_right.add_child(UITheme.label("Shipping Bin", 12, UITheme.WOOD_DK))
		var drop := PanelContainer.new()
		drop.add_theme_stylebox_override("panel", UITheme.box(Color("#c8a070"), UITheme.OUTLINE, 2, 4, 8, false))
		drop.custom_minimum_size = Vector2(180, 110)
		drop.gui_input.connect(_on_ship_input)
		var dv := VBoxContainer.new()
		dv.alignment = BoxContainer.ALIGNMENT_CENTER
		drop.add_child(dv)
		dv.add_child(UITheme.icon_rect(Art.world("shipping_bin"), 48))
		var dl := UITheme.label("Drop items here.\nThey sell overnight.", 9, UITheme.INK)
		dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		dv.add_child(dl)
		_right.add_child(drop)
		_ship_total = UITheme.label("", 10, UITheme.WOOD_DK)
		_right.add_child(_ship_total)
		_refresh_ship()
	_container_box = VBoxContainer.new()
	_right.add_child(_container_box)

	var info := PanelContainer.new()
	info.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 5, false))
	main.add_child(info)
	var iv := VBoxContainer.new()
	iv.add_theme_constant_override("separation", 1)
	info.add_child(iv)
	_info_name = UITheme.label("", 11, UITheme.WOOD_DK)
	iv.add_child(_info_name)
	_info_desc = UITheme.label("Drag to move · R rotate · Right-click for actions · Shift-click quick move · Esc close", 9, UITheme.INK)
	_info_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_desc.custom_minimum_size = Vector2(420, 0)
	iv.add_child(_info_desc)

	_ghost = Control.new()
	_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost.top_level = true
	_ghost.z_index = 100
	_ghost.draw.connect(_draw_ghost)
	add_child(_ghost)
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	_refresh_hotbar()
	await get_tree().process_frame
	_center()

func _center() -> void:
	var s := get_combined_minimum_size()
	offset_left = -s.x / 2.0
	offset_right = s.x / 2.0
	offset_top = -s.y / 2.0 - 10
	offset_bottom = s.y / 2.0 - 10

func _make_view(i: Inventory) -> GridView:
	var v := GridView.new()
	v.setup(i, self)
	v.cell_pressed.connect(_on_cell)
	v.hover_changed.connect(_on_hover)
	return v

func held_size() -> Vector2i:
	return Inventory.size_of(held_id, held_rot)

func can_drop(view: GridView, origin: Vector2i) -> bool:
	if held_uid == "":
		return false
	if not view.inv.accepts(held_id):
		return false
	var at := view.inv.entry_at(view.hover_cell.x, view.hover_cell.y)
	if not at.is_empty() and at.uid != held_uid:
		if at.id == held_id and Data.stack_max(held_id) > int(at.n):
			return true
		if at.has("inv") and at.inv.accepts(held_id) and Data.container_spec(held_id).is_empty():
			return true
		return false
	return view.inv.can_place(held_size(), origin.x, origin.y, held_uid)

# --- Input ---------------------------------------------------------------------------------

func _on_cell(view: GridView, cell: Vector2i, button: int, shift: bool) -> void:
	var e := view.inv.entry_at(cell.x, cell.y)
	if button == MOUSE_BUTTON_LEFT:
		if held_uid != "":
			_drop(view, cell)
		elif not e.is_empty():
			if shift:
				_quick_move(view.inv, e)
			else:
				_pick(view.inv, e, cell)
	elif button == MOUSE_BUTTON_RIGHT:
		if held_uid != "":
			_cancel_held()
		elif not e.is_empty():
			_open_menu(view.inv, e)

func _pick(inv: Inventory, e: Dictionary, cell: Vector2i) -> void:
	held_uid = e.uid
	held_from = inv
	held_rot = bool(e.r)
	held_id = e.id
	held_grab = cell - Vector2i(int(e.x), int(e.y))
	Audio.sfx("pickup", 0.1)
	_ghost.queue_redraw()

func _drop(view: GridView, cell: Vector2i) -> void:
	var origin := cell - held_grab
	var at := view.inv.entry_at(cell.x, cell.y)
	var ok := false
	if not at.is_empty() and at.uid != held_uid:
		ok = view.inv.move_from(held_from, held_uid, cell.x, cell.y, held_rot)
	else:
		ok = view.inv.move_from(held_from, held_uid, origin.x, origin.y, held_rot)
	if ok:
		Audio.sfx("place", 0.1)
		if held_uid == _container_uid and view.inv != player.inventory:
			_close_container()
		_clear_held()
		_changed()
	else:
		Audio.sfx("error", 0.0)

func _cancel_held() -> void:
	_clear_held()

func _clear_held() -> void:
	held_uid = ""
	held_from = null
	held_id = ""
	_ghost.queue_redraw()
	for v in [_pack_view, _other_view, _container_view]:
		if v:
			v.queue_redraw()

func _quick_move(inv: Inventory, e: Dictionary) -> void:
	var target: Inventory = null
	if inv == player.inventory or (inv != other and _container_view and inv == _container_view.inv):
		target = other if other else (_container_view.inv if _container_view and inv == player.inventory else null)
		if inv != player.inventory:
			target = player.inventory
	else:
		target = player.inventory
	if mode == "ship" and inv != other:
		_ship_entry(e)
		return
	if target == null or not target.accepts(e.id):
		Audio.sfx("error", 0.0)
		return
	var item := inv.take(e.uid, int(e.n))
	var left := target.add(item.id, int(item.n), int(item.q), item.meta)
	if left > 0:
		inv.add(item.id, left, int(item.q), item.meta)
	Audio.sfx("place", 0.1)
	_changed()

func _on_hover(view: GridView, e: Dictionary) -> void:
	_hover = e
	_hover_inv = view.inv
	if e.is_empty():
		_info_name.text = ""
		_info_desc.text = "Drag to move · R rotate · Right-click for actions · Shift-click quick move · Esc close"
		return
	var it: Dictionary = Data.get_item(e.id)
	_info_name.text = Data.item_name(e.id, int(e.get("q", 0))) + ("  x%d" % int(e.n) if int(e.n) > 1 else "")
	var bits: Array = [str(it.get("desc", ""))]
	var price := Data.sell_price(e.id, int(e.get("q", 0)))
	if price > 0:
		bits.append("Sells %dg" % price)
	if float(it.get("energy", 0)) > 0:
		bits.append("+%d energy" % int(it.energy))
	var sz: Vector2i = Data.item_size(e.id)
	bits.append("%dx%d" % [sz.x, sz.y])
	if e.has("inv"):
		bits.append("Holds %dx%d%s" % [e.inv.w, e.inv.h, (" (" + ", ".join(e.inv.filter) + ")") if not e.inv.filter.is_empty() else ""])
	_info_desc.text = " · ".join(bits.filter(func(b): return b != ""))

func _on_hotbar_input(ev: InputEvent, i: int) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_LEFT and held_uid != "":
			var f := player.inventory.find(held_uid)
			if not f.is_empty():
				player.bind_hotbar(i, f.entry)
				_clear_held()
				_refresh_hotbar()
		elif ev.button_index == MOUSE_BUTTON_RIGHT:
			player.hotbar[i] = {}
			_refresh_hotbar()
		accept_event()

func _on_ship_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and held_uid != "":
		var f := player.inventory.find(held_uid)
		if not f.is_empty():
			_ship_entry(f.entry)
		_clear_held()

func _ship_entry(e: Dictionary) -> void:
	var r: Dictionary = Coop.act("ship", [e.uid, -1])
	if r.ok:
		Audio.sfx("ship")
		_changed()
		_refresh_ship()
	elif r.reason != "":
		EventBus.toast.emit(r.reason, "")

func _refresh_ship() -> void:
	if _ship_total == null:
		return
	var total := 0
	for s in GameState.world.get("shipping", []):
		total += Data.sell_price(s.id, int(s.q)) * int(s.n)
	_ship_total.text = "In the bin: %dg" % total

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed:
		return
	if event.is_action_pressed("rotate_item"):
		if held_uid != "":
			var sz := held_size()
			held_rot = not held_rot
			held_grab = Vector2i(clampi(held_grab.y, 0, sz.y - 1), clampi(held_grab.x, 0, sz.x - 1))
			Audio.sfx("tick", 0.0)
		elif not _hover.is_empty() and _hover_inv:
			if _hover_inv.rotate(_hover.uid):
				Audio.sfx("tick", 0.0)
				_changed()
		get_viewport().set_input_as_handled()
		return
	for i in PlayerData.HOTBAR_SIZE:
		if event.is_action_pressed("hotbar_%d" % i) and not _hover.is_empty():
			var f := player.inventory.find(_hover.uid)
			if not f.is_empty():
				player.bind_hotbar(i, f.entry)
				Audio.sfx("tick", 0.0)
				_refresh_hotbar()
			get_viewport().set_input_as_handled()
			return

# --- Context menu ---------------------------------------------------------------------------

func _open_menu(inv: Inventory, e: Dictionary) -> void:
	_menu.clear()
	_menu_entry = e
	_menu_inv = inv
	var it: Dictionary = Data.get_item(e.id)
	if e.has("inv"):
		_menu.add_item("Open", 1)
	if Data.is_edible(e.id) and it.get("cat", "") != "seed":
		_menu.add_item("Eat", 2)
	if int(e.n) > 1:
		_menu.add_item("Split half", 3)
		_menu.add_item("Split one", 4)
	if mode == "ship" and Data.sell_price(e.id, 0) > 0 and inv != other:
		_menu.add_item("Ship (%dg)" % (Data.sell_price(e.id, int(e.q)) * int(e.n)), 5)
	if other != null:
		_menu.add_item("Move to %s" % ("Backpack" if inv == other else other_title), 6)
	if inv == player.inventory or player.inventory.find(e.uid).size() > 0:
		_menu.add_item("Bind to next hotbar slot", 7)
	if not it.get("cat", "") in ["tool", "key"]:
		_menu.add_separator()
		_menu.add_item("Trash", 9)
	_menu.reset_size()
	_menu.popup(Rect2i(Vector2i(get_viewport().get_mouse_position()), Vector2i.ZERO))

func _on_menu(id: int) -> void:
	var e := _menu_entry
	match id:
		1: _open_container(e)
		2:
			var r: Dictionary = Coop.act("eat", [e.uid])
			if r.ok:
				Audio.sfx("eat")
		3: _menu_inv.split(e.uid, int(e.n) / 2)
		4: _menu_inv.split(e.uid, 1)
		5: _ship_entry(e)
		6: _quick_move(_menu_inv, e)
		7:
			for i in PlayerData.HOTBAR_SIZE:
				if player.hotbar[i].is_empty():
					player.bind_hotbar(i, e)
					break
		9:
			_menu_inv.take(e.uid, int(e.n))
			Audio.sfx("trash")
	_changed()

func _open_container(e: Dictionary) -> void:
	_close_container()
	_container_uid = e.uid
	_container_box.add_child(UITheme.label(Data.item_name(e.id), 11, UITheme.WOOD_DK))
	_container_view = _make_view(e.inv)
	_container_box.add_child(_container_view)
	_container_box.add_child(UITheme.button("Close %s" % Data.item_name(e.id), _close_container))
	await get_tree().process_frame
	_center()

func _close_container() -> void:
	for c in _container_box.get_children():
		c.queue_free()
	_container_view = null
	_container_uid = ""
	await get_tree().process_frame
	if is_inside_tree():
		reset_size()
		_center()

# --- Misc ------------------------------------------------------------------------------------

func _changed() -> void:
	EventBus.inventory_changed.emit()
	_refresh_hotbar()
	for v in [_pack_view, _other_view, _container_view]:
		if v:
			v.queue_redraw()

func _refresh_hotbar() -> void:
	for i in _hotbar.size():
		var e := player.hotbar_entry(i)
		var s: ItemSlot = _hotbar[i]
		if e.is_empty():
			s.set_item("", 0, 0)
		else:
			s.set_item(e.id, player.inventory.count(e.id) if Data.stack_max(e.id) > 1 else 1, 0)
		s.selected = i == player.selected
	EventBus.hotbar_changed.emit()

func _process(_d: float) -> void:
	if held_uid != "":
		_ghost.queue_redraw()

func _draw_ghost() -> void:
	if held_uid == "":
		return
	var f := held_from.find(held_uid) if held_from else {}
	if f.is_empty():
		return
	var e: Dictionary = f.entry.duplicate()
	e.r = held_rot
	var sz := held_size()
	var mp := _ghost.get_global_mouse_position()
	var r := Rect2(mp - Vector2(held_grab) * GridView.CELL - Vector2(GridView.CELL / 2.0, GridView.CELL / 2.0), Vector2(sz) * GridView.CELL)
	_ghost.draw_rect(r, Color(1, 1, 1, 0.25))
	GridView.draw_item(_ghost, e, r, 0.9)

func _exit_tree() -> void:
	if on_close.is_valid():
		on_close.call()
	closed.emit()
