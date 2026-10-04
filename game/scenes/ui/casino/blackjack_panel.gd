class_name BlackjackPanel
extends CasinoPanel
## Blackjack against the house: bet, deal, then hit, stand, double, split or take insurance.

var _hand: Dictionary = {}
var _dealer_row: HBoxContainer
var _dealer_total: Label
var _hands_box: VBoxContainer
var _msg: Label
var _hint: Label
var _controls: HBoxContainer
var _bet := 0
var _hints := false

const RESULT_TEXT := {"win": "Win", "blackjack": "Blackjack!", "push": "Push", "lose": "Lose", "bust": "Bust"}

func _init() -> void:
	super("blackjack")

func title() -> String:
	return tr("Blackjack")

func rules() -> String:
	return tr("Get closer to 21 than the dealer without going over. Number cards count their value, faces count 10, aces 1 or 11. Blackjack (an ace and a ten on the first two cards) pays 3:2, other wins pay 1:1, ties push. The dealer draws to 16 and stands on all 17s, including soft 17, and checks for blackjack first. Double on any two cards, also after a split. Split equal cards up to four hands; split aces get one card each. When the dealer shows an ace you may take insurance for half your bet, which pays 2:1 if the dealer has blackjack. Six decks, shuffled when the cut card comes out.")

func panel_size() -> Vector2:
	return Vector2(520, 310)

func build() -> void:
	var felt := PanelContainer.new()
	felt.add_theme_stylebox_override("panel", UITheme.box(Color("#2f7a4a"), Color("#1e4a30"), 2, 6, 6, false))
	felt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(felt)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	felt.add_child(v)
	var dh := HBoxContainer.new()
	v.add_child(dh)
	dh.add_child(UITheme.label("Dealer", 9, Color("#e8d8a0")))
	_dealer_total = UITheme.label("", 9, Color.WHITE)
	dh.add_child(_dealer_total)
	_dealer_row = HBoxContainer.new()
	_dealer_row.add_theme_constant_override("separation", 3)
	_dealer_row.custom_minimum_size = Vector2(0, 44)
	v.add_child(_dealer_row)
	_hands_box = VBoxContainer.new()
	_hands_box.add_theme_constant_override("separation", 2)
	_hands_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_hands_box)
	_msg = UITheme.label("Place your bet.", 9, Color("#ffe58a"))
	v.add_child(_msg)
	_hint = UITheme.label("", 8, Color("#c8f0d0"))
	v.add_child(_hint)
	_controls = HBoxContainer.new()
	_controls.add_theme_constant_override("separation", 4)
	body.add_child(_controls)
	var hints := CheckBox.new()
	hints.text = tr("Strategy hints")
	hints.add_theme_font_override("font", UITheme.font())
	hints.add_theme_font_size_override("font_size", UITheme.fs(8))
	hints.toggled.connect(func(on): _hints = on; _render())
	body.add_child(hints)
	var r: Dictionary = await Coop.act_async("blackjack_act", ["state"])
	_hand = r.get("hand", {})
	_render()

func _bj() -> Blackjack:
	return Blackjack.new({"hand": _hand, "seed": 1, "round": 0, "shoe_seed": 1, "pos": 0}, 0)

func _playing() -> bool:
	return not _hand.is_empty() and str(_hand.get("phase", "")) != "done"

