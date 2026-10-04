class_name Casino
extends RefCounted
## Casino chips: bought and sold for gold at the cashier, won and lost at the tables, and spent in
## the chip shop. Chips belong to the player, not the farm.

static func chips(p: PlayerData) -> int:
	return p.chips if p else 0

static func add_chips(p: PlayerData, n: int) -> void:
	p.chips = maxi(0, p.chips + n)

static func spend_chips(p: PlayerData, n: int) -> bool:
	if p == null or n < 0 or p.chips < n:
		return false
	p.chips -= n
	return true
