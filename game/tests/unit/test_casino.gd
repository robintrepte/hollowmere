extends GutTest
## Casino rules and payouts: every roulette bet, blackjack hands and strategy, video poker hands,
## slot lines and return, race odds, the wheel, the cashier and the daily limit.

var pid := ""
var p: PlayerData

func before_each() -> void:
	GameState.new_game({"seed": 41, "starter": "puddlop"})
	pid = Net.local_id()
	p = GameState.local_player()

## Cards by rank (1 ace .. 13 king), all spades.
func _c(rank: int, suit: int = 0) -> int:
	return suit * 13 + (rank - 1)

# --- Roulette ---------------------------------------------------------------------------

func test_roulette_layout_and_validity() -> void:
	var wheel := Roulette.WHEEL.duplicate()
	wheel.sort()
	assert_eq(wheel, range(37), "37 pockets, each once")
	assert_eq(Roulette.color(0), "green")
	assert_eq(Roulette.color(1), "red")
	assert_eq(Roulette.color(2), "black")
	assert_eq(Roulette.RED.size(), 18)
	for good in [{"kind": "split", "nums": [1, 2]}, {"kind": "split", "nums": [5, 8]}, {"kind": "split", "nums": [0, 3]},
			{"kind": "street", "nums": [34, 35, 36]}, {"kind": "street", "nums": [0, 2, 3]}, {"kind": "corner", "nums": [1, 2, 4, 5]},
			{"kind": "corner", "nums": [0, 1, 2, 3]}, {"kind": "corner", "nums": [32, 33, 35, 36]}, {"kind": "sixline", "nums": [31, 32, 33, 34, 35, 36]},
			{"kind": "dozen", "n": 3}, {"kind": "column", "n": 1}]:
		good["amount"] = 1
		assert_true(Roulette.valid(good), str(good))
	for bad in [{"kind": "split", "nums": [3, 4]}, {"kind": "split", "nums": [0, 4]}, {"kind": "street", "nums": [2, 3, 4]},
			{"kind": "corner", "nums": [3, 4, 6, 7]}, {"kind": "corner", "nums": [33, 34, 36, 37]}, {"kind": "sixline", "nums": [2, 3, 4, 5, 6, 7]},
			{"kind": "straight", "nums": [37]}, {"kind": "dozen", "n": 4}, {"kind": "straight", "nums": [5], "amount": 0}]:
		if not bad.has("amount"):
			bad["amount"] = 1
		assert_false(Roulette.valid(bad), str(bad))

func test_every_roulette_bet_pays_right_and_returns_36_of_37() -> void:
	var bets := [
		[{"kind": "straight", "nums": [17]}, 35], [{"kind": "split", "nums": [17, 20]}, 17], [{"kind": "street", "nums": [16, 17, 18]}, 11],
		[{"kind": "corner", "nums": [13, 14, 16, 17]}, 8], [{"kind": "sixline", "nums": [13, 14, 15, 16, 17, 18]}, 5],
		[{"kind": "black"}, 1], [{"kind": "odd"}, 1], [{"kind": "low"}, 1], [{"kind": "dozen", "n": 2}, 2], [{"kind": "column", "n": 2}, 2],
	]
	for pair in bets:
		var b: Dictionary = pair[0]
		b["amount"] = 10
		assert_eq(Roulette.payout(b, 17), 10 * (1 + int(pair[1])), "%s on 17" % b.kind)
		var total := 0
		for n in 37:
			total += Roulette.payout(b, n)
		assert_eq(total, 360, "%s returns 36 of 37 over a full wheel" % b.kind)
	assert_eq(Roulette.payout({"kind": "red", "amount": 10}, 0), 0, "zero beats the outside bets")
	assert_eq(Roulette.payout({"kind": "even", "amount": 10}, 0), 0)
	assert_eq(Roulette.payout({"kind": "high", "amount": 10}, 19), 20)

