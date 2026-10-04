class_name PokerPanel
extends CasinoPanel
## Jacks or Better video poker: bet 1 to 5 coins, deal, hold, draw.

var _hand: Dictionary = {}
var _coins := 5
var _cards: Array = []
var _holds: Array = [false, false, false, false, false]
var _pay_cells: Dictionary = {}
var _msg: Label
var _coin_row: HBoxContainer
var _btn: Button

func _init() -> void:
	super("poker")

func title() -> String:
	return tr("Video Poker")

func rules() -> String:
	return tr("Jacks or Better. You get five cards; click the ones you want to keep, then draw to replace the rest. The final hand pays by the table, per coin. A pair of jacks, queens, kings or aces is the smallest paying hand. A royal flush pays 800 per coin when you play all five coins, so max coins is the best play. One coin costs %d chips. With perfect play the machine returns about 99.5 %%.") % int(Casino.cfg().poker.coin)

func panel_size() -> Vector2:
	return Vector2(480, 320)

func build() -> void:
	var table := GridContainer.new()
	table.columns = 6
	table.add_theme_constant_override("h_separation", 6)
	table.add_theme_constant_override("v_separation", 0)
	body.add_child(table)
	for hid in VideoPoker.HANDS:
		var n := UITheme.label(VideoPoker.HAND_NAMES[hid], 8, UITheme.INK)
		n.custom_minimum_size = Vector2(110, 0)
		table.add_child(n)
		var cells: Array = []
		for c in range(1, 6):
			var l := UITheme.label(str(VideoPoker.pays(hid, c)), 8, UITheme.INK)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			l.custom_minimum_size = Vector2(40, 0)
			table.add_child(l)
			cells.append(l)
		_pay_cells[hid] = cells
	var felt := PanelContainer.new()
	felt.add_theme_stylebox_override("panel", UITheme.box(Color("#24406a"), Color("#16263e"), 2, 6, 6, false))
	body.add_child(felt)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	felt.add_child(row)
	for i in 5:
		var cv := CardView.new(-1, false)
		cv.custom_minimum_size = Vector2(40, 56)
		cv.clicked.connect(func(): _toggle(i))
		row.add_child(cv)
		_cards.append(cv)
	_msg = UITheme.label("", 9, UITheme.WOOD_DK)
	body.add_child(_msg)
	var ctl := HBoxContainer.new()
	ctl.add_theme_constant_override("separation", 4)
	body.add_child(ctl)
	ctl.add_child(UITheme.label("Coins:", 9, UITheme.INK))
	_coin_row = HBoxContainer.new()
	_coin_row.add_theme_constant_override("separation", 2)
	ctl.add_child(_coin_row)
	for c in range(1, 6):
		var b := UITheme.button(str(c), func(): if not _active(): _coins = c; _sync())
		b.toggle_mode = true
		_coin_row.add_child(b)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctl.add_child(sp)
	_btn = UITheme.button("Deal", _press)
	ctl.add_child(_btn)
	var r: Dictionary = await Coop.act_async("poker_act", ["state"])
	_hand = r.get("hand", {})
	if _active():
		_coins = int(_hand.coins)
	_show_cards()
	_sync()

func _active() -> bool:
	return str(_hand.get("phase", "")) == "hold"

func _toggle(i: int) -> void:
	if not _active():
		return
	_holds[i] = not _holds[i]
	_cards[i].held = _holds[i]
	_cards[i].queue_redraw()
	Audio.sfx("tick")

func _show_cards() -> void:
	var cards: Array = _hand.get("cards", [])
	for i in 5:
		var cv: CardView = _cards[i]
		cv.held = _active() and _holds[i]
		cv.highlight = false
		if i < cards.size():
			cv.set_card(int(cards[i]), true)
		else:
			cv.set_card(-1, false)

func _sync() -> void:
	if not is_inside_tree():
		return
	for i in _coin_row.get_child_count():
		_coin_row.get_child(i).button_pressed = i + 1 == _coins
		_coin_row.get_child(i).disabled = _active()
	var result := str(_hand.get("result", ""))
	for hid in _pay_cells:
		for i in 5:
			var l: Label = _pay_cells[hid][i]
			var on := i + 1 == _coins
			var hit: bool = not _active() and hid == result and on
			l.add_theme_color_override("font_color", Color("#c02020") if hit else (UITheme.WOOD_DK if on else UITheme.MUTED))
	_btn.text = tr("Draw") if _active() else tr("Deal")
	if _active():
		_msg.text = tr("Click cards to hold them, then draw.")
		var now := VideoPoker.evaluate(_hand.cards)
		if now != "":
			_msg.text += "  " + tr("You have: %s") % tr(VideoPoker.HAND_NAMES[now])
	elif _hand.is_empty():
		_msg.text = tr("%d coins = %d chips. Press Deal.") % [_coins, _coins * int(Casino.cfg().poker.coin)]

func _press() -> void:
	if _active():
		var r := await act("poker_act", ["draw", _holds])
		if r.get("ok", false):
			_hand = r.hand
			_show_cards()
			var res := str(_hand.result)
			_msg.text = tr("%s! You win %s chips.") % [tr(VideoPoker.HAND_NAMES[res]), Num.group(int(r.chips))] if res != "" else tr("No win. Deal again?")
	else:
		var r := await act("poker_act", ["deal", _coins])
		if r.get("ok", false):
			_hand = r.hand
			_holds = [false, false, false, false, false]
			_show_cards()
	_sync()
