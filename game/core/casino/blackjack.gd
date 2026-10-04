class_name Blackjack
extends CasinoGame
## Blackjack from a six-deck shoe with a cut card. The dealer peeks for blackjack, stands on soft 17,
## blackjack pays 3:2, double on any two cards (also after a split), split up to four hands,
## split aces take one card each, insurance pays 2:1.
##
## Cards are ints 0..51: rank = c % 13 (0 ace, 1..8 two to nine, 9..12 ten to king), suit = c / 13.

const DECKS := 6
const CUT := 0.75
const MAX_HANDS := 4

func _init(st: Dictionary = {}, seed_base: int = 0) -> void:
	super("blackjack", st, seed_base)
	if not state.has("shoe_seed"):
		_new_shoe()

static func value(c: int) -> int:
	var r := c % 13
	if r == 0:
		return 11
	return 10 if r >= 9 else r + 1

## [total, soft] with aces counted as 11 while that doesn't bust.
static func total(cards: Array) -> Array:
	var t := 0
	var aces := 0
	for c in cards:
		t += value(int(c))
		if int(c) % 13 == 0:
			aces += 1
	while t > 21 and aces > 0:
		t -= 10
		aces -= 1
	return [t, aces > 0]

static func is_blackjack(cards: Array) -> bool:
	return cards.size() == 2 and int(total(cards)[0]) == 21

func _new_shoe() -> void:
	state["shoe_seed"] = next_rng().randi()
	state["pos"] = 0
	state["shuffled"] = true

## state.shoe, when set, is a fixed card order (replays and scripted hands); otherwise the seed builds it.
func _shoe() -> Array:
	if state.has("shoe"):
		return state.shoe
	var cards: Array = []
	for i in DECKS * 52:
		cards.append(i % 52)
	var r := RandomNumberGenerator.new()
	r.seed = int(state.shoe_seed)
	return shuffled(cards, r)

func draw(shoe: Array) -> int:
	if int(state.pos) >= shoe.size():
		_new_shoe()
		shoe.assign(_shoe())
	var c: int = shoe[int(state.pos)]
	state["pos"] = int(state.pos) + 1
	return c

func hand() -> Dictionary:
	return state.get("hand", {})

func active() -> bool:
	return not hand().is_empty() and str(hand().get("phase", "")) != "done"

## Starts a round with the bet already taken. Returns the round state.
func deal(bet: int) -> Dictionary:
	state["shuffled"] = false
	if int(state.pos) >= int(DECKS * 52 * CUT):
		_new_shoe()
	var shoe := _shoe()
	var p1 := draw(shoe)
	var d1 := draw(shoe)
	var p2 := draw(shoe)
	var d2 := draw(shoe)
	state["hand"] = {
		"hands": [{"cards": [p1, p2], "bet": bet, "done": false, "doubled": false, "split": false}],
		"dealer": [d1, d2], "active": 0, "insurance": 0, "phase": "play", "bet": bet, "results": [], "credit": 0,
	}
	if d1 % 13 == 0:
		hand().phase = "insurance"
	else:
		_after_peek()
	return hand()

## What an action costs on top of the bets already down.
func cost(op: String) -> int:
	var h := hand()
	if h.is_empty():
		return 0
	match op:
		"double", "split":
			return int(h.hands[int(h.active)].bet)
		"insurance":
			return int(h.bet) / 2
	return 0

func can(op: String) -> bool:
	var h := hand()
	if h.is_empty():
		return false
	if h.phase == "insurance":
		return op in ["insurance", "no_insurance"]
	if h.phase != "play":
		return false
	var cur: Dictionary = h.hands[int(h.active)]
	var cards: Array = cur.cards
	match op:
		"hit", "stand":
			return true
		"double":
			return cards.size() == 2
		"split":
			return cards.size() == 2 and value(int(cards[0])) == value(int(cards[1])) and h.hands.size() < MAX_HANDS and not (cur.split and int(cards[0]) % 13 == 0)
	return false

