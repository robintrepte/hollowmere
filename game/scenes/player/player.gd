class_name Player
extends Node2D
## Local (or remote) farmer. Position is at the feet. Free 8-direction movement with
## sliding grid collision. The controller handles what tool use / interact do.

signal use_pressed(tile: Vector2i)
signal interact_pressed(tile: Vector2i)
signal warp_entered(warp: Dictionary)

const SLOW_SPEED := 104.0   ## light stick / short joystick push
const WALK_SPEED := 148.0   ## default pace (the old unshifted speed)
const RUN_SPEED := 220.0    ## shift
const REACH := 1

var pid := "local"
var local := true
var world: World
var doll: PaperDoll
var facing := Vector2.DOWN
var moving := false
var running := false
var locked := false
## After fleeing a wild battle, touching a Wildling does not start another until this runs out.
var encounter_grace := 0.0
var target := Vector2i.ZERO
var _talk_tile := Vector2i.ZERO
var _name_label: Label
var _mouse_mode := false
var _speed_mult := 1.0
var _speed_t := 0.0
var _last_mouse := Vector2.ZERO
var _step_t := 0.0
var _remote_target := Vector2.ZERO
var _warp_cooldown := 0.3
var _use_held := 0.0
var _net_t := 0.0
var _remote_stamp := 0.0

func _ready() -> void:
	add_to_group("players")
	add_child(Npc._shadow())
	doll = PaperDoll.new()
	add_child(doll)
	var p := GameState.player(pid)
	if p:
		doll.set_look(p.look)
	_name_label = UITheme.label("", 8, UITheme.CREAM, true)
	_name_label.position = Vector2(-40, -60)
	_name_label.size = Vector2(80, 10)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_name_label)
	if not local and p:
		_name_label.text = p.name
	_remote_target = position

var _pack_shown := ""

func _sync_pack() -> void:
	var p := GameState.player(pid)
	if p == null or p.backpack == _pack_shown:
		return
	_pack_shown = p.backpack
	doll.set_pack(Art.color(Economy.backpack_spec(p.backpack).get("tint", "#8a6a48")))

func set_remote_state(pos: Vector2, face: Vector2, mov: bool) -> void:
	var now := Time.get_ticks_msec() * 0.001
	var dt := now - _remote_stamp
	if _remote_stamp > 0.0 and dt > 0.02 and dt < 0.5:
		var spd := pos.distance_to(_remote_target) / dt
		var gate := 170.0 if running else 190.0
		running = mov and spd > gate
	elif not mov:
		running = false
	_remote_stamp = now
	_remote_target = pos
	facing = face
	moving = mov

func _physics_process(delta: float) -> void:
	_sync_pack()
	if not local:
		position = position.lerp(_remote_target, minf(1.0, delta * 12.0))
		if position.distance_to(_remote_target) > 96:
			position = _remote_target
		doll.facing = facing
		doll.moving = moving
		doll.running = running
		return
	_warp_cooldown = maxf(0.0, _warp_cooldown - delta)
	encounter_grace = maxf(0.0, encounter_grace - delta)
	var dir := Vector2.ZERO
	if not locked and not UIRoot.blocking and not doll.is_swinging():
		dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	moving = dir.length() > 0.1
	running = false
	if moving:
		facing = dir.normalized()
		_mouse_mode = false
		var pushed := dir.length()
		running = Input.is_action_pressed("run") and pushed >= 0.6
		var speed := SLOW_SPEED if pushed < 0.6 else (RUN_SPEED if running else WALK_SPEED)
		_speed_t -= delta
		if _speed_t <= 0.0:
			_speed_t = 0.5
			_speed_mult = clampf(Modifiers.mult(GameState.player(pid), "move_speed"), 0.5, 1.6)
		var step := dir.normalized() * speed * _speed_mult * delta
		_move(step)
		_step_t += delta
		if _step_t > 0.32 * WALK_SPEED / speed:
			_step_t = 0.0
			Audio.sfx("step", 0.15 if not running else 0.22)
			if running and world and not world.info.get("indoor", false):
				Juice.burst(get_parent(), position + Vector2(0, -1), "dust")
	doll.facing = facing
	doll.moving = moving
	doll.running = running
	var p := GameState.player(pid)
	if p:
		p.pos = position
	_net_t += delta
	if _net_t >= 0.1 and world:
		_net_t = 0.0
		Coop.send_position(world.map_id, position, facing, moving)
	_update_target()
	if not locked and _warp_cooldown <= 0.0 and world:
		var wp := world.warp_at(GameState.to_tile(position))
		if not wp.is_empty():
			_warp_cooldown = 1.0
			warp_entered.emit(wp)
	if _use_held > 0.0 and Input.is_action_pressed("use_tool") and not locked:
		_use_held += delta
		if _use_held > 0.38 and not doll.is_swinging():
			_use_held = 0.01
			use_pressed.emit(target)
	elif not Input.is_action_pressed("use_tool"):
		_use_held = 0.0

