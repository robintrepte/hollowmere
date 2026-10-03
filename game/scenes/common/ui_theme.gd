class_name UITheme
extends RefCounted
## Builds the cozy parchment + wood UI theme in code (no .tres to keep in sync).

const INK := Color("#3a2a2e")
const OUTLINE := Color("#22181e")
const PARCHMENT := Color("#f4e4c4")
const PARCHMENT_DK := Color("#e2cc9f")
const CREAM := Color("#fff4dc")
const WOOD := Color("#8a5a3a")
const WOOD_LT := Color("#b07a48")
const WOOD_DK := Color("#5e3a24")
const LEAF := Color("#5fa64b")
const COIN := Color("#f0c040")
const HEART := Color("#e05060")
const ENERGY := Color("#70d050")
const MUTED := Color("#8a7a6a")

static var _theme: Theme
static var _font: FontVariation

## A font size scaled by the player's text size setting.
static func fs(size: int) -> int:
	return int(round(size * Settings.text_scale))

## Drops the cached theme so the next theme() call picks up a new text size.
static func reset() -> void:
	_theme = null

static func font() -> Font:
	if _font == null:
		_font = FontVariation.new()
		_font.base_font = load("res://assets/fonts/Tiny5.ttf")
		_font.fallbacks = [symbols()]
	return _font

## Hearts, stars and checkmarks Tiny5 lacks. Browsers have no system fallback fonts.
static func symbols() -> Font:
	var f: FontFile = load("res://assets/fonts/SymbolsFallback.ttf")
	f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	return f

static func box(bg: Color, border: Color = OUTLINE, bw: int = 2, radius: int = 3, pad: int = 6, shadow: bool = true) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(pad)
	s.anti_aliasing = false
	if shadow:
		s.shadow_color = Color(0, 0, 0, 0.25)
		s.shadow_size = 0
		s.shadow_offset = Vector2(0, 2)
	return s

static func parchment(pad: int = 8) -> StyleBoxFlat:
	var s := box(PARCHMENT, OUTLINE, 2, 4, pad)
	s.border_width_bottom = 3
	return s

static func wood(pad: int = 6) -> StyleBoxFlat:
	var s := box(WOOD, OUTLINE, 2, 3, pad)
	s.border_width_bottom = 3
	return s

static func slot(selected: bool = false) -> StyleBoxFlat:
	var s := box(Color("#d9c08e") if not selected else Color("#fff0b8"), Color("#ffd447") if selected else Color("#7a5a3a"), 2 if selected else 1, 2, 0, false)
	return s

