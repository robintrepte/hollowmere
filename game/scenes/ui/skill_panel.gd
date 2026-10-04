class_name SkillPanel
extends PanelContainer
## Skill tree tab: a pannable, zoomable graph of six branches around the centre, with a detail
## pane for the selected skill. Drag or swipe to pan, wheel / pinch to zoom, arrows or the d-pad
## to hop between skills, Enter / A to learn the selected one.

signal closed

var embedded := false
var player: PlayerData
var _graph: SkillGraph
var _level: Label
var _xp: ProgressBar
var _points: Label
var _detail: VBoxContainer
var _sel := ""
var _confirm := ""

func _init(p: PlayerData = null) -> void:
	player = p if p else GameState.local_player()

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	v.add_child(head)
	_level = UITheme.label("", 11, UITheme.WOOD_DK)
	head.add_child(_level)
	_xp = ProgressBar.new()
	_xp.show_percentage = false
	_xp.custom_minimum_size = Vector2(90, 6)
	_xp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_xp)
	_points = UITheme.label("", 10, UITheme.LEAF.darkened(0.3))
	_points.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_points)
	head.add_child(UITheme.button("Center", func(): _graph.reset_view()))
	head.add_child(UITheme.button("Reset tree", _ask_respec))
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", UITheme.box(Color("#2a2024"), UITheme.OUTLINE, 2, 4, 0, false))
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.clip_contents = true
	body.add_child(frame)
	_graph = SkillGraph.new(player)
	_graph.selected.connect(_select)
	_graph.activated.connect(_on_activate)
	frame.add_child(_graph)
	var side := PanelContainer.new()
	side.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK, Color("#b09060"), 1, 3, 6, false))
	side.custom_minimum_size = Vector2(180, 0)
	body.add_child(side)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 4)
	side.add_child(_detail)
	EventBus.skills_changed.connect(_on_changed)
	EventBus.player_leveled.connect(func(_pid, _l): _refresh())
	_refresh()
	_select(_graph.first_open())

func on_tab_shown() -> void:
	_graph.grab_focus.call_deferred()

func _on_changed(pid: String) -> void:
	if pid == player.id:
		_refresh()

func _refresh() -> void:
	_level.text = tr("Level %d") % player.level
	var need := Skills.xp_to_next(player.level)
	_xp.max_value = need
	_xp.value = player.xp if player.level < Skills.MAX_LEVEL else need
	_xp.tooltip_text = tr("%s / %s XP") % [Num.group(player.xp), Num.group(need)]
	var free := Skills.points_free(player, GameState.world)
	_points.text = tr("%d skill points free") % free if free != 1 else tr("1 skill point free")
	_graph.queue_redraw()
	_show_detail()

func _select(id: String) -> void:
	if id != _sel:
		_confirm = ""
	_sel = id
	_graph.sel = id
	_graph.queue_redraw()
	_show_detail()

func _on_activate(id: String) -> void:
	_select(id)
	_learn()

