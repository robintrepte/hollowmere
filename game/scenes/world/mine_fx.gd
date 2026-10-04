class_name MineFx
extends Node2D
## Small pixel overlays for the mine: ore flecks in a wall, crystal clusters, cracks,
## and stand-ins for torches, beams, rails, carts and the lift when no sprite exists.

var kind := ""
var col := Color.WHITE
var amount := 0.0
var seed_v := 0

func _init(k: String, c: Color = Color.WHITE, a: float = 0.0, s: int = 0) -> void:
	kind = k
	col = c
	amount = a
	seed_v = s

func _draw() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	match kind:
		"vein":
			for i in 5:
				var c := Vector2(rng.randi_range(-11, 9), rng.randi_range(-40, -14) if amount < 0.5 else rng.randi_range(-18, -7))
				var s := float(rng.randi_range(2, 3))
				draw_colored_polygon(PackedVector2Array([c + Vector2(0, -s), c + Vector2(s, 0), c + Vector2(0, s), c + Vector2(-s, 0)]), col.darkened(0.25))
				draw_rect(Rect2(c + Vector2(-1, -1), Vector2(2, 2)), col.lightened(0.45))
		"crystal":
			var shards := [[-7, 14, 4, -0.25], [0, 22, 5, 0.0], [7, 12, 4, 0.3], [-2, 9, 3, 0.55]]
			for sh in shards:
				var base := Vector2(float(sh[0]), -3)
				var up := Vector2.UP.rotated(float(sh[3])) * float(sh[1])
				var side := up.orthogonal().normalized() * float(sh[2]) * 0.5
				var tip := base + up
				var poly := PackedVector2Array([base - side, base - side + up * 0.75, tip, base + side + up * 0.75, base + side])
				draw_colored_polygon(poly, col.darkened(0.15))
				draw_colored_polygon(PackedVector2Array([base, base + up * 0.75, tip, base - side + up * 0.75, base - side]), col.lightened(0.35))
				draw_polyline(poly + PackedVector2Array([poly[0]]), col.darkened(0.55), 1.0)
		"crack":
			var lines := int(ceil(amount * 4.0))
			var c0 := Vector2(0, -24)
			for i in lines:
				var a := rng.randf() * TAU
				var p := c0
				for j in 3:
					var q := p + Vector2.RIGHT.rotated(a + rng.randf_range(-0.6, 0.6)) * rng.randf_range(4, 7)
					draw_line(p, q, Color(0.05, 0.03, 0.06, 0.85), 1.0)
					p = q
		"torch":
			draw_rect(Rect2(-1.5, -14, 3, 13), Color("#6a4428"))
			draw_rect(Rect2(-2.5, -18, 5, 5), Color("#ffb040"))
			draw_rect(Rect2(-1.5, -21, 3, 4), Color("#fff0a0"))
		"support":
			var wood := Color("#8a5a3a")
			var dark := Color("#3a2414")
			draw_rect(Rect2(-13, -44, 4, 44), dark)
			draw_rect(Rect2(9, -44, 4, 44), dark)
			draw_rect(Rect2(-12, -44, 2, 43), wood)
			draw_rect(Rect2(10, -44, 2, 43), wood)
			draw_rect(Rect2(-15, -47, 30, 5), dark)
			draw_rect(Rect2(-14, -46, 28, 3), wood.lightened(0.15))
		"rail":
			var steel := Color("#9aa0b0")
			var tie := Color("#6a4428")
			var vertical := amount > 0.5
			for i in 4:
				var o := -14.0 + i * 9.0
				draw_rect(Rect2(o, -26, 4, 20) if not vertical else Rect2(-10, -30 + i * 8, 20, 3), tie)
			if vertical:
				draw_rect(Rect2(-7, -32, 2, 32), steel)
				draw_rect(Rect2(5, -32, 2, 32), steel)
			else:
				draw_rect(Rect2(-16, -24, 32, 2), steel)
				draw_rect(Rect2(-16, -10, 32, 2), steel)
		"minecart":
			draw_rect(Rect2(-12, -22, 24, 14), Color("#3a2a20"))
			draw_rect(Rect2(-11, -21, 22, 12), Color("#7a6a60"))
			draw_rect(Rect2(-10, -24, 20, 4), Color("#c08a50"))
			draw_circle(Vector2(-7, -6), 3.0, Color("#202020"))
			draw_circle(Vector2(7, -6), 3.0, Color("#202020"))
		"elevator":
			var iron := Color("#5a5a6a")
			draw_rect(Rect2(-14, -46, 28, 46), Color(0.1, 0.08, 0.12))
			for i in 5:
				draw_rect(Rect2(-14 + i * 6.5, -46, 2, 46), iron)
			draw_rect(Rect2(-16, -50, 32, 5), iron.darkened(0.3))
			draw_rect(Rect2(-16, -2, 32, 3), iron.darkened(0.3))
			draw_line(Vector2(0, -50), Vector2(0, -64), Color("#2a2a30"), 2.0)
