class_name WildCreature
extends Node2D
## An overworld Wildling. Wild ones wander, sometimes notice you and come closer, and
## start a battle on touch. Ranch ones (pet = true) roam the farm and can be petted.

const WANDER_SPEED := 26.0
const CHASE_SPEED := 62.0
const TOUCH_DIST := 14.0
const NOTICE_DIST := 84.0
const BODY_GAP := 20.0

var species := ""
var level := 1
var starry := false
var pet := false
## Guardians and legends: larger, calm, and battle with the smart AI.
var boss := false
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
var _working := false
var _stuck := 0.0
var _dance := 0.0
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
	if boss:
		sprite.scale = Vector2(1.4, 1.4)
		var aura := CPUParticles2D.new()
		aura.amount = 10
		aura.lifetime = 1.6
		aura.position = Vector2(0, -20)
		aura.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
		aura.emission_sphere_radius = 18.0
		aura.gravity = Vector2(0, -16)
		aura.color = Color(Data.type_color(str(Data.species.get(species, {}).get("types", ["glow"])[0])), 0.8)
		aura.scale_amount_min = 1.0
		aura.scale_amount_max = 2.5
		add_child(aura)
	_curious = not pet and not boss and _rng.randf() < 0.45
	_target = position
	_wait = _rng.randf_range(0.2, 2.0)

func stun(seconds: float) -> void:
	_stun = seconds
	_chasing = 0.0
	_target = position
	_wait = maxf(_wait, seconds)

func emote(text: String, seconds: float = 1.2) -> void:
	_emote.text = text
	_emote.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(seconds)
	tw.tween_property(_emote, "modulate:a", 0.0, 0.3)

## Hops on the spot for a while, e.g. when its farmer dances nearby.
func dance(seconds: float) -> void:
	if _dance <= 0.0:
		emote("la")
	_dance = maxf(_dance, seconds)
	_target = position

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
	if _dance > 0.0:
		_dance -= delta
		sprite.position.y = -absf(sin(_t * 7.0)) * 5.0
		sprite.flip_h = int(_t * 2.0) % 2 == 0
		return
	var pl := _local_player()
	var d := INF
	if pl and not pet:
		d = pl.position.distance_to(position)
		if d < TOUCH_DIST and not pl.locked and pl.encounter_grace <= 0.0 and not UIRoot.blocking:
			_stun = 0.5
			var setup := {"kind": "wild", "species": species, "level": level, "starry": starry, "node": self}
			if boss:
				setup["ai"] = 2
				setup["boss"] = true
			EventBus.battle_requested.emit(setup)
			return
		_notice_cd -= delta
		if _curious and d < NOTICE_DIST and _chasing <= 0.0 and _notice_cd <= 0.0 and pl.encounter_grace <= 0.0 and not pl.locked:
			_chasing = 2.5
			_notice_cd = 7.0
			emote("!")
		if (pl.locked or pl.encounter_grace > 0.0) and _chasing > 0.0:
			_chasing = 0.0
			_target = position
			_wait = 1.5
	if _chasing > 0.0 and pl:
		_chasing -= delta
		_target = pl.position
		moving = _step(CHASE_SPEED * delta)
		if _chasing <= 0.0:
			_target = position
			_wait = _rng.randf_range(2.0, 4.0)
	else:
		if position.distance_to(_target) < 2.0:
			if _working:
				_working = false
				_work_fx()
			_wait -= delta
			if _wait <= 0.0:
				_pick_target()
		else:
			var before := position
			moving = _step(WANDER_SPEED * delta)
			_stuck = _stuck + delta if position.distance_to(before) < 0.05 else 0.0
			if _stuck > 1.5:
				_stuck = 0.0
				_working = false
				_target = position
	_separate()
	# Hop while moving, gentle breathing while idle
	if moving:
		sprite.position.y = -absf(sin(_t * 12.0)) * 3.0
	else:
		sprite.position.y = 0.0
		sprite.scale = Vector2(1.0, 1.0 + sin(_t * 3.0) * 0.03)

## Ranch workers walk to something relevant to their job (crops, debris, machines) now and then.
func _work_target() -> Vector2:
	var g: FarmGrid = world.grid
	if g == null:
		return Vector2.INF
	var tiles: Array = []
	match creature.job:
		"water", "grow", "pollinate", "harvest", "preserve":
			tiles = g.planted_tiles()
		"clear", "smelt":
			for i in g.deco.size():
				if g.deco[i] in [Tiles.DECO.weed, Tiles.DECO.rock, Tiles.DECO.branch]:
					tiles.append(Vector2i(i % g.w, int(i / g.w)))
		"power":
			for k in g.objects:
				if g.objects[k].kind == "machine":
					tiles.append(Tiles.parse_key(k))
	if tiles.is_empty():
		return Vector2.INF
	var t: Vector2i = tiles[_rng.randi() % tiles.size()]
	return GameState.tile_center(t) + Vector2(_rng.randf_range(-6, 6), 10)

func _work_fx() -> void:
	var p := CPUParticles2D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = 8
	p.lifetime = 0.7
	p.explosiveness = 0.8
	p.position = Vector2(0, -12)
	p.direction = Vector2(0, -1)
	p.spread = 60.0
	p.initial_velocity_min = 20.0
	p.initial_velocity_max = 40.0
	p.gravity = Vector2(0, 90)
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	p.color = Data.type_color(FarmJobs.job_type(creature.job))
	add_child(p)
	p.finished.connect(p.queue_free)
	var tw := create_tween()
	tw.tween_property(sprite, "scale", Vector2(1.15, 0.85), 0.08)
	tw.tween_property(sprite, "scale", Vector2.ONE, 0.12)

func _pick_target() -> void:
	if pet and creature and creature.job != "" and creature.energy > 0 and _rng.randf() < 0.55:
		var wt := _work_target()
		if wt != Vector2.INF and not world.is_solid_at(wt, Vector2(6, 3)):
			_target = wt
			_working = true
			_wait = _rng.randf_range(1.5, 3.0)
			return
	for i in 6:
		var off := Vector2(_rng.randf_range(-80, 80), _rng.randf_range(-60, 60))
		var p := position + off
		if not world.is_solid_at(p, Vector2(6, 3)) and Rect2(Vector2(40, 40), world.map_size_px() - Vector2(80, 80)).has_point(p):
			_target = p
			_wait = _rng.randf_range(1.0, 3.5)
			return
	_wait = 1.0

## Keep a pile of Wildlings from standing on the same pixel and all touching the farmer at once.
func _separate() -> void:
	if world == null or world.grid == null:
		return
	for raw in world.creatures:
		var other := raw as Node2D
		if other == null or other == self or not is_instance_valid(other):
			continue
		var gap: Vector2 = position - other.position
		var dist: float = gap.length()
		if dist >= BODY_GAP:
			continue
		var push := Vector2.RIGHT * BODY_GAP
		if dist >= 0.01:
			push = gap.normalized() * (BODY_GAP - dist) * 0.35
		var dest: Vector2 = position + push
		if not world.is_solid_at(dest, Vector2(6, 3)):
			position = dest

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
