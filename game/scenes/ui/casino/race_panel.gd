class_name RacePanel
extends CasinoPanel
## Wildling races: read the card, back one runner at fixed odds and watch them run.

var _card: Array = []
var _list: VBoxContainer
var _track: RaceTrack
var _pick := -1
var _bet := 0
var _bet_label: Label
var _start: Button
var _msg: Label

func _init() -> void:
	super("race")

func title() -> String:
	return tr("Wildling Races")

func rules() -> String:
	return tr("Six wildlings line up for each race. Their chance to win comes from their base speed and today's form; the odds already include the house's share. Pick one runner and place your bet. If your runner crosses the line first you get your bet times the odds back (odds of 3.5 turn 10 chips into 35). A new card is drawn after every race.")

func panel_size() -> Vector2:
	return Vector2(560, 310)

func build() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 1)
	_list.custom_minimum_size = Vector2(210, 0)
	row.add_child(_list)
	_track = RaceTrack.new()
	_track.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_track)
	_msg = UITheme.label("Pick a runner.", 9, UITheme.WOOD_DK)
	body.add_child(_msg)
	var ctl := HBoxContainer.new()
	ctl.add_theme_constant_override("separation", 4)
	body.add_child(ctl)
	var picker := chip_picker([10, 25, 100, 500])
	ctl.add_child(picker)
	for b in picker.get_children():
		b.pressed.connect(func(): _bet += chip_value; _sync())
	_bet_label = UITheme.label("", 9, UITheme.INK)
	_bet_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctl.add_child(_bet_label)
	ctl.add_child(UITheme.button("Clear", func(): _bet = 0; _sync()))
	_start = UITheme.button("Start race", _run)
	ctl.add_child(_start)
	_load_card()

func _load_card() -> void:
	var r: Dictionary = await Coop.act_async("race_card_act", [])
	if not is_inside_tree():
		return
	_card = r.get("card", [])
	_pick = -1
	_track.set_runners(_card)
	_track.pick = -1
	_render_card()
	_sync()

func _render_card() -> void:
	for c in _list.get_children():
		c.queue_free()
	var head := HBoxContainer.new()
	_list.add_child(head)
	for h in [["Runner", 110], ["Speed", 36], ["Form", 30], ["Odds", 34]]:
		var l := UITheme.label(h[0], 7, UITheme.MUTED)
		l.custom_minimum_size = Vector2(h[1], 0)
		head.add_child(l)
	for i in _card.size():
		var r: Dictionary = _card[i]
		var b := Button.new()
		b.toggle_mode = true
		b.button_pressed = i == _pick
		b.custom_minimum_size = Vector2(0, 22)
		var row_bg := UITheme.box(UITheme.PARCHMENT_DK, UITheme.OUTLINE, 1, 3, 2, false)
		b.add_theme_stylebox_override("normal", row_bg)
		b.add_theme_stylebox_override("hover", UITheme.box(UITheme.PARCHMENT_DK.lightened(0.15), UITheme.OUTLINE, 1, 3, 2, false))
		b.add_theme_stylebox_override("pressed", UITheme.box(UITheme.PARCHMENT_DK.lightened(0.25), UITheme.COIN, 2, 3, 2, false))
		b.add_theme_stylebox_override("hover_pressed", b.get_theme_stylebox("pressed"))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(func(): _pick = i; _track.pick = i; _track.queue_redraw(); _render_card(); _sync())
		var h := HBoxContainer.new()
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.set_anchors_preset(Control.PRESET_FULL_RECT)
		h.add_theme_constant_override("separation", 2)
		b.add_child(h)
		var icon := UITheme.icon_rect(Art.creature(str(r.species), true), 18)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(icon)
		var form := float(r.form)
		var cells := [[Data.species_name(str(r.species)), 90], [str(int(r.speed)), 36], ["▲" if form >= 1.05 else ("▼" if form <= 0.95 else "–"), 30], ["%.1f" % float(r.odds), 34]]
		var form_col := UITheme.LEAF.darkened(0.2) if form >= 1.05 else (UITheme.HEART if form <= 0.95 else UITheme.INK)
		for ci in cells.size():
			var c: Array = cells[ci]
			var l := UITheme.label(c[0], 8, form_col if ci == 2 else UITheme.INK)
			l.custom_minimum_size = Vector2(c[1], 0)
			l.clip_text = true
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			h.add_child(l)
		_list.add_child(b)

func _sync() -> void:
	var odds := float(_card[_pick].odds) if _pick >= 0 and _pick < _card.size() else 0.0
	_bet_label.text = tr("Bet: %s") % Num.group(_bet) + ("  ·  " + tr("pays %s") % Num.group(int(floor(_bet * odds))) if odds > 0 and _bet > 0 else "")
	_start.disabled = _pick < 0 or _bet <= 0 or _track.running

func _run() -> void:
	if _pick < 0 or _bet <= 0 or _track.running:
		return
	hold_chips = true
	_chips.set_amount(Casino.chips(me()) - _bet)
	var r := await act("race_act", [_pick, _bet])
	if not r.get("ok", false):
		hold_chips = false
		refresh_chips()
		return
	_msg.text = tr("And they're off!")
	_start.disabled = true
	_busy = true
	_track.start(r.race.paths)
	await _track.finished
	_busy = false
	hold_chips = false
	if not is_inside_tree():
		return
	refresh_chips()
	var winner := Data.species_name(str(_card[int(r.race.winner)].species))
	if int(r.chips) > 0:
		Audio.sfx("chips")
		_msg.text = tr("%s wins! You collect %s chips.") % [winner, Num.group(int(r.chips))]
	else:
		_msg.text = tr("%s wins. Better luck next race.") % winner
	await get_tree().create_timer(1.6).timeout
	if is_inside_tree():
		_load_card()
