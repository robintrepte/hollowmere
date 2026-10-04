class_name CasinoPanel
extends PanelContainer
## Shared frame for every casino screen: title, chip count, rules, a chip picker, the table feed
## (what other players at the same table just did) and the reminder that chips are play money.

signal closed

var game := ""
var body: VBoxContainer
var chip_value := 10
var _chips: CoinLabel
var _feed: Label
var _feed_lines: Array = []
var _picker: HBoxContainer
var _busy := false
## While a wheel or reels are still turning, the chip count waits so it doesn't give the result away.
var hold_chips := false

const CHIP_COLORS := {1: "#e8e0d0", 5: "#d04040", 10: "#4070d0", 25: "#40a050", 100: "#303030", 500: "#9040b0", 1000: "#e0a020"}

func _init(game_id: String = "") -> void:
	game = game_id

func me() -> PlayerData:
	return GameState.local_player()

func title() -> String:
	return ""

func rules() -> String:
	return ""

func panel_size() -> Vector2:
	return Vector2(580, 320)

## Subclasses fill `body` here.
func build() -> void:
	pass

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	var sz := panel_size()
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -sz.x / 2
	offset_right = sz.x / 2
	offset_top = -sz.y / 2
	offset_bottom = sz.y / 2
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	v.add_child(head)
	var t := UITheme.label(title(), 14, UITheme.WOOD_DK)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	_chips = CoinLabel.new(Casino.chips(me()), 12, UITheme.WOOD_DK, "_chip")
	head.add_child(_chips)
	if rules() != "":
		head.add_child(UITheme.button("Rules", show_rules))
	head.add_child(UITheme.button("Close", func(): if not _busy: closed.emit()))
	body = VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 4)
	v.add_child(body)
	var foot := HBoxContainer.new()
	v.add_child(foot)
	_feed = UITheme.label("", 7, UITheme.MUTED)
	_feed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_feed.clip_text = true
	foot.add_child(_feed)
	foot.add_child(UITheme.label("Chips are play money with no real-world value.", 7, UITheme.MUTED))
	EventBus.chips_changed.connect(refresh_chips)
	EventBus.casino_news.connect(_on_news)
	build()

func refresh_chips() -> void:
	if not hold_chips and is_instance_valid(_chips) and me():
		_chips.set_amount(Casino.chips(me()))

func _on_news(g: String, text: String) -> void:
	if g != game or not is_instance_valid(_feed):
		return
	_feed_lines.push_front(text)
	_feed_lines = _feed_lines.slice(0, 2)
	_feed.text = "  ·  ".join(_feed_lines)

## Runs a casino action through the host. Shows the reason on failure.
func act(action: String, args: Array) -> Dictionary:
	_busy = true
	var r: Dictionary = await Coop.act_async(action, args)
	_busy = false
	if not r.get("ok", false):
		Audio.sfx("error")
		if str(r.get("reason", "")) != "":
			EventBus.toast.emit(str(r.reason), "")
	elif str(r.get("sfx", "")) != "":
		Audio.sfx(str(r.sfx))
	refresh_chips()
	return r

## Chip buttons; the picked one is the value each click on the table adds.
func chip_picker(values: Array) -> HBoxContainer:
	_picker = HBoxContainer.new()
	_picker.add_theme_constant_override("separation", 3)
	if not chip_value in values:
		chip_value = int(values[0])
	for val in values:
		var b := ChipButton.new(int(val), Color(CHIP_COLORS.get(int(val), "#808080")))
		b.selected = int(val) == chip_value
		b.pressed.connect(func():
			chip_value = int(val)
			Audio.sfx("chips")
			for c in _picker.get_children():
				c.selected = c.value == chip_value
				c.queue_redraw())
		_picker.add_child(b)
	return _picker

func show_rules() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.parchment(10))
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	p.add_child(v)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var l := UITheme.label(rules(), 9, UITheme.INK)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(l)
	v.add_child(UITheme.button("Got it", func(): p.queue_free()))
	add_child(p)

static func chip_color(val: int) -> Color:
	var best := 1
	for k in CHIP_COLORS:
		if int(k) <= val:
			best = maxi(best, int(k))
	return Color(CHIP_COLORS[best])

## A round casino chip with its value, drawn in code.
static func draw_chip(ci: CanvasItem, center: Vector2, r: float, val: int, outline: bool = false) -> void:
	var col := chip_color(val)
	ci.draw_circle(center + Vector2(0, 1), r, Color(0, 0, 0, 0.35))
	ci.draw_circle(center, r, col)
	for i in 6:
		var a := TAU * i / 6.0
		ci.draw_line(center + Vector2(cos(a), sin(a)) * (r - 2.5), center + Vector2(cos(a), sin(a)) * r, Color(1, 1, 1, 0.85), 1.5)
	ci.draw_arc(center, r - 3.0, 0, TAU, 20, Color(1, 1, 1, 0.5), 1.0)
	ci.draw_arc(center, r, 0, TAU, 24, Color("#ffd447") if outline else UITheme.OUTLINE, 1.5 if outline else 1.0)
	var f := UITheme.font()
	var t := Num.short(val)
	var fs := 7 if t.length() <= 2 else 6
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var tc := UITheme.INK if col.get_luminance() > 0.6 else Color.WHITE
	ci.draw_string(f, center + Vector2(-w / 2.0, fs * 0.35), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, tc)
