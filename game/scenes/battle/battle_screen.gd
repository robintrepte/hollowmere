class_name BattleScreen
extends CanvasLayer
## Classic 1v1 battle presentation on top of BattleEngine. `await run()` returns
## {result, befriended: Creature, foe_species}.

signal _picked(action: Dictionary)
signal _advance

const FOE_POS := Vector2(470, 156)
const ME_POS := Vector2(170, 272)
const STATUS_TAG := {"burn": ["BRN", "#e86a3a"], "soak": ["SOK", "#4a9ae8"], "root": ["ROT", "#6ab04a"], "daze": ["DAZ", "#c070e0"], "sleep": ["SLP", "#8a8aa0"]}

var setup: Dictionary
var engine: BattleEngine
var player: PlayerData
var root: Control
var _flash: ColorRect
var _foe_spr: Sprite2D
var _me_spr: Sprite2D
var _foe_box: Dictionary = {}
var _me_box: Dictionary = {}
var _msg: Label
var _cmd: GridContainer
var _overlay: PanelContainer
var _typing := false
var _hp_shown := [0.0, 0.0]
var _wx: Control
var _wx_kind := ""
var _wx_parts: Array = []
var _wx_flash := 0.0

func _init(s: Dictionary = {}) -> void:
	setup = s
	layer = 25

func _ready() -> void:
	player = GameState.local_player()
	root = Control.new()
	root.theme = UITheme.theme()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var bg := TextureRect.new()
	bg.texture = Art.backdrop(setup.get("backdrop", "grass"))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	root.add_child(bg)
	var plat := Control.new()
	plat.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plat.draw.connect(func():
		for p in [[FOE_POS, 72.0], [ME_POS, 88.0]]:
			plat.draw_set_transform(p[0] + Vector2(0, -4), 0.0, Vector2(1.0, 0.28))
			plat.draw_circle(Vector2.ZERO, p[1], Color(0.1, 0.12, 0.05, 0.35))
			plat.draw_circle(Vector2.ZERO, p[1] - 6.0, Color(0.85, 0.9, 0.6, 0.25))
		plat.draw_set_transform(Vector2.ZERO))
	root.add_child(plat)
	_wx = Control.new()
	_wx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wx.draw.connect(_draw_weather)
	_foe_spr = _make_sprite(2.0)
	_me_spr = _make_sprite(2.5)
	_me_spr.flip_h = true
	root.add_child(_wx)
	_foe_box = _info_box(Vector2(16, 18), false)
	_me_box = _info_box(Vector2(404, 196), true)
	# Bottom bar: message + commands
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", UITheme.parchment(8))
	bar.anchor_top = 1
	bar.anchor_bottom = 1
	bar.anchor_right = 1
	bar.offset_left = 6
	bar.offset_right = -6
	bar.offset_top = -84
	bar.offset_bottom = -6
	root.add_child(bar)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	bar.add_child(h)
	_msg = UITheme.label("", 12, UITheme.INK)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(_msg)
	_cmd = GridContainer.new()
	_cmd.columns = 2
	_cmd.custom_minimum_size = Vector2(250, 0)
	_cmd.add_theme_constant_override("h_separation", 4)
	_cmd.add_theme_constant_override("v_separation", 4)
	_cmd.visible = false
	h.add_child(_cmd)
	_flash = ColorRect.new()
	_flash.color = Color.WHITE
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.modulate.a = 0.0
	root.add_child(_flash)

func _set_weather(w: String) -> void:
	_wx_kind = w
	_wx_parts.clear()
	var n: int = {"rain": 90, "storm": 120, "snow": 70, "fog": 6, "sun": 14}.get(w, 0)
	for i in n:
		_wx_parts.append(Vector3(randf() * 640.0, randf() * 360.0, randf()))
	_wx.queue_redraw()