func _show_detail() -> void:
	for c in _detail.get_children():
		c.queue_free()
	var n := Skills.node(_sel)
	if n.is_empty():
		_detail.add_child(_wrap(tr("Pick a skill to see what it does."), 9, UITheme.MUTED))
		return
	var br := Skills.branch(str(n.branch))
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	_detail.add_child(top)
	top.add_child(UITheme.icon_rect(Art.item(str(n.icon)), 28))
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(tv)
	tv.add_child(_wrap(Skills.node_name(n), 11, UITheme.WOOD_DK, 110))
	tv.add_child(UITheme.label(tr(str(br.get("name", ""))), 8, Color(str(br.get("color", "#888888"))).darkened(0.3)))
	var r := Skills.rank(player, _sel)
	var maxr := int(n.ranks)
	_detail.add_child(UITheme.label(tr("Rank %d / %d") % [r, maxr], 9, UITheme.INK))
	if r > 0:
		_detail.add_child(UITheme.label("Now", 8, UITheme.MUTED))
		for line in Skills.effect_lines(n, r):
			_detail.add_child(_wrap(line, 9, UITheme.INK))
	if r < maxr:
		_detail.add_child(UITheme.label("Next rank" if r > 0 else "Learn", 8, UITheme.MUTED))
		for line in Skills.effect_lines(n, r + 1):
			_detail.add_child(_wrap(line, 9, UITheme.LEAF.darkened(0.35)))
	if n.has("need"):
		_detail.add_child(_wrap(tr("Capstone: needs %d points in %s.") % [int(n.need), tr(str(br.get("name", "")))], 8, UITheme.MUTED))
	var why := Skills.blocker(player, GameState.world, _sel)
	if r >= maxr:
		_detail.add_child(UITheme.label("Mastered", 10, UITheme.COIN.darkened(0.3)))
		return
	if why != "":
		_detail.add_child(_wrap(why, 8, Color("#b04040")))
		return
	var b := UITheme.button(tr("Confirm: learn %s") % Skills.node_name(n) if _confirm == _sel else tr("Learn (1 point)"), _learn)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.custom_minimum_size.x = 0
	_detail.add_child(b)

## First press asks, the second one learns (so a stray click never spends a point).
func _learn() -> void:
	if not Skills.can_invest(player, GameState.world, _sel):
		Audio.sfx("error")
		return
	if _confirm != _sel:
		_confirm = _sel
		_show_detail()
		return
	_confirm = ""
	var res: Dictionary = Coop.act("invest_skill_act", [_sel])
	if res.ok:
		Audio.sfx("levelup")
		_graph.pulse(_sel)
	elif str(res.get("reason", "")) != "":
		EventBus.toast.emit(res.reason, "")
	_refresh()

func _ask_respec() -> void:
	if player.tree.is_empty():
		EventBus.toast.emit(tr("Your skill tree is already empty."), "")
		return
	var shell := _ui()
	if shell == null:
		return
	var cost := Skills.respec_cost(player)
	var c: int = await shell.ask(tr("Reset your whole skill tree for %s? You get every point back.") % CoinLabel.text(cost), ["Reset", "Keep"])
	if c != 0:
		return
	var res: Dictionary = Coop.act("respec_skills_act", [])
	if not res.ok and str(res.get("reason", "")) != "":
		EventBus.toast.emit(res.reason, "")
	_refresh()

func _ui() -> UIRoot:
	var n: Node = self
	while n:
		if n is MenuShell:
			return n.ui
		n = n.get_parent()
	return null

