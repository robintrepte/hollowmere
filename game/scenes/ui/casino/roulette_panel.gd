class_name RoulettePanel
extends CasinoPanel
## European roulette at the shared table: place chips on the layout, spin, watch the ball drop.

var _table: RouletteTable
var _wheel: RouletteWheel
var _history: HBoxContainer
var _stake: Label
var _result: Label
var _spin_btn: Button
var _last: Array = []

func _init() -> void:
	super("roulette")

func title() -> String:
	return tr("Roulette")

func rules() -> String:
	return tr("European roulette with one zero. Click a number for a straight bet (35:1), the line between two numbers for a split (17:1), the bottom edge of a column of three for a street (11:1), the point where four numbers meet for a corner (8:1) and the bottom corner between two columns for a six line (5:1). Dozens and columns pay 2:1; red, black, even, odd, 1-18 and 19-36 pay 1:1 and lose on zero. Right-click a chip to take it back. Everyone in the casino plays the same wheel.")

func panel_size() -> Vector2:
	return Vector2(600, 300)

func build() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(row)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 4)
	row.add_child(left)
	_wheel = RouletteWheel.new()
	left.add_child(_wheel)
	_history = HBoxContainer.new()
	_history.add_theme_constant_override("separation", 1)
	left.add_child(_history)
	_result = UITheme.label("", 9, UITheme.WOOD_DK)
	_result.custom_minimum_size = Vector2(140, 0)
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_result)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	row.add_child(right)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 6)
	pad.add_theme_constant_override("margin_top", 6)
	right.add_child(pad)
	_table = RouletteTable.new()
	_table.chip_value = chip_value
	_table.changed.connect(_update)
	pad.add_child(_table)
	var picker := chip_picker([5, 25, 100, 500, 1000])
	right.add_child(picker)
	for b in picker.get_children():
		b.pressed.connect(func(): _table.chip_value = chip_value)
	var ctl := HBoxContainer.new()
	ctl.add_theme_constant_override("separation", 4)
	right.add_child(ctl)
	_stake = UITheme.label("", 9, UITheme.INK)
	_stake.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctl.add_child(_stake)
	ctl.add_child(UITheme.button("Clear", func(): _table.clear()))
	ctl.add_child(UITheme.button("Rebet", func(): if not _last.is_empty(): _table.set_bets(_last)))
	_spin_btn = UITheme.button("Spin", _spin)
	ctl.add_child(_spin_btn)
	var l := CasinoGame.limits("roulette", Casino.vip(me()))
	right.add_child(UITheme.label(tr("Table limits: %d to %d chips per spin.") % [l.x, l.y], 7, UITheme.MUTED))
	_draw_history(GameState.world.get("casino", {}).get("tables", {}).get("roulette", {}).get("history", []))
	_update()

func _update() -> void:
	_stake.text = tr("Stake: %s chips") % Num.group(_table.total())
	_spin_btn.disabled = _table.total() <= 0 or _wheel.spinning

func _draw_history(h: Array) -> void:
	for c in _history.get_children():
		c.queue_free()
	for n in h.slice(0, 10):
		var lab := UITheme.label(str(int(n)), 7, Color.WHITE)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.custom_minimum_size = Vector2(12, 10)
		var bg := PanelContainer.new()
		var col := Color("#2a9a5a") if int(n) == 0 else (Color("#c03038") if Roulette.color(int(n)) == "red" else Color("#26202a"))
		bg.add_theme_stylebox_override("panel", UITheme.box(col, UITheme.OUTLINE, 1, 1, 0, false))
		bg.add_child(lab)
		_history.add_child(bg)

func _spin() -> void:
	var bets := _table.bet_list()
	if bets.is_empty() or _wheel.spinning:
		return
	_spin_btn.disabled = true
	hold_chips = true
	_chips.set_amount(Casino.chips(me()) - _table.total())
	var r := await act("roulette_act", [bets])
	if not r.get("ok", false):
		hold_chips = false
		refresh_chips()
		_update()
		return
	_last = bets
	_result.text = ""
	_wheel.spin_to(int(r.number))
	_busy = true
	await _wheel.settled
	_busy = false
	hold_chips = false
	if not is_inside_tree():
		return
	refresh_chips()
	_table.winner = int(r.number)
	_table.bets.clear()
	_table.queue_redraw()
	_draw_history(r.history)
	var colname: String = {"red": tr("red"), "black": tr("black"), "green": tr("green")}[str(r.color)]
	var won := int(r.chips)
	if won > 0:
		Audio.sfx("chips")
		_result.text = tr("%d %s. You win %s chips!") % [int(r.number), colname, Num.group(won)]
	else:
		_result.text = tr("%d %s. No luck this time.") % [int(r.number), colname]
	_update()