func _process(delta: float) -> void:
	if _wx_kind == "":
		return
	for i in _wx_parts.size():
		var p: Vector3 = _wx_parts[i]
		match _wx_kind:
			"rain", "storm":
				p.y += delta * (420.0 + p.z * 200.0)
				p.x -= delta * (60.0 if _wx_kind == "rain" else 160.0)
			"snow":
				p.y += delta * (30.0 + p.z * 30.0)
				p.x += sin(p.y * 0.05 + p.z * 6.0) * delta * 20.0
			"fog":
				p.x += delta * (8.0 + p.z * 10.0)
			"sun":
				p.y -= delta * (6.0 + p.z * 8.0)
		if p.y > 370.0:
			p.y = -10.0
		elif p.y < -10.0:
			p.y = 370.0
		if p.x < -60.0:
			p.x = 700.0
		elif p.x > 700.0:
			p.x = -60.0
		_wx_parts[i] = p
	if _wx_kind == "storm":
		_wx_flash = maxf(0.0, _wx_flash - delta * 2.5)
		if randf() < delta * 0.25:
			_wx_flash = 0.6
			Audio.sfx("thunder")
	_wx.queue_redraw()

func _draw_weather() -> void:
	match _wx_kind:
		"rain", "storm":
			_wx.draw_rect(Rect2(0, 0, 640, 360), Color(0.1, 0.15, 0.3, 0.18))
			for p: Vector3 in _wx_parts:
				var len := 7.0 + p.z * 6.0
				_wx.draw_line(Vector2(p.x, p.y), Vector2(p.x + len * 0.25, p.y - len), Color(0.75, 0.85, 1.0, 0.45 + p.z * 0.3), 1.0)
			if _wx_flash > 0.0:
				_wx.draw_rect(Rect2(0, 0, 640, 360), Color(1, 1, 0.9, _wx_flash * 0.5))
		"snow":
			_wx.draw_rect(Rect2(0, 0, 640, 360), Color(0.85, 0.9, 1.0, 0.12))
			for p in _wx_parts:
				_wx.draw_rect(Rect2(floorf(p.x), floorf(p.y), 2 if p.z > 0.5 else 1, 2 if p.z > 0.5 else 1), Color(1, 1, 1, 0.85))
		"fog":
			_wx.draw_rect(Rect2(0, 0, 640, 360), Color(0.85, 0.88, 0.9, 0.28))
			for p in _wx_parts:
				_wx.draw_set_transform(Vector2(p.x, 120.0 + p.z * 170.0), 0.0, Vector2(1.0, 0.3))
				_wx.draw_circle(Vector2.ZERO, 90.0 + p.z * 50.0, Color(0.95, 0.95, 0.97, 0.22))
			_wx.draw_set_transform(Vector2.ZERO)
		"sun":
			_wx.draw_rect(Rect2(0, 0, 640, 360), Color(1.0, 0.8, 0.4, 0.14))
			for p in _wx_parts:
				_wx.draw_circle(Vector2(p.x, p.y), 1.5 + p.z, Color(1, 0.95, 0.6, 0.5))

func _make_sprite(sc: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.centered = false
	s.offset = Vector2(-32, -62)
	s.scale = Vector2(sc, sc)
	root.add_child(s)
	return s

func _info_box(pos: Vector2, mine: bool) -> Dictionary:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.parchment(6))
	p.position = pos
	p.custom_minimum_size = Vector2(220, 0)
	root.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	p.add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var name := UITheme.label("", 12, UITheme.WOOD_DK)
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name)
	var status := UITheme.label("", 9, Color.WHITE, true)
	top.add_child(status)
	var pips := UITheme.label("", 8, UITheme.WOOD)
	top.add_child(pips)
	var lvl := UITheme.label("", 10, UITheme.INK)
	top.add_child(lvl)
	var hp := ProgressBar.new()
	hp.show_percentage = false
	hp.custom_minimum_size = Vector2(0, 7)
	hp.max_value = 1.0
	hp.step = 0.0
	v.add_child(hp)
	var d := {"panel": p, "name": name, "lvl": lvl, "hp": hp, "status": status, "pips": pips}
	if mine:
		var nums := UITheme.label("", 9, UITheme.INK)
		nums.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v.add_child(nums)
		var xp := ProgressBar.new()
		xp.show_percentage = false
		xp.custom_minimum_size = Vector2(0, 3)
		xp.max_value = 1.0
		xp.step = 0.0
		xp.add_theme_stylebox_override("fill", UITheme.box(Color("#5aa8e8"), Color(0, 0, 0, 0), 0, 1, 0, false))
		v.add_child(xp)
		d.nums = nums
		d.xp = xp
	return d