func _wrap(text: String, size: int, col: Color, w := 150) -> Label:
	var l := UITheme.label(text, size, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(w, 0)
	return l


## The node graph itself: draws every branch and node, and handles pan, zoom and picking.
class SkillGraph extends Control:
	signal selected(id: String)
	signal activated(id: String)

	const NODE_R := 13.0
	const ZOOM_MIN := 0.35
	const ZOOM_MAX := 1.8

	var player: PlayerData
	var sel := ""
	var zoom := 0.7
	var offset := Vector2.ZERO
	var _drag_from := Vector2.INF
	var _dragged := false
	var _touches: Dictionary = {}
	var _pinch_d := 0.0
	var _pulse_id := ""
	var _pulse_t := 0.0

	func _init(p: PlayerData) -> void:
		player = p
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		set_anchors_preset(Control.PRESET_FULL_RECT)
		clip_contents = true

	func reset_view() -> void:
		zoom = 0.7
		offset = Vector2.ZERO
		queue_redraw()

	func first_open() -> String:
		var best := ""
		for n in Skills.nodes():
			if Skills.can_invest(player, GameState.world, str(n.id)):
				if best == "" or int(n.tier) < int(Skills.node(best).tier):
					best = str(n.id)
		return best if best != "" else str(Skills.nodes()[0].id)

	func pulse(id: String) -> void:
		_pulse_id = id
		_pulse_t = 0.6

	func _process(delta: float) -> void:
		if _pulse_t > 0.0:
			_pulse_t -= delta
			queue_redraw()

	func _to_screen(pos: Vector2) -> Vector2:
		return size / 2.0 + offset + pos * zoom

	func _node_pos(n: Dictionary) -> Vector2:
		return Vector2(float(n.pos[0]), float(n.pos[1]))

	func _pick(at: Vector2) -> String:
		var best := ""
		var best_d := (NODE_R + 4.0) * maxf(zoom, 0.6)
		for n in Skills.nodes():
			var d := _to_screen(_node_pos(n)).distance_to(at)
			if d < best_d:
				best_d = d
				best = str(n.id)
		return best

	func _zoom_at(factor: float, at: Vector2) -> void:
		var nz := clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
		var world_at := (at - size / 2.0 - offset) / zoom
		zoom = nz
		offset = at - size / 2.0 - world_at * zoom
		queue_redraw()

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton:
			if ev.button_index == MOUSE_BUTTON_WHEEL_UP and ev.pressed:
				_zoom_at(1.1, ev.position)
				accept_event()
			elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN and ev.pressed:
				_zoom_at(1.0 / 1.1, ev.position)
				accept_event()
			elif ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
				if ev.pressed:
					grab_focus()
					_drag_from = ev.position
					_dragged = false
					if ev.double_click and ev.button_index == MOUSE_BUTTON_LEFT:
						var hit := _pick(ev.position)
						if hit != "":
							activated.emit(hit)
				else:
					if not _dragged and ev.button_index == MOUSE_BUTTON_LEFT:
						var id := _pick(ev.position)
						if id != "":
							selected.emit(id)
					_drag_from = Vector2.INF
				accept_event()
		elif ev is InputEventMouseMotion and _drag_from != Vector2.INF and _touches.size() < 2:
			if ev.position.distance_to(_drag_from) > 3.0 or _dragged:
				_dragged = true
				offset += ev.relative
				queue_redraw()
		elif ev is InputEventMagnifyGesture:
			_zoom_at(ev.factor, ev.position)
		elif ev is InputEventPanGesture:
			offset -= ev.delta * 8.0
			queue_redraw()
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
					_zoom_at(d / _pinch_d, _pinch_center())
				_pinch_d = d
		elif ev.is_action_pressed("ui_accept"):
			if sel != "":
				activated.emit(sel)
			accept_event()
		else:
			for dir in [["ui_left", Vector2.LEFT], ["ui_right", Vector2.RIGHT], ["ui_up", Vector2.UP], ["ui_down", Vector2.DOWN]]:
				if ev.is_action_pressed(dir[0]):
					_hop(dir[1])
					accept_event()
					return

	func _pinch_distance() -> float:
		var pts: Array = _touches.values()
		return (pts[0] as Vector2).distance_to(pts[1]) if pts.size() >= 2 else 0.0

	func _pinch_center() -> Vector2:
		var pts: Array = _touches.values()
		return ((pts[0] as Vector2) + (pts[1] as Vector2)) / 2.0 if pts.size() >= 2 else size / 2.0

	## Keyboard / d-pad: jump to the nearest node roughly in that direction and keep it in view.
	func _hop(dir: Vector2) -> void:
		var from := _node_pos(Skills.node(sel)) if sel != "" else Vector2.ZERO
		var best := ""
		var best_score := INF
		for n in Skills.nodes():
			var d := _node_pos(n) - from
			if d.length() < 1.0:
				continue
			var along := d.dot(dir)
			if along <= 0.0:
				continue
			var score := d.length() + absf(d.cross(dir)) * 2.0
			if score < best_score:
				best_score = score
				best = str(n.id)
		if best != "":
			selected.emit(best)
			var sp := _to_screen(_node_pos(Skills.node(best)))
			var margin := 40.0
			if not Rect2(Vector2(margin, margin), size - Vector2(margin, margin) * 2.0).has_point(sp):
				offset -= sp - size / 2.0
			queue_redraw()

	func _draw() -> void:
		var font := UITheme.font()
		var world := GameState.world
		var center := _to_screen(Vector2.ZERO)
		draw_circle(center, 22.0 * zoom, Color("#3a2e32"))
		# Branch labels and spokes
		for bid in Data.skill_branches:
			var b: Dictionary = Data.skill_branches[bid]
			var ang := deg_to_rad(float(b.angle) - 90.0)
			var col := Color(str(b.color))
			var tip := _to_screen(Vector2(cos(ang), sin(ang)) * 30.0)
			draw_line(center, tip, col.darkened(0.4), 2.0)
			var lp := _to_screen(Vector2(cos(ang), sin(ang)) * 535.0)
			var txt := tr(str(b.name))
			var fs := maxi(6, int(11 * zoom))
			var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, lp - Vector2(w / 2.0, -fs / 3.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		# Links
		for n in Skills.nodes():
			var a := _to_screen(_node_pos(n))
			var reqs: Array = n.get("req", [])
			var col := Color(str(Skills.branch(str(n.branch)).color))
			if reqs.is_empty():
				var ang := deg_to_rad(float(Skills.branch(str(n.branch)).angle) - 90.0)
				reqs = []
				draw_line(_to_screen(Vector2(cos(ang), sin(ang)) * 30.0), a, col.darkened(0.5), 2.0)
			for r in reqs:
				var other := Skills.node(str(r))
				var lit := Skills.rank(player, str(r)) > 0 and Skills.rank(player, str(n.id)) > 0
				draw_line(_to_screen(_node_pos(other)), a, col if lit else Color(0.35, 0.3, 0.32), 2.5 if lit else 1.5)
		# Nodes
		var nr := NODE_R * maxf(zoom, 0.55)
		for n in Skills.nodes():
			var id := str(n.id)
			var p := _to_screen(_node_pos(n))
			if p.x < -30 or p.y < -30 or p.x > size.x + 30 or p.y > size.y + 30:
				continue
			var col := Color(str(Skills.branch(str(n.branch)).color))
			var r := Skills.rank(player, id)
			var maxr := int(n.ranks)
			var open := Skills.blocker(player, world, id) == ""
			var reachable := Skills.reachable(player, id)
			var rad := nr * (1.25 if n.has("need") else 1.0)
			var bg := col.darkened(0.15) if r > 0 else (Color("#4a3e42") if reachable else Color("#2e2629"))
			draw_circle(p, rad + 2.0, UITheme.OUTLINE)
			draw_circle(p, rad, bg)
			var ring := UITheme.COIN if r >= maxr else (col if open else Color("#5a4e52"))
			draw_arc(p, rad, 0, TAU, 24, ring, 2.0 if (open or r > 0) else 1.0)
			if id == sel:
				draw_arc(p, rad + 4.0, 0, TAU, 24, Color.WHITE, 1.5)
			if id == _pulse_id and _pulse_t > 0.0:
				draw_arc(p, rad + 4.0 + (0.6 - _pulse_t) * 30.0, 0, TAU, 24, Color(1, 1, 0.6, _pulse_t / 0.6), 2.0)
			var tex := Art.item(str(n.icon))
			if tex:
				var isz := rad * 1.3
				draw_texture_rect(tex, Rect2(p - Vector2(isz, isz) / 2.0, Vector2(isz, isz)), false, Color(1, 1, 1, 1.0 if reachable else 0.35))
			if zoom >= 0.5:
				var rt := "%d/%d" % [r, maxr]
				var fs := maxi(6, int(8 * zoom))
				var w := font.get_string_size(rt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				draw_string_outline(font, p + Vector2(-w / 2.0, rad + fs + 1), rt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, UITheme.OUTLINE)
				draw_string(font, p + Vector2(-w / 2.0, rad + fs + 1), rt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.COIN if r >= maxr else UITheme.CREAM)
