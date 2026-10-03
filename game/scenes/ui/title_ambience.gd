class_name TitleAmbience
extends Control
## Animated layer over the title backdrop: weather particles for the current scene, drifting clouds,
## birds, stars, and Wildlings wandering along the bottom edge. Click a Wildling and it hops.

const FX := {
	"pollen": {"n": 34, "colors": ["#fff2b0", "#ffe08a", "#ffffff"], "size": [Vector2(1, 1)], "vx": [-4.0, 8.0], "vy": [-7.0, -2.0], "sway": 4.0},
	"petals": {"n": 42, "colors": ["#f8b8d0", "#f0a0c0", "#ffd8e8", "#ffffff"], "size": [Vector2(2, 2), Vector2(3, 2)], "vx": [12.0, 24.0], "vy": [14.0, 26.0], "sway": 10.0},
	"leaves": {"n": 30, "colors": ["#e07030", "#c04030", "#f0b040", "#a05030"], "size": [Vector2(3, 2), Vector2(2, 3)], "vx": [8.0, 22.0], "vy": [16.0, 28.0], "sway": 16.0},
	"snow": {"n": 95, "colors": ["#ffffff", "#e8f0ff", "#d0e0f8"], "size": [Vector2(1, 1), Vector2(2, 2)], "vx": [-5.0, 5.0], "vy": [10.0, 26.0], "sway": 6.0},
	"fireflies": {"n": 26, "colors": ["#e8ff80", "#fff27a", "#b8ff9a"], "size": [Vector2(1, 1)], "vx": [-6.0, 6.0], "vy": [-4.0, 4.0], "sway": 8.0},
}
const HEART := ["01010", "11111", "11111", "01110", "00100"]

var fx := "pollen"
var _parts: Array = []
var _stars: Array = []
var _clouds: Array = []
var _birds: Array = []
var _walkers: Array = []
var _hearts: Array = []
var _shooting: Dictionary = {}
var _t := 0.0
var _next_walker := 1.5
var _next_birds := 3.0
var _next_shooting := 4.0
var _species: Array = []
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_rng.randomize()
	for id in Data.species.keys():
		if ResourceLoader.exists("res://assets/creatures/small/%s.png" % id):
			_species.append(id)
	set_fx(fx)

func set_fx(name: String) -> void:
	fx = name if FX.has(name) else "pollen"
	_parts.clear()
	for i in FX[fx].n:
		_parts.append(_new_part(true))
	_stars.clear()
	_clouds.clear()
	_birds.clear()
	if fx == "fireflies":
		for i in 70:
			_stars.append({"p": Vector2(_rng.randf_range(0, _w()), _rng.randf_range(0, _h() * 0.42)), "ph": _rng.randf() * TAU, "sp": _rng.randf_range(1.0, 3.0)})
	else:
		for i in 4:
			_clouds.append(_new_cloud(_rng.randf_range(-40, _w())))

func _w() -> float:
	return maxf(size.x, 640.0)

func _h() -> float:
	return maxf(size.y, 360.0)

func _new_part(anywhere: bool) -> Dictionary:
	var f: Dictionary = FX[fx]
	var v := Vector2(_rng.randf_range(f.vx[0], f.vx[1]), _rng.randf_range(f.vy[0], f.vy[1]))
	var p := Vector2(_rng.randf_range(-20, _w()), _rng.randf_range(0, _h()))
	if fx == "fireflies":
		p.y = _rng.randf_range(_h() * 0.45, _h())
	elif not anywhere:
		if v.y > 0:
			p.y = -4.0
		else:
			p.y = _h() + 4.0
	var sizes: Array = f.size
	var cols: Array = f.colors
	return {"p": p, "v": v, "ph": _rng.randf() * TAU, "s": sizes[_rng.randi() % sizes.size()],
		"c": Color(cols[_rng.randi() % cols.size()]), "life": -1.0}

