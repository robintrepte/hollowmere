class_name Player
extends Node2D
## Local (or remote) farmer. Position is at the feet. Free 8-direction movement with
## sliding grid collision. The controller handles what tool use / interact do.

signal use_pressed(tile: Vector2i)
signal interact_pressed(tile: Vector2i)
signal warp_entered(warp: Dictionary)

const WALK_SPEED := 104.0
const RUN_SPEED := 148.0
const REACH := 1

var pid := "local"
var local := true
var world: World
var doll: PaperDoll
var facing := Vector2.DOWN
var moving := false
var locked := false
var target := Vector2i.ZERO
var _name_label: Label
var _mouse_mode := false
var _last_mouse := Vector2.ZERO
var _step_t := 0.0
var _remote_target := Vector2.ZERO
var _warp_cooldown := 0.3
var _use_held := 0.0
var _net_t := 0.0

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

func set_remote_state(pos: Vector2, face: Vector2, mov: bool) -> void:
	_remote_target = pos
	facing = face
	moving = mov

func _physics_process(delta: float) -> void:
	if not local:
		position = position.lerp(_remote_target, minf(1.0, delta * 12.0))
		if position.distance_to(_remote_target) > 96:
			position = _remote_target
		doll.facing = facing
		doll.moving = moving
		return
	_warp_cooldown = maxf(0.0, _warp_cooldown - delta)
	var dir := Vector2.ZERO
	if not locked and not UIRoot.blocking and not doll.is_swinging():
		dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	moving = dir.length() > 0.1
	if moving:
		facing = dir.normalized()
		_mouse_mode = false
		var speed := WALK_SPEED if Input.is_action_pressed("run") or dir.length() < 0.6 else RUN_SPEED
		var step := dir.normalized() * speed * delta
		_move(step)
		_step_t += delta
		if _step_t > 0.32:
			_step_t = 0.0
			Audio.sfx("step", 0.15)
			if speed == RUN_SPEED and world and not world.info.get("indoor", false):
				Juice.burst(get_parent(), position + Vector2(0, -1), "dust")
	doll.facing = facing
	doll.moving = moving
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
	target = t
	world.cursor.show_at(t, not locked)

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
		interact_pressed.emit(target)
		get_viewport().set_input_as_handled()
