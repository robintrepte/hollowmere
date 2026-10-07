class_name WildlingCandy
extends RefCounted
## Candy left behind when a Shelter Wildling is sent on its way, and what one candy is worth.
##
## A release is a consolation for a duplicate, not a way to train. One candy is a slice of the
## gap to the next level: ten candies at level 1, a few more as the Wildling grows. Sending off
## a Wildling of the same level pays back well under half of that level, so battling stays faster.

const ITEM := "wildling_candy"
const BASE_COST := 10

## How many candies a Shelter Wildling leaves. One, plus one per 10 levels, plus one if Starry or legendary.
static func yield_for(c: Creature) -> int:
	var n := 1 + int(c.level / 10)
	if c.starry:
		n += 1
	if c.species().get("legendary", false):
		n += 1
	return n

## Candies that cover a full level gap at `level`. Higher levels ask for a few more.
static func cost_at(level: int) -> int:
	return BASE_COST + int(level / 2)

## XP one candy grants at `level`. Sized so `cost_at` candies from a fresh level reach the next one.
static func xp_per_candy(level: int) -> int:
	if level >= Creature.MAX_LEVEL:
		return 0
	var full := Creature.xp_for_level(level + 1) - Creature.xp_for_level(level)
	return maxi(1, ceili(float(full) / float(cost_at(level))))

## How many candies this Wildling still needs for its next level, counting XP it already has.
static func candies_left(c: Creature) -> int:
	var each := xp_per_candy(c.level)
	if each <= 0:
		return 0
	return ceili(float(c.xp_to_next()) / float(each))
