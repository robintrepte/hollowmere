class_name GridView
extends Control
## Draws an Inventory as a Tarkov-style grid. Items span WxH cells and can be rotated.
## The owning InventoryPanel handles drag state; this view reports hover + clicks.

signal cell_pressed(view: GridView, cell: Vector2i, button: int, shift: bool, double: bool)
signal hover_changed(view: GridView, entry: Dictionary)

const CELL := 26
const CAT_TINT := {
	"tool": Color("#b0b8c8"), "seed": Color("#d8c890"), "crop": Color("#b8d898"), "fruit": Color("#e8b0a0"),
	"container": Color("#c8a878"), "treat": Color("#f0c0d0"), "candy": Color("#f0a0c8"), "charm": Color("#d0b8f0"), "food": Color("#f0d0a0"),
	"medicine": Color("#f0b0b0"), "artisan": Color("#e0c0e8"), "gem": Color("#b8e0f0"), "ore": Color("#c0c0c8"),
	"bar": Color("#f0e0a0"), "placeable": Color("#d8c0a0"), "material": Color("#d0c0a8"),
}

var inv: Inventory
var panel: Node
var hover_cell := Vector2i(-1, -1)
var highlight_uid := ""

func setup(i: Inventory, owner_panel: Node) -> void:
	inv = i
	panel = owner_panel
	custom_minimum_size = Vector2(inv.w * CELL + 2, inv.h * CELL + 2)
	size = custom_minimum_size
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	if not inv.changed.is_connected(queue_redraw):
		inv.changed.connect(queue_redraw)
	queue_redraw()

func cell_at(local_pos: Vector2) -> Vector2i:
	return Vector2i(floori((local_pos.x - 1) / CELL), floori((local_pos.y - 1) / CELL))

## Screen position of a cell's top-right corner (where a gamepad's action menu opens).
func cell_screen_pos(c: Vector2i) -> Vector2:
	return get_global_transform_with_canvas() * Vector2(1 + (c.x + 1) * CELL, 1 + c.y * CELL)

func _set_hover(c: Vector2i) -> void:
	if c == hover_cell:
		return
	hover_cell = c
	hover_changed.emit(self, inv.entry_at(c.x, c.y) if c.x >= 0 else {})
	queue_redraw()

const PAD_DIRS := {"ui_left": [Vector2i(-1, 0), SIDE_LEFT], "ui_right": [Vector2i(1, 0), SIDE_RIGHT],
	"ui_up": [Vector2i(0, -1), SIDE_TOP], "ui_down": [Vector2i(0, 1), SIDE_BOTTOM]}

func _gui_input(event: InputEvent) -> void:
	if inv == null:
		return
	if event is InputEventMouseMotion:
		_set_hover(cell_at(event.position))
	elif event is InputEventMouseButton and event.pressed:
		_set_hover(cell_at(event.position))
		var double_click := false
		if event is InputEventMouseButton:
			double_click = (event as InputEventMouseButton).double_click
		cell_pressed.emit(self, cell_at(event.position), event.button_index, event.shift_pressed, double_click)
		accept_event()
	elif has_focus():
		_pad_input(event)

## Keyboard/gamepad cursor: arrows or d-pad move (and hop to the next grid at an edge),
## accept picks up / drops, X (use_tool) opens the actions menu, rotate_item rotates.
func _pad_input(event: InputEvent) -> void:
	var c := hover_cell if hover_cell.x >= 0 else Vector2i.ZERO
	for a in PAD_DIRS:
		if event.is_action_pressed(a, true):
			var n: Vector2i = c + PAD_DIRS[a][0]
			if n.x < 0 or n.y < 0 or n.x >= inv.w or n.y >= inv.h:
				var next := find_valid_focus_neighbor(PAD_DIRS[a][1])
				if next:
					next.grab_focus()
			else:
				_set_hover(n)
			accept_event()
			return
	if event.is_action_pressed("ui_accept"):
		cell_pressed.emit(self, c, MOUSE_BUTTON_LEFT, false, false)
	elif event.is_action_pressed("use_tool"):
		cell_pressed.emit(self, c, MOUSE_BUTTON_RIGHT, false, false)
	elif event.is_action_pressed("rotate_item") and panel and panel.has_method("rotate_held_or_hovered"):
		panel.rotate_held_or_hovered()
	else:
		return
	accept_event()

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and not has_focus():
		_set_hover(Vector2i(-1, -1))
	elif what == NOTIFICATION_FOCUS_ENTER:
		if hover_cell.x < 0:
			_set_hover(Vector2i.ZERO)
		queue_redraw()
	elif what == NOTIFICATION_FOCUS_EXIT:
		_set_hover(Vector2i(-1, -1))

func _process(_d: float) -> void:
	if panel and panel.get("held_uid") != "":
		queue_redraw()