# --- Box + sprite refresh ------------------------------------------------------------------

func _refresh_box(side: int, animate_hp: bool = false) -> void:
	var c := engine.active(side)
	var b: Dictionary = _me_box if side == 0 else _foe_box
	b.name.text = ("★ " if c.starry else "") + c.display_name()
	b.lvl.text = "Lv%d" % c.level
	var team: Array = engine.sides[side].team
	var pips := ""
	if team.size() > 1:
		for m in team:
			pips += "○" if m.is_fainted() else "●"
	b.pips.text = pips + (" " if pips != "" else "")
	var tag: Array = STATUS_TAG.get(c.status, ["", "#000000"])
	b.status.text = tag[0]
	b.status.add_theme_color_override("font_outline_color", Color(tag[1]))
	b.status.add_theme_constant_override("outline_size", 6)
	var frac := float(c.hp) / float(maxi(1, c.max_hp()))
	if not animate_hp:
		_hp_shown[side] = frac
		_set_hp_bar(side, frac)
	if side == 0:
		b.nums.text = "%d / %d" % [c.hp, c.max_hp()]
		var lo := Creature.xp_for_level(c.level)
		var hi := Creature.xp_for_level(c.level + 1)
		b.xp.value = clampf(float(c.xp - lo) / float(maxi(1, hi - lo)), 0.0, 1.0)

func _set_hp_bar(side: int, frac: float) -> void:
	var b: Dictionary = _me_box if side == 0 else _foe_box
	b.hp.value = frac
	var col := Color("#5ccf5c") if frac > 0.5 else (Color("#f0c040") if frac > 0.2 else Color("#e84a3a"))
	b.hp.add_theme_stylebox_override("fill", UITheme.box(col, Color(0, 0, 0, 0), 0, 2, 0, false))

func _tween_hp(side: int, to_frac: float) -> void:
	var from: float = _hp_shown[side]
	_hp_shown[side] = to_frac
	var tw := create_tween()
	tw.tween_method(func(f: float): _set_hp_bar(side, f), from, to_frac, clampf(absf(from - to_frac) * 1.2, 0.15, 0.8))
	await tw.finished

func _sprite(side: int) -> Sprite2D:
	return _me_spr if side == 0 else _foe_spr

