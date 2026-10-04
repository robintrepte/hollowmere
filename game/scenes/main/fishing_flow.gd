class_name FishingFlow
extends Node
## Rod in hand: hold to charge a cast, wait for the bite, tap to hook, then keep the fish
## inside the catch zone by holding the tool button. The host rolls the catch (see GameState).

enum State { IDLE, CHARGE, CAST, WAIT, BITE, FIGHT, DONE }

const BITE_WINDOW := 1.0
const CHARGE_TIME := 0.9
const FILL := 0.34
const DRAIN := 0.24
const TREASURE_FILL := 0.7

var ctl: Controller
var state := State.IDLE
var _power := 0.0
var _power_dir := 1.0
var _t := 0.0
var _held := false
var _tile := Vector2i.ZERO
var _hook: Dictionary = {}
var _line: FishingLine
var _ui: CanvasLayer
var _game: ReelGame
var _card: Control

func _init(c: Controller) -> void:
	ctl = c

func active() -> bool:
	return state != State.IDLE

## The rod was used: start charging (the tool button is still held).
func start() -> void:
	if state != State.IDLE:
		return
	state = State.CHARGE
	_power = 0.0
	_power_dir = 1.0
	_held = true
	ctl.player.locked = true
	_line = FishingLine.new()
	_line.flow = self
	ctl.world.add_child(_line)
	_ui = CanvasLayer.new()
	_ui.layer = 8
	add_child(_ui)

func _process(delta: float) -> void:
	if state == State.IDLE:
		return
	var down := Input.is_action_pressed("use_tool")
	var pressed := down and not _held
	_held = down
	if state == State.DONE:
		if not down:
			state = State.IDLE
			ctl.player.locked = false
		return
	if state in [State.WAIT, State.BITE, State.CHARGE] and Input.is_action_just_pressed("ui_cancel"):
		_finish("missed" if state != State.CHARGE else "")
		return
	_t += delta
	match state:
		State.CHARGE:
			_power += _power_dir * delta / CHARGE_TIME
			if _power >= 1.0 or _power <= 0.0:
				_power_dir = -_power_dir
				_power = clampf(_power, 0.0, 1.0)
			if not down:
				_cast()
		State.WAIT:
			if pressed:
				EventBus.toast.emit(tr("You reeled in too early."), "")
				_finish("missed")
			elif _t >= float(_hook.bite):
				_bite()
		State.BITE:
			if pressed or Settings.easy_fishing:
				_hooked()
			elif _t >= BITE_WINDOW:
				EventBus.toast.emit(tr("It got away..."), "")
				_finish("missed")
		State.FIGHT:
			if _game and _game.result != "":
				var res := _game.result
				_finish(res, _game.treasure_got)
	if _line:
		_line.queue_redraw()

func power() -> float:
	return _power

func _cast() -> void:
	state = State.CAST
	var me := GameState.to_tile(ctl.player.position)
	var dir := _cast_dir(me)
	var rod := GameState.local_player().tool_level("fishing_rod")
	var reach := 1 + int(round(_power * float(Fishing.cast_range(rod) - 1)))
	var info: Dictionary = ctl.world.info
	var target := Vector2i(-1, -1)
	for d in range(reach, 0, -1):
		var t := me + dir * d
		if Fishing.water_kind(info, t) != "":
			target = t
			break
	if target.x < 0:
		EventBus.toast.emit(tr("Cast into water. Face the water and hold the tool button to cast farther."), "")
		Audio.sfx("error")
		_finish("")
		return
	_tile = target
	ctl.player.face_tile(target)
	ctl.player.doll.swing()
	Audio.sfx("cast", 0.1)
	_line.fly_to(GameState.tile_center(target) + Vector2(0, -6), 0.35)
	await get_tree().create_timer(0.35).timeout
	if state != State.CAST:
		return
	Audio.sfx("splash")
	var r: Dictionary = await Coop.act_async("fish_cast_act", [ctl.world.map_id, target])
	if state != State.CAST:
		return
	for f in r.get("fx", []):
		EventBus.popup.emit(ctl.player.position + Vector2(0, -24), str(f[0]), f[1] if f[1] is Color else Color(str(f[1])), "")
	if not r.get("ok", false):
		if str(r.get("reason", "")) != "":
			EventBus.toast.emit(str(r.reason), "")
			Audio.sfx("error")
		_finish("")
		return
	_hook = r
	_t = 0.0
	state = State.WAIT

func _cast_dir(me: Vector2i) -> Vector2i:
	var d := ctl.player.target - me
	if d == Vector2i.ZERO:
		var f: Vector2 = ctl.player.facing
		d = Vector2i(roundi(f.x), roundi(f.y))
	if absi(d.x) >= absi(d.y):
		return Vector2i(signi(d.x) if d.x != 0 else 1, 0)
	return Vector2i(0, signi(d.y))

