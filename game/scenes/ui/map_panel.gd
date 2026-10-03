class_name MapPanel
extends PanelContainer
## Valley map opened with M: the roads out of the village, and which ones are open.

signal closed

const CROSS := [
	["", "whisperwood", ""],
	["farm", "town", "tidecove"],
	["", "meadow", ""],
]

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -168
	offset_right = 168
	offset_top = -150
	offset_bottom = 150
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var title := UITheme.label("Valley map", 14, UITheme.WOOD_DK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(UITheme.button("Close", func(): closed.emit()))
	var here := _here_id()
	var where := UITheme.label(tr("You are in %s") % _place_name(here), 10, UITheme.INK)
	where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(where)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	v.add_child(grid)
	for row in CROSS:
		for id in row:
			grid.add_child(_cell(str(id), here))
	v.add_child(UITheme.label("Opened by restoring shrines", 10, UITheme.WOOD))
	for rid in Data.region_order:
		if rid in ["meadow", "whisperwood", "tidecove"]:
			continue
		var open := GameState.region_unlocked(rid)
		var name := Data.region_name(rid) if open else tr("Closed")
		var mark := "● " if _at(here, rid) else ""
		var col := UITheme.LEAF.darkened(0.2) if _at(here, rid) else (UITheme.INK if open else UITheme.MUTED)
		v.add_child(UITheme.label(mark + name, 9, col))

func _here_id() -> String:
	var p := GameState.local_player()
	return p.map_id if p else ""

func _place_name(id: String) -> String:
	if id.begins_with("mine:"):
		var parts := id.split(":")
		var mine: String = str(Data.regions.get(parts[1], {}).get("mine", {}).get("name", parts[1]))
		return tr("%s B%s") % [tr(mine), parts[2] if parts.size() > 2 else "?"]
	return Data.region_name(id) if id != "" else tr("the valley")

func _at(here: String, place: String) -> bool:
	if here == place:
		return true
	if place == "farm" and here in ["greenhouse", "terrace"]:
		return true
	if here.begins_with("mine:") and here.split(":")[1] == place:
		return true
	return false

func _cell(id: String, here: String) -> Control:
	if id == "":
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(100, 36)
		return gap
	var open := id in ["farm", "town"] or GameState.region_unlocked(id)
	var here_now := _at(here, id)
	var b := PanelContainer.new()
	var edge := UITheme.LEAF if here_now else UITheme.OUTLINE
	b.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK if open else Color("#e6d7b8"), edge, 2 if here_now else 1, 3, 4, false))
	b.custom_minimum_size = Vector2(100, 36)
	var text := Data.region_name(id) if open else tr("Closed")
	if here_now:
		text = "● " + text
	var l := UITheme.label(text, 8, UITheme.INK if open else UITheme.MUTED)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_child(l)
	return b