func test_roulette_spins_are_seeded_and_kept_in_history() -> void:
	var a := Roulette.new({}, 5)
	var b := Roulette.new({}, 5)
	var sa: Array = []
	var sb: Array = []
	for i in 20:
		sa.append(a.spin())
		sb.append(b.spin())
	assert_eq(sa, sb)
	assert_eq(a.state.history.size(), Roulette.HISTORY)
	assert_eq(int(a.state.history[0]), int(sa[-1]))

# --- Blackjack ---------------------------------------------------------------------------

func _bj(cards: Array) -> Blackjack:
	return Blackjack.new({"shoe": cards, "pos": 0, "shoe_seed": 1}, 1)

func test_blackjack_totals() -> void:
	assert_eq(Blackjack.total([_c(1), _c(6)]), [17, true])
	assert_eq(Blackjack.total([_c(1), _c(6), _c(10)]), [17, false])
	assert_eq(Blackjack.total([_c(1), _c(1), _c(9)]), [21, true])
	assert_true(Blackjack.is_blackjack([_c(1), _c(13)]))
	assert_false(Blackjack.is_blackjack([_c(7), _c(7), _c(7)]))

func test_blackjack_pays_three_to_two() -> void:
	var g := _bj([_c(1), _c(9), _c(12), _c(7)])
	var h := g.deal(10)
	assert_eq(h.phase, "done")
	assert_eq(h.results, ["blackjack"])
	assert_eq(int(h.credit), 25)

func test_dealer_stands_on_soft_17() -> void:
	var g := _bj([_c(10), _c(6), _c(8), _c(1), _c(5)])
	g.deal(10)
	var h := g.act("stand")
	assert_eq(h.dealer.size(), 2, "soft 17 stands")
	assert_eq(h.results, ["win"])
	assert_eq(int(h.credit), 20)

func test_double_split_and_bust() -> void:
	var g := _bj([_c(6), _c(10), _c(5), _c(7), _c(10), _c(4)])
	g.deal(10)
	assert_eq(g.cost("double"), 10)
	var h := g.act("double")
	assert_eq(int(h.hands[0].bet), 20)
	assert_eq(h.hands[0].cards.size(), 3)
	assert_eq(h.phase, "done")
	assert_eq(h.results, ["win"], "a doubled 21 beats the dealer's 17")
	assert_eq(int(h.credit), 40)
	g = _bj([_c(8), _c(10), _c(8, 1), _c(9), _c(3), _c(10), _c(10, 2)])
	g.deal(10)
	assert_true(g.can("split"))
	h = g.act("split")
	assert_eq(h.hands.size(), 2)
	assert_eq(h.hands[0].cards, [_c(8), _c(3)])
	assert_eq(h.hands[1].cards, [_c(8, 1), _c(10)])
	h = g.act("hit")
	assert_eq(int(Blackjack.total(h.hands[0].cards)[0]), 21)
	assert_eq(int(h.active), 1, "21 ends the first hand, play moves to the second")
	g = _bj([_c(10), _c(10), _c(6), _c(7), _c(9)])
	g.deal(10)
	h = g.act("hit")
	assert_eq(h.results, ["bust"])
	assert_eq(h.dealer.size(), 2, "the dealer doesn't draw against a bust")
	assert_eq(int(h.credit), 0)

func test_insurance_pays_two_to_one() -> void:
	var g := _bj([_c(10), _c(1), _c(9), _c(13)])
	var h := g.deal(10)
	assert_eq(h.phase, "insurance")
	assert_eq(g.cost("insurance"), 5)
	h = g.act("insurance")
	assert_eq(h.phase, "done")
	assert_eq(h.results, ["lose"])
	assert_eq(int(h.credit), 15, "insurance 5 returns 15, the hand loses 10: even overall")
	g = _bj([_c(10), _c(1), _c(9), _c(5), _c(4)])
	g.deal(10)
	h = g.act("no_insurance")
	assert_eq(h.phase, "play", "no dealer blackjack, play on")

