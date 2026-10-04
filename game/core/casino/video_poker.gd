class_name VideoPoker
extends CasinoGame
## Jacks or Better with the full-pay 9/6 table: deal five, hold any, draw once.
## Cards use the Blackjack encoding (rank = c % 13 with 0 = ace, suit = c / 13).

const HANDS := ["royal_flush", "straight_flush", "four_kind", "full_house", "flush", "straight", "three_kind", "two_pair", "jacks_better"]
const HAND_NAMES := {
	"royal_flush": "Royal Flush", "straight_flush": "Straight Flush", "four_kind": "Four of a Kind", "full_house": "Full House",
	"flush": "Flush", "straight": "Straight", "three_kind": "Three of a Kind", "two_pair": "Two Pair", "jacks_better": "Jacks or Better",
}

func _init(st: Dictionary = {}, seed_base: int = 0) -> void:
	super("poker", st, seed_base)

## Best paying hand, or "" for nothing.
static func evaluate(cards: Array) -> String:
	var counts := {}
	var suits := {}
	var vals: Array = []
	for c in cards:
		var r := int(c) % 13
		counts[r] = int(counts.get(r, 0)) + 1
		suits[int(c) / 13] = true
		vals.append(14 if r == 0 else r + 1)
	vals.sort()
	var flush := suits.size() == 1
	var straight: bool = counts.size() == 5 and (vals[4] - vals[0] == 4 or vals == [2, 3, 4, 5, 14])
	if straight and flush:
		return "royal_flush" if vals[0] == 10 else "straight_flush"
	var groups: Array = counts.values()
	groups.sort()
	groups.reverse()
	if groups[0] == 4:
		return "four_kind"
	if groups[0] == 3 and groups[1] == 2:
		return "full_house"
	if flush:
		return "flush"
	if straight:
		return "straight"
	if groups[0] == 3:
		return "three_kind"
	if groups[0] == 2 and groups[1] == 2:
		return "two_pair"
	if groups[0] == 2:
		for r in counts:
			if counts[r] == 2 and (r == 0 or r >= 10):
				return "jacks_better"
	return ""

## Payout in coins for a hand at this many coins (the royal jumps to 800 per coin at max coins).
static func pays(hand_id: String, coins: int) -> int:
	var cfg: Dictionary = Casino.cfg().get("poker", {})
	if hand_id == "":
		return 0
	var per := int(cfg.get("pays", {}).get(hand_id, 0))
	if hand_id == "royal_flush" and coins >= int(Casino.cfg().tables.poker.max):
		per = int(cfg.get("royal_max", 800))
	return per * coins

func hand() -> Dictionary:
	return state.get("hand", {})

func active() -> bool:
	return str(hand().get("phase", "")) == "hold"

func deal(coins: int) -> Dictionary:
	var deck: Array = range(52)
	var r := next_rng()
	deck = shuffled(deck, r)
	state["hand"] = {"cards": deck.slice(0, 5), "spare": deck.slice(5, 10), "coins": coins, "phase": "hold", "result": "", "won": 0}
	return hand()

## Replaces every card not held. Returns the hand with result and coins won.
func draw(holds: Array) -> Dictionary:
	var h := hand()
	if not active():
		return {}
	var cards: Array = h.cards
	for i in 5:
		if i >= holds.size() or not bool(holds[i]):
			cards[i] = h.spare[i]
	h.result = evaluate(cards)
	h.won = pays(h.result, int(h.coins))
	h.phase = "done"
	return h
