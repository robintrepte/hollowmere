class_name WeatherFx
extends CanvasLayer
## Screen-space rain / snow / storm / wind-petal particles.

var kind := ""
var _p: CPUParticles2D
var _flash: ColorRect
var _flash_t := 0.0

func _ready() -> void:
	layer = 5
	_p = CPUParticles2D.new()
	_p.emitting = false
	_p.position = Vector2(320, -10)
	_p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_p.emission_rect_extents = Vector2(400, 4)
	add_child(_p)
	_flash = ColorRect.new()
	_flash.color = Color(1, 1, 1, 0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_flash)

func set_kind(k: String) -> void:
	kind = k
	if _p == null:
		return
	_p.emitting = false
	match k:
		"rain", "storm":
			_p.amount = 160 if k == "rain" else 260
			_p.lifetime = 0.8
			_p.direction = Vector2(-0.25, 1)
			_p.spread = 3
			_p.initial_velocity_min = 380
			_p.initial_velocity_max = 460
			_p.gravity = Vector2.ZERO
			_p.scale_amount_min = 1
			_p.scale_amount_max = 1
			_p.color = Color(0.75, 0.85, 1.0, 0.55)
			_p.texture = _streak()
			_p.emitting = true
		"snow":
			_p.amount = 120
			_p.lifetime = 5.0
			_p.direction = Vector2(-0.2, 1)
			_p.spread = 20
			_p.initial_velocity_min = 25
			_p.initial_velocity_max = 45
			_p.gravity = Vector2(0, 4)
			_p.scale_amount_min = 1
			_p.scale_amount_max = 2
			_p.color = Color(1, 1, 1, 0.85)
			_p.texture = null
			_p.emitting = true
		"wind":
			_p.amount = 24
			_p.lifetime = 4.0
			_p.direction = Vector2(1, 0.3)
			_p.position = Vector2(-10, 180)
			_p.emission_rect_extents = Vector2(4, 200)
			_p.initial_velocity_min = 90
			_p.initial_velocity_max = 140
			_p.gravity = Vector2.ZERO
			_p.scale_amount_min = 1.5
			_p.scale_amount_max = 2.5
			_p.color = Color(1.0, 0.75, 0.85, 0.9) if GameState.season() == "spring" else Color(0.95, 0.65, 0.3, 0.9)
			_p.texture = null
			_p.emitting = true
	if k != "wind":
		_p.position = Vector2(320, -10)
		_p.emission_rect_extents = Vector2(400, 4)

func _streak() -> Texture2D:
	var img := Image.create(1, 6, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(img)

func _process(delta: float) -> void:
	if kind == "storm":
		_flash_t -= delta
		if _flash_t <= 0:
			_flash_t = randf_range(6, 14)
			var tw := create_tween()
			tw.tween_property(_flash, "color:a", 0.5, 0.05)
			tw.tween_property(_flash, "color:a", 0.0, 0.35)
			Audio.sfx("thunder")
