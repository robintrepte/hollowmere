class_name HatcheryPanel
extends PanelContainer
## Incubating eggs: what's warming, how long is left, and eggs you can add from your bag or the farm chest.

signal closed

var player: PlayerData
var _body: VBoxContainer

func _init(p: PlayerData = null) -> void:
	player = p

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -190
	offset_right = 190
	offset_top = -130
	offset_bottom = 130
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := UITheme.label("Hatchery", 14, UITheme.WOOD_DK)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(UITheme.button("Close", func(): closed.emit()))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 4)
	sc.add_child(_body)
	_refresh()

static func egg_hint(egg: Dictionary) -> String:
	var parents: Array = egg.get("parents", [])
	if parents.size() == 2:
		return TranslationServer.translate("From %s and %s") % [TranslationServer.translate(str(Data.get_species(parents[0]).get("name", "?"))), TranslationServer.translate(str(Data.get_species(parents[1]).get("name", "?")))]
	var t: String = Data.get_species(egg.get("species", "")).get("types", ["wild"])[0]
	return TranslationServer.translate("It feels a little %s...") % _egg_feel(t)

static func _egg_feel(t: String) -> String:
	match t:
		"leaf":
			return TranslationServer.translate("leafy")
		"tide":
			return TranslationServer.translate("damp")
		"ember":
			return TranslationServer.translate("warm")
		"stone":
			return TranslationServer.translate("heavy")
		"gale":
			return TranslationServer.translate("light")
		"spark":
			return TranslationServer.translate("tingly")
		"frost":
			return TranslationServer.translate("chilly")
		"shade":
			return TranslationServer.translate("shadowy")
		"glow":
			return TranslationServer.translate("glowy")
		"wild":
			return TranslationServer.translate("fuzzy")
	return TranslationServer.translate("odd")

func _available_eggs() -> Array:
	var out: Array = []
	for src in [[player.inventory, "Bag"], [GameState.farm_chest, "Farm chest"]]:
		var inv: Inventory = src[0]
		for e in inv.all_entries():
			if e.id == "wildling_egg":
				out.append({"entry": e, "from": src[1]})
	return out

func _refresh() -> void:
	for c in _body.get_children():
		c.queue_free()
	var cap := GameState.hatchery_capacity()
	if cap == 0:
		var l := UITheme.label("The Hatchery needs rebuilding before it can warm eggs.\nAsk at the Carpenter's.", 10, UITheme.INK)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_body.add_child(l)
		return
	_body.add_child(UITheme.label(TranslationServer.translate("Warming %d / %d") % [GameState.world.hatchery.size(), cap], 10, UITheme.WOOD))
	for i in cap:
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 4, false))
		_body.add_child(row)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		row.add_child(h)
		if i < GameState.world.hatchery.size():
			var slot: Dictionary = GameState.world.hatchery[i]
			var egg: Dictionary = slot.egg
			h.add_child(UITheme.icon_rect(Art.item("wildling_egg"), 24))
			var v := VBoxContainer.new()
			v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.add_theme_constant_override("separation", 1)
			h.add_child(v)
			var days := int(slot.days)
			v.add_child(UITheme.label(TranslationServer.translate("Hatches %s") % (TranslationServer.translate("tomorrow!") if days <= 1 else TranslationServer.translate("in %d days") % days), 10, UITheme.INK))
			v.add_child(UITheme.label(egg_hint(egg), 8, UITheme.MUTED))
			var bar := ProgressBar.new()
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(0, 4)
			bar.max_value = maxi(1, int(egg.get("days", days)))
			bar.value = bar.max_value - days
			v.add_child(bar)
		else:
			h.add_child(UITheme.label("An empty nest of warm straw.", 9, UITheme.MUTED))
	var eggs := _available_eggs()
	if eggs.is_empty():
		_body.add_child(UITheme.label("No eggs to add. Pair Wildlings in the Den and eggs appear in the farm chest.", 8, UITheme.MUTED))
		return
	_body.add_child(UITheme.label("Eggs you have", 10, UITheme.WOOD))
	for e in eggs:
		var row2 := HBoxContainer.new()
		_body.add_child(row2)
		row2.add_child(UITheme.icon_rect(Art.item("wildling_egg"), 20))
		var meta: Dictionary = e.entry.get("meta", {})
		var l2 := UITheme.label(TranslationServer.translate("%s  (%s)") % [egg_hint(meta.get("egg", {})), e.from], 9, UITheme.INK)
		l2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(l2)
		var b := UITheme.button("Incubate", func():
			if Coop.act("incubate", [e.entry.uid]).ok:
				Audio.sfx("chest")
				GameState.bump_stat("incubate")
			_refresh())
		b.disabled = GameState.world.hatchery.size() >= cap
		row2.add_child(b)
