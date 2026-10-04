extends Node
## CI entry point: `godot --headless --path game res://tests/sim/casino_rtp.tscn -- --rounds=1000000`
## Plays every casino game headless and exits 1 when a return to player leaves its target band.

const BANDS := {"slots": [0.93, 0.97], "roulette": [0.95, 0.995], "race": [0.85, 0.92], "blackjack": [0.97, 1.01]}

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var n := int(args.get("rounds", "1000000"))
	var t0 := Time.get_ticks_msec()
	var rtp := {"slots": _slots(n), "roulette": _roulette(n), "race": _race(n / 10), "blackjack": _blackjack(n / 10)}
	var ok := true
	for g in rtp:
		var band: Array = BANDS[g]
		var good: bool = rtp[g] >= band[0] and rtp[g] <= band[1]
		ok = ok and good
		print("%-10s RTP %.4f  (target %.2f-%.2f) %s" % [g, rtp[g], band[0], band[1], "ok" if good else "OUT OF BAND"])
	print("\nCasino sim (%d rounds) finished in %.1fs: %s" % [n, (Time.get_ticks_msec() - t0) / 1000.0, "OK" if ok else "FAILED"])
	get_tree().quit(0 if ok else 1)

## Includes the progressive jackpot: 1 % of each bet feeds the pot, five jackpot symbols win it.
func _slots(n: int) -> float:
	var g := Slots.new({}, 101)
	var cfg := Slots.cfg()
	var pot := int(cfg.jackpot_seed)
	var seed_paid := 0
	var spent := 0
	var won := 0
	var max_bet := int(Casino.cfg().tables.slots.max)
	for i in n:
		pot += maxi(1, int(round(max_bet * Slots.LINES * float(cfg.jackpot_share))))
		var r := g.spin(max_bet, pot)
		spent += max_bet * Slots.LINES
		won += int(r.won)
		if int(r.jackpot) > 0:
			pot = int(cfg.jackpot_seed)
			seed_paid += pot
	return float(won - seed_paid) / spent

func _roulette(n: int) -> float:
	var g := Roulette.new({}, 202)
	var kinds := [{"kind": "red", "amount": 1}, {"kind": "straight", "nums": [17], "amount": 1}, {"kind": "dozen", "n": 2, "amount": 1}, {"kind": "corner", "nums": [1, 2, 4, 5], "amount": 1}]
	var won := 0
	for i in n:
		g.state.erase("history")
		won += Roulette.payout(kinds[i % kinds.size()], g.spin())
	return float(won) / n

func _race(n: int) -> float:
	var g := WildlingRace.new({}, 303)
	var spent := 0.0
	var won := 0.0
	for i in n:
		var card := g.card()
		var pick := i % card.size()
		var res := g.run()
		spent += 100.0
		if int(res.winner) == pick:
			won += floor(100.0 * float(card[pick].odds))
	return won / spent

## Plays perfect basic strategy, no insurance.
func _blackjack(n: int) -> float:
	var g := Blackjack.new({}, 404)
	var spent := 0
	var won := 0
	for i in n:
		g.deal(10)
		spent += 10
		while g.hand().phase != "done":
			var h := g.hand()
			if h.phase == "insurance":
				g.act("no_insurance")
				continue
			var cur: Dictionary = h.hands[int(h.active)]
			var op := Blackjack.advice(cur.cards, int(h.dealer[0]), g.can("double"), g.can("split"))
			if op in ["double", "split"]:
				spent += g.cost(op)
			g.act(op)
		won += int(g.hand().credit)
	return float(won) / spent
