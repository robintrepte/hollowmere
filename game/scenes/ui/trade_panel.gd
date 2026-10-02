class_name TradePanel
extends PanelContainer
## Two-sided trade. Each player puts up items and/or Wildlings, both press Ready,
## and the host swaps everything at once. Any change clears both Ready marks.

signal closed

var state: Dictionary
var tid: int
var _offer: Array = []          # [{kind, uid, n}]
var _mine: VBoxContainer
var _theirs: VBoxContainer
var _their_title: Label
var _ready_btn: Button
var _their_ready: Label
var _my_ready: Label
var _status: Label
var _picker: PanelContainer

func _init(s: Dictionary = {}) -> void:
	state = s
	tid = int(s.get("tid", -1))

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -220
	offset_right = 220
	offset_top = -140
	offset_bottom = 140
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	add_child(v)
	v.add_child(UITheme.label("Trade", 13, UITheme.WOOD_DK))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 10)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(cols)
	var left := _column(cols, "You offer")
	_mine = left[1]
	_my_ready = UITheme.label("", 10, UITheme.LEAF)
	left[0].add_child(_my_ready)
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 4)
	left[0].add_child(add_row)
	add_row.add_child(UITheme.button("+ Item", _pick_item))
	add_row.add_child(UITheme.button("+ Wildling", _pick_creature))
	add_row.add_child(UITheme.button("Clear", func():
		_offer.clear()
		_push()))
	var right := _column(cols, "")
	_their_title = right[0].get_child(0)
	_theirs = right[1]
	_their_ready = UITheme.label("", 10, UITheme.LEAF)
	right[0].add_child(_their_ready)
	_status = UITheme.label("", 9, UITheme.HEART)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(420, 0)
	v.add_child(_status)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 6)
	v.add_child(bottom)
	_ready_btn = UITheme.button("Ready", func(): Coop.trade_op("ready", {"tid": tid, "on": not _am_ready()}))
	bottom.add_child(_ready_btn)
	bottom.add_child(UITheme.button("Cancel trade", func(): Coop.trade_op("cancel", {"tid": tid})))
	Coop.trade_updated.connect(_on_state)
	tree_exiting.connect(func():
		if not str(state.get("status", "")) in ["done", "closed"]:
			Coop.trade_op("cancel", {"tid": tid}))
	_render()

func _column(parent: Control, title: String) -> Array:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, UITheme.WOOD, 1, 3, 6, false))
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	box.add_child(v)
	v.add_child(UITheme.label(title, 10, UITheme.WOOD_DK))
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size = Vector2(190, 120)
	v.add_child(list)
	return [v, list]

func _me() -> String:
	return Net.local_id()

func _other() -> String:
	return str(state.b) if str(state.a) == _me() else str(state.a)

func _am_ready() -> bool:
	return bool(state.get("ok", {}).get(_me(), false))

func _on_state(s: Dictionary) -> void:
	if int(s.get("tid", -2)) != tid:
		return
	state = s
	_offer = (s.get("offer", {}).get(_me(), []) as Array).duplicate(true)
	match str(s.status):
		"done":
			Audio.sfx("coin")
			EventBus.toast.emit("Trade complete!", "gift")
			closed.emit()
			return
		"closed":
			if str(s.get("msg", "")) != "":
				EventBus.toast.emit(str(s.msg), "")
			closed.emit()
			return
	_render()

func _render() -> void:
	var other_name: String = str(state.get("b_name" if str(state.get("a", "")) == _me() else "a_name", "Friend"))
	_their_title.text = "%s offers" % other_name
	var views: Dictionary = state.get("views", {})
	_fill(_mine, views.get(_me(), []), "Nothing yet. Add items or Wildlings.")
	var waiting := str(state.get("status", "")) == "invite"
	_fill(_theirs, views.get(_other(), []), ("Waiting for %s to accept..." % other_name) if waiting else "Nothing yet.")
	var they_ok := bool(state.get("ok", {}).get(_other(), false))
	_their_ready.text = "✓ Ready" if they_ok else ""
	_my_ready.text = "✓ Ready" if _am_ready() else ""
	_ready_btn.text = "Not ready" if _am_ready() else "Ready"
	_ready_btn.disabled = waiting
	_status.text = str(state.get("msg", ""))

func _fill(list: VBoxContainer, lines: Array, empty_text: String) -> void:
	for c in list.get_children():
		c.queue_free()
	if lines.is_empty():
		list.add_child(UITheme.label(empty_text, 9, UITheme.MUTED))
	for l: Dictionary in lines:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		list.add_child(h)
		var tex := Art.item(str(l.id)) if l.icon == "item" else Art.creature(str(l.id), true)
		h.add_child(UITheme.icon_rect(tex, 16))
		h.add_child(UITheme.label(str(l.text), 9, UITheme.INK))

func _push() -> void:
	Coop.trade_op("offer", {"tid": tid, "offer": _offer})

func _offered(uid: String) -> int:
	for o: Dictionary in _offer:
		if o.uid == uid:
			return int(o.get("n", 1))
	return 0

# --- Pickers -------------------------------------------------------------------------------------

func _open_picker(title: String) -> VBoxContainer:
	_close_picker()
	_picker = PanelContainer.new()
	_picker.add_theme_stylebox_override("panel", UITheme.parchment(8))
	_picker.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_picker.offset_left = -150
	_picker.offset_right = 150
	_picker.offset_top = -120
	_picker.offset_bottom = 120
	add_child(_picker)
	var v := VBoxContainer.new()
	_picker.add_child(v)
	v.add_child(UITheme.label(title, 11, UITheme.WOOD_DK))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	v.add_child(UITheme.button("Back", _close_picker))
	return list

func _close_picker() -> void:
	if is_instance_valid(_picker):
		_picker.queue_free()
	_picker = null

func _pick_item() -> void:
	var list := _open_picker("Offer an item")
	var p := GameState.local_player()
	for e: Dictionary in p.inventory.all_entries():
		if Data.get_item(str(e.id)).get("cat", "") == "tool":
			continue
		var left := int(e.n) - _offered(str(e.uid))
		if left <= 0:
			continue
		var h := HBoxContainer.new()
		list.add_child(h)
		h.add_child(UITheme.icon_rect(Art.item(str(e.id)), 16))
		var l := UITheme.label("%s x%d" % [Data.item_name(str(e.id)), left], 9, UITheme.INK)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		var uid: String = e.uid
		h.add_child(UITheme.button("1", func(): _add_item(uid, 1)))
		if left > 1:
			h.add_child(UITheme.button("All", func(): _add_item(uid, left)))

func _add_item(uid: String, n: int) -> void:
	for o: Dictionary in _offer:
		if o.uid == uid:
			o.n = int(o.n) + n
			_close_picker()
			_push()
			return
	_offer.append({"kind": "item", "uid": uid, "n": n})
	_close_picker()
	_push()

func _pick_creature() -> void:
	var list := _open_picker("Offer a Wildling")
	var p := GameState.local_player()
	for c: Creature in p.party:
		if _offered(c.uid) > 0:
			continue
		var h := HBoxContainer.new()
		list.add_child(h)
		h.add_child(UITheme.icon_rect(Art.creature(c.species_id, true), 24))
		var uid := c.uid
		var b := UITheme.button("%s  Lv%d" % [c.display_name(), c.level], func():
			_offer.append({"kind": "creature", "uid": uid})
			_close_picker()
			_push())
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		h.add_child(b)
	if p.party.size() <= 1:
		list.add_child(UITheme.label("You need to keep at least one Wildling with you.", 9, UITheme.MUTED))
