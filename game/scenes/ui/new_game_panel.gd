class_name NewGamePanel
extends PanelContainer
## Character creator: name, farm name, look (paper doll), starter Wildling.

signal closed

const SKINS := ["#f8dcc0", "#f0c8a0", "#d8a880", "#c08860", "#a06a48", "#7a4a30"]
const HAIRS := ["#2a1a14", "#5a3a2a", "#8a4a2a", "#c87838", "#e8c040", "#f0f0f0", "#e070a0", "#4a8ac0", "#4a8a5a", "#7a5aa0"]
const CLOTHES := ["#4a8ac0", "#d07050", "#6a8a4a", "#e0a040", "#a04060", "#5050a0", "#f0f0e0", "#3a3a3a", "#c8a070", "#70b0b0"]

var title: TitleScreen
var look := {"skin": "#f0c8a0", "hair": "#5a3a2a", "shirt": "#4a8ac0", "pants": "#3a3a5a", "style": 0}
var starter := "sproutle"
var _name: LineEdit
var _farm: LineEdit
var _doll: PaperDoll
var _starter_btns: Dictionary = {}
var _style_lbl: Label

func _init(t: TitleScreen = null) -> void:
	title = t

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -230
	offset_right = 230
	offset_top = -165
	offset_bottom = 165
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	add_child(v)
	v.add_child(UITheme.label("A new life in Hollowmere", 14, UITheme.WOOD_DK))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	v.add_child(cols)
	# Preview
	var prev := PanelContainer.new()
	prev.add_theme_stylebox_override("panel", UITheme.box(Color("#9ccf7a"), UITheme.OUTLINE, 2, 4, 0, false))
	prev.custom_minimum_size = Vector2(90, 130)
	cols.add_child(prev)
	var holder := Control.new()
	prev.add_child(holder)
	_doll = PaperDoll.new()
	_doll.position = Vector2(45, 112)
	_doll.scale = Vector2(2, 2)
	holder.add_child(_doll)
	_doll.set_look(look)
	# Fields
	var f := VBoxContainer.new()
	f.add_theme_constant_override("separation", 3)
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(f)
	_name = _field(f, "Your name", "Robin")
	_farm = _field(f, "Farm name", "Sunny")
	_swatches(f, "Skin", SKINS, "skin")
	_swatches(f, "Hair", HAIRS, "hair")
	var sr := HBoxContainer.new()
	f.add_child(sr)
	var sl := UITheme.label("Style", 9)
	sl.custom_minimum_size = Vector2(44, 0)
	sr.add_child(sl)
	sr.add_child(UITheme.button("<", func(): _style(-1)))
	_style_lbl = UITheme.label("short", 9)
	_style_lbl.custom_minimum_size = Vector2(60, 0)
	_style_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sr.add_child(_style_lbl)
	sr.add_child(UITheme.button(">", func(): _style(1)))
	_swatches(f, "Shirt", CLOTHES, "shirt")
	_swatches(f, "Pants", CLOTHES, "pants")
	# Starter
	v.add_child(UITheme.label("Choose your first Wildling partner", 11, UITheme.WOOD))
	var st := HBoxContainer.new()
	st.alignment = BoxContainer.ALIGNMENT_CENTER
	st.add_theme_constant_override("separation", 8)
	v.add_child(st)
	for sid in GameState.STARTERS:
		var sp: Dictionary = Data.get_species(sid)
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(110, 0)
		b.icon = Art.creature(sid, true)
		b.expand_icon = false
		b.text = tr("%s\n%s") % [sp.get("name", sid), "/".join(sp.get("types", [])).capitalize()]
		b.pressed.connect(func(): _pick_starter(sid))
		st.add_child(b)
		_starter_btns[sid] = b
	_pick_starter(starter)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(row)
	row.add_child(UITheme.button("Back", func(): closed.emit()))
	var go := UITheme.button("Start farming!", _start)
	row.add_child(go)
	_name.call_deferred("grab_focus")

func _field(parent: Control, label: String, placeholder: String) -> LineEdit:
	var h := HBoxContainer.new()
	parent.add_child(h)
	var l := UITheme.label(label, 9)
	l.custom_minimum_size = Vector2(60, 0)
	h.add_child(l)
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.max_length = 16
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_font_size_override("font_size", UITheme.fs(10))
	h.add_child(e)
	return e

func _swatches(parent: Control, label: String, colors: Array, key: String) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)
	parent.add_child(h)
	var l := UITheme.label(label, 9)
	l.custom_minimum_size = Vector2(44, 0)
	h.add_child(l)
	for c in colors:
		var b := Button.new()
		b.custom_minimum_size = Vector2(14, 14)
		var sb := UITheme.box(Color(c), UITheme.OUTLINE, 1, 2, 0, false)
		for s in ["normal", "hover", "pressed", "focus"]:
			var sb2 := sb.duplicate()
			if s != "normal":
				sb2.border_color = Color("#ffd447")
				sb2.set_border_width_all(2)
			b.add_theme_stylebox_override(s, sb2)
		b.pressed.connect(func(): look[key] = c; _doll.set_look(look); Audio.sfx("tick", 0.1))
		h.add_child(b)

func _style(d: int) -> void:
	look.style = (int(look.style) + d + Art.HAIR_STYLES.size()) % Art.HAIR_STYLES.size()
	_style_lbl.text = Art.HAIR_STYLES[look.style]
	_doll.set_look(look)

func _pick_starter(sid: String) -> void:
	starter = sid
	for k in _starter_btns:
		_starter_btns[k].button_pressed = k == sid

func _start() -> void:
	var opts := {
		"player_name": _name.text.strip_edges() if _name.text.strip_edges() != "" else "Robin",
		"farm_name": _farm.text.strip_edges() if _farm.text.strip_edges() != "" else "Sunny",
		"look": look.duplicate(), "starter": starter, "seed": randi(),
	}
	closed.emit()
	title.new_game_requested.emit(opts)

func _process(delta: float) -> void:
	if _doll:
		_doll.facing = Vector2.DOWN
		_doll.moving = int(Time.get_ticks_msec() / 1500) % 2 == 1
