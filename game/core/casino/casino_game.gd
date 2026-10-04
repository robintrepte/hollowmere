class_name CasinoGame
extends RefCounted
## Shared table code: a persisted state dictionary, a seeded RNG that advances once per round, and
## the table limits. The host settles every round and saves right after, so reloading can't undo a bet.

var id := ""
var state: Dictionary

func _init(game_id: String, st: Dictionary, seed_base: int) -> void:
	id = game_id
	state = st
	if not state.has("seed"):
		state["seed"] = hash([seed_base, game_id]) & 0x7fffffff
		state["round"] = 0

## A fresh generator for the next round. The same seed and round always give the same result.
func next_rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([int(state.seed), int(state.round)])
	state["round"] = int(state.round) + 1
	return r

static func limits(game_id: String, vip: bool = false) -> Vector2i:
	var t: Dictionary = Casino.cfg().get("tables", {}).get(game_id, {})
	var mult := int(Casino.cfg().get("vip_mult", 5)) if vip else 1
	return Vector2i(int(t.get("min", 1)), int(t.get("max", 100)) * mult)

static func valid_bet(game_id: String, n: int, vip: bool = false) -> bool:
	var l := limits(game_id, vip)
	return n >= l.x and n <= l.y

## Fisher-Yates with the given generator.
static func shuffled(items: Array, rng: RandomNumberGenerator) -> Array:
	var out := items.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out
