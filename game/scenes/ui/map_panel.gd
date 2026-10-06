class_name MapPanel
extends PanelContainer
## Valley map: a drawn chart of the roads out of Hollowmere. Drag to pan, scroll or pinch to zoom.
## Closed places sit under cloud. Map Reader travels to an open place.

signal closed

## Shown as a tab inside the MenuShell: no frame and no close button of its own.
var embedded := false

## Map space, y down. Roads match the village exits: farm west, Eisenkamm northwest,
## Whisperwood north, the meadow south, Tidecove east, Gull Bay southeast, Lumière by ferry.
const POS := {
	"eisenkamm": Vector2(-230, -32),
	"galepeak": Vector2(-70, -80),
	"whisperwood": Vector2(-40, -18),
	"farm": Vector2(-230, 48),
	"town": Vector2(-40, 48),
	"meadow": Vector2(-40, 128),
	"stonehollow": Vector2(130, -84),
	"cinder_ridge": Vector2(140, -10),
	"frostmere": Vector2(300, -80),
	"umbral_glade": Vector2(310, -8),
	"sparkmarsh": Vector2(200, 44),
	"tidecove": Vector2(120, 124),
	"gull_bay": Vector2(270, 124),
	"lumiere": Vector2(480, 96),
}
## [from, to, bend] bend pushes the road sideways so it doesn't cut the coast.
const ROADS := [
	["farm", "town", -18.0],
	["eisenkamm", "town", 16.0],
	["whisperwood", "town", 12.0],
	["town", "meadow", -10.0],
	["town", "tidecove", -16.0],
	["town", "gull_bay", 18.0],
]
const FERRY := ["gull_bay", "lumiere", 26.0]
const LAND := [
	Vector2(-310, 32), Vector2(-310, -56), Vector2(-200, -124), Vector2(-20, -136),
	Vector2(160, -136), Vector2(300, -124), Vector2(400, -88), Vector2(400, -16),
	Vector2(370, 32), Vector2(340, 80), Vector2(350, 140), Vector2(200, 168),
	Vector2(-20, 172), Vector2(-160, 144), Vector2(-280, 96),
]
const ISLE := [
	Vector2(430, 70), Vector2(470, 52), Vector2(540, 64), Vector2(560, 108),
	Vector2(520, 142), Vector2(450, 138), Vector2(418, 100),
]
const BEACH := [Vector2(400, -16), Vector2(370, 32), Vector2(340, 80), Vector2(350, 140), Vector2(200, 168)]
const TINT := {
	"farm": Color("#74b256"),
	"town": Color("#7eae58"),
	"meadow": Color("#9bc85a"),
	"whisperwood": Color("#2c6840"),
	"eisenkamm": Color("#8d8478"),
	"galepeak": Color("#8ea0a4"),
	"tidecove": Color("#e6d2a4"),
	"gull_bay": Color("#e4c88a"),
	"lumiere": Color("#f0d8a8"),
	"cinder_ridge": Color("#b5523c"),
	"stonehollow": Color("#c6a36e"),
	"sparkmarsh": Color("#4c7a58"),
	"frostmere": Color("#d7e7ef"),
	"umbral_glade": Color("#6e548c"),
}

