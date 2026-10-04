class_name Roulette
extends CasinoGame
## European roulette with a single zero. Bets are {kind, nums, amount} for inside bets and
## {kind, n, amount} for dozens and columns. Payouts include the stake.

const RED := [1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36]
## Pocket order around the wheel, clockwise from zero.
const WHEEL := [0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26]
## Winnings per chip staked, on top of the stake.
const PAYS := {
	"straight": 35, "split": 17, "street": 11, "corner": 8, "sixline": 5,
	"red": 1, "black": 1, "even": 1, "odd": 1, "low": 1, "high": 1, "dozen": 2, "column": 2,
}
const HISTORY := 12

func _init(st: Dictionary = {}, seed_base: int = 0) -> void:
	super("roulette", st, seed_base)

static func color(n: int) -> String:
	if n == 0:
		return "green"
	return "red" if n in RED else "black"

static func _row(n: int) -> int:
	return (n - 1) / 3

static func _sorted(nums: Array) -> Array:
	var out: Array = []
	for x in nums:
		out.append(int(x))
	out.sort()
	return out

## Numbers a bet covers, or [] if the bet isn't a real spot on the layout.
static func covers(bet: Dictionary) -> Array:
	var kind := str(bet.get("kind", ""))
	var nums := _sorted(bet.get("nums", []))
	var n := int(bet.get("n", 0))
	for x in nums:
		if x < 0 or x > 36:
			return []
	match kind:
		"straight":
			return nums if nums.size() == 1 else []
		"split":
			if nums.size() != 2:
				return []
			var a: int = nums[0]
			var b: int = nums[1]
			if a == 0:
				return nums if b in [1, 2, 3] else []
			if b - a == 3 or (b - a == 1 and _row(a) == _row(b)):
				return nums
			return []
		"street":
			if nums == [0, 1, 2] or nums == [0, 2, 3]:
				return nums
			if nums.size() == 3 and nums[0] > 0 and nums[0] % 3 == 1 and nums == [nums[0], nums[0] + 1, nums[0] + 2]:
				return nums
			return []
		"corner":
			if nums == [0, 1, 2, 3]:
				return nums
			if nums.size() == 4 and nums[0] > 0 and nums[0] % 3 != 0 and nums[0] <= 32 and nums == [nums[0], nums[0] + 1, nums[0] + 3, nums[0] + 4]:
				return nums
			return []
		"sixline":
			if nums.size() == 6 and nums[0] > 0 and nums[0] % 3 == 1 and nums[0] <= 31:
				var want: Array = range(nums[0], nums[0] + 6)
				return nums if nums == want else []
			return []
		"red":
			return RED.duplicate()
		"black":
			return range(1, 37).filter(func(x): return not x in RED)
		"even":
			return range(1, 37).filter(func(x): return x % 2 == 0)
		"odd":
			return range(1, 37).filter(func(x): return x % 2 == 1)
		"low":
			return range(1, 19)
		"high":
			return range(19, 37)
		"dozen":
			return range(12 * (n - 1) + 1, 12 * n + 1) if n >= 1 and n <= 3 else []
		"column":
			return range(1, 37).filter(func(x): return (x - 1) % 3 == n - 1) if n >= 1 and n <= 3 else []
	return []

static func valid(bet: Dictionary) -> bool:
	return int(bet.get("amount", 0)) > 0 and not covers(bet).is_empty()

## Chips back for one bet on this number: stake plus winnings, or 0.
static func payout(bet: Dictionary, number: int) -> int:
	if not number in covers(bet):
		return 0
	return int(bet.amount) * (1 + int(PAYS[str(bet.kind)]))

static func total_stake(bets: Array) -> int:
	var s := 0
	for b in bets:
		s += int(b.get("amount", 0))
	return s

func spin() -> int:
	var n := next_rng().randi_range(0, 36)
	var h: Array = state.get("history", [])
	h.push_front(n)
	state["history"] = h.slice(0, HISTORY)
	return n
