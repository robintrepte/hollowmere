class_name InventoryPanel
extends PanelContainer
## Tarkov-style grid inventory: drag/drop, rotate (R), split, quick-move (Shift-click),
## open containers (pouches, cases, chests), bind to hotbar (hover + 1-0), ship mode.

signal closed

var embedded := false

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
var _other_win: FloatingWindow
## Open bags and cases: uid -> {win: FloatingWindow, view: GridView}
var _open: Dictionary = {}
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
var _menu_at := Vector2.ZERO

const MOUSE_HELP := "Drag to move · Double-click a bag to open · R rotate · Right-click for actions · Shift-click quick move · Esc close"
const PAD_HELP := "D-pad move · A pick up / drop · X actions · B rotate · Start close"
const TOUCH_HELP := "Tap to pick up, tap again to place · Double-tap a bag to open · Hold an item for actions · Rotate turns it · X closes"

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
	if player.packs.size() > 1:
		title_row.add_child(_pack_picker())
	else:
		title_row.add_child(UITheme.label(Data.item_name(player.backpack), 12, UITheme.WOOD_DK))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(sp)
	if TouchControls.active:
		title_row.add_child(UITheme.button("Rotate", rotate_held_or_hovered))
	var sort_btn := UITheme.button("Sort", func(): player.inventory.auto_sort(); _changed())
	title_row.add_child(sort_btn)
	_pack_view = _make_view(player.inventory)
	left.add_child(_pack_view)
	left.add_child(UITheme.label("Hotbar  (pick up an item and tap a slot)" if TouchControls.active else "Hotbar  (hover an item + press 1-0, or drop it here)", 8, UITheme.MUTED))
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

	if other != null:
		_other_win = FloatingWindow.new(other_title, "inv:" + _window_kind(other))
		_other_win.top_level = true
		_other_view = _make_view(other)
		_other_win.body.add_child(_other_view)
		if other == GameState.shipping_bin:
			var hint := UITheme.label("Sells when the game day turns over. Take items back out any time before then.", 8, UITheme.MUTED)
			hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			hint.custom_minimum_size = Vector2(180, 0)
			_other_win.body.add_child(hint)
			_ship_total = UITheme.label("", 10, UITheme.WOOD_DK)
			_other_win.body.add_child(_ship_total)
			_refresh_ship()
		_other_win.closed.connect(func(): closed.emit())

	var info := PanelContainer.new()
	info.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 5, false))
	if embedded:
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		cols.add_child(info)
	else:
		main.add_child(info)
	var iv := VBoxContainer.new()
	iv.add_theme_constant_override("separation", 1)
	info.add_child(iv)
	_info_name = UITheme.label("", 11, UITheme.WOOD_DK)
	iv.add_child(_info_name)
	_info_desc = UITheme.label(_help(), 9, UITheme.INK)
	_info_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_desc.custom_minimum_size = Vector2(160 if embedded else 420, 0)
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
	if not embedded:
		_center()
	if _other_win:
		_add_window(_other_win)
	if Settings.using_pad:
		_pack_view.grab_focus()

static func _window_kind(inv: Inventory) -> String:
	if inv == GameState.shipping_bin:
		return "shipping_bin"
	if inv == GameState.farm_chest:
		return "farm_chest"
	return "chest"

## Floating windows start beside the backpack (or where the player last left that kind of window).
func _add_window(w: FloatingWindow) -> void:
	var r := _pack_view.get_global_rect() if embedded else get_global_rect()
	var n := _open.size() + (1 if _other_win and w != _other_win else 0)
	w.position = Vector2(r.end.x + 6 + n * 12, r.position.y + n * 16)
	add_child(w)

func _views() -> Array:
	var out: Array = [_pack_view]
	if _other_view:
		out.append(_other_view)
	for uid in _open:
		out.append(_open[uid].view)
	return out

func _help() -> String:
	if Settings.using_pad:
		return PAD_HELP
	return TOUCH_HELP if TouchControls.active else MOUSE_HELP

## Touch stand-in for right-click: open the actions menu for the item under the finger.
func touch_long_press(pos: Vector2) -> void:
	if _hover.is_empty() or _hover_inv == null:
		return
	_cancel_held()
	_menu_at = pos
	_open_menu(_hover_inv, _hover)

func _center() -> void:
	var s := get_combined_minimum_size()
	offset_left = -s.x / 2.0
	offset_right = s.x / 2.0
	offset_top = -s.y / 2.0 - 10
	offset_bottom = s.y / 2.0 - 10

func _pack_picker() -> OptionButton:
	var ob := OptionButton.new()
	ob.tooltip_text = tr("Switch packs")
	for i in player.packs.size():
		ob.add_item(Data.item_name(player.packs[i]))
		if player.packs[i] == player.backpack:
			ob.select(i)
	ob.item_selected.connect(func(i: int):
		if held_uid != "":
			_cancel_held()
		var r: Dictionary = await Coop.act_async("equip_backpack", [player.packs[i]])
		if not is_inside_tree():
			return
		if r.ok:
			_pack_view.setup(player.inventory, self)
			_changed()
			Audio.sfx("pickup")
		else:
			ob.select(player.packs.find(player.backpack))
			if r.reason != "":
				Audio.sfx("error")
				EventBus.toast.emit(r.reason, ""))
	return ob

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

func _on_cell(view: GridView, cell: Vector2i, button: int, shift: bool, double: bool = false) -> void:
	var e := view.inv.entry_at(cell.x, cell.y)
	if button == MOUSE_BUTTON_LEFT and double and not e.is_empty() and e.has("inv") and (held_uid == "" or held_uid == e.uid):
		if held_uid != "":
			_cancel_held()
		_open_container(e)
		return
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
			_menu_at = view.cell_screen_pos(cell) if Settings.using_pad else get_viewport().get_mouse_position()
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
		if _open.has(held_uid) and view.inv != held_from:
			_close_container(held_uid)
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
	for v in _views():
		v.queue_redraw()