var _map: MapView
var _where: Label
var _frame: Panel
var _side: PanelContainer
var _card: VBoxContainer

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", StyleBoxEmpty.new() if embedded else UITheme.parchment(8))
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	v.add_child(head)
	_where = UITheme.label(tr("You are in %s") % place_name(here_id()), 11, UITheme.WOOD_DK)
	_where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_where.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_where.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(_where)
	head.add_child(UITheme.button("-", func(): _map.zoom_by(1.0 / 1.15)))
	head.add_child(UITheme.button("+", func(): _map.zoom_by(1.15)))
	head.add_child(UITheme.button("Center", func(): _map.reset_view()))
	if not embedded:
		head.add_child(UITheme.button("Close", func(): closed.emit()))
	_frame = Panel.new()
	_frame.add_theme_stylebox_override("panel", UITheme.box(Color("#e7d4a8"), UITheme.WOOD_DK, 2, 3, 0, false))
	_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_frame.clip_contents = true
	v.add_child(_frame)
	_map = MapView.new()
	_map.travel_requested.connect(_go)
	_map.selected.connect(_show)
	_map.hovered.connect(func(id: String): _show(id if id != "" else _map.sel))
	_frame.add_child(_map)
	_side = PanelContainer.new()
	_side.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 6, false))
	_side.custom_minimum_size = Vector2(180, 0)
	_side.mouse_filter = Control.MOUSE_FILTER_STOP
	_side.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_side.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_frame.add_child(_side)
	_card = VBoxContainer.new()
	_card.add_theme_constant_override("separation", 3)
	_side.add_child(_card)
	var hint := UITheme.label("Drag to pan. Scroll or pinch to zoom.", 8, UITheme.MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	if Skills.has_unlock(GameState.local_player(), "map_travel"):
		var go := UITheme.label("Map Reader: click an open place to travel there.", 8, UITheme.LEAF.darkened(0.3))
		go.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(go)
	resized.connect(_place_card)
	_show(_map.sel)

func on_tab_shown() -> void:
	_map.grab_focus.call_deferred()

func _place_card() -> void:
	if not is_instance_valid(_side) or not is_instance_valid(_frame):
		return
	var h := maxf(_side.get_combined_minimum_size().y, 28.0)
	var w := minf(220.0, maxf(160.0, _frame.size.x - 16.0))
	_side.offset_left = 8
	_side.offset_right = 8 + w
	_side.offset_bottom = -8
	_side.offset_top = -8 - h

func _show(id: String) -> void:
	if id == "":
		id = _map.sel
	for c in _card.get_children():
		c.queue_free()
	if id == "" or not POS.has(id):
		_place_card.call_deferred()
		return
	var open := GameState.place_open(id)
	var title := ("! " if open and quest_on(id) else "") + ("● " if at_place(here_id(), id) else "")
	title += place_name(id) if open else tr("Closed")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_card.add_child(row)
	var sw := ColorRect.new()
	sw.custom_minimum_size = Vector2(14, 14)
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sw.color = TINT.get(id, UITheme.LEAF) if open else Color("#b7c4c8")
	row.add_child(sw)
	var name := UITheme.label(title, 11, UITheme.WOOD_DK)
	name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name.custom_minimum_size = Vector2(150, 0)
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name)
	var sub := ""
	if open and Data.regions.has(id) and str(Data.regions[id].get("warden", "")) != "":
		var state := Adventure.shrine_state(GameState.world, id)
		match state:
			"dark":
				sub = tr("Warden %s awaits") % Data.villager_name(str(Data.regions[id].warden))
			"ready":
				sub = tr("Shrine ready to wake")
			"restored":
				sub = tr("Shrine awake ✓")
		_card.add_child(UITheme.label(sub, 8, UITheme.LEAF.darkened(0.3) if state == "restored" else UITheme.MUTED))
		var mine: Dictionary = Data.regions[id].get("mine", {})
		if not mine.is_empty():
			var deep := Adventure.deepest(GameState.world, id)
			if deep > 0:
				var total := Adventure.mine_floors(id)
				var extra := (tr(" / %d") % total) if total > 0 else ""
				_card.add_child(UITheme.label(tr("%s B%d%s") % [tr(str(mine.name)), deep, extra], 8, UITheme.MUTED))
			else:
				_card.add_child(UITheme.label(str(mine.name), 8, UITheme.MUTED))
	elif not open and Data.regions.has(id):
		sub = tr("Opened by restoring shrines")
		_card.add_child(UITheme.label(sub, 8, UITheme.MUTED))
	if can_travel(id):
		var place := id
		var b := UITheme.button("Travel", func(): _go(place))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_card.add_child(b)
	_place_card.call_deferred()

func _go(id: String) -> void:
	if not can_travel(id):
		return
	Audio.sfx("sparkle")
	closed.emit()
	EventBus.map_change_requested.emit(id, AdventureFlow.wayshrine_arrival(id))

static func here_id() -> String:
	var p := GameState.local_player()
	return p.map_id if p else ""

static func place_name(id: String) -> String:
	if id.begins_with("mine:"):
		var parts := id.split(":")
		var mine: String = str(Data.regions.get(parts[1], {}).get("mine", {}).get("name", parts[1]))
		return TranslationServer.translate("%s B%s") % [TranslationServer.translate(mine), parts[2] if parts.size() > 2 else "?"]
	return Data.region_name(id) if id != "" else TranslationServer.translate("the valley")

static func at_place(here: String, place: String) -> bool:
	if here == place:
		return true
	if place == "farm" and here in ["greenhouse", "terrace"]:
		return true
	if place == "lumiere" and here in ["casino", "casino_vip"]:
		return true
	if here.begins_with("mine:") and here.split(":").size() > 1 and here.split(":")[1] == place:
		return true
	return false

static func pin_id() -> String:
	var here := here_id()
	for id in POS:
		if at_place(here, id):
			return id
	return "town"

static func can_travel(id: String) -> bool:
	return GameState.place_open(id) and not at_place(here_id(), id) and Skills.has_unlock(GameState.local_player(), "map_travel")

static func quest_on(id: String) -> bool:
	var p := GameState.local_player()
	if p == null:
		return false
	for m in Quests.tracked_maps(p):
		var mid := str(m)
		if mid == id or at_place(mid, id):
			return true
	return false


