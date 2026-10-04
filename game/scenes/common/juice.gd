class_name Juice
extends RefCounted
## One-shot pixel particle bursts and small flourishes for game feel.

const STYLES := {
	"dust": {"color": Color(0.85, 0.78, 0.65, 0.55), "n": 3, "speed": 14.0, "gravity": -8.0, "size": 1.2, "life": 0.35, "spread": 60.0, "z": 0},
	"hoe": {"color": Color("#7a5236"), "n": 8, "speed": 45.0, "gravity": 180.0, "size": 2.0},
	"plant": {"color": Color("#6a4a30"), "n": 5, "speed": 30.0, "gravity": 160.0, "size": 1.5},
	"water": {"color": Color("#7ac8ff"), "n": 12, "speed": 55.0, "gravity": 220.0, "size": 1.5},
	"rock": {"color": Color("#9a9aa4"), "n": 10, "speed": 70.0, "gravity": 260.0, "size": 2.0},
	"dig": {"color": Color("#8a5a3a"), "n": 8, "speed": 50.0, "gravity": 220.0, "size": 1.8},
	"clink": {"color": Color("#e0b060"), "n": 10, "speed": 75.0, "gravity": 260.0, "size": 1.6},
	"crystal": {"color": Color("#a8f0ff"), "n": 12, "speed": 60.0, "gravity": 60.0, "size": 1.4, "life": 0.6, "spread": 180.0},
	"sparkle": {"color": Color("#d8a8ff"), "n": 10, "speed": 40.0, "gravity": -30.0, "size": 1.2, "life": 0.7, "spread": 180.0},
	"boom": {"color": Color("#ffb040"), "n": 26, "speed": 120.0, "gravity": 160.0, "size": 2.5, "life": 0.6, "spread": 180.0},
	"chop": {"color": Color("#b07a48"), "n": 9, "speed": 65.0, "gravity": 240.0, "size": 2.0},
	"scythe": {"color": Color("#6fbf4a"), "n": 9, "speed": 50.0, "gravity": 120.0, "size": 1.5},
	"harvest": {"color": Color("#ffe58a"), "n": 10, "speed": 50.0, "gravity": -20.0, "size": 1.5, "life": 0.6, "spread": 180.0},
	"pickup": {"color": Color("#fff4dc"), "n": 6, "speed": 35.0, "gravity": -30.0, "size": 1.0, "life": 0.5, "spread": 180.0},
	"ship": {"color": Color("#f0c040"), "n": 10, "speed": 60.0, "gravity": 120.0, "size": 1.5},
	"coin": {"color": Color("#f0c040"), "n": 8, "speed": 50.0, "gravity": 100.0, "size": 1.5},
	"machine": {"color": Color(1, 1, 1, 0.8), "n": 6, "speed": 18.0, "gravity": -40.0, "size": 2.5, "life": 0.8, "spread": 25.0},
	"chest": {"color": Color("#ffd447"), "n": 8, "speed": 40.0, "gravity": -10.0, "size": 1.0, "life": 0.6, "spread": 180.0},
	"befriend": {"color": Color("#ff8fb0"), "n": 14, "speed": 45.0, "gravity": -40.0, "size": 2.0, "life": 0.9, "spread": 180.0},
	"levelup": {"color": Color("#ffd447"), "n": 24, "speed": 110.0, "gravity": 200.0, "size": 2.0, "life": 0.9, "spread": 70.0, "rainbow": true},
}
const CONFETTI := [Color("#ffd447"), Color("#ff8fb0"), Color("#8fe36b"), Color("#7ac8ff"), Color("#c890ff")]

static func burst(parent: Node, pos: Vector2, style: String, tint: Color = Color(0, 0, 0, 0)) -> void:
	var st: Dictionary = STYLES.get(style, {})
	if st.is_empty() or parent == null or not parent.is_inside_tree():
		return
	var p := CPUParticles2D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = int(round(st.n * 1.4))
	p.lifetime = float(st.get("life", 0.45))
	p.explosiveness = 0.95
	p.direction = Vector2(0, -1)
	p.spread = float(st.get("spread", 70.0))
	p.initial_velocity_min = float(st.speed) * 0.5
	p.initial_velocity_max = float(st.speed)
	p.gravity = Vector2(0, float(st.gravity))
	p.scale_amount_min = float(st.size) * 1.2
	p.scale_amount_max = float(st.size) * 2.0
	p.color = tint if tint.a > 0.0 else st.color
	if st.get("rainbow", false):
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
		g.colors = PackedColorArray(CONFETTI)
		p.color = Color.WHITE
		p.color_initial_ramp = g
	var fade := Gradient.new()
	fade.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0)])
	fade.offsets = PackedFloat32Array([0.6, 1.0])
	p.color_ramp = fade
	p.position = pos
	p.z_index = int(st.get("z", 50))
	parent.add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)

## A quick scale bounce, e.g. for counters that just went up.
static func pop(c: CanvasItem, amount: float = 0.25) -> void:
	if c == null or not c.is_inside_tree():
		return
	if c is Control:
		c.pivot_offset = c.size / 2.0
	var tw := c.create_tween()
	tw.tween_property(c, "scale", Vector2.ONE * (1.0 + amount), 0.06)
	tw.tween_property(c, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
