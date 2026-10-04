class_name Casino
extends RefCounted
## Casino chips: bought and sold for gold at the cashier, won and lost at the tables, and spent in
## the chip shop. Chips belong to the player, not the farm. Chips have no real-world value and can
## never be bought with real money.

const GAMES := ["roulette", "blackjack", "slots", "poker", "race"]

static func cfg() -> Dictionary:
	return Data.casino

static func chips(p: PlayerData) -> int:
	return p.chips if p else 0

static func add_chips(p: PlayerData, n: int) -> void:
	p.chips = maxi(0, p.chips + n)

static func spend_chips(p: PlayerData, n: int) -> bool:
	if p == null or n < 0 or p.chips < n:
		return false
	p.chips -= n
	return true

## Gold per chip, the same both ways.
static func rate() -> int:
	return int(cfg().get("rate", 10))

## Real calendar day, so daily bonuses and limits follow the clock, not the farm's days.
static func today() -> String:
	return Time.get_date_string_from_unix_time(int(TimeService.now()))

## Builds exported with the "no_casino" feature tag (an all-ages edition) leave the casino out entirely.
static func built_in() -> bool:
	return not OS.has_feature("no_casino")

## Closed for this player: left out of the build or hidden in the settings.
static func hidden() -> bool:
	return not built_in() or Settings.hide_casino

static func vip(p: PlayerData) -> bool:
	return p != null and (bool(p.flags.get("casino_vip", false)) or int(p.stats.get("casino_staked", 0)) >= int(cfg().get("vip_turnover", 25000)))

## Chips staked today and the player's own daily cap (0 = no cap).
static func staked_today(p: PlayerData) -> int:
	return int(p.flags.get("casino_today", 0)) if str(p.flags.get("casino_day", "")) == today() else 0

static func limit(p: PlayerData) -> int:
	return int(p.flags.get("casino_limit", 0))

## Why a stake can't be placed, or "" if it can.
static func stake_block(p: PlayerData, n: int) -> String:
	if p == null or n <= 0:
		return TranslationServer.translate("Place a bet first.")
	if p.chips < n:
		return TranslationServer.translate("Not enough chips.")
	if limit(p) > 0 and staked_today(p) + n > limit(p):
		return TranslationServer.translate("That would go over your daily casino limit.")
	return ""

## Takes a stake and books it against today's limit and the VIP turnover.
static func stake(p: PlayerData, n: int) -> bool:
	if stake_block(p, n) != "":
		return false
	p.chips -= n
	p.flags["casino_day"] = today()
	p.flags["casino_today"] = staked_today(p) + n
	p.stat_add("casino_staked", n)
	return true

static func daily_bonus(p: PlayerData) -> int:
	return int(round(float(cfg().get("daily_bonus", 100)) * Modifiers.mult(p, "casino_daily")))

static func bonus_ready(p: PlayerData) -> bool:
	return str(p.flags.get("casino_bonus_day", "")) != today()

static func wheel_ready(p: PlayerData) -> bool:
	return str(p.flags.get("casino_wheel_day", "")) != today()

## Index of the wheel segment a spin lands on.
static func spin_wheel(rng: RandomNumberGenerator) -> int:
	var segs: Array = cfg().get("wheel", [])
	var total := 0
	for s in segs:
		total += int(s.w)
	var x := rng.randi_range(1, total)
	for i in segs.size():
		x -= int(segs[i].w)
		if x <= 0:
			return i
	return segs.size() - 1

static func wheel_label(seg: Dictionary) -> String:
	if seg.has("chips"):
		return str(int(seg.chips))
	if str(seg.get("item", "")) == "book":
		return TranslationServer.translate("Book")
	return "%d× %s" % [int(seg.get("n", 1)), Data.item_name(str(seg.item))]