func _bite() -> void:
	state = State.BITE
	_t = 0.0
	Audio.sfx("bite")
	_line.dip()
	EventBus.popup.emit(ctl.player.position + Vector2(0, -36), "!", Color("#ffd447"), "")

func _hooked() -> void:
	if str(_hook.get("hook", "")) == "wild":
		Audio.sfx("swing")
		_finish("caught")
		return
	state = State.FIGHT
	_t = 0.0
	_game = ReelGame.new()
	_game.setup(_hook, Settings.easy_fishing)
	_ui.add_child(_game)
	var sp: Vector2 = ctl.player.get_global_transform_with_canvas().origin
	var vp := ctl.get_viewport().get_visible_rect().size
	_game.position = Vector2(clampf(sp.x + 26.0, 4.0, vp.x - ReelGame.W - 30.0), clampf(sp.y - ReelGame.H - 10.0, 4.0, vp.y - ReelGame.H - 4.0))
	if bool(_hook.get("legendary", false)):
		EventBus.toast.emit(tr("Something huge is on the line!"), "star")

func _finish(outcome: String, treasure := false) -> void:
	var was := state
	state = State.DONE
	if is_instance_valid(_game):
		_game.queue_free()
	_game = null
	if is_instance_valid(_line):
		_line.queue_free()
	_line = null
	var hook := _hook
	_hook = {}
	if outcome != "" and was in [State.WAIT, State.BITE, State.FIGHT]:
		var r: Dictionary = await Coop.act_async("fish_result_act", [outcome, treasure])
		_show_result(r, outcome)
		if r.get("ok", false) and r.has("wild"):
			_cleanup(false)
			EventBus.battle_requested.emit({"kind": "wild", "species": str(r.wild), "level": int(r.level)})
			return
	elif outcome == "" and was == State.CAST and not hook.is_empty():
		Coop.act("fish_result_act", ["missed", false])
	_cleanup()

## Keeps the player still until the tool button is let go, so the held reel doesn't cast again.
func _cleanup(wait_release := true) -> void:
	if is_instance_valid(_ui):
		var ui := _ui
		_ui = null
		get_tree().create_timer(2.6).timeout.connect(func():
			if is_instance_valid(ui):
				ui.queue_free())
	if wait_release:
		state = State.DONE
		return
	state = State.IDLE
	ctl.player.locked = false

func _show_result(r: Dictionary, outcome: String) -> void:
	if not r.get("ok", false):
		if str(r.get("reason", "")) != "":
			EventBus.toast.emit(str(r.reason), "")
		return
	if r.get("lost", false):
		if outcome == "lost":
			EventBus.toast.emit(tr("The fish got away."), "")
			Audio.sfx("error")
		return
	for f in r.get("fx", []):
		EventBus.popup.emit(ctl.player.position + Vector2(0, -24), str(f[0]), f[1] if f[1] is Color else Color(str(f[1])), "")
	if not r.has("id"):
		return
	Audio.sfx("catch")
	if _ui:
		_card = CatchCard.new()
		_card.setup(r)
		_ui.add_child(_card)

## The line, the bobber and the charge meter, drawn in the world.
class FishingLine extends Node2D:
	var flow: FishingFlow
	var _bob := Vector2.ZERO
	var _flying := false
	var _dip := 0.0
	var _tt := 0.0

	func _ready() -> void:
		z_index = 50

	func fly_to(p: Vector2, secs: float) -> void:
		var start := _hand()
		_bob = start
		_flying = true
		var tw := create_tween()
		tw.tween_method(func(k: float):
			_bob = start.lerp(p, k) + Vector2(0, -40.0 * sin(k * PI)), 0.0, 1.0, secs)
		tw.tween_callback(func(): _flying = false)

	func dip() -> void:
		_dip = 1.0

	func _hand() -> Vector2:
		var pl: Player = flow.ctl.player
		return pl.position + Vector2(pl.facing.x * 10.0, -22.0)

	func _process(delta: float) -> void:
		_tt += delta
		_dip = maxf(0.0, _dip - delta * 1.5)

	func _draw() -> void:
		var pl: Player = flow.ctl.player
		if flow.state == FishingFlow.State.CHARGE:
			var at := pl.position + Vector2(-16, -46)
			draw_rect(Rect2(at, Vector2(32, 6)), UITheme.OUTLINE)
			draw_rect(Rect2(at + Vector2(1, 1), Vector2(30, 4)), Color("#3a2a2e"))
			var col := Color("#70d050").lerp(Color("#ffd447"), flow.power())
			draw_rect(Rect2(at + Vector2(1, 1), Vector2(30.0 * flow.power(), 4)), col)
			return
		if flow.state in [FishingFlow.State.IDLE, FishingFlow.State.DONE]:
			return
		var b := _bob
		if not _flying:
			b += Vector2(0, sin(_tt * 3.0) * 1.0 + _dip * 5.0)
			if flow.state == FishingFlow.State.BITE:
				b += Vector2(sin(_tt * 40.0) * 1.5, 3.0)
			if flow.state == FishingFlow.State.FIGHT:
				b += Vector2(sin(_tt * 13.0) * 2.0, cos(_tt * 9.0) * 1.5)
		var hand := _hand()
		var mid := (hand + b) / 2.0 + Vector2(0, 10)
		var pts := PackedVector2Array()
		for i in 9:
			var k := i / 8.0
			pts.append(hand.lerp(mid, k).lerp(mid.lerp(b, k), k))
		draw_polyline(pts, Color(1, 1, 1, 0.7), 1.0)
		if not _flying:
			var ring := fmod(_tt, 1.4) / 1.4
			draw_arc(b + Vector2(0, 2), 3.0 + ring * 7.0, 0, TAU, 16, Color(1, 1, 1, 0.5 * (1.0 - ring)), 1.0)
		draw_circle(b, 3.0, Color("#f4f4f4"))
		draw_rect(Rect2(b + Vector2(-3, -3), Vector2(6, 3)), Color("#e04040"))
		draw_arc(b, 3.0, 0, TAU, 12, UITheme.OUTLINE, 1.0)