## A pixel cloud: one solid silhouette of overlapping puffs with a shaded underside, baked to a texture.
func _new_cloud(x: float) -> Dictionary:
	var n := _rng.randi_range(3, 5)
	var w := n * 11 + 16
	var h := 22
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var puffs: Array = []
	for i in n:
		var r := _rng.randf_range(5.0, 9.0) if i in [0, n - 1] else _rng.randf_range(7.0, 10.5)
		puffs.append(Vector3(8.0 + i * 11.0 + _rng.randf_range(-2, 2), h - 3.0 - r * 0.8, r))
	var base := h - 4
	for y in h:
		for xx in w:
			var inside := false
			for p: Vector3 in puffs:
				if Vector2(xx + 0.5 - p.x, (y + 0.5 - p.y) * 1.25).length() < p.z:
					inside = true
					break
			if inside and y <= base:
				img.set_pixel(xx, y, Color(0.86, 0.9, 0.98) if y >= base - 2 else Color.WHITE)
	return {"x": x, "y": _rng.randf_range(4, 60), "v": _rng.randf_range(3.0, 7.0), "tex": ImageTexture.create_from_image(img), "w": float(w)}

func _spawn_walker() -> void:
	if _species.is_empty():
		return
	var dir := 1.0 if _rng.randf() < 0.5 else -1.0
	var id: String = _species[_rng.randi() % _species.size()]
	_walkers.append({"tex": Art.creature(id, true), "x": -24.0 if dir > 0 else _w() + 24.0, "dir": dir,
		"v": _rng.randf_range(20, 32), "ph": _rng.randf() * TAU, "jump": 0.0, "jv": 0.0, "pause": 0.0})

func _spawn_birds() -> void:
	var dir := 1.0 if _rng.randf() < 0.5 else -1.0
	var y := _rng.randf_range(24, 80)
	var x0 := -20.0 if dir > 0 else _w() + 20.0
	for i in _rng.randi_range(3, 5):
		_birds.append({"p": Vector2(x0 - dir * i * 9.0, y + absf(i - 2) * 5.0), "dir": dir, "v": _rng.randf_range(34, 40), "ph": i * 0.7})

func _process(delta: float) -> void:
	_t += delta
	var f: Dictionary = FX[fx]
	for i in _parts.size():
		var q: Dictionary = _parts[i]
		if fx == "fireflies":
			q.v += Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 20.0 * delta
			q.v = q.v.limit_length(8.0)
		q.p += q.v * delta + Vector2(sin(_t * 1.6 + q.ph) * f.sway * delta, 0)
		if q.life >= 0.0:
			q.life -= delta
			q.v.y += 30.0 * delta
			if q.life < 0.0:
				q.life = -2.0
			continue
		var out: bool = q.p.x > _w() + 24 or q.p.x < -24 or q.p.y > _h() + 6 or q.p.y < -8
		if fx == "fireflies":
			out = out or q.p.y < _h() * 0.4
		if out:
			_parts[i] = _new_part(fx == "fireflies")
	_parts = _parts.filter(func(q): return q.life != -2.0)
	for c in _clouds:
		c.x += c.v * delta
		if c.x > _w() + 10:
			var n := _new_cloud(-c.w - 10)
			c.merge(n, true)
	if fx != "fireflies":
		_next_birds -= delta
		if _next_birds <= 0.0:
			_next_birds = _rng.randf_range(9, 18)
			_spawn_birds()
	for b in _birds:
		b.p.x += b.dir * b.v * delta
	_birds = _birds.filter(func(b): return b.p.x > -60 and b.p.x < _w() + 60)
	if fx == "fireflies":
		_next_shooting -= delta
		if _next_shooting <= 0.0:
			_next_shooting = _rng.randf_range(6, 14)
			_shooting = {"p": Vector2(_rng.randf_range(_w() * 0.2, _w()), _rng.randf_range(4, 50)), "life": 0.7}
		if not _shooting.is_empty():
			_shooting.p += Vector2(-220, 90) * delta
			_shooting.life -= delta
			if _shooting.life <= 0.0:
				_shooting = {}
	_next_walker -= delta
	if _next_walker <= 0.0 and _walkers.size() < 3:
		_next_walker = _rng.randf_range(6, 14)
		_spawn_walker()
	for wk in _walkers:
		if wk.pause > 0.0:
			wk.pause -= delta
		else:
			wk.x += wk.dir * wk.v * delta
		if wk.jump > 0.0 or wk.jv != 0.0:
			wk.jump += wk.jv * delta
			wk.jv -= 260.0 * delta
			if wk.jump <= 0.0:
				wk.jump = 0.0
				wk.jv = 0.0
		elif wk.pause <= 0.0 and _rng.randf() < delta * 0.15:
			wk.pause = _rng.randf_range(0.8, 2.0)
	_walkers = _walkers.filter(func(wk): return wk.x > -40 and wk.x < _w() + 40)
	for h in _hearts:
		h.p.y -= 18.0 * delta
		h.life -= delta
	_hearts = _hearts.filter(func(h): return h.life > 0.0)
	queue_redraw()

