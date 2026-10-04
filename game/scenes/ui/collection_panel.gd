class_name CollectionPanel
extends JournalPanel
## Collections: every fish with its record size, the Wildling dex and the village museum.

const COLLECTION_TABS := [["fish", "Fish"], ["dex", "Wildlings"], ["museum", "Museum"]]

func _init(p: PlayerData = null, start_tab: String = "fish") -> void:
	super(p, start_tab)

func _tab_list() -> Array:
	return COLLECTION_TABS

func _render(id: String) -> void:
	if id == "museum":
		_museum()
	else:
		super(id)

## Minerals, crystals and fossils on display, plus the next donation reward.
func _museum() -> void:
	var shown: Array = GameState.world.get("mining", {}).get("museum", [])
	_body.add_child(UITheme.label(tr("On display %d of %d") % [shown.size(), Mining.MUSEUM.size()], 10, UITheme.WOOD))
	for n in Mining.MUSEUM_REWARDS:
		if shown.size() < int(n):
			_body.add_child(UITheme.label(tr("Next gift from the curator at %d pieces") % int(n), 8, UITheme.MUTED))
			break
	_body.add_child(_wrap(tr("Bring finds from the mines to the museum in the village to put them on display."), 8, UITheme.MUTED))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 3)
	_body.add_child(grid)
	for item in Mining.MUSEUM:
		var have: bool = item in shown
		var pc := PanelContainer.new()
		pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pc.add_theme_stylebox_override("panel", UITheme.box(UITheme.CREAM if have else UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 2, false))
		grid.add_child(pc)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		pc.add_child(h)
		var ic := UITheme.icon_rect(Art.item(item), 24)
		if not have:
			ic.modulate = Color(0.1, 0.1, 0.15, 0.55)
		h.add_child(ic)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(col)
		col.add_child(UITheme.label(Data.item_name(item) if have else "???", 9, UITheme.INK))
		var d := UITheme.label(str(Data.get_item(item).get("desc", "")) if have else tr("Not donated yet"), 7, UITheme.MUTED)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size = Vector2(200, 0)
		col.add_child(d)