func _render() -> void:
	if not is_inside_tree():
		return
	for c in _dealer_row.get_children():
		c.queue_free()
	for c in _hands_box.get_children():
		c.queue_free()
	for c in _controls.get_children():
		c.queue_free()
	_hint.text = ""
	var done := str(_hand.get("phase", "")) == "done"
	if not _hand.is_empty():
		var dealer: Array = _hand.dealer
		for i in dealer.size():
			_dealer_row.add_child(CardView.new(int(dealer[i]), i == 0 or done))
		_dealer_total.text = "  %d" % int(Blackjack.total(dealer)[0]) if done else "  %d" % Blackjack.value(int(dealer[0]))
		var hands: Array = _hand.hands
		for i in hands.size():
			var hd: Dictionary = hands[i]
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 3)
			_hands_box.add_child(row)
			var mark := UITheme.label("▶" if _playing() and i == int(_hand.active) and hands.size() > 1 else "  ", 9, Color("#ffd447"))
			row.add_child(mark)
			for c in hd.cards:
				row.add_child(CardView.new(int(c)))
			var t: Array = Blackjack.total(hd.cards)
			var info := "%s%d" % [tr("soft ") if bool(t[1]) and int(t[0]) < 21 else "", int(t[0])]
			info += "  ·  " + tr("bet %s") % Num.group(int(hd.bet))
			if done and i < _hand.results.size():
				info += "  ·  " + tr(RESULT_TEXT.get(str(_hand.results[i]), ""))
			row.add_child(UITheme.label(info, 9, Color.WHITE))
	if _playing():
		var bj := _bj()
		if _hand.phase == "insurance":
			_msg.text = tr("The dealer shows an ace. Insurance?")
			var ins := UITheme.button(tr("Insurance (%d)") % bj.cost("insurance"), func(): _do("insurance"))
			_controls.add_child(ins)
			_controls.add_child(UITheme.button("No insurance", func(): _do("no_insurance")))
			if _hints:
				_hint.text = tr("Hint: basic strategy never takes insurance.")
		else:
			_msg.text = tr("Your move.")
			for op in [["hit", "Hit"], ["stand", "Stand"], ["double", "Double"], ["split", "Split"]]:
				var b := UITheme.button(op[1], func(): _do(op[0]))
				b.disabled = not bj.can(op[0])
				if op[0] in ["double", "split"] and bj.can(op[0]):
					b.tooltip_text = tr("+%d chips") % bj.cost(op[0])
				_controls.add_child(b)
			if _hints:
				var cur: Dictionary = _hand.hands[int(_hand.active)]
				var adv := Blackjack.advice(cur.cards, int(_hand.dealer[0]), bj.can("double"), bj.can("split"))
				_hint.text = tr("Hint: %s") % tr({"hit": "Hit", "stand": "Stand", "double": "Double", "split": "Split"}[adv])
		return
	if done:
		var staked := int(_hand.insurance)
		for x in _hand.hands:
			staked += int(x.bet)
		var net := int(_hand.credit) - staked
		_msg.text = tr("You win %s chips.") % Num.group(net) if net > 0 else (tr("Even. Your chips come back.") if net == 0 else tr("The house wins %s chips.") % Num.group(-net))
	var picker := chip_picker([10, 25, 100, 500])
	_controls.add_child(picker)
	for b in picker.get_children():
		b.pressed.connect(func(): _bet += chip_value; _render())
	var bl := UITheme.label(tr("Bet: %s") % Num.group(_bet), 9, UITheme.INK)
	bl.custom_minimum_size = Vector2(70, 0)
	_controls.add_child(bl)
	_controls.add_child(UITheme.button("Clear", func(): _bet = 0; _render()))
	var deal := UITheme.button("Deal", _deal)
	deal.disabled = _bet <= 0
	_controls.add_child(deal)

func _deal() -> void:
	var r := await act("blackjack_act", ["deal", _bet])
	if r.get("ok", false):
		_hand = r.hand
		if r.get("shuffled", false):
			EventBus.toast.emit(tr("The dealer shuffles a fresh shoe."), "")
		if str(_hand.phase) == "done":
			_finish()
	_render()

func _do(op: String) -> void:
	var r := await act("blackjack_act", [op, 0])
	if r.get("ok", false):
		_hand = r.hand
		if str(_hand.phase) == "done":
			_finish()
	_render()

func _finish() -> void:
	if "blackjack" in _hand.results:
		Audio.sfx("jackpot")
	elif _hand.results.any(func(x): return x == "win"):
		Audio.sfx("chips")