func test_basic_strategy_advice() -> void:
	assert_eq(Blackjack.advice([_c(10), _c(6)], _c(10), true, true), "hit")
	assert_eq(Blackjack.advice([_c(10), _c(6)], _c(5), true, true), "stand")
	assert_eq(Blackjack.advice([_c(6), _c(5)], _c(6), true, true), "double")
	assert_eq(Blackjack.advice([_c(6), _c(5)], _c(6), false, true), "hit")
	assert_eq(Blackjack.advice([_c(1), _c(7)], _c(9), true, true), "hit")
	assert_eq(Blackjack.advice([_c(1), _c(7)], _c(2), true, true), "stand")
	assert_eq(Blackjack.advice([_c(8), _c(8, 1)], _c(1), true, true), "split")
	assert_eq(Blackjack.advice([_c(10), _c(13)], _c(6), true, true), "stand")
	assert_eq(Blackjack.advice([_c(5), _c(5, 1)], _c(9), true, true), "double", "fives play as ten")

func test_shoe_reshuffles_at_the_cut_card() -> void:
	var g := Blackjack.new({}, 9)
	var first := int(g.state.shoe_seed)
	g.state.pos = int(Blackjack.DECKS * 52 * Blackjack.CUT) + 1
	g.deal(10)
	assert_ne(int(g.state.shoe_seed), first, "a new shoe after the cut card")
	assert_eq(int(g.state.pos), 4)

# --- Video poker ---------------------------------------------------------------------------

func test_video_poker_hands() -> void:
	var cases := {
		"royal_flush": [_c(10), _c(11), _c(12), _c(13), _c(1)],
		"straight_flush": [_c(5, 1), _c(6, 1), _c(7, 1), _c(8, 1), _c(9, 1)],
		"four_kind": [_c(4), _c(4, 1), _c(4, 2), _c(4, 3), _c(9)],
		"full_house": [_c(4), _c(4, 1), _c(4, 2), _c(9), _c(9, 1)],
		"flush": [_c(2, 2), _c(6, 2), _c(9, 2), _c(11, 2), _c(13, 2)],
		"straight": [_c(1), _c(2, 1), _c(3, 2), _c(4, 3), _c(5)],
		"three_kind": [_c(7), _c(7, 1), _c(7, 2), _c(2), _c(9)],
		"two_pair": [_c(7), _c(7, 1), _c(2, 2), _c(2), _c(9)],
		"jacks_better": [_c(11), _c(11, 1), _c(2, 2), _c(5), _c(9)],
		"": [_c(10), _c(10, 1), _c(2, 2), _c(5), _c(9)],
	}
	for want in cases:
		assert_eq(VideoPoker.evaluate(cases[want]), want, want)
	assert_eq(VideoPoker.evaluate([_c(10), _c(11, 1), _c(12), _c(13), _c(1)]), "straight", "ace-high straight, mixed suits")
	assert_eq(VideoPoker.pays("royal_flush", 5), 4000)
	assert_eq(VideoPoker.pays("royal_flush", 4), 1000)
	assert_eq(VideoPoker.pays("full_house", 3), 27)

func test_video_poker_hold_and_draw() -> void:
	var g := VideoPoker.new({}, 3)
	var h := g.deal(5)
	var dealt: Array = h.cards.duplicate()
	h = g.draw([true, true, false, false, true])
	assert_eq(h.cards[0], dealt[0])
	assert_eq(h.cards[4], dealt[4])
	assert_ne(h.cards[2], dealt[2])
	assert_eq(h.phase, "done")
	assert_eq(int(h.won), VideoPoker.pays(h.result, 5))

# --- Slots ---------------------------------------------------------------------------------