func _draw() -> void:
	if inv == null:
		return
	draw_rect(Rect2(Vector2.ZERO, custom_minimum_size), Color("#5e3a24"))
	for y in inv.h:
		for x in inv.w:
			var r := Rect2(1 + x * CELL, 1 + y * CELL, CELL - 1, CELL - 1)
			draw_rect(r, Color("#d9c08e") if (x + y) % 2 == 0 else Color("#d2b886"))
	var held: String = panel.get("held_uid") if panel else ""
	for e in inv.entries:
		var sz := Inventory.entry_size(e)
		var r := Rect2(1 + int(e.x) * CELL, 1 + int(e.y) * CELL, sz.x * CELL - 1, sz.y * CELL - 1)
		var is_held: bool = e.uid == held
		if not e.has("inv"):
			var cat: String = Data.get_item(e.id).get("cat", "")
			var tint: Color = CAT_TINT.get(cat, Color("#e8d4a8"))
			draw_rect(r, tint.darkened(0.05) if not is_held else tint.darkened(0.35))
			draw_rect(r, Color("#7a5a3a"), false, 1.0)
		if e.uid == highlight_uid:
			draw_rect(r.grow(-1), Color("#ffd447"), false, 2.0)
		draw_item(self, e, r, 0.4 if is_held else 1.0)
	# Drop preview
	if panel and held != "" and hover_cell.x >= 0:
		var hs: Vector2i = panel.held_size()
		var origin: Vector2i = hover_cell - panel.get("held_grab")
		var ok: bool = panel.can_drop(self, origin)
		var pr := Rect2(1 + origin.x * CELL, 1 + origin.y * CELL, hs.x * CELL - 1, hs.y * CELL - 1)
		draw_rect(pr, Color(0.4, 1, 0.4, 0.3) if ok else Color(1, 0.3, 0.3, 0.3))
		draw_rect(pr, Color(0.4, 1, 0.4, 0.9) if ok else Color(1, 0.3, 0.3, 0.9), false, 1.0)
	elif hover_cell.x >= 0 and hover_cell.x < inv.w and hover_cell.y < inv.h:
		var e2 := inv.entry_at(hover_cell.x, hover_cell.y)
		if not e2.is_empty():
			var sz2 := Inventory.entry_size(e2)
			draw_rect(Rect2(1 + int(e2.x) * CELL, 1 + int(e2.y) * CELL, sz2.x * CELL - 1, sz2.y * CELL - 1), Color(1, 1, 1, 0.9), false, 1.0)
	if has_focus() and hover_cell.x >= 0:
		draw_rect(Rect2(1 + hover_cell.x * CELL, 1 + hover_cell.y * CELL, CELL - 1, CELL - 1), Color("#ffd447"), false, 2.0)

static func draw_container_plate(ci: CanvasItem, r: Rect2, alpha: float) -> void:
	ci.draw_rect(r, Color(Color("#8d5a32"), alpha))
	ci.draw_rect(r, Color(Color("#f0c14a"), alpha), false, 2.0)
	var pocket := Rect2(r.position + Vector2(3, 5), r.size - Vector2(6, 8))
	if pocket.size.x > 2.0 and pocket.size.y > 2.0:
		ci.draw_rect(pocket, Color(Color("#c4894a"), alpha))
		ci.draw_rect(pocket, Color(Color("#5c3218"), alpha), false, 1.0)
	ci.draw_rect(Rect2(r.position + Vector2(2, 2), Vector2(r.size.x - 4, 3)), Color(Color("#e8b03a"), alpha))

static func draw_item(ci: CanvasItem, e: Dictionary, r: Rect2, alpha: float = 1.0) -> void:
	var bag := e.has("inv")
	if bag:
		draw_container_plate(ci, r, alpha)
	var tex := Art.item(e.id)
	var rotated := bool(e.get("r", false))
	if tex:
		var base: Vector2i = Data.item_size(e.id)
		var scale := 1.0 if bag else (3.0 if base.x >= 2 and base.y >= 2 else 1.5)
		if bag and base.x >= 2 and base.y >= 2:
			scale = 2.0
		var isz := Vector2(16, 16) * scale
		var c := r.position + r.size / 2.0 + (Vector2(0, 1) if bag else Vector2.ZERO)
		if rotated:
			ci.draw_set_transform(c, PI / 2.0, Vector2.ONE)
			ci.draw_texture_rect(tex, Rect2(-isz / 2.0, isz), false, Color(1, 1, 1, alpha))
			ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			ci.draw_texture_rect(tex, Rect2((c - isz / 2.0).floor(), isz), false, Color(1, 1, 1, alpha))
		var me := GameState.local_player()
		if me and Enchanting.has_any(me, str(e.id)):
			ci.draw_rect(r.grow(-1), Color(0.78, 0.5, 1.0, 0.9 * alpha), false, 1.0)
			ci.draw_texture_rect(tex, Rect2((c - isz / 2.0).floor(), isz), false, Color(0.75, 0.45, 1.0, 0.25 * alpha))
	var f := UITheme.font()
	if int(e.n) > 1:
		var t := str(e.n)
		var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
		var p := r.position + Vector2(r.size.x - w - 2, r.size.y - 2)
		for o in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
			ci.draw_string(f, p + o, t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UITheme.OUTLINE)
		ci.draw_string(f, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UITheme.CREAM)
	var q := int(e.get("q", 0))
	if q > 0:
		ItemSlot.draw_quality(ci, r.position + Vector2(2, r.size.y - 6), q)
	if e.has("inv"):
		var used: int = e.inv.used_cells()
		var cap: int = e.inv.w * e.inv.h
		var bar := Rect2(r.position + Vector2(3, r.size.y - 5), Vector2(r.size.x - 6, 3))
		ci.draw_rect(bar, Color(0, 0, 0, 0.45 * alpha))
		ci.draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(used) / maxf(1.0, cap), bar.size.y)), Color(Color("#8fe36b"), alpha))
		if r.size.x >= CELL * 2.0:
			var label := "%dx%d" % [e.inv.w, e.inv.h]
			ci.draw_string(f, r.position + Vector2(3, 12), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(Color("#3a2414"), alpha))