## Shift-click: from the backpack into the open chest (or the last opened bag), anything else back to the backpack.
func _quick_move(inv: Inventory, e: Dictionary) -> void:
	var target: Inventory = null
	if inv == player.inventory:
		if other:
			target = other
		elif not _open.is_empty():
			target = _open[_open.keys()[-1]].view.inv
	else:
		target = player.inventory
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
		_info_desc.text = _help()
		return
	var it: Dictionary = Data.get_item(e.id)
	_info_name.text = Data.item_name(e.id, int(e.get("q", 0))) + (tr("  x%d") % int(e.n) if int(e.n) > 1 else "")
	var bits: Array = [Data.item_desc(e.id)]
	var price := GameState.sell_value(player, e.id, int(e.get("q", 0)))
	if price > 0:
		bits.append(tr("Sells for %s") % CoinLabel.text(price))
	if float(it.get("energy", 0)) > 0:
		bits.append(tr("+%d energy") % int(it.energy))
	var sz: Vector2i = Data.item_size(e.id)
	bits.append(tr("%dx%d") % [sz.x, sz.y])
	if e.has("inv"):
		bits.append(tr("Holds %dx%d%s") % [e.inv.w, e.inv.h, (" (" + ", ".join(e.inv.filter) + ")") if not e.inv.filter.is_empty() else ""])
		bits.append(tr("Double-click to open"))
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

func _refresh_ship() -> void:
	if _ship_total == null:
		return
	var total := 0
	for e in GameState.shipping_bin.entries:
		total += GameState.sell_value(GameState.local_player(), e.id, int(e.q), true) * int(e.n)
	for s in GameState.world.get("shipping", []):
		total += GameState.sell_value(GameState.local_player(), s.id, int(s.q), true) * int(s.n)
	_ship_total.text = tr("In the bin: %s") % CoinLabel.text(total)

func rotate_held_or_hovered() -> void:
	if held_uid != "":
		var sz := held_size()
		held_rot = not held_rot
		held_grab = Vector2i(clampi(held_grab.y, 0, sz.y - 1), clampi(held_grab.x, 0, sz.x - 1))
		Audio.sfx("tick", 0.0)
		for v in _views():
			v.queue_redraw()
	elif not _hover.is_empty() and _hover_inv:
		if _hover_inv.rotate(_hover.uid):
			Audio.sfx("tick", 0.0)
			_changed()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed:
		return
	if event.is_action_pressed("rotate_item"):
		rotate_held_or_hovered()
		get_viewport().set_input_as_handled()
		return
	for i in PlayerData.HOTBAR_SIZE:
		if event.is_action_pressed(tr("hotbar_%d") % i) and not _hover.is_empty():
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
		_menu.add_item(tr("Open"), 1)
	if Data.is_edible(e.id) and it.get("cat", "") != "seed":
		_menu.add_item(tr("Eat"), 2)
	if it.has("hat") and inv == player.inventory:
		_menu.add_item(tr("Wear"), 10)
	if int(e.n) > 1:
		_menu.add_item(tr("Split half"), 3)
		_menu.add_item(tr("Split one"), 4)
	if other != null:
		_menu.add_item(tr("Move to %s") % ("Backpack" if inv == other else other_title), 6)
	if inv == player.inventory or player.inventory.find(e.uid).size() > 0:
		_menu.add_item(tr("Bind to next hotbar slot"), 7)
	if not it.get("cat", "") in ["tool", "key"]:
		_menu.add_separator()
		_menu.add_item(tr("Trash"), 9)
	_menu.reset_size()
	_menu.popup(Rect2i(Vector2i(_menu_at), Vector2i.ZERO))

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
		6: _quick_move(_menu_inv, e)
		7:
			for i in PlayerData.HOTBAR_SIZE:
				if player.hotbar[i].is_empty():
					player.bind_hotbar(i, e)
					break
		9:
			_menu_inv.take(e.uid, int(e.n))
			Audio.sfx("trash")
		10:
			Coop.act("wear_hat_act", [e.uid])
	_changed()

## Bags open in their own small window; several can be open at once, nested ones too.
func _open_container(e: Dictionary) -> void:
	if _open.has(e.uid):
		_open[e.uid].win.raise()
		return
	var w := FloatingWindow.new(Data.item_name(e.id), "bag:" + str(e.id))
	w.top_level = true
	var view := _make_view(e.inv)
	w.body.add_child(view)
	var uid: String = e.uid
	w.closed.connect(func(): _open.erase(uid))
	_open[uid] = {"win": w, "view": view}
	_add_window(w)
	Audio.sfx("open", 0.1)

func _close_container(uid: String) -> void:
	if _open.has(uid):
		var w: FloatingWindow = _open[uid].win
		_open.erase(uid)
		if is_instance_valid(w):
			w.close()

# --- Misc ------------------------------------------------------------------------------------

func _changed() -> void:
	EventBus.inventory_changed.emit()
	_refresh_ship()
	_refresh_hotbar()
	for uid in _open.keys():
		var f := player.inventory.find(uid)
		if f.is_empty() and (other == null or other.find(uid).is_empty()):
			_close_container(uid)
	for v in _views():
		v.queue_redraw()

func _refresh_hotbar() -> void:
	for i in _hotbar.size():
		var e := player.hotbar_entry(i)
		var s: ItemSlot = _hotbar[i]
		s.glint = not e.is_empty() and Enchanting.has_any(player, e.id)
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
	if held_uid == "" or Settings.using_pad:
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
