class_name CashierPanel
extends CasinoPanel
## The cashier: gold for chips and back at one fixed rate with no fee, plus the daily free chips.

var _info: VBoxContainer

func _init() -> void:
	super("cashier")

func title() -> String:
	return tr("Cashier")

func panel_size() -> Vector2:
	return Vector2(420, 250)

func build() -> void:
	_info = VBoxContainer.new()
	_info.add_theme_constant_override("separation", 6)
	body.add_child(_info)
	_render()

func _render() -> void:
	for c in _info.get_children():
		c.queue_free()
	var p := me()
	var rate := Casino.rate()
	_info.add_child(UITheme.label(tr("1 chip = %s, both ways, no fee.") % CoinLabel.text(rate), 10, UITheme.INK))
	var have := HBoxContainer.new()
	have.add_theme_constant_override("separation", 12)
	_info.add_child(have)
	have.add_child(CoinLabel.new(GameState.money(), 11, UITheme.WOOD_DK))
	have.add_child(CoinLabel.new(Casino.chips(p), 11, UITheme.WOOD_DK, "_chip"))
	var buy := HBoxContainer.new()
	buy.add_theme_constant_override("separation", 4)
	_info.add_child(buy)
	buy.add_child(UITheme.label("Buy chips:", 9, UITheme.INK))
	for n in [10, 100, 1000, 5000]:
		var b := UITheme.button("+%s" % Num.group(n), func(): _trade("buy", n))
		b.disabled = GameState.money() < n * rate
		b.tooltip_text = CoinLabel.text(n * rate)
		buy.add_child(b)
	var sell := HBoxContainer.new()
	sell.add_theme_constant_override("separation", 4)
	_info.add_child(sell)
	sell.add_child(UITheme.label("Cash out:", 9, UITheme.INK))
	for n in [10, 100, 1000]:
		var b := UITheme.button("-%s" % Num.group(n), func(): _trade("sell", n))
		b.disabled = Casino.chips(p) < n
		sell.add_child(b)
	var all := UITheme.button("Cash out all", func(): _trade("sell", Casino.chips(me())))
	all.disabled = Casino.chips(p) <= 0
	sell.add_child(all)
	var bonus := HBoxContainer.new()
	_info.add_child(bonus)
	if Casino.bonus_ready(p):
		bonus.add_child(UITheme.button(tr("Collect today's %d free chips") % Casino.daily_bonus(p), _bonus))
	else:
		bonus.add_child(UITheme.label("Today's free chips are collected. Come back tomorrow.", 8, UITheme.MUTED))
	var lim := Casino.limit(p)
	var lt := tr("Daily limit: %s · staked today: %s") % [Num.group(lim), Num.group(Casino.staked_today(p))] if lim > 0 else tr("No daily limit set. You can set one in Settings.")
	_info.add_child(UITheme.label(lt, 8, UITheme.MUTED))

func _trade(dir: String, n: int) -> void:
	if n <= 0:
		return
	await act("casino_exchange_act", [dir, n])
	if is_inside_tree():
		_render()

func _bonus() -> void:
	var r := await act("casino_bonus_act", [])
	if r.get("ok", false):
		EventBus.toast.emit(tr("+%d chips. Good luck!") % int(r.chips), "")
	if is_inside_tree():
		_render()
