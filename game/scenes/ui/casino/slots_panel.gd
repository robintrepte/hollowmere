class_name SlotsPanel
extends CasinoPanel
## Slot machines: three themes on the same math, ten lines, a paytable and the shared jackpot.

var _reels: SlotReels
var _line_bet := 1
var _theme := "orchard"
var _win: Label
var _pot: CoinLabel
var _bet_label: Label
var _spin_btn: Button
var _themes: HBoxContainer
var _bets: HBoxContainer

func _init(theme_id: String = "orchard") -> void:
	super("slots")
	_theme = theme_id

func title() -> String:
	return tr(str(Slots.cfg().themes[_theme].name))

func rules() -> String:
	return tr("Ten lines run across five reels from left to right. Three or more equal symbols on a line from the first reel pay that symbol's amount times your line bet. The wild stands in for every line symbol except the jackpot. Scatters pay anywhere on the reels, times your total bet. Five jackpot symbols on a line win the progressive jackpot, scaled by your line bet (the full pot at the top line bet). One chip in every hundred staked grows the pot. Over many spins the machine returns about 95 % of what goes in.")

func panel_size() -> Vector2:
	return Vector2(460, 300)

func build() -> void:
	_themes = HBoxContainer.new()
	_themes.add_theme_constant_override("separation", 4)
	body.add_child(_themes)
	for t in Slots.cfg().themes:
		var b := UITheme.button(str(Slots.cfg().themes[t].name), func(): _set_theme(t))
		b.toggle_mode = true
		b.button_pressed = t == _theme
		_themes.add_child(b)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	body.add_child(row)
	_reels = SlotReels.new()
	_reels.theme_id = _theme
	var g := RandomNumberGenerator.new()
	for i in 5:
		_reels.stops[i] = g.randi_range(0, Slots.strip().length() - 1)
		_reels.offsets[i] = float(_reels.stops[i])
	row.add_child(_reels)
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 5)
	row.add_child(side)
	side.add_child(UITheme.label("Jackpot", 9, UITheme.WOOD_DK))
	_pot = CoinLabel.new(int(GameState.world.get("casino", {}).get("jackpot", Slots.cfg().jackpot_seed)), 12, Color("#a04a00"), "_chip")
	side.add_child(_pot)
	_win = UITheme.label("", 10, UITheme.WOOD_DK)
	_win.custom_minimum_size = Vector2(140, 0)
	_win.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_win)
	side.add_child(UITheme.button("Paytable", _paytable))
	var ctl := HBoxContainer.new()
	ctl.add_theme_constant_override("separation", 4)
	body.add_child(ctl)
	ctl.add_child(UITheme.label("Line bet:", 9, UITheme.INK))
	_bets = HBoxContainer.new()
	_bets.add_theme_constant_override("separation", 2)
	ctl.add_child(_bets)
	for n in [1, 2, 5, 10]:
		var b := UITheme.button(str(n), func(): _line_bet = n; _sync())
		b.toggle_mode = true
		_bets.add_child(b)
	_bet_label = UITheme.label("", 9, UITheme.INK)
	_bet_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctl.add_child(_bet_label)
	_spin_btn = UITheme.button("Spin", _spin)
	ctl.add_child(_spin_btn)
	_sync()

func _sync() -> void:
	var vals := [1, 2, 5, 10]
	for i in _bets.get_child_count():
		_bets.get_child(i).button_pressed = vals[i] == _line_bet
	_bet_label.text = tr("Total bet: %d chips") % (_line_bet * Slots.LINES)
	_spin_btn.disabled = _reels.spinning
	for i in _themes.get_child_count():
		_themes.get_child(i).button_pressed = Slots.cfg().themes.keys()[i] == _theme

func _set_theme(t: String) -> void:
	if _reels.spinning:
		return
	_theme = t
	_reels.theme_id = t
	_reels.wins = []
	_reels.queue_redraw()
	_sync()

func _spin() -> void:
	if _reels.spinning:
		return
	hold_chips = true
	_chips.set_amount(Casino.chips(me()) - _line_bet * Slots.LINES)
	var r := await act("slots_act", [_line_bet])
	if not r.get("ok", false):
		hold_chips = false
		refresh_chips()
		return
	_win.text = ""
	_spin_btn.disabled = true
	_busy = true
	_reels.spin_to(r.spin.stops, r.spin.lines)
	await _reels.stopped
	_busy = false
	hold_chips = false
	if not is_inside_tree():
		return
	refresh_chips()
	_pot.set_amount(int(r.jackpot_pot))
	var won := int(r.chips)
	if int(r.spin.jackpot) > 0:
		Audio.sfx("jackpot")
		Juice.burst(self, size / 2.0, "levelup")
		_win.text = tr("JACKPOT! %s chips!") % Num.group(won)
	elif won > 0:
		Audio.sfx("reels_win")
		var extra := tr(" (%d scatters)") % int(r.spin.scatters) if int(r.spin.scatter) > 0 else ""
		_win.text = tr("You win %s chips%s.") % [Num.group(won), extra]
	_sync()

func _paytable() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.parchment(8))
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	p.add_child(v)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	v.add_child(grid)
	var pays: Dictionary = Slots.cfg().pays
	for sym in ["F", "E", "D", "C", "B", "A", "W", "J", "S"]:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		h.add_child(UITheme.icon_rect(_reels.tex(sym), 20))
		var t := ""
		if sym == "S":
			var sc: Array = Slots.cfg().scatter
			t = tr("Scatter: 3 = x%d, 4 = x%d, 5 = x%d total bet") % [sc[0], sc[1], sc[2]]
		elif sym == "J":
			t = tr("3 = %d, 4 = %d, 5 = JACKPOT") % [int(pays.J[0]), int(pays.J[1])]
		else:
			t = "3 = %d, 4 = %d, 5 = %d" % [int(pays[sym][0]), int(pays[sym][1]), int(pays[sym][2])]
			if sym == "W":
				t = tr("Wild: %s") % t
		h.add_child(UITheme.label(t, 8, UITheme.INK))
		grid.add_child(h)
	v.add_child(UITheme.label("Line wins are multiplied by the line bet.", 8, UITheme.MUTED))
	v.add_child(UITheme.button("Got it", func(): p.queue_free()))
	add_child(p)