func _show_creature(side: int, pop: bool) -> void:
	var c := engine.active(side)
	var s := _sprite(side)
	s.texture = Art.creature(c.species_id)
	s.modulate = Color(1.2, 1.15, 0.85) if c.starry else Color.WHITE
	s.position = ME_POS if side == 0 else FOE_POS
	var sc := 2.5 if side == 0 else 2.0
	s.visible = true
	if pop:
		s.scale = Vector2(0.1, 0.1)
		var tw := create_tween()
		tw.tween_property(s, "scale", Vector2(sc, sc), 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		await tw.finished
	else:
		s.scale = Vector2(sc, sc)
	_refresh_box(side)

# --- Main loop -------------------------------------------------------------------------

func run() -> Dictionary:
	if setup.get("kind", "") == "pvp":
		return await _run_pvp()
	var foe_team: Array = setup.get("team", [])
	var kind: int = BattleEngine.Kind.TRAINER if setup.get("kind", "wild") != "wild" else BattleEngine.Kind.WILD
	engine = BattleEngine.new(player.party, foe_team, kind, randi(), setup.get("foe_name", ""), player.name)
	engine.set_field_weather(setup.get("weather", ""))
	engine.sides[1].items = setup.get("items", {}).duplicate()
	if setup.has("ai"):
		engine.sides[1].ai_level = int(setup.ai)
	for c in foe_team:
		GameState.dex_mark(c.species_id)
	Audio.music("battle" if kind == BattleEngine.Kind.WILD else "trainer", 0.3)
	Audio.sfx("encounter")
	_foe_spr.visible = false
	_me_spr.visible = false
	_foe_box.panel.visible = false
	_me_box.panel.visible = false
	await _flash_screen(3)
	if kind == BattleEngine.Kind.WILD:
		_foe_box.panel.visible = true
		await _show_creature(1, true)
	await _play(engine.start())
	while not engine.is_over():
		if engine.needs_switch(1):
			await _play(engine.force_switch(1, engine.ai_replacement(1)))
			continue
		if engine.needs_switch(0):
			var idx: int = await _choose_party(true)
			await _play(engine.force_switch(0, idx))
			continue
		var a0: Dictionary = await _choose_action()
		if engine.is_over():
			break
		var a1 := BattleAI.choose_action(engine, 1)
		await _play(engine.submit(a0, a1))
	await _after_battle()
	return {"result": engine.result, "befriended": engine.befriended, "foe_species": foe_team[0].species_id if foe_team.size() > 0 else ""}

# --- Friendly battles -------------------------------------------------------------------------
## The challenger (host_side) owns the engine. The opponent shows mirrored events and snaps to
## the challenger's snapshot after every step. Teams are copies, so nothing carries over.

signal _remote_msg

var _remote_q: Array = []
var _opponent := ""

func _run_pvp() -> Dictionary:
	_opponent = str(setup.opponent)
	var host: bool = setup.get("host_side", false)
	var mine: Array = []
	for c: Creature in player.party:
		var copy := Creature.from_dict(c.to_dict())
		copy.heal_full()
		mine.append(copy)
	var theirs: Array = []
	for d in setup.team:
		var c2 := Creature.from_dict(d)
		c2.heal_full()
		theirs.append(c2)
	engine = BattleEngine.new(mine, theirs, BattleEngine.Kind.PVP, int(setup.seed), str(setup.name), player.name)
	engine.set_field_weather(setup.get("weather", ""))
	Coop.pvp_action.connect(_on_remote)
	Net.peer_left.connect(_on_peer_left)
	Audio.music("trainer", 0.3)
	Audio.sfx("encounter")
	_foe_spr.visible = false
	_me_spr.visible = false
	_foe_box.panel.visible = false
	_me_box.panel.visible = false
	await _flash_screen(3)
	if host:
		await _host_pvp()
	else:
		await _guest_pvp()
	Coop.pvp_action.disconnect(_on_remote)
	Net.peer_left.disconnect(_on_peer_left)
	match engine.result:
		"win":
			await _say("You won the friendly battle!")
		"lose":
			await _say("%s won the friendly battle. Good match!" % setup.name)
	return {"result": "pvp_" + engine.result, "befriended": null, "foe_species": ""}

func _send(msg: Dictionary) -> void:
	Coop.send_pvp_action(_opponent, msg)

func _on_remote(msg: Dictionary) -> void:
	_remote_q.append(msg)
	_remote_msg.emit()

func _on_peer_left(pid: String) -> void:
	if pid == _opponent:
		_on_remote({"op": "left"})

## Next message from the opponent (optionally of one op); "left" always wins.
func _next_remote(op: String = "") -> Dictionary:
	while true:
		for i in _remote_q.size():
			var m: Dictionary = _remote_q[i]
			if m.get("op", "") == "left" or op == "" or m.get("op", "") == op:
				_remote_q.remove_at(i)
				return m
		await _remote_msg
	return {}

func _opponent_left() -> void:
	if engine.result == "":
		engine.result = "win"
	await _say("%s left the battle." % setup.name)

func _host_step(ev: Array) -> void:
	_send({"op": "ev", "ev": BattleEngine.mirror_events(ev), "st": engine.snapshot()})
	await _play(ev)

func _host_pvp() -> void:
	await _host_step(engine.start())
	while not engine.is_over():
		if engine.needs_switch(1):
			_send({"op": "force"})
			_msg.text = "Waiting for %s..." % setup.name
			var f := await _next_remote("force")
			if f.op == "left":
				await _opponent_left()
				return
			await _host_step(engine.force_switch(1, int(f.i)))
			continue
		if engine.needs_switch(0):
			var idx: int = await _choose_party(true)
			await _host_step(engine.force_switch(0, idx))
			continue
		_send({"op": "turn"})
		var a0: Dictionary = await _choose_action()
		_msg.text = "Waiting for %s..." % setup.name
		var m := await _next_remote("act")
		if m.op == "left":
			await _opponent_left()
			return
		await _host_step(engine.submit(a0, m.a))

func _guest_pvp() -> void:
	while not engine.is_over():
		var m := await _next_remote()
		match str(m.get("op", "")):
			"left":
				await _opponent_left()
				return
			"ev":
				for e: Dictionary in m.ev:
					_apply_event_state(e)
					await _play([e])
				engine.apply_snapshot(m.st, true)
				_refresh_box(0)
				_refresh_box(1)
			"force":
				var idx: int = await _choose_party(true)
				_send({"op": "force", "i": idx})
				_msg.text = "Waiting for %s..." % setup.name
			"turn":
				var a: Dictionary = await _choose_action()
				_send({"op": "act", "a": a})
				_msg.text = "Waiting for %s..." % setup.name

## Keeps the display-only engine in step while mirrored events play.
func _apply_event_state(e: Dictionary) -> void:
	var side := int(e.get("side", 0))
	match str(e.t):
		"switch":
			engine.sides[side].active = int(e.index)
		"damage", "heal":
			engine.active(side).hp = int(e.hp)
		"status":
			engine.active(side).status = str(e.status)
		"faint":
			engine.active(side).hp = 0
		"end":
			engine.result = str(e.result)

func _after_battle() -> void:
	match engine.result:
		"win":
			if setup.get("kind", "wild") != "wild":
				var reward := int(setup.get("reward", 0))
				await _say("You beat %s!" % setup.get("foe_name", "the trainer"))
				for l in setup.get("lose_lines", []):
					await _say(l)
				if reward > 0:
					GameState.earn(reward)
					Audio.sfx("coin")
					await _say("You got %dg for winning." % reward)
		"lose":
			await _say("Your Wildlings are all worn out...")
			await _say("You hurry back home to rest.")
	# Evolutions
	for c in player.party:
		if not c.is_fainted() and c.can_evolve() != "":
			var before: String = c.display_name()
			_me_spr.texture = Art.creature(c.species_id)
			_me_spr.visible = true
			_me_spr.position = ME_POS
			await _say("What? %s is evolving!" % before)
			for i in 6:
				_me_spr.modulate = Color(3, 3, 3) if i % 2 == 0 else Color.WHITE
				await get_tree().create_timer(0.18 - i * 0.02).timeout
			c.evolve()
			_me_spr.texture = Art.creature(c.species_id)
			_me_spr.modulate = Color.WHITE
			Audio.sfx("levelup")
			await _flash_screen(1)
			await _say("%s evolved into %s!" % [before, Data.get_species(c.species_id).name])
			GameState.dex_mark(c.species_id, true, c.starry)
	EventBus.party_changed.emit()

# --- Event playback ----------------------------------------------------------------------

func _play(events: Array) -> void:
	for e in events:
		match e.t:
			"text":
				await _say(e.msg)
			"switch":
				if e.side == 0:
					_me_box.panel.visible = true
				else:
					_foe_box.panel.visible = true
				await _show_creature(int(e.side), true)
			"move":
				await _lunge(int(e.side), e.cat)
			"damage":
				await _hit(int(e.side), e)
			"miss":
				Audio.sfx("miss")
			"weather":
				_set_weather(str(e.w))
				if e.w == "storm":
					_wx_flash = 0.8
			"item":
				Audio.sfx("open")
			"heal":
				Audio.sfx("heal")
				if int(e.side) == 0:
					_me_box.nums.text = "%d / %d" % [int(e.hp), int(e.max)]
				await _tween_hp(int(e.side), float(e.hp) / float(maxi(1, int(e.max))))
			"stat":
				Audio.sfx("sparkle" if int(e.n) > 0 else "miss")
				var s := _sprite(int(e.side))
				var tw := create_tween()
				var tint := Color(1.3, 1.3, 0.8) if int(e.n) > 0 else Color(0.7, 0.7, 1.2)
				tw.tween_property(s, "modulate", tint, 0.15)
				tw.tween_property(s, "modulate", Color.WHITE, 0.25)
				await tw.finished
			"status":
				_refresh_box(int(e.side), true)
			"faint":
				Audio.sfx("faint")
				var fs := _sprite(int(e.side))
				var tw2 := create_tween().set_parallel(true)
				tw2.tween_property(fs, "position:y", fs.position.y + 40, 0.4)
				tw2.tween_property(fs, "modulate:a", 0.0, 0.4)
				await tw2.finished
				fs.visible = false
				fs.modulate.a = 1.0
			"befriend":
				await _befriend_anim(int(e.shakes), bool(e.success))
			"xp":
				if engine.active(0).uid == e.uid:
					await get_tree().create_timer(0.1).timeout
					var c := engine.active(0)
					var lo := Creature.xp_for_level(c.level)
					var hi := Creature.xp_for_level(c.level + 1)
					var tw3 := create_tween()
					tw3.tween_property(_me_box.xp, "value", clampf(float(c.xp - lo) / float(maxi(1, hi - lo)), 0.0, 1.0), 0.5)
					await tw3.finished
			"level":
				Audio.sfx("levelup")
				if engine.active(0).uid == e.get("uid", ""):
					_refresh_box(0)

func _say(text: String) -> void:
	_cmd.visible = false
	_msg.text = text
	_msg.visible_characters = 0
	_typing = true
	var n := text.length()
	var t := 0.0
	while _msg.visible_characters < n and _typing:
		await get_tree().process_frame
		t += get_process_delta_time()
		_msg.visible_characters = mini(n, int(t * 70.0))
	_msg.visible_characters = -1
	_typing = false
	var timer := get_tree().create_timer(0.9)
	var done := [false]
	timer.timeout.connect(func(): if not done[0]: _advance.emit())
	await _advance
	done[0] = true

func _unhandled_input(event: InputEvent) -> void:
	var press: bool = event.is_action_pressed("interact") or event.is_action_pressed("ui_accept") or event.is_action_pressed("use_tool")
	if press and not _cmd.visible:
		if _typing:
			_typing = false
		else:
			_advance.emit()
		get_viewport().set_input_as_handled()

func _lunge(side: int, cat: String) -> void:
	var s := _sprite(side)
	var home := s.position
	var dir := Vector2(30, -14) if side == 0 else Vector2(-30, 14)
	if cat == "status":
		Audio.sfx("sparkle")
		var tw0 := create_tween()
		tw0.tween_property(s, "position:y", home.y - 10, 0.1)
		tw0.tween_property(s, "position:y", home.y, 0.12)
		await tw0.finished
		return
	var tw := create_tween()
	tw.tween_property(s, "position", home + dir, 0.09)
	tw.tween_property(s, "position", home, 0.14)
	await tw.finished

func _hit(side: int, e: Dictionary) -> void:
	Audio.sfx("super_hit" if float(e.eff) > 1.0 or e.get("crit", false) else "hit")
	var s := _sprite(side)
	var home := s.position
	if Settings.screen_shake and (float(e.eff) > 1.0 or e.get("crit", false)):
		_shake_root()
	for i in 3:
		s.modulate.a = 0.2
		await get_tree().create_timer(0.05).timeout
		s.modulate.a = 1.0
		await get_tree().create_timer(0.05).timeout
	s.position = home
	if side == 0:
		_me_box.nums.text = "%d / %d" % [int(e.hp), int(e.max)]
	await _tween_hp(side, float(e.hp) / float(maxi(1, int(e.max))))

func _shake_root() -> void:
	var tw := create_tween()
	for i in 4:
		tw.tween_property(root, "position", Vector2(randf_range(-4, 4), randf_range(-3, 3)), 0.03)
	tw.tween_property(root, "position", Vector2.ZERO, 0.03)

func _flash_screen(times: int) -> void:
	for i in times:
		var tw := create_tween()
		tw.tween_property(_flash, "modulate:a", 0.9, 0.06)
		tw.tween_property(_flash, "modulate:a", 0.0, 0.12)
		await tw.finished

func _befriend_anim(shakes: int, success: bool) -> void:
	var icon := Sprite2D.new()
	icon.texture = Art.item(setup.get("_last_item", "lure_charm"))
	icon.scale = Vector2(2, 2)
	icon.position = ME_POS + Vector2(40, -60)
	root.add_child(icon)
	var target := FOE_POS + Vector2(0, -24)
	var tw := create_tween()
	tw.tween_method(func(t: float):
		icon.position = (ME_POS + Vector2(40, -60)).lerp(target, t) + Vector2(0, -80.0 * sin(t * PI))
		icon.rotation = t * TAU, 0.0, 1.0, 0.5)
	await tw.finished
	icon.rotation = 0.0
	var tw2 := create_tween()
	tw2.tween_property(_foe_spr, "scale", Vector2(0.05, 0.05), 0.2)
	await tw2.finished
	_foe_spr.visible = false
	var tw2b := create_tween()
	tw2b.tween_property(icon, "position:y", FOE_POS.y - 8, 0.2).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	await tw2b.finished
	for i in shakes:
		await get_tree().create_timer(0.35).timeout
		Audio.sfx("charm_shake")
		var tw3 := create_tween()
		tw3.tween_property(icon, "rotation", 0.35, 0.08)
		tw3.tween_property(icon, "rotation", -0.35, 0.12)
		tw3.tween_property(icon, "rotation", 0.0, 0.08)
		await tw3.finished
	await get_tree().create_timer(0.4).timeout
	if success:
		Audio.sfx("befriend")
		var p := CPUParticles2D.new()
		p.position = icon.position
		p.amount = 24
		p.one_shot = true
		p.explosiveness = 0.9
		p.spread = 180.0
		p.initial_velocity_min = 40.0
		p.initial_velocity_max = 90.0
		p.gravity = Vector2(0, 60)
		p.color = Color("#fff3a0")
		p.scale_amount_min = 2.0
		p.scale_amount_max = 3.0
		root.add_child(p)
		p.emitting = true
		await get_tree().create_timer(0.6).timeout
	else:
		icon.queue_free()
		_foe_spr.visible = true
		var tw4 := create_tween()
		tw4.tween_property(_foe_spr, "scale", Vector2(2, 2), 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		await tw4.finished

# --- Choosing actions --------------------------------------------------------------------

func _clear_cmd() -> void:
	for c in _cmd.get_children():
		c.queue_free()

func _cmd_button(text: String, cb: Callable, col: Color = UITheme.WOOD) -> Button:
	var b := UITheme.button(text, cb)
	b.custom_minimum_size = Vector2(122, 30)
	if col != UITheme.WOOD:
		for st in ["normal", "hover", "pressed", "focus"]:
			var sb := UITheme.box(col if st != "hover" else col.lightened(0.15), UITheme.OUTLINE, 2, 3, 4)
			b.add_theme_stylebox_override(st, sb)
	_cmd.add_child(b)
	return b

func _choose_action() -> Dictionary:
	_show_main_menu()
	var a: Dictionary = await _picked
	_cmd.visible = false
	return a

func _show_main_menu() -> void:
	_clear_cmd()
	_cmd.visible = true
	_msg.text = "What will %s do?" % engine.active(0).display_name()
	_msg.visible_characters = -1
	var f := _cmd_button("Fight", _show_moves)
	_cmd_button("Bag", _show_bag)
	_cmd_button("Party", func():
		var i: int = await _choose_party(false)
		if i >= 0:
			_picked.emit({"k": "switch", "i": i})
		else:
			_show_main_menu())
	var pvp: bool = setup.get("kind", "") == "pvp"
	_cmd_button("Forfeit" if pvp else "Run", func():
		if pvp:
			_confirm_forfeit()
		elif setup.get("kind", "wild") != "wild":
			_msg.text = "You can't run from a trainer battle!"
			Audio.sfx("error")
		else:
			_picked.emit({"k": "run"}))
	f.call_deferred("grab_focus")

func _confirm_forfeit() -> void:
	_clear_cmd()
	_msg.text = "Forfeit the friendly battle?"
	_cmd_button("Forfeit", func(): _picked.emit({"k": "run"}), UITheme.HEART.darkened(0.3))
	_cmd_button("Keep going", _show_main_menu).call_deferred("grab_focus")

func _show_moves() -> void:
	_clear_cmd()
	var c := engine.active(0)
	var first: Button = null
	for i in c.moves.size():
		var m: Dictionary = Data.get_move(c.moves[i])
		var label := "%s\n%s%s" % [m.name, Data.type_name(m.type), (" · %d" % int(m.power)) if int(m.power) > 0 else " · status"]
		var idx := i
		var b := _cmd_button(label, func(): _picked.emit({"k": "move", "i": idx}), Data.type_color(m.type).darkened(0.25))
		b.add_theme_font_size_override("font_size", 10)
		b.tooltip_text = m.get("desc", "")
		var eff := Data.type_mult(m.type, engine.active(1).types()) if int(m.power) > 0 else 1.0
		if eff > 1.0:
			b.text += " ▲"
		elif eff < 1.0:
			b.text += " ▼"
		if first == null:
			first = b
	if c.moves.is_empty():
		_cmd_button("Struggle", func(): _picked.emit({"k": "move", "i": 0}))
	_cmd_button("Back", _show_main_menu)
	if first:
		first.call_deferred("grab_focus")

func _bag_items() -> Array:
	var out: Array = []
	var wild: bool = setup.get("kind", "wild") == "wild"
	var seen := {}
	for e in player.inventory.all_entries():
		if seen.has(e.id):
			continue
		var it: Dictionary = Data.get_item(e.id)
		var befriend: bool = it.has("charm") or it.get("cat", "") == "treat" or (it.has("treat") and it.get("cat", "") in ["food", "crop", "fruit", "forage"])
		var medicine: bool = it.has("heal") or it.has("revive") or it.get("cure", false)
		if medicine or (befriend and wild):
			seen[e.id] = true
			out.append({"id": e.id, "n": player.inventory.count(e.id), "befriend": befriend and not medicine})
	out.sort_custom(func(a, b): return int(a.befriend) > int(b.befriend))
	return out

func _show_bag() -> void:
	var pvp: bool = setup.get("kind", "") == "pvp"
	var items := [] if pvp else _bag_items()
	var p := _list_overlay("Bag")
	var v: VBoxContainer = p.get_meta("list")
	if pvp:
		v.add_child(UITheme.label("Items stay in the bag during friendly battles.", 10, UITheme.MUTED))
	elif items.is_empty():
		v.add_child(UITheme.label("Nothing useful to use here.", 10, UITheme.MUTED))
	for it in items:
		var row := HBoxContainer.new()
		v.add_child(row)
		row.add_child(UITheme.icon_rect(Art.item(it.id), 16))
		var text := "%s  x%d" % [Data.item_name(it.id), int(it.n)]
		if it.befriend:
			text += "   (%d%%)" % roundi(engine.befriend_chance(it.id) * 100.0)
		var id: String = it.id
		var b := UITheme.button(text, func():
			_close_overlay()
			player.inventory.remove(id, 1)
			EventBus.inventory_changed.emit()
			if it.befriend:
				setup["_last_item"] = id
				_picked.emit({"k": "befriend", "id": id})
			else:
				var target: int = engine.sides[0].active
				if Data.get_item(id).has("revive"):
					for i in player.party.size():
						if player.party[i].is_fainted():
							target = i
							break
				_picked.emit({"k": "item", "id": id, "target": target}))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	v.add_child(UITheme.button("Back", func(): _close_overlay(); _show_main_menu()))

func _choose_party(forced: bool) -> int:
	var p := _list_overlay("Choose a Wildling" if forced else "Party")
	var v: VBoxContainer = p.get_meta("list")
	var result := [-2]
	var team: Array = engine.sides[0].team
	for i in team.size():
		var c: Creature = team[i]
		var row := HBoxContainer.new()
		v.add_child(row)
		row.add_child(UITheme.icon_rect(Art.creature(c.species_id, true), 32))
		var b := UITheme.button("%s  Lv%d   HP %d/%d%s" % [c.display_name(), c.level, c.hp, c.max_hp(), "  (out)" if i == engine.sides[0].active else ""], func():
			result[0] = i
			_advance.emit())
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = c.is_fainted() or (i == engine.sides[0].active and not engine.active(0).is_fainted())
		row.add_child(b)
	if not forced:
		v.add_child(UITheme.button("Back", func(): result[0] = -1; _advance.emit()))
	while result[0] == -2:
		await _advance
	_close_overlay()
	return result[0]

func _list_overlay(title: String) -> PanelContainer:
	_close_overlay()
	_cmd.visible = false
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.parchment(8))
	p.anchor_left = 0.5
	p.anchor_right = 0.5
	p.anchor_top = 0.5
	p.anchor_bottom = 0.5
	p.offset_left = -160
	p.offset_right = 160
	p.offset_top = -130
	p.offset_bottom = 90
	root.add_child(p)
	var v := VBoxContainer.new()
	p.add_child(v)
	v.add_child(UITheme.label(title, 13, UITheme.WOOD_DK))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	p.set_meta("list", list)
	_overlay = p
	return p

func _close_overlay() -> void:
	if is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