## Plays one action. Returns the round state; when phase is "done", h.credit holds the chips to pay.
func act(op: String) -> Dictionary:
	if not can(op):
		return {}
	var h := hand()
	var shoe := _shoe()
	match op:
		"insurance", "no_insurance":
			if op == "insurance":
				h.insurance = int(h.bet) / 2
			_after_peek()
			return h
		"hit":
			var cur: Dictionary = h.hands[int(h.active)]
			cur.cards.append(draw(shoe))
			if int(total(cur.cards)[0]) >= 21:
				cur.done = true
		"stand":
			h.hands[int(h.active)].done = true
		"double":
			var cur: Dictionary = h.hands[int(h.active)]
			cur.bet = int(cur.bet) * 2
			cur.doubled = true
			cur.cards.append(draw(shoe))
			cur.done = true
		"split":
			var cur: Dictionary = h.hands[int(h.active)]
			var second: int = cur.cards.pop_back()
			var aces := int(cur.cards[0]) % 13 == 0
			cur.split = true
			cur.cards.append(draw(shoe))
			var nh := {"cards": [second, draw(shoe)], "bet": int(cur.bet), "done": false, "doubled": false, "split": true}
			h.hands.insert(int(h.active) + 1, nh)
			if aces:
				cur.done = true
				nh.done = true
			elif int(total(cur.cards)[0]) == 21:
				cur.done = true
	_advance(shoe)
	return h

func _after_peek() -> void:
	var h := hand()
	h.phase = "play"
	var up := int(h.dealer[0])
	if (value(up) == 10 or up % 13 == 0) and is_blackjack(h.dealer):
		for x in h.hands:
			x.done = true
		_settle()
		return
	if is_blackjack(h.hands[0].cards):
		h.hands[0].done = true
		_settle()

func _advance(shoe: Array) -> void:
	var h := hand()
	while int(h.active) < h.hands.size() and h.hands[int(h.active)].done:
		h.active = int(h.active) + 1
	if int(h.active) < h.hands.size():
		var cur: Dictionary = h.hands[int(h.active)]
		if cur.cards.size() == 1:
			cur.cards.append(draw(shoe))
		return
	h.active = h.hands.size() - 1
	var live: bool = h.hands.any(func(x): return int(total(x.cards)[0]) <= 21)
	if live:
		while int(total(h.dealer)[0]) < 17:
			h.dealer.append(draw(shoe))
	_settle()

func _settle() -> void:
	var h := hand()
	var dt := int(total(h.dealer)[0])
	var dbj := is_blackjack(h.dealer)
	var credit := 0
	var results: Array = []
	if int(h.insurance) > 0 and dbj:
		credit += int(h.insurance) * 3
	for x in h.hands:
		var pt := int(total(x.cards)[0])
		var pbj: bool = is_blackjack(x.cards) and not x.split and h.hands.size() == 1
		var res := "lose"
		var back := 0
		if pt > 21:
			res = "bust"
		elif pbj and not dbj:
			res = "blackjack"
			back = int(x.bet) + int(x.bet) * 3 / 2
		elif dbj and not pbj:
			res = "lose"
		elif pbj and dbj:
			res = "push"
			back = int(x.bet)
		elif dt > 21 or pt > dt:
			res = "win"
			back = int(x.bet) * 2
		elif pt == dt:
			res = "push"
			back = int(x.bet)
		results.append(res)
		credit += back
	h.results = results
	h.credit = credit
	h.phase = "done"

## Basic strategy for this rule set: "hit", "stand", "double", "split" or "insurance" decline.
static func advice(cards: Array, dealer_up: int, can_double: bool, can_split: bool) -> String:
	var up := value(dealer_up)
	if can_split and cards.size() == 2 and value(int(cards[0])) == value(int(cards[1])):
		var v := value(int(cards[0]))
		match v:
			11, 8:
				return "split"
			9:
				if up in [2, 3, 4, 5, 6, 8, 9]:
					return "split"
			7, 2, 3:
				if up <= 7:
					return "split"
			6:
				if up <= 6:
					return "split"
			4:
				if up in [5, 6]:
					return "split"
	var t: Array = total(cards)
	var tot := int(t[0])
	var dbl := "double" if can_double else "hit"
	if bool(t[1]) and tot <= 21:
		if tot >= 19:
			return "stand"
		if tot == 18:
			if up >= 3 and up <= 6:
				return "double" if can_double else "stand"
			return "stand" if up in [2, 7, 8] else "hit"
		if tot == 17:
			return dbl if up >= 3 and up <= 6 else "hit"
		if tot >= 15:
			return dbl if up >= 4 and up <= 6 else "hit"
		return dbl if up in [5, 6] else "hit"
	if tot >= 17:
		return "stand"
	if tot >= 13:
		return "stand" if up <= 6 else "hit"
	if tot == 12:
		return "stand" if up >= 4 and up <= 6 else "hit"
	if tot == 11:
		return dbl if up != 11 else "hit"
	if tot == 10:
		return dbl if up <= 9 else "hit"
	if tot == 9:
		return dbl if up >= 3 and up <= 6 else "hit"
	return "hit"
