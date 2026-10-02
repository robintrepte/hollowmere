class_name WildCreature
extends Node2D
## An overworld Wildling. Wild ones wander, sometimes notice you and come closer, and
## start a battle on touch. Ranch ones (pet = true) roam the farm and can be petted.

const WANDER_SPEED := 26.0
const CHASE_SPEED := 62.0
const TOUCH_DIST := 14.0
const NOTICE_DIST := 84.0

var species := ""
var level := 1
var starry := false
var pet := false
var creature: Creature          # ranch creatures keep a reference
var world: World
var sprite: Sprite2D
var _target := Vector2.ZERO
var _wait := 0.0
var _t := 0.0
var _stun := 0.0
var _curious := false
var _chasing := 0.0
var _notice_cd := 1.5
var _emote: Label
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.seed = hash([species, position, Time.get_ticks_usec()])
	add_child(Npc._shadow())
	sprite = Sprite2D.new()
	sprite.texture = Art.creature(species, true)
	sprite.centered = false
	sprite.offset = Vector2(-16, -30)
	add_child(sprite)
	if starry:
		sprite.modulate = Color(1.15, 1.1, 0.8)
		var sp := CPUParticles2D.new()
		sp.amount = 6
		sp.lifetime = 1.2
		sp.position = Vector2(0, -16)
		sp.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
		sp.emission_sphere_radius = 12.0
		sp.gravity = Vector2(0, -12)
		sp.color = Color("#fff3a0")
		sp.scale_amount_min = 1.0
		sp.scale_amount_max = 2.0
		add_child(sp)
	_emote = UITheme.label("", 10, UITheme.CREAM, true)
	_emote.position = Vector2(-20, -46)
	_emote.size = Vector2(40, 12)
	_emote.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_emote)
	_curious = not pet and _rng.randf() < 0.45
	_target = position
	_wait = _rng.randf_range(0.2, 2.0)

func stun(seconds: float) -> void:
	_stun = seconds
	_chasing = 0.0

func emote(text: String, seconds: float = 1.2) -> void:
	_emote.text = text
	_emote.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(seconds)
	tw.tween_property(_emote, "modulate:a", 0.0, 0.3)

func _local_player() -> Player:
	for p in get_tree().get_nodes_in_group("players"):
		if p.local:
			return p
	return null

func _process(delta: float) -> void:
	_t += delta
	if world == null:
		return
	var moving := false
	if _stun > 0.0:
		_stun -= delta
		sprite.visible = int(_stun * 8.0) % 2 == 0
		return
	sprite.visible = true
	var pl := _local_player()
	var d := INF
	if pl and not pet:
		d = pl.position.distance_to(position)
		if d < TOUCH_DIST and not pl.locked and not UIRoot.blocking:
			_stun = 0.5
			EventBus.battle_requested.emit({"kind": "wild", "species": species, "level": level, "starry": starry, "node": self})
			return
		_notice_cd -= delta
		if _curious and d < NOTICE_DIST and _chasing <= 0.0 and _notice_cd <= 0.0:
			_chasing = 2.5
			_notice_cd = 7.0
			emote("!")
	if _chasing > 0.0 and pl:
		_chasing -= delta
		_target = pl.position
		moving = _step(CHASE_SPEED * delta)
		if _chasing <= 0.0:
			_target = position
			_wait = _rng.randf_range(2.0, 4.0)
	else:
		if position.distance_to(_target) < 2.0:
			_wait -= delta
			if _wait <= 0.0:
				_pick_target()
		else:
			moving = _step(WANDER_SPEED * delta)
	# Hop while moving, gentle breathing while idle
	if moving:
		sprite.position.y = -absf(sin(_t * 12.0)) * 3.0
	else:
		sprite.position.y = 0.0
		sprite.scale = Vector2(1.0, 1.0 + sin(_t * 3.0) * 0.03)

func _pick_target() -> void:
	for i in 6:
		var off := Vector2(_rng.randf_range(-80, 80), _rng.randf_range(-60, 60))
		var p := position + off
		if not world.is_solid_at(p, Vector2(6, 3)) and Rect2(Vector2(40, 40), world.map_size_px() - Vector2(80, 80)).has_point(p):
			_target = p
			_wait = _rng.randf_range(1.0, 3.5)
			return
	_wait = 1.0

func _step(dist: float) -> bool:
	var dir := (_target - position)
	if dir.length() < 1.0:
		return false
	var step := dir.normalized() * minf(dist, dir.length())
	sprite.flip_h = step.x > 0.0
	var nx := position + Vector2(step.x, 0)
	if not world.is_solid_at(nx, Vector2(6, 3)):
		position = nx
	var ny := position + Vector2(0, step.y)
	if not world.is_solid_at(ny, Vector2(6, 3)):
		position = ny
	if position.distance_to(_target) >= dir.length() - 0.1:
		_target = position
	return true