## The reel minigame: a vertical bar, the fish darting about, and the zone you lift by holding.
class ReelGame extends Control:
	const W := 34.0
	const H := 150.0
	var result := ""
	var treasure_got := false
	var _zone_h := 0.25
	var _zone := 0.0
	var _zv := 0.0
	var _fish := 0.3
	var _fish_target := 0.3
	var _fish_timer := 0.0
	var _speed := 0.4
	var _move := "smooth"
	var _progress := 0.3
	var _escape := 1.0
	var _perfect := true
	var _easy := false
	var _has_treasure := false
	var _tre_pos := -1.0
	var _tre := 0.0
	var _tre_wait := 1.2
	var _legend := false
	var _tt := 0.0
	var _rng := RandomNumberGenerator.new()

	func setup(hook: Dictionary, easy: bool) -> void:
		_zone_h = float(hook.get("zone", 0.25))
		_speed = 0.12 + float(hook.get("diff", 20)) / 100.0 * 0.75
		_move = str(hook.get("move", "smooth"))
		_escape = float(hook.get("escape", 1.0))
		_has_treasure = bool(hook.get("treasure", false))
		_legend = bool(hook.get("legendary", false))
		_easy = easy
		_rng.randomize()
		custom_minimum_size = Vector2(W + 14, H)
		size = custom_minimum_size
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		if result != "":
			return
		_tt += delta
		_move_fish(delta)
		if _easy:
			var goal := clampf(_fish - _zone_h / 2.0, 0.0, 1.0 - _zone_h)
			_zone = lerpf(_zone, goal, minf(1.0, delta * 5.0))
		else:
			var lift := Input.is_action_pressed("use_tool")
			_zv += (2.6 if lift else -2.2) * delta
			_zv = clampf(_zv, -1.4, 1.4)
			_zone += _zv * delta
			if _zone < 0.0:
				_zone = 0.0
				_zv = -_zv * 0.35
			elif _zone > 1.0 - _zone_h:
				_zone = 1.0 - _zone_h
				_zv = -_zv * 0.35
		var inside := _fish >= _zone and _fish <= _zone + _zone_h
		if _easy:
			_progress += FishingFlow.FILL * 0.8 * delta
		elif inside:
			_progress += FishingFlow.FILL * delta
		else:
			_progress -= FishingFlow.DRAIN * _escape * delta
			_perfect = false
		if _has_treasure and not treasure_got:
			_tre_wait -= delta
			if _tre_wait <= 0.0 and _tre_pos < 0.0:
				_tre_pos = _rng.randf_range(0.1, 0.9)
			if _tre_pos >= 0.0 and (_easy or (_tre_pos >= _zone and _tre_pos <= _zone + _zone_h)):
				_tre += FishingFlow.TREASURE_FILL * delta
				if _tre >= 1.0:
					treasure_got = true
					Audio.sfx("coin")
		if _progress >= 1.0:
			result = "easy" if _easy else ("perfect" if _perfect else "caught")
		elif _progress <= 0.0:
			result = "lost"
		queue_redraw()

	func _move_fish(delta: float) -> void:
		_fish_timer -= delta
		if _fish_timer <= 0.0:
			var mv := _move
			if mv == "mixed":
				mv = ["smooth", "dart", "sinker", "floater"][_rng.randi() % 4]
			var r := _rng.randf()
			match mv:
				"sinker":
					r = pow(r, 1.7)
				"floater":
					r = 1.0 - pow(r, 1.7)
			_fish_target = clampf(r, 0.04, 0.96)
			_fish_timer = _rng.randf_range(0.25, 0.7) if mv == "dart" else _rng.randf_range(0.7, 1.6)
		var step := _speed * delta * (2.2 if _move == "dart" else 1.0)
		_fish = move_toward(_fish, _fish_target, step) + sin(_tt * 7.0) * 0.002

	func _y(v: float) -> float:
		return 6.0 + (1.0 - v) * (H - 12.0)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, Vector2(W, H)), UITheme.OUTLINE)
		draw_rect(Rect2(Vector2(2, 2), Vector2(W - 4, H - 4)), UITheme.WOOD)
		var water := Rect2(Vector2(5, 6), Vector2(W - 10, H - 12))
		draw_rect(water, Color("#2a5a8c"))
		draw_rect(Rect2(water.position, Vector2(water.size.x, water.size.y * 0.3)), Color(1, 1, 1, 0.06))
		var zy := _y(_zone + _zone_h)
		var zh := _zone_h * (H - 12.0)
		draw_rect(Rect2(Vector2(5, zy), Vector2(W - 10, zh)), Color(0.45, 0.85, 0.35, 0.55))
		draw_rect(Rect2(Vector2(5, zy), Vector2(W - 10, zh)), Color("#c8f0a0"), false, 1.0)
		if _tre_pos >= 0.0 and not treasure_got:
			var ty := _y(_tre_pos)
			draw_rect(Rect2(Vector2(W / 2.0 - 5, ty - 4), Vector2(10, 8)), Color("#c08030"))
			draw_rect(Rect2(Vector2(W / 2.0 - 5, ty - 4), Vector2(10, 8)), UITheme.OUTLINE, false, 1.0)
			draw_rect(Rect2(Vector2(W / 2.0 - 5, ty + 5), Vector2(10.0 * _tre, 2)), Color("#ffd447"))
		var fy := _y(_fish)
		var fc := Color("#ffd447") if _legend else Color("#f0a060")
		var c := Vector2(W / 2.0, fy)
		draw_colored_polygon(PackedVector2Array([c + Vector2(-7, 0), c + Vector2(-2, -4), c + Vector2(4, -3), c + Vector2(7, 0), c + Vector2(4, 3), c + Vector2(-2, 4)]), fc)
		draw_colored_polygon(PackedVector2Array([c + Vector2(6, 0), c + Vector2(10, -4), c + Vector2(10, 4)]), fc.darkened(0.2))
		draw_rect(Rect2(c + Vector2(-5, -1), Vector2(2, 2)), UITheme.OUTLINE)
		var px := W + 3.0
		draw_rect(Rect2(Vector2(px, 0), Vector2(10, H)), UITheme.OUTLINE)
		var ph := (H - 4.0) * clampf(_progress, 0.0, 1.0)
		var pcol := Color("#e05050").lerp(Color("#70d050"), clampf(_progress, 0.0, 1.0))
		draw_rect(Rect2(Vector2(px + 2, H - 2 - ph), Vector2(6, ph)), pcol)