func test_slot_lines() -> void:
	assert_eq(Slots.line_win(["A", "A", "A", "B", "C"]), ["A", 3, 6])
	assert_eq(Slots.line_win(["W", "A", "A", "A", "C"]), ["A", 4, 22], "wilds join the line")
	assert_eq(Slots.line_win(["W", "W", "W", "A", "B"]), ["W", 3, 100], "three wilds beat four cherries")
	assert_eq(Slots.line_win(["J", "J", "J", "J", "J"]), ["J", 5, -1], "five jackpot symbols")
	assert_eq(Slots.line_win(["W", "J", "J", "J", "J"]), ["", 0, 0], "wilds don't make jackpots")
	assert_eq(Slots.line_win(["S", "S", "S", "A", "A"]), ["", 0, 0], "scatters only pay anywhere")
	assert_eq(Slots.line_win(["A", "B", "A", "A", "A"]), ["", 0, 0])

func test_slots_return_about_95_percent() -> void:
	var g := Slots.new({}, 77)
	var spent := 0
	var won := 0
	var hits := 0
	var n := 60000
	for i in n:
		var r := g.spin(1, 0)
		spent += Slots.LINES
		won += int(r.won)
		if int(r.won) > 0:
			hits += 1
	var rtp := float(won) / spent
	assert_between(rtp, 0.90, 0.98, "base game RTP %.3f (target 0.94 + 0.01 jackpot)" % rtp)
	assert_between(float(hits) / n, 0.28, 0.38, "about one spin in three pays")
	for theme in Slots.cfg().themes:
		assert_eq(Slots.cfg().themes[theme].symbols.size(), 9, theme)

# --- Race and wheel ------------------------------------------------------------------------

func test_race_odds_carry_the_edge() -> void:
	var g := WildlingRace.new({}, 11)
	var card := g.card()
	assert_eq(card.size(), 6)
	assert_eq(card, g.card(), "the card waits for the race")
	var total := 0.0
	for r in card:
		total += float(r.chance)
		assert_lte(float(r.chance) * float(r.odds), 0.95, "%s pays less than fair" % r.species)
		assert_true(Data.species.has(str(r.species)))
	assert_almost_eq(total, 1.0, 0.0001)
	var res := g.run()
	assert_eq(res.order.size(), 6)
	assert_eq(int(res.paths[int(res.winner)][-1] * 100), 100, "the winner crosses first")
	assert_ne(g.card(), card, "a new card after each race")

func test_race_winners_follow_the_chances() -> void:
	var g := WildlingRace.new({"seed": 3, "round": 0, "race": 0}, 0)
	var fav_wins := 0
	var fav_chance := 0.0
	for i in 1500:
		g.state.race = 0
		var card := g.card()
		var fav := 0
		for k in card.size():
			if float(card[k].chance) > float(card[fav].chance):
				fav = k
		fav_chance = float(card[fav].chance)
		if int(g.run().winner) == fav:
			fav_wins += 1
	assert_almost_eq(fav_wins / 1500.0, fav_chance, 0.05)

func test_wheel_weights() -> void:
	var g := RandomNumberGenerator.new()
	g.seed = 1
	var seen := {}
	for i in 3000:
		seen[Casino.spin_wheel(g)] = true
	assert_eq(seen.size(), Casino.cfg().wheel.size(), "every segment can come up")

# --- GameState -----------------------------------------------------------------------------

func test_cashier_trades_both_ways_at_one_rate() -> void:
	var gold := GameState.money()
	GameState.add_money(1000)
	assert_true(GameState.casino_exchange_act(pid, "buy", 50).ok)
	assert_eq(p.chips, 50)
	assert_eq(GameState.money(), gold + 1000 - 50 * Casino.rate())
	assert_true(GameState.casino_exchange_act(pid, "sell", 20).ok)
	assert_eq(p.chips, 30)
	assert_eq(GameState.money(), gold + 1000 - 30 * Casino.rate())
	assert_false(GameState.casino_exchange_act(pid, "sell", 31).ok)

func test_daily_bonus_and_wheel_once_a_day() -> void:
	var r := GameState.casino_bonus_act(pid)
	assert_true(r.ok)
	assert_eq(p.chips, Casino.daily_bonus(p))
	assert_false(GameState.casino_bonus_act(pid).ok)
	r = GameState.casino_wheel_act(pid)
	assert_true(r.ok)
	assert_false(GameState.casino_wheel_act(pid).ok)
	p.flags["casino_wheel_day"] = "2000-01-01"
	assert_true(GameState.casino_wheel_act(pid).ok, "a new calendar day, a new spin")

