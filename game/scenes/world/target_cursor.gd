class_name TargetCursor
extends Node2D
## Pulsing outline on the tile the player will act on.

var tile := Vector2i(-99, -99)
var active := false
var ok := true
var _t := 0.0
var _rest := 0.0
var _below := false
var _tip: PanelContainer
var _tip_text: Label
## How long the cursor rests on a crop before its growth tip appears.
const TIP_DELAY := 0.35
const TIP_W := 140.0

func _ready() -> void:
	_tip = PanelContainer.new()
	_tip.add_theme_stylebox_override("panel", UITheme.box(Color(0.12, 0.09, 0.1, 0.85), UITheme.COIN, 1, 3, 3, false))
	_tip.visible = false
	_tip.z_index = 10
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tip)
	_tip_text = UITheme.label("", 7, UITheme.CREAM)
	_tip_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_text.custom_minimum_size = Vector2(TIP_W, 0)
	_tip.add_child(_tip_text)

## from: the actor's tile, so the tip opens on the side away from them.
func show_at(t: Vector2i, can_act: bool, from: Vector2i = Vector2i(-99, -99)) -> void:
	_below = t.y > from.y and from.x != -99
	if t != tile:
		_rest = 0.0 if not _tip.visible else TIP_DELAY
		_tip.visible = false
	tile = t
	ok = can_act
	active = true
	position = Vector2(t.x * Tiles.TILE, t.y * Tiles.TILE)
	queue_redraw()

func hide_cursor() -> void:
	if active:
		active = false
		_tip.visible = false
		queue_redraw()

func _process(delta: float) -> void:
	if active:
		_t += delta
		_rest += delta
		if _rest >= TIP_DELAY:
			_rest -= 1.0
			_refresh_tip()
		queue_redraw()

## "Parsnip / ripe in 12 min · 2 harvests left · watered" above an aimed crop.
func _refresh_tip() -> void:
	var g: FarmGrid = get_parent().grid if get_parent() is World else null
	if g == null or g.crop_at(tile).is_empty():
		_tip.visible = false
		return
	var c := g.crop_at(tile)
	if g.crop_ready(tile):
		_tip_text.text = "%s\n%s" % [Data.item_name(c.id), tr("Ready to harvest")]
	else:
		_tip_text.text = Controller.crop_info(g, tile).replace(": ", "\n")
	_tip.reset_size()
	_tip.position = Vector2(Tiles.TILE / 2.0 - _tip.size.x / 2.0, Tiles.TILE + 3 if _below else -_tip.size.y - 3)
	_tip.visible = true

func _draw() -> void:
	if not active:
		return
	var a := 0.55 + 0.25 * sin(_t * 6.0)
	var c := Color(1, 1, 1, a) if ok else Color(1, 0.5, 0.4, a * 0.7)
	var s := float(Tiles.TILE)
	var l := 7.0
	for corner in [Vector2(0, 0), Vector2(s, 0), Vector2(0, s), Vector2(s, s)]:
		var dx := 1.0 if corner.x == 0 else -1.0
		var dy := 1.0 if corner.y == 0 else -1.0
		draw_line(corner + Vector2(dx, dy), corner + Vector2(dx * l, dy), c, 2)
		draw_line(corner + Vector2(dx, dy), corner + Vector2(dx, dy * l), c, 2)