## "Carp · 45.2 cm · Gold · New!" with the fish icon, fading out on its own.
class CatchCard extends PanelContainer:
	func setup(r: Dictionary) -> void:
		var id := str(r.id)
		var q := int(r.get("q", 0))
		add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT, UITheme.OUTLINE, 2, 4, 6, true))
		anchor_left = 0.5
		anchor_right = 0.5
		anchor_top = 0.2
		anchor_bottom = 0.2
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		add_child(h)
		h.add_child(UITheme.icon_rect(Art.item(id), 40))
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		h.add_child(v)
		v.add_child(UITheme.label(Data.item_name(id, q), 12, UITheme.WOOD_DK))
		var sub: PackedStringArray = []
		if r.has("size"):
			sub.append(tr("%s cm") % Num.decimal(float(r.size)))
		if r.get("new", false):
			sub.append(tr("New to your Fishdex!"))
		elif r.get("record", false):
			sub.append(tr("New size record!"))
		if not sub.is_empty():
			v.add_child(UITheme.label(" · ".join(sub), 9, UITheme.LEAF.darkened(0.35) if r.get("new", false) or r.get("record", false) else UITheme.INK))
		if r.has("treasure"):
			v.add_child(UITheme.label("Treasure!", 9, UITheme.COIN.darkened(0.3)))
		modulate.a = 0.0
		var tw := create_tween()
		tw.tween_property(self, "modulate:a", 1.0, 0.15)
		tw.tween_interval(2.0)
		tw.tween_property(self, "modulate:a", 0.0, 0.4)
		tw.tween_callback(queue_free)

	func _ready() -> void:
		await get_tree().process_frame
		offset_left = -size.x / 2.0
		offset_right = size.x / 2.0
