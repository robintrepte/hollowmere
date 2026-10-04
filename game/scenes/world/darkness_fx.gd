class_name DarknessFx
extends ColorRect
## Deep Mine darkness: one full-map pass that is cut open around players, torches,
## glowing crystals and lava. Only the nearest MAX_LIGHTS lights count.

const MAX_LIGHTS := 48
const SHADER := """
shader_type canvas_item;
uniform float dark = 0.7;
uniform int count = 0;
uniform vec3 lights[48];
varying vec2 wpos;
void vertex() {
	wpos = VERTEX;
}
void fragment() {
	vec2 q = floor(wpos / 2.0) * 2.0;
	float lit = 0.0;
	for (int i = 0; i < 48; i++) {
		if (i >= count) {
			break;
		}
		float d = distance(q, lights[i].xy);
		lit = max(lit, 1.0 - smoothstep(lights[i].z * 0.3, lights[i].z, d));
	}
	float a = dark * (1.0 - lit);
	a = floor(a * 6.0 + 0.5) / 6.0;
	COLOR = vec4(0.02, 0.01, 0.05, a);
}
"""

var world: World
var sources: Array = []
var _near: Array = []
var _sort_t := 0.0
var _mat: ShaderMaterial

func _init(w: World, darkness: float) -> void:
	world = w
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 39
	position = Vector2.ZERO
	size = w.map_size_px()
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("dark", darkness)
	material = _mat
	rebuild()

## Static lights: torches, crystals and lava edges. Players are added every frame.
func rebuild() -> void:
	sources.clear()
	_sort_t = 0.0
	var g := world.grid
	for y in g.h:
		for x in g.w:
			var p := Vector2i(x, y)
			var c := Vector2(x * Tiles.TILE + 16, y * Tiles.TILE + 16)
			var d := g.get_deco(p)
			if d == Tiles.DECO.torch:
				sources.append(Vector3(c.x, c.y - 8, 120))
			elif d == Tiles.DECO.crystal:
				sources.append(Vector3(c.x, c.y, 40))
			elif d == Tiles.DECO.elevator or d == Tiles.DECO.ladder_up:
				sources.append(Vector3(c.x, c.y, 56))
			elif g.get_ground(p) == Tiles.GROUND.lava and (x + y) % 2 == 0:
				sources.append(Vector3(c.x, c.y, 52))

func _process(delta: float) -> void:
	var lights: Array = []
	var focus := Vector2.ZERO
	var lamp := 0.0
	var me := GameState.local_player()
	if me and me.inventory.count("miners_helmet") > 0:
		lamp = 70.0
	for n in get_tree().get_nodes_in_group("players"):
		var pn := n as Node2D
		if pn == null or not pn.is_inside_tree():
			continue
		lights.append(Vector3(pn.position.x, pn.position.y - 12, 84.0 + lamp))
		if pn == world.get_parent().get("player"):
			focus = pn.position
	if focus == Vector2.ZERO and not lights.is_empty():
		focus = Vector2(lights[0].x, lights[0].y)
	_sort_t -= delta
	if _sort_t <= 0.0:
		_sort_t = 0.25
		_near = sources.duplicate()
		_near.sort_custom(func(a: Vector3, b: Vector3): return Vector2(a.x, a.y).distance_squared_to(focus) < Vector2(b.x, b.y).distance_squared_to(focus))
	for s in _near:
		if lights.size() >= MAX_LIGHTS:
			break
		lights.append(s)
	var packed := PackedVector3Array(lights)
	packed.resize(MAX_LIGHTS)
	_mat.set_shader_parameter("lights", packed)
	_mat.set_shader_parameter("count", mini(lights.size(), MAX_LIGHTS))