func _walker_pos(wk: Dictionary) -> Vector2:
	var hop := 0.0 if wk.pause > 0.0 else absf(sin(_t * 9.0 + wk.ph)) * 3.0
	return Vector2(wk.x, _h() - 6.0 - hop - wk.jump)

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	for wk in _walkers:
		var p := _walker_pos(wk)
		if Rect2(p - Vector2(16, 30), Vector2(32, 30)).has_point(event.position) and wk.jump == 0.0:
			wk.jv = 110.0
			wk.jump = 0.01
			_hearts.append({"p": p - Vector2(2, 34), "life": 1.2})
			Audio.sfx("heart")
			accept_event()
			return
	var f: Dictionary = FX[fx]
	for i in 10:
		var q := _new_part(true)
		q.p = event.position
		q.v = Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(20, 50) + Vector2(0, -20)
		q.life = _rng.randf_range(0.8, 1.6)
		_parts.append(q)
	if _parts.size() > f.n + 60:
		_parts = _parts.slice(_parts.size() - f.n - 60)

func _draw() -> void:
	for s in _stars:
		var a := 0.35 + 0.65 * absf(sin(_t * s.sp + s.ph))
		draw_rect(Rect2(s.p.floor(), Vector2.ONE), Color(1, 1, 0.9, a))
	if not _shooting.is_empty():
		var a: float = clampf(_shooting.life / 0.7, 0, 1)
		for k in 8:
			draw_rect(Rect2((_shooting.p + Vector2(k * 2.4, -k * 1.0)).floor(), Vector2.ONE), Color(1, 1, 0.85, a * (1.0 - k / 8.0)))
	for c in _clouds:
		draw_texture(c.tex, Vector2(c.x, c.y).floor(), Color(1, 1, 1, 0.55))
	for b in _birds:
		var up := sin(_t * 10.0 + b.ph) > 0.0
		var p: Vector2 = b.p.floor()
		var col := Color("#3a2a2e")
		draw_rect(Rect2(p, Vector2.ONE), col)
		draw_rect(Rect2(p + Vector2(-2, -1 if up else 0), Vector2(2, 1)), col)
		draw_rect(Rect2(p + Vector2(1, -1 if up else 0), Vector2(2, 1)), col)
	for q in _parts:
		var col: Color = q.c
		if fx == "fireflies" or fx == "pollen":
			var glow := 0.4 + 0.6 * absf(sin(_t * 2.2 + q.ph))
			col.a = glow
			if fx == "fireflies":
				draw_rect(Rect2(q.p.floor() - Vector2.ONE, Vector2(3, 3)), Color(col, glow * 0.25))
		elif q.life >= 0.0:
			col.a = clampf(q.life, 0, 1)
		draw_rect(Rect2(q.p.floor(), q.s), col)
	for wk in _walkers:
		var p := _walker_pos(wk).floor()
		draw_rect(Rect2(Vector2(wk.x - 7, _h() - 6).floor(), Vector2(14, 2)), Color(0, 0, 0, 0.22))
		draw_set_transform(p, 0.0, Vector2(wk.dir, 1))
		draw_texture(wk.tex, Vector2(-16, -30))
		draw_set_transform(Vector2.ZERO)
	for h in _hearts:
		var a: float = clampf(h.life, 0, 1)
		for y in HEART.size():
			for x in HEART[y].length():
				if HEART[y][x] == "1":
					draw_rect(Rect2(h.p.floor() + Vector2(x, y), Vector2.ONE), Color(UITheme.HEART, a))
