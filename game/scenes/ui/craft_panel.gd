class_name CraftPanel
extends PanelContainer
## Crafting (anywhere) and cooking (farmhouse kitchen). Uses your pack, plus the farm chest at home.

signal closed

## Shown as a tab inside the MenuShell: no frame and no close button of its own.
var embedded := false

var kind := "crafting"
var player: PlayerData
var _sel := ""
var _list: VBoxContainer
var _detail: VBoxContainer

func _init(p: PlayerData = null, k: String = "crafting") -> void:
	player = p
	kind = k

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -250
	offset_right = 250
	offset_top = -150
	offset_bottom = 140
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := UITheme.label("Cooking" if kind == "cooking" else "Crafting", 14, UITheme.WOOD_DK)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	if GameState.craft_sources(player).size() > 1:
		head.add_child(UITheme.label("Using your pack + farm chest   ", 8, UITheme.MUTED))
	if not embedded:
		head.add_child(UITheme.button("Close", func(): closed.emit()))
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 10)
	v.add_child(cols)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(200, 0)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cols.add_child(sc)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 2)
	sc.add_child(_list)
	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 4)
	cols.add_child(_detail)
	_refresh()

func _known() -> Array:
	var c := GameState.ctx()
	c["recipes"] = player.recipes
	var ids := Economy.known_recipes(kind, c)
	var srcs := GameState.craft_sources(player)
	ids.sort_custom(func(a, b):
		var ma := Economy.can_make(kind, a, srcs)
		var mb := Economy.can_make(kind, b, srcs)
		if ma != mb:
			return ma
		return Data.item_name(a) < Data.item_name(b))
	return ids

func _locked() -> Array:
	var known := _known()
	var out: Array = []
	for id in Data.recipes.get(kind, {}):
		if not id in known:
			out.append(id)
	return out

func _refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	var srcs := GameState.craft_sources(player)
	var ids := _known()
	if _sel == "" and ids.size() > 0:
		_sel = ids[0]
	for id in ids:
		_list.add_child(_row(id, Economy.can_make(kind, id, srcs), false))
	for id in _locked():
		_list.add_child(_row(id, false, true))
	_show_detail()

func _row(id: String, can: bool, locked: bool) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(190, 26)
	var picked := id == _sel
	var bg := UITheme.CREAM if picked else (UITheme.PARCHMENT_DK if not locked else Color("#d8ccb4"))
	var st := UITheme.box(bg, Color("#ffd447") if picked else Color("#b09060"), 2 if picked else 1, 3, 2, false)
	for s in ["normal", "hover", "pressed"]:
		b.add_theme_stylebox_override(s, st)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func(): _sel = id; Audio.sfx("tick", 0.0); _refresh())
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 3
	b.add_child(h)
	var ic := UITheme.icon_rect(Art.item(id), 20)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if locked:
		ic.modulate = Color(0, 0, 0, 0.45)
	h.add_child(ic)
	var l := UITheme.label("???" if locked else Data.item_name(id), 9, UITheme.INK if can else UITheme.MUTED)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	if can:
		var ok := UITheme.label("✓ ", 10, UITheme.LEAF.darkened(0.3))
		ok.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(ok)
	return b

func _show_detail() -> void:
	for c in _detail.get_children():
		c.queue_free()
	if _sel == "":
		_detail.add_child(UITheme.label("No recipes yet.", 10, UITheme.MUTED))
		return
	var r := Economy.recipe(kind, _sel)
	var locked := not _sel in _known()
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_detail.add_child(top)
	var art := PanelContainer.new()
	art.add_theme_stylebox_override("panel", UITheme.box(UITheme.CREAM, UITheme.OUTLINE, 2, 4, 4, false))
	var ic := UITheme.icon_rect(Art.item(_sel), 48)
	if locked:
		ic.modulate = Color(0, 0, 0, 0.45)
	art.add_child(ic)
	top.add_child(art)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(info)
	info.add_child(UITheme.label("???" if locked else Data.item_name(_sel), 12, UITheme.WOOD_DK))
	var it: Dictionary = Data.get_item(_sel)
	var desc := UITheme.label(Economy.req_text(r.unlock) if locked else str(it.get("desc", "")), 8, UITheme.MUTED)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(desc)
	if int(it.get("energy", 0)) > 0 and not locked:
		info.add_child(UITheme.label(tr("+%d energy") % int(it.energy), 9, UITheme.LEAF.darkened(0.3)))
	if locked:
		return
	_detail.add_child(UITheme.label("Ingredients", 10, UITheme.WOOD))
	var srcs := GameState.craft_sources(player)
	for k in r.in:
		var have := Economy.count_in(srcs, k)
		var need := int(r.in[k])
		var row := HBoxContainer.new()
		row.add_child(UITheme.icon_rect(Art.item(k), 20))
		var nl := UITheme.label(Data.item_name(k), 9, UITheme.INK)
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(nl)
		row.add_child(UITheme.label(tr("%d / %d") % [have, need], 9, UITheme.LEAF.darkened(0.3) if have >= need else Color("#b04040")))
		_detail.add_child(row)
	var acts := HBoxContainer.new()
	acts.add_theme_constant_override("separation", 4)
	_detail.add_child(acts)
	var can := Economy.can_make(kind, _sel, srcs)
	var b := UITheme.button("Cook" if kind == "cooking" else "Craft", func(): _make(1))
	b.disabled = not can
	acts.add_child(b)
	var b5 := UITheme.button("x5", func(): _make(5))
	b5.disabled = not can
	acts.add_child(b5)

func _make(n: int) -> void:
	var made := 0
	for i in n:
		var res: Dictionary = Coop.act("craft", [kind, _sel])
		if not res.ok:
			if made == 0 and res.reason != "":
				Audio.sfx("error")
				EventBus.toast.emit(res.reason, "")
			break
		made += 1
	if made > 0:
		Audio.sfx("chest")
		EventBus.toast.emit(tr("Made %d %s") % [made, Data.item_name(_sel)], "")
	await get_tree().process_frame
	_refresh()