func test_daily_limit_blocks_stakes() -> void:
	Casino.add_chips(p, 1000)
	GameState.casino_prefs_act(pid, 100)
	assert_true(GameState.roulette_act(pid, [{"kind": "red", "amount": 60}]).ok)
	var r := GameState.roulette_act(pid, [{"kind": "red", "amount": 60}])
	assert_false(r.ok, "over the limit")
	assert_ne(str(r.reason), "")
	GameState.casino_prefs_act(pid, 0)
	assert_true(GameState.roulette_act(pid, [{"kind": "red", "amount": 60}]).ok, "no limit by default")

func test_roulette_act_settles_bets() -> void:
	Casino.add_chips(p, 500)
	var r := GameState.roulette_act(pid, [{"kind": "straight", "nums": [7], "amount": 10}, {"kind": "red", "amount": 10}])
	assert_true(r.ok)
	var want := Roulette.payout({"kind": "straight", "nums": [7], "amount": 10}, int(r.number)) + Roulette.payout({"kind": "red", "amount": 10}, int(r.number))
	assert_eq(int(r.chips), want)
	assert_eq(p.chips, 500 - 20 + want)
	assert_false(GameState.roulette_act(pid, [{"kind": "red", "amount": 2}]).ok, "under the table minimum")
	assert_false(GameState.roulette_act(pid, [{"kind": "split", "nums": [3, 4], "amount": 10}]).ok, "not a real split")
	assert_eq(int(p.stats.get("casino_round", 0)), 1)

func test_blackjack_act_takes_and_pays_chips() -> void:
	Casino.add_chips(p, 200)
	var r := GameState.blackjack_act(pid, "deal", 20)
	assert_true(r.ok)
	if r.hand.phase != "done":
		assert_false(GameState.blackjack_act(pid, "deal", 20).ok, "one hand at a time")
	var guard := 0
	while r.hand.phase != "done" and guard < 10:
		guard += 1
		r = GameState.blackjack_act(pid, "no_insurance" if r.hand.phase == "insurance" else "stand")
	assert_eq(r.hand.phase, "done")
	var staked := int(r.hand.insurance)
	for x in r.hand.hands:
		staked += int(x.bet)
	assert_eq(p.chips, 200 - staked + int(r.chips))

func test_slots_feed_the_jackpot() -> void:
	Casino.add_chips(p, 500)
	var pot := GameState.jackpot()
	var r := GameState.slots_act(pid, 10)
	assert_true(r.ok)
	assert_eq(p.chips, 500 - 100 + int(r.chips))
	assert_true(GameState.jackpot() > pot or int(r.spin.jackpot) > 0)
	assert_false(GameState.slots_act(pid, 11).ok, "line bet over the maximum")

func test_vip_raises_limits_and_race_pays_odds() -> void:
	Casino.add_chips(p, 20000)
	assert_false(GameState.race_act(pid, 0, 2000).ok, "over the normal limit")
	p.flags["casino_vip"] = true
	var card := GameState.race_card(pid)
	var r := GameState.race_act(pid, 2, 2000)
	assert_true(r.ok)
	if int(r.race.winner) == 2:
		assert_eq(int(r.chips), int(floor(2000 * float(card[2].odds))))
	else:
		assert_eq(int(r.chips), 0)

func test_casino_state_survives_a_save() -> void:
	Casino.add_chips(p, 300)
	GameState.blackjack_act(pid, "deal", 10)
	var d := GameState.to_dict()
	var round_before := int(GameState.world.casino.players[pid].blackjack.round)
	GameState.from_dict(JSON.parse_string(JSON.stringify(d)))
	assert_eq(int(GameState.world.casino.players[pid].blackjack.round), round_before)
	assert_eq(GameState.local_player().chips, p.chips)