static func theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = fs(10)
	t.set_color("font_color", "Label", INK)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	t.set_stylebox("panel", "Panel", parchment())
	t.set_stylebox("panel", "PanelContainer", parchment())
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		var b := wood(5)
		match st:
			"hover": b.bg_color = WOOD_LT
			"pressed":
				b.bg_color = WOOD_DK
				b.border_width_bottom = 2
			"disabled": b.bg_color = Color("#9a8a7a")
			"focus":
				b.bg_color = Color(0, 0, 0, 0)
				b.border_color = Color("#ffd447")
				b.shadow_size = 0
		b.content_margin_left = 10
		b.content_margin_right = 10
		b.content_margin_top = 4
		b.content_margin_bottom = 5
		t.set_stylebox(st, "Button", b)
	t.set_color("font_color", "Button", CREAM)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", PARCHMENT_DK)
	t.set_color("font_disabled_color", "Button", Color("#d8ccb8"))
	t.set_color("font_focus_color", "Button", Color.WHITE)
	t.set_font_size("font_size", "Button", fs(10))
	var le := box(CREAM, Color("#7a5a3a"), 2, 2, 4, false)
	t.set_stylebox("normal", "LineEdit", le)
	var lef := le.duplicate()
	lef.border_color = Color("#ffd447")
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_color("font_color", "LineEdit", INK)
	t.set_color("caret_color", "LineEdit", INK)
	t.set_color("font_placeholder_color", "LineEdit", MUTED)
	var sb_bg := box(Color("#c8b088"), Color("#7a5a3a"), 1, 2, 0, false)
	var sb_fill := box(LEAF, Color(0, 0, 0, 0), 0, 2, 0, false)
	t.set_stylebox("background", "ProgressBar", sb_bg)
	t.set_stylebox("fill", "ProgressBar", sb_fill)
	t.set_stylebox("slider", "HSlider", box(Color("#c8b088"), Color("#7a5a3a"), 1, 2, 2, false))
	t.set_stylebox("grabber_area", "HSlider", box(WOOD_LT, Color("#7a5a3a"), 1, 2, 2, false))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(COIN, Color("#7a5a3a"), 1, 2, 2, false))
	t.set_stylebox("panel", "TooltipPanel", box(Color("#2e2228"), COIN, 1, 2, 4, false))
	t.set_color("font_color", "TooltipLabel", CREAM)
	t.set_font_size("font_size", "TooltipLabel", fs(9))
	t.set_color("font_color", "CheckBox", INK)
	t.set_color("font_hover_color", "CheckBox", INK)
	t.set_color("font_pressed_color", "CheckBox", INK)
	t.set_color("font_hover_pressed_color", "CheckBox", INK)
	t.set_color("font_focus_color", "CheckBox", INK)
	var cb_flat := StyleBoxEmpty.new()
	cb_flat.content_margin_left = 2
	cb_flat.content_margin_right = 4
	var cb_focus := box(Color(0, 0, 0, 0), Color("#ffd447"), 1, 2, 2, false)
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		t.set_stylebox(st, "CheckBox", cb_flat)
	t.set_stylebox("focus", "CheckBox", cb_focus)
	t.set_color("font_color", "OptionButton", CREAM)
	t.set_stylebox("panel", "PopupMenu", parchment(4))
	t.set_color("font_color", "PopupMenu", INK)
	t.set_color("font_hover_color", "PopupMenu", WOOD_DK)
	t.set_stylebox("hover", "PopupMenu", box(PARCHMENT_DK, Color(0, 0, 0, 0), 0, 2, 2, false))
	t.set_color("default_color", "RichTextLabel", INK)
	t.set_font_size("normal_font_size", "RichTextLabel", fs(10))
	t.set_font_size("bold_font_size", "RichTextLabel", fs(10))
	var bold := FontVariation.new()
	bold.base_font = load("res://assets/fonts/Tiny5.ttf")
	bold.fallbacks = [symbols()]
	bold.variation_embolden = 0.6
	t.set_font("bold_font", "RichTextLabel", bold)
	var sc := box(Color(0, 0, 0, 0.12), Color(0, 0, 0, 0), 0, 2, 0, false)
	t.set_stylebox("scroll", "VScrollBar", sc)
	t.set_stylebox("grabber", "VScrollBar", box(WOOD_LT, Color(0, 0, 0, 0), 0, 2, 0, false))
	t.set_stylebox("grabber_highlight", "VScrollBar", box(WOOD, Color(0, 0, 0, 0), 0, 2, 0, false))
	t.set_stylebox("grabber_pressed", "VScrollBar", box(WOOD_DK, Color(0, 0, 0, 0), 0, 2, 0, false))
	_theme = t
	return t

static func label(text: String, size: int = 10, col: Color = INK, outline: bool = false) -> Label:
	var l := Label.new()
	l.text = tr(text) if text != "" else text
	l.add_theme_font_override("font", font())
	l.add_theme_font_size_override("font_size", fs(size))
	l.add_theme_color_override("font_color", col)
	if outline:
		l.add_theme_color_override("font_outline_color", OUTLINE)
		l.add_theme_constant_override("outline_size", 4)
	return l

static func button(text: String, cb: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = tr(text) if text != "" else text
	b.focus_mode = Control.FOCUS_ALL
	if cb.is_valid():
		b.pressed.connect(cb)
	b.pressed.connect(func(): Audio.sfx("ui"))
	return b

static func icon_rect(t: Texture2D, size: int = 32) -> TextureRect:
	var r := TextureRect.new()
	r.texture = t
	r.custom_minimum_size = Vector2(size, size)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return r