## The chart itself. Places are picked in screen space; the drawing is in map space.
class MapView extends Control:
	signal selected(id: String)
	signal hovered(id: String)
	signal travel_requested(id: String)

	const PAPER := Color("#e7d4a8")
	const SEA := Color("#2f6f98")
	const SHALLOW := Color("#5aa6c4")
	const LAND := Color("#6ea84e")
	const ZOOM_MIN := 0.28
	const ZOOM_MAX := 2.4

	var sel := ""
	var zoom := 0.6
	var offset := Vector2.ZERO
	var _hover := ""
	var _pin := ""
	var _drag_from := Vector2.INF
	var _dragged := false
	var _moved := false
	var _t := 0.0
	var _touches: Dictionary = {}
	var _pinch_d := 0.0
	var _land := PackedVector2Array()
	var _isle := PackedVector2Array()
	var _taken: Array[Rect2] = []

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		set_anchors_preset(Control.PRESET_FULL_RECT)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		clip_contents = true

	func _ready() -> void:
		sel = MapPanel.pin_id()
		_pin = sel
		_ensure()
		mouse_exited.connect(func():
			if _hover != "":
				_hover = ""
				_cursor()
				hovered.emit(""))
		resized.connect(func():
			if not _moved:
				fit())
		fit.call_deferred()

	func _process(delta: float) -> void:
		_t += delta
		_pin = MapPanel.pin_id()
		queue_redraw()

	func reset_view() -> void:
		_moved = false
		fit()

	func zoom_by(factor: float) -> void:
		_moved = true
		_zoom_at(factor, size * 0.5)

	func fit() -> void:
		_ensure()
		if size.x < 8.0 or size.y < 8.0:
			return
		var b := _bounds()
		var m := 18.0
		zoom = clampf(minf((size.x - m * 2.0) / b.size.x, (size.y - m * 2.0) / b.size.y), ZOOM_MIN, ZOOM_MAX)
		offset = -b.get_center() * zoom
		queue_redraw()

	func _ensure() -> void:
		if _land.is_empty():
			_land = _chaikin(_packed(MapPanel.LAND), 2)
			_isle = _chaikin(_packed(MapPanel.ISLE), 2)

	func _bounds() -> Rect2:
		var r := Rect2(_land[0], Vector2.ZERO)
		for p in _land:
			r = r.expand(p)
		for p in _isle:
			r = r.expand(p)
		return r.grow(24.0)

	func _screen(p: Vector2) -> Vector2:
		var s := size * 0.5 + offset + p * zoom
		return Vector2(round(s.x), round(s.y))

	func _sc() -> float:
		return clampf(zoom, 0.72, 1.8)

	func _zoom_at(factor: float, at: Vector2) -> void:
		var nz := clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
		var world_at := (at - size * 0.5 - offset) / zoom
		zoom = nz
		offset = at - size * 0.5 - world_at * zoom
		queue_redraw()

	func _pick(at: Vector2) -> String:
		var best := ""
		var reach := maxf(16.0, 12.0 * _sc())
		for id in MapPanel.POS:
			var d := _screen(MapPanel.POS[id]).distance_to(at)
			if d <= reach and (best == "" or d < _screen(MapPanel.POS[best]).distance_to(at)):
				best = id
		return best

	func _cursor() -> void:
		if _drag_from != Vector2.INF and _dragged:
			mouse_default_cursor_shape = Control.CURSOR_DRAG
		elif _hover != "":
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		else:
			mouse_default_cursor_shape = Control.CURSOR_ARROW

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_WHEEL_UP and ev.pressed:
			_moved = true
			_zoom_at(1.12, ev.position)
			accept_event()
		elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_WHEEL_DOWN and ev.pressed:
			_moved = true
			_zoom_at(1.0 / 1.12, ev.position)
			accept_event()
		elif ev is InputEventMouseButton and ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			if ev.pressed:
				grab_focus()
				_drag_from = ev.position
				_dragged = false
			else:
				if not _dragged and ev.button_index == MOUSE_BUTTON_LEFT:
					_activate(_pick(ev.position))
				_drag_from = Vector2.INF
				_cursor()
			accept_event()
		elif ev is InputEventMouseMotion:
			if _drag_from != Vector2.INF and _touches.size() < 2:
				if ev.position.distance_to(_drag_from) > 4.0 or _dragged:
					_dragged = true
					_moved = true
					offset += ev.relative
					queue_redraw()
			var hit := "" if _dragged else _pick(ev.position)
			if hit != _hover:
				_hover = hit
				_cursor()
				hovered.emit(hit)
			elif _dragged:
				_cursor()
		elif ev is InputEventMagnifyGesture:
			_moved = true
			_zoom_at(ev.factor, ev.position)
			accept_event()
		elif ev is InputEventPanGesture:
			_moved = true
			offset -= ev.delta * 8.0
			queue_redraw()
			accept_event()
		elif ev is InputEventScreenTouch:
			if ev.pressed:
				_touches[ev.index] = ev.position
			else:
				_touches.erase(ev.index)
			_pinch_d = _pinch_distance()
		elif ev is InputEventScreenDrag:
			_touches[ev.index] = ev.position
			if _touches.size() >= 2:
				var d := _pinch_distance()
				if _pinch_d > 0.0 and d > 0.0:
					_moved = true
					_zoom_at(d / _pinch_d, _pinch_center())
				_pinch_d = d
		elif ev.is_action_pressed("ui_accept"):
			_activate(sel)
			accept_event()
		else:
			for dir in [["ui_left", Vector2.LEFT], ["ui_right", Vector2.RIGHT], ["ui_up", Vector2.UP], ["ui_down", Vector2.DOWN]]:
				if ev.is_action_pressed(dir[0]):
					_hop(dir[1])
					accept_event()
					return

	func _activate(id: String) -> void:
		if id == "":
			return
		if MapPanel.can_travel(id):
			travel_requested.emit(id)
			return
		sel = id
		selected.emit(id)
		queue_redraw()

	func _hop(dir: Vector2) -> void:
		var from: Vector2 = MapPanel.POS.get(sel, Vector2.ZERO)
		var best := ""
		var best_score := INF
		for id in MapPanel.POS:
			if id == sel:
				continue
			var d: Vector2 = MapPanel.POS[id] - from
			if d.length() < 1.0:
				continue
			var along := d.dot(dir)
			if along <= 0.0:
				continue
			var score := d.length() + absf(d.cross(dir)) * 2.0
			if score < best_score:
				best_score = score
				best = id
		if best == "":
			return
		sel = best
		selected.emit(best)
		var sp := _screen(MapPanel.POS[best])
		var margin := 36.0
		if not Rect2(Vector2(margin, margin), size - Vector2(margin, margin) * 2.0).has_point(sp):
			_moved = true
			offset -= sp - size * 0.5
		queue_redraw()

	func _pinch_distance() -> float:
		var pts: Array = _touches.values()
		return (pts[0] as Vector2).distance_to(pts[1]) if pts.size() >= 2 else 0.0

	func _pinch_center() -> Vector2:
		var pts: Array = _touches.values()
		return ((pts[0] as Vector2) + (pts[1] as Vector2)) / 2.0 if pts.size() >= 2 else size * 0.5

	func _draw() -> void:
		_ensure()
		draw_rect(Rect2(Vector2.ZERO, size), PAPER, true)
		_fill_poly(_sea(), SEA)
		_fill_poly(_shifted(_land, Vector2(5, 6)), Color(0, 0, 0, 0.13))
		_fill_poly(_land, LAND)
		_stroke(_land, Color("#234028"), maxf(1.5, 2.2 * zoom))
		_stroke_open(MapPanel.BEACH, Color("#e7d3a4"), maxf(2.0, 5.0 * zoom))
		for id in MapPanel.POS:
			if id == "lumiere" or not GameState.place_open(id):
				continue
			var col: Color = MapPanel.TINT[id]
			col.a = 0.82
			_ellipse(MapPanel.POS[id], 50.0, 36.0, col)
		_draw_water()
		_draw_ridge()
		_draw_roads()
		_draw_ferry()
		_draw_waves()
		if GameState.place_open("lumiere"):
			_fill_poly(_isle, MapPanel.TINT.lumiere)
			_stroke(_isle, Color("#8a7040"), maxf(1.0, 1.6 * zoom))
			_stamp("lumiere")
		_draw_stamps()
		_draw_clouds()
		_draw_rings()
		_draw_labels()
		_draw_marks()
		_compass()

	func _draw_water() -> void:
		_polyline([Vector2(8, 0), Vector2(28, 48), Vector2(46, 96), Vector2(58, 140)], Color("#2a6488"), maxf(3.0, 5.5 * zoom))
		_polyline([Vector2(8, 0), Vector2(28, 48), Vector2(46, 96), Vector2(58, 140)], Color("#7ec4dc"), maxf(1.5, 2.6 * zoom))
		_ellipse(Vector2(72, 150), 22, 12, Color("#3d86ab"))
		_ellipse(Vector2(-188, 78), 12, 7, Color("#3d86ab"))

	func _draw_ridge() -> void:
		_peak(Vector2(-160, -96), 16, 13, Color("#6a615c"), false)
		_peak(Vector2(-90, -108), 22, 15, Color("#7a716c"), false)
		_peak(Vector2(10, -104), 15, 12, Color("#6e6560"), false)
		_peak(Vector2(90, -112), 20, 14, Color("#756c68"), false)
		_peak(Vector2(180, -104), 17, 13, Color("#7d746e"), false)
		var snow := GameState.place_open("frostmere")
		_peak(Vector2(260, -100), 22, 16, Color("#8a8078"), snow)
		_peak(Vector2(340, -88), 16, 12, Color("#7a736c"), snow)

	func _draw_roads() -> void:
		for link in MapPanel.ROADS:
			var a: Vector2 = MapPanel.POS[link[0]]
			var b: Vector2 = MapPanel.POS[link[1]]
			var pts := _curve(a, b, float(link[2]))
			draw_polyline(pts, Color("#6b5030"), maxf(2.0, 5.5 * zoom), false)
			draw_polyline(pts, Color("#e2c27a"), maxf(1.0, 2.4 * zoom), false)

	func _draw_ferry() -> void:
		var a: Vector2 = MapPanel.POS[MapPanel.FERRY[0]]
		var b: Vector2 = MapPanel.POS[MapPanel.FERRY[1]]
		var bend := float(MapPanel.FERRY[2])
		var pts := _curve(a, b, bend)
		var on := true
		var acc := 0.0
		var dash := maxf(5.0, 7.0 * zoom)
		for i in pts.size() - 1:
			if on:
				draw_line(pts[i], pts[i + 1], Color("#f7f1e2"), maxf(1.0, 1.6 * zoom), false)
			acc += pts[i].distance_to(pts[i + 1])
			if acc >= dash:
				on = not on
				acc = 0.0
		_boat(_bezier(a, b, bend, 0.55))

	func _draw_waves() -> void:
		for at in [Vector2(400, 40), Vector2(450, 160), Vector2(390, 120), Vector2(520, 40), Vector2(250, 175), Vector2(560, 80)]:
			if _on_land(at):
				continue
			var s := _screen(at)
			var sc := maxf(zoom, 0.45)
			draw_line(s + Vector2(-5, 0) * sc, s + Vector2(-1, -2) * sc, SHALLOW, 1.0, false)
			draw_line(s + Vector2(-1, -2) * sc, s + Vector2(2, 0) * sc, SHALLOW, 1.0, false)
			draw_line(s + Vector2(2, 0) * sc, s + Vector2(6, -2) * sc, SHALLOW, 1.0, false)

	func _draw_stamps() -> void:
		for id in MapPanel.POS:
			if id == "lumiere" or not GameState.place_open(id):
				continue
			_stamp(id)

	func _draw_clouds() -> void:
		for id in MapPanel.POS:
			if GameState.place_open(id):
				continue
			var at: Vector2 = MapPanel.POS[id]
			if id == "lumiere":
				_cloud(at, 1.15)
			else:
				_cloud(at, 1.0)

	func _draw_rings() -> void:
		if sel != "" and sel != _hover:
			_ring(sel, Color("#fff4dc"))
		if _hover != "":
			_ring(_hover, UITheme.COIN if MapPanel.can_travel(_hover) else Color("#fff4dc"))

	func _draw_labels() -> void:
		_taken.clear()
		var forced: Array[String] = []
		var open: Array[String] = []
		var closed: Array[String] = []
		for id in MapPanel.POS:
			if _label_forced(id):
				forced.append(id)
			elif GameState.place_open(id):
				open.append(id)
			else:
				closed.append(id)
		for id in forced:
			_place_label(id, true)
		for id in open:
			_place_label(id, false)
		for id in closed:
			_place_label(id, false)

	func _draw_marks() -> void:
		for id in MapPanel.POS:
			if GameState.place_open(id) and MapPanel.quest_on(id):
				_bang(MapPanel.POS[id])
		if _pin != "" and MapPanel.POS.has(_pin):
			_pin_at(MapPanel.POS[_pin])

	func _stamp(id: String) -> void:
		var at: Vector2 = MapPanel.POS[id]
		_medallion(at, MapPanel.TINT[id])
		match id:
			"farm":
				_field(at + Vector2(-18, 12), Color("#c4a05a"))
				_field(at + Vector2(-6, 14), Color("#5e9a3e"))
				_field(at + Vector2(8, 12), Color("#c4a05a"))
				_house(at + Vector2(-6, -8), Color("#b04a3a"))
			"town":
				_ellipse(at + Vector2(2, 2), 10, 7, Color("#d7c090"))
				_house(at + Vector2(-16, -6), Color("#c05040"))
				_house(at + Vector2(14, -8), Color("#5070a0"))
				_house(at + Vector2(-10, 12), Color("#e0a040"))
				_house(at + Vector2(12, 12), Color("#6a8a3a"))
			"meadow":
				var blooms: Array[Color] = [Color("#e07098"), Color("#f0d050"), Color("#f4f0e8"), Color("#e07098"), Color("#f0d050")]
				var spots: Array[Vector2] = [Vector2(-14, 6), Vector2(-4, 12), Vector2(8, 4), Vector2(14, 14), Vector2(0, -8)]
				for i in spots.size():
					draw_circle(_screen(at + spots[i]), maxf(1.0, 1.6 * _sc()), blooms[i], true, -1.0, false)
			"whisperwood":
				for tree_at in [Vector2(-14, 2), Vector2(-2, -8), Vector2(10, 0), Vector2(2, 10), Vector2(16, 10)]:
					_pine(at + tree_at, 13.0)
			"eisenkamm":
				_peak(at + Vector2(-8, 6), 14, 11, Color("#5e5854"), false)
				_peak(at + Vector2(8, 4), 18, 12, Color("#6a625c"), false)
				draw_rect(Rect2(_screen(at + Vector2(0, 8)) + Vector2(-3, -2) * _sc(), Vector2(6, 5) * _sc()), Color("#1a1418"), true)
			"galepeak":
				_peak(at + Vector2(-6, 4), 16, 12, Color("#7a868c"), true)
				_peak(at + Vector2(8, 2), 20, 11, Color("#8a9498"), true)
			"tidecove", "gull_bay":
				_palm(at + Vector2(-12, 4))
				_palm(at + Vector2(10, 8))
				if id == "gull_bay":
					draw_line(_screen(at), _screen(at + Vector2(18, 10)), Color("#8a5a3a"), maxf(2.0, 2.5 * _sc()), false)
			"cinder_ridge":
				_peak(at, 20, 16, Color("#5c342c"), false)
				draw_circle(_screen(at) + Vector2(0, -12) * _sc(), 3.2 * _sc(), Color("#e05838"), true, -1.0, false)
			"stonehollow":
				for i in 3:
					var y := 4.0 + float(i) * 4.0
					draw_line(_screen(at + Vector2(-12, y)), _screen(at + Vector2(12, y - 1)), Color("#a68458"), maxf(1.0, 1.5 * _sc()), false)
			"sparkmarsh":
				_ellipse(at + Vector2(-8, 6), 8, 4, Color("#3d6a78"))
				_ellipse(at + Vector2(8, 8), 6, 3, Color("#3d6a78"))
				draw_line(_screen(at + Vector2(-2, 2)), _screen(at + Vector2(-2, -8)), Color("#2a5038"), maxf(1.0, _sc()), false)
			"frostmere":
				_peak(at + Vector2(-6, 4), 16, 12, Color("#c5d5de"), true)
				_peak(at + Vector2(8, 2), 20, 13, Color("#d5e4ec"), true)
			"umbral_glade":
				_pine(at + Vector2(-8, 4), 12.0)
				_pine(at + Vector2(6, 6), 14.0)
				_star(at + Vector2(0, -10), Color("#f0e090"))
			"lumiere":
				_house(at + Vector2(-12, 2), Color("#d06058"))
				_house(at + Vector2(0, -2), Color("#f0d8a0"))
				_house(at + Vector2(12, 2), Color("#6070a0"))
				_palm(at + Vector2(-18, 8))
				_palm(at + Vector2(18, 8))

	func _cloud(at: Vector2, scale: float) -> void:
		var puffs: Array[Vector2] = [Vector2.ZERO, Vector2(-16, 6), Vector2(15, 7), Vector2(-4, -12), Vector2(12, -11)]
		for puff in puffs:
			_ellipse(at + puff * scale, 18.0 * scale, 11.0 * scale, Color(0.45, 0.55, 0.62, 0.28))
		for puff in puffs:
			_ellipse(at + puff * scale + Vector2(-1, -2), 16.0 * scale, 10.0 * scale, Color("#f6f1e6"))

	func _label_forced(id: String) -> bool:
		return id == sel or id == _hover or id == _pin or (GameState.place_open(id) and MapPanel.quest_on(id))

	func _place_label(id: String, force: bool) -> void:
		var open := GameState.place_open(id)
		var text := Data.region_name(id) if open else "?"
		var col := UITheme.INK
		if not open:
			col = UITheme.MUTED
		elif id == _pin:
			col = UITheme.HEART.darkened(0.2)
		var font := UITheme.font()
		var fs: int = maxi(UITheme.fs(8), 8)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var s := _screen(MapPanel.POS[id]) + Vector2(0, 12.0 * _sc())
		var top := Vector2(round(s.x - w * 0.5), round(s.y))
		var rect := Rect2(top.x - 3, top.y - 1, w + 6, fs + 3)
		if not force:
			for prev in _taken:
				if prev.intersects(rect.grow(1)):
					return
		_taken.append(rect)
		draw_rect(rect, Color(0.97, 0.91, 0.78, 0.94), true)
		var edge := UITheme.COIN if open and MapPanel.quest_on(id) else Color("#6a5038")
		draw_rect(rect, edge, false, 1.0)
		draw_string(font, Vector2(top.x, top.y + fs - 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)

	func _ring(id: String, col: Color) -> void:
		draw_arc(_screen(MapPanel.POS[id]), 11.0 * _sc(), 0, TAU, 22, col, maxf(1.5, 2.0 * _sc()), false)

	func _bang(at: Vector2) -> void:
		var s := _screen(at) + Vector2(9, -10) * _sc()
		draw_circle(s, 5.5 * _sc(), UITheme.OUTLINE, true, -1.0, false)
		draw_circle(s, 4.4 * _sc(), UITheme.COIN, true, -1.0, false)
		var fs: int = maxi(int(8.0 * _sc()), 7)
		var font := UITheme.font()
		var w := font.get_string_size("!", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, s + Vector2(-w * 0.5, fs * 0.35), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.OUTLINE)

	func _pin_at(at: Vector2) -> void:
		var bob := sin(_t * 3.2) * 1.5
		var s := _screen(at) + Vector2(0, bob - 12.0)
		draw_colored_polygon(PackedVector2Array([s + Vector2(0, 9), s + Vector2(-4.5, -1), s + Vector2(4.5, -1)]), UITheme.HEART)
		draw_circle(s + Vector2(0, -3), 5.0, UITheme.OUTLINE, true, -1.0, false)
		draw_circle(s + Vector2(0, -3), 3.8, UITheme.HEART, true, -1.0, false)
		draw_circle(s + Vector2(0, -3.4), 1.5, Color("#fff4dc"), true, -1.0, false)

	func _medallion(at: Vector2, col: Color) -> void:
		var s := _screen(at)
		draw_circle(s, 5.5 * _sc(), UITheme.OUTLINE, true, -1.0, false)
		draw_circle(s, 4.2 * _sc(), col.lightened(0.15), true, -1.0, false)

	func _house(at: Vector2, roof: Color) -> void:
		var s := _screen(at)
		var sc := _sc()
		draw_rect(Rect2(s + Vector2(-5, -1) * sc, Vector2(10, 7) * sc), Color("#f4e6c8"), true)
		draw_colored_polygon(PackedVector2Array([
			s + Vector2(-6.5, -1) * sc, s + Vector2(0, -7) * sc, s + Vector2(6.5, -1) * sc,
		]), roof)

	func _field(at: Vector2, col: Color) -> void:
		var r := Rect2(_screen(at), Vector2(9, 6) * _sc())
		draw_rect(r, col, true)
		draw_rect(r, Color(0, 0, 0, 0.28), false, 1.0)

	func _pine(at: Vector2, h: float) -> void:
		var s := _screen(at)
		var sc := _sc()
		draw_rect(Rect2(s + Vector2(-1, 0) * sc, Vector2(2, 3) * sc), Color("#5c3a28"), true)
		draw_colored_polygon(PackedVector2Array([
			s + Vector2(0, -h) * sc, s + Vector2(-h * 0.4, 0) * sc, s + Vector2(h * 0.4, 0) * sc,
		]), Color("#1f5a30"))
		draw_colored_polygon(PackedVector2Array([
			s + Vector2(0, -h * 0.62) * sc, s + Vector2(-h * 0.26, -h * 0.22) * sc, s + Vector2(h * 0.26, -h * 0.22) * sc,
		]), Color("#3d8a46"))

	func _peak(at: Vector2, h: float, w: float, rock: Color, snow: bool) -> void:
		var s := _screen(at)
		var sc := _sc()
		var tip := s + Vector2(0, -h) * sc
		var pts := PackedVector2Array([tip, s + Vector2(-w, 3) * sc, s + Vector2(w * 0.75, 3) * sc])
		draw_colored_polygon(pts, rock)
		if snow:
			draw_colored_polygon(PackedVector2Array([
				tip, s + Vector2(-w * 0.28, -h * 0.52) * sc, s + Vector2(w * 0.22, -h * 0.48) * sc,
			]), Color("#f5fbff"))

	func _palm(at: Vector2) -> void:
		var s := _screen(at)
		var sc := _sc()
		draw_line(s, s + Vector2(1, -8) * sc, Color("#6b4a2a"), maxf(1.0, sc), false)
		draw_circle(s + Vector2(2, -8) * sc, 3.2 * sc, Color("#2f8a45"), true, -1.0, false)

	func _star(at: Vector2, col: Color) -> void:
		var s := _screen(at)
		var sc := _sc()
		draw_line(s + Vector2(0, -4) * sc, s + Vector2(0, 4) * sc, col, maxf(1.0, sc), false)
		draw_line(s + Vector2(-3, 0) * sc, s + Vector2(3, 0) * sc, col, maxf(1.0, sc), false)

	func _boat(at: Vector2) -> void:
		var s := _screen(at)
		var sc := _sc()
		draw_colored_polygon(PackedVector2Array([
			s + Vector2(-7, 1) * sc, s + Vector2(7, 1) * sc, s + Vector2(5, 4) * sc, s + Vector2(-5, 4) * sc,
		]), Color("#8a5a3a"))
		draw_line(s + Vector2(-1, 1) * sc, s + Vector2(-1, -7) * sc, Color("#5e3a24"), maxf(1.0, sc), false)
		draw_colored_polygon(PackedVector2Array([
			s + Vector2(-1, -6) * sc, s + Vector2(5, -2) * sc, s + Vector2(-1, -1) * sc,
		]), Color("#f4f0e4"))

	func _compass() -> void:
		var s := Vector2(size.x - 20, 20)
		draw_circle(s, 11, Color(0.91, 0.84, 0.68, 0.94), true, -1.0, false)
		draw_arc(s, 11, 0, TAU, 24, UITheme.WOOD_DK, 1.0, false)
		draw_colored_polygon(PackedVector2Array([s + Vector2(0, -8), s + Vector2(-3, 0), s + Vector2(3, 0)]), UITheme.HEART)
		draw_colored_polygon(PackedVector2Array([s + Vector2(0, 7), s + Vector2(-2.5, 0), s + Vector2(2.5, 0)]), UITheme.WOOD)
		var fs: int = maxi(UITheme.fs(7), 7)
		draw_string(UITheme.font(), s + Vector2(-3, -12), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.WOOD_DK)

	func _ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
		draw_colored_polygon(_oval(center, rx, ry), col)

	func _oval(center: Vector2, rx: float, ry: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for i in 22:
			var a := TAU * float(i) / 22.0
			pts.append(_screen(center + Vector2(cos(a) * rx, sin(a) * ry)))
		return pts

	func _fill_poly(world: PackedVector2Array, col: Color) -> void:
		if world.size() < 3:
			return
		draw_colored_polygon(_to_screen(world), col)

	func _stroke(world: PackedVector2Array, col: Color, width: float) -> void:
		var pts := _to_screen(world)
		if pts.is_empty():
			return
		pts.append(pts[0])
		draw_polyline(pts, col, width, false)

	func _stroke_open(world: Array, col: Color, width: float) -> void:
		draw_polyline(_to_screen(_packed(world)), col, width, false)

	func _polyline(world: Array, col: Color, width: float) -> void:
		draw_polyline(_to_screen(_packed(world)), col, width, false)

	func _to_screen(world: PackedVector2Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		out.resize(world.size())
		for i in world.size():
			out[i] = _screen(world[i])
		return out

	func _shifted(world: PackedVector2Array, by: Vector2) -> PackedVector2Array:
		var out := PackedVector2Array()
		out.resize(world.size())
		for i in world.size():
			out[i] = world[i] + by
		return out

	func _sea() -> PackedVector2Array:
		return _packed([
			Vector2(220, -150), Vector2(680, -150), Vector2(680, 240), Vector2(300, 240),
			Vector2(250, 170), Vector2(330, 90), Vector2(390, 10), Vector2(360, -80),
		])

	func _on_land(at: Vector2) -> bool:
		return Geometry2D.is_point_in_polygon(at, _land) or Geometry2D.is_point_in_polygon(at, _isle)

	func _curve(a: Vector2, b: Vector2, bend: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for i in 14:
			pts.append(_screen(_bezier(a, b, bend, float(i) / 13.0)))
		return pts

	func _bezier(a: Vector2, b: Vector2, bend: float, t: float) -> Vector2:
		var dir := b - a
		var n := Vector2(-dir.y, dir.x).normalized()
		var c := (a + b) * 0.5 + n * bend
		var u := 1.0 - t
		return u * u * a + 2.0 * u * t * c + t * t * b

	func _packed(pts: Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in pts:
			out.append(p)
		return out

	func _chaikin(pts: PackedVector2Array, passes: int) -> PackedVector2Array:
		var cur := pts
		for _p in passes:
			var nxt := PackedVector2Array()
			var n := cur.size()
			for i in n:
				var a: Vector2 = cur[i]
				var b: Vector2 = cur[(i + 1) % n]
				nxt.append(a.lerp(b, 0.25))
				nxt.append(a.lerp(b, 0.75))
			cur = nxt
		return cur
