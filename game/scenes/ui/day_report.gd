class_name DayReport
extends PanelContainer
## Morning summary (Farm Story style): shipping earnings, Wildling job results, eggs, events.

signal closed

var report: Dictionary

func _init(r: Dictionary = {}) -> void:
	report = r

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -170
	offset_right = 170
	offset_top = -60
	offset_bottom = 60
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var day_i := int(report.get("day", GameState.day()))
	var t := UITheme.label("Good morning!", 15, UITheme.WOOD_DK)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var d := UITheme.label("%s · %s" % [Calendar.date_string(day_i), Calendar.weather_name(GameState.world.weather)], 10, UITheme.MUTED)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(d)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(body)
	var shipped: Array = report.get("shipped", [])
	if not shipped.is_empty():
		body.add_child(UITheme.label("Shipped", 11, UITheme.WOOD))
		var grid := GridContainer.new()
		grid.columns = 3
		body.add_child(grid)
		for s in shipped:
			grid.add_child(UITheme.icon_rect(Art.item(s.id), 16))
			grid.add_child(UITheme.label("%s x%d" % [Data.item_name(s.id, int(s.q)), int(s.n)], 9))
			var val := UITheme.label("%dg" % int(s.v), 9, UITheme.WOOD_DK)
			val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(val)
		var tot := UITheme.label("Total: %dg" % int(report.get("ship_total", 0)), 13, UITheme.WOOD_DK)
		tot.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		body.add_child(tot)
	var jobs: Dictionary = report.get("jobs", {})
	var lines: Array = []
	for k in [["watered", "tiles watered"], ["grown", "crops nudged to grow"], ["cleared", "debris cleared"], ["harvested", "crops harvested"],
			["pollinated", "crops pollinated"], ["smelted", "bars smelted"], ["preserved", "goods preserved"], ["produce", "produce gathered"]]:
		var jv: Variant = jobs.get(k[0], 0)
		var n := 0
		if jv is Dictionary:
			for id in jv:
				n += int(jv[id])
		elif jv is int or jv is float:
			n = int(jv)
		if n > 0:
			lines.append("%d %s" % [n, k[1]])
	if int(jobs.get("tired", 0)) > 0:
		lines.append("%d Wildlings are tired and need rest" % int(jobs.tired))
	if not lines.is_empty():
		body.add_child(UITheme.label("Your Wildlings worked overnight", 11, UITheme.WOOD))
		for l in lines:
			body.add_child(UITheme.label("· " + l, 9))
	for h in report.get("hatched", []):
		body.add_child(UITheme.label("An egg hatched: %s%s!" % ["Starry " if h.starry else "", Data.get_species(h.species).get("name", h.species)], 10, UITheme.LEAF.darkened(0.3)))
	if int(report.get("eggs", 0)) > 0:
		body.add_child(UITheme.label("%d new egg%s in the farm chest!" % [int(report.eggs), "s" if int(report.eggs) > 1 else ""], 10, UITheme.LEAF.darkened(0.3)))
	var farm: Dictionary = report.get("farm", {})
	if int(farm.get("crow", 0)) > 0:
		body.add_child(UITheme.label("A crow ate %d crop. A scarecrow would help!" % int(farm.crow), 9, UITheme.HEART))
	if int(farm.get("withered", 0)) > 0:
		body.add_child(UITheme.label("%d crops withered with the season change." % int(farm.withered), 9, UITheme.HEART))
	if report.get("passed_out", false):
		body.add_child(UITheme.label("You passed out from exhaustion%s." % (" and lost %dg" % int(report.lost_money) if report.has("lost_money") else ""), 9, UITheme.HEART))
	var fest: String = report.get("festival", "")
	if fest != "":
		body.add_child(UITheme.label("Today: %s in the village!" % fest.capitalize(), 10, UITheme.COIN.darkened(0.3)))
	if body.get_child_count() == 0:
		body.add_child(UITheme.label("A quiet night. A fresh day awaits.", 10, UITheme.MUTED))
	var b := UITheme.button("Let's go!", func(): closed.emit())
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(b)
	b.call_deferred("grab_focus")
	if int(report.get("ship_total", 0)) > 0:
		Audio.sfx("coin")
	await get_tree().process_frame
	sc.custom_minimum_size.y = minf(body.get_combined_minimum_size().y, 210.0)
	var s := get_combined_minimum_size()
	offset_top = -s.y / 2.0
	offset_bottom = s.y / 2.0