func _move(step: Vector2) -> void:
	if world == null:
		position += step
		return
	var nx := position + Vector2(step.x, 0)
	if not world.is_solid_at(nx):
		position = nx
	elif absf(step.y) < 0.01:
		for nudge in [-1.0, 1.0]:
			var alt := position + Vector2(step.x * 0.7, nudge * absf(step.x) * 0.7)
			if not world.is_solid_at(alt):
				position = alt
				break
	var ny := position + Vector2(0, step.y)
	if not world.is_solid_at(ny):
		position = ny
	elif absf(step.x) < 0.01:
		for nudge in [-1.0, 1.0]:
			var alt := position + Vector2(nudge * absf(step.y) * 0.7, step.y * 0.7)
			if not world.is_solid_at(alt):
				position = alt
				break
	var sz := world.map_size_px()
	position = position.clamp(Vector2(4, 8), sz - Vector2(4, 2))

func _update_target() -> void:
	if world == null:
		return
	var me := GameState.to_tile(position + Vector2(0, -6))
	var mp := get_global_mouse_position()
	if mp.distance_to(_last_mouse) > 2.0:
		_last_mouse = mp
		_mouse_mode = not TouchControls.owns_pointer
	var t := me
	if _mouse_mode:
		var mt := GameState.to_tile(mp)
		if absi(mt.x - me.x) <= REACH and absi(mt.y - me.y) <= REACH:
			t = mt
		else:
			var d := (mp - position).normalized()
			t = me + Vector2i(roundi(d.x), roundi(d.y))
	else:
		var f := facing
		if absf(f.x) > absf(f.y):
			f = Vector2(signf(f.x), 0)
		else:
			f = Vector2(0, signf(f.y))
		t = me + Vector2i(int(f.x), int(f.y))
	# Tools, seeds and furniture stay on the exact tile. Talk, gifts and doors
	# also reach a villager or object one tile off, as long as you're facing it.
	_talk_tile = world.focus_tile(me, t)
	target = t if _precise_aim() else _talk_tile
	world.cursor.show_at(target, not locked, me)

func _precise_aim() -> bool:
	var p := GameState.player(pid)
	if p == null:
		return false
	var e := p.selected_entry()
	if e.is_empty():
		return false
	var it: Dictionary = Data.get_item(e.id)
	var cat := str(it.get("cat", ""))
	return cat in ["tool", "seed", "sapling"] or it.has("fert") or it.has("place")

func face_tile(t: Vector2i) -> void:
	var d := Vector2(GameState.tile_center(t) - (position + Vector2(0, -8)))
	if d.length() > 1.0:
		facing = d.normalized()

func _unhandled_input(event: InputEvent) -> void:
	if not local or locked:
		return
	if event is InputEventMouseButton and event.pressed:
		_update_target()
	if event.is_action_pressed("use_tool"):
		_use_held = 0.01
		use_pressed.emit(target)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("interact"):
		interact_pressed.emit(_talk_tile)
		get_viewport().set_input_as_handled()
