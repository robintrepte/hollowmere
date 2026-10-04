class_name CardView
extends Control
## A playing card drawn in code: rank in the corners, a pixel suit in the middle, or the back.
## Card ids follow Blackjack (rank = c % 13 with 0 = ace, suit = c / 13: spades, hearts, diamonds, clubs).

signal clicked()

const RANKS := ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
const SUITS := [
	["...#...", "..###..", ".#####.", "#######", "#######", "...#...", "..###.."],
	[".##.##.", "#######", "#######", ".#####.", "..###..", "...#...", "......."],
	["...#...", "..###..", ".#####.", "#######", ".#####.", "..###..", "...#..."],
	["..###..", "..###..", "##.#.##", "#######", "##.#.##", "...#...", "..###.."],
]
const RED := Color("#c83040")
const BLACK := Color("#22181e")

var card := -1
var face_up := true
var held := false
var highlight := false
var pop := 0.0

func _init(c: int = -1, up: bool = true) -> void:
	card = c
	face_up = up
	custom_minimum_size = Vector2(30, 42)
	mouse_filter = Control.MOUSE_FILTER_PASS

func set_card(c: int, up: bool = true) -> void:
	card = c
	face_up = up
	queue_redraw()

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit()
		accept_event()

static func suit_pixels(ci: CanvasItem, at: Vector2, suit: int, px: float, col: Color) -> void:
	var rows: Array = SUITS[clampi(suit, 0, 3)]
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			if row[x] == "#":
				ci.draw_rect(Rect2(at + Vector2(x, y) * px, Vector2(px, px)), col)

func _draw() -> void:
	var r := Rect2(Vector2(0, -6 if held else 0), size)
	draw_rect(Rect2(r.position + Vector2(1, 2), r.size), Color(0, 0, 0, 0.3))
	if card < 0:
		draw_rect(r, Color(0, 0, 0, 0.12))
		draw_rect(r, Color(0, 0, 0, 0.3), false, 1.0)
		return
	if not face_up:
		draw_rect(r, Color("#7a2030"))
		draw_rect(r.grow(-2), Color("#a83848"))
		for i in range(-int(r.size.y), int(r.size.x), 5):
			draw_line(r.position + Vector2(i, 0), r.position + Vector2(i + r.size.y, r.size.y), Color(1, 1, 1, 0.12), 1.0)
		draw_rect(r, UITheme.OUTLINE, false, 1.0)
		return
	draw_rect(r, Color("#fffaf0"))
	draw_rect(r, Color("#ffd447") if highlight else UITheme.OUTLINE, false, 2.0 if highlight else 1.0)
	var suit := card / 13
	var col := RED if suit in [1, 2] else BLACK
	var f := UITheme.font()
	var rank: String = RANKS[card % 13]
	draw_string(f, r.position + Vector2(3, 10), rank, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, col)
	suit_pixels(self, r.position + Vector2(3, 12), suit, 1.0, col)
	var px := floorf(minf(r.size.x, r.size.y) / 14.0)
	suit_pixels(self, r.position + r.size / 2.0 - Vector2(3.5, 2.5) * px, suit, px, col)
	if held:
		var t := TranslationServer.translate("HOLD")
		var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
		draw_rect(Rect2(r.position.x, r.end.y + 1, r.size.x, 10), Color("#ffd447"))
		draw_string(f, Vector2(r.position.x + (r.size.x - w) / 2.0, r.end.y + 9), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, UITheme.INK)
