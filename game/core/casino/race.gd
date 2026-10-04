class_name WildlingRace
extends CasinoGame
## Wildling races: six runners per card, chances from base speed and today's form, decimal odds with
## the house edge taken off. The card for a race number never changes until it is run.

const CHECKPOINTS := 12

func _init(st: Dictionary = {}, seed_base: int = 0) -> void:
	super("race", st, seed_base)

static func cfg() -> Dictionary:
	return Casino.cfg().get("race", {})

## [{species, speed, form, chance, odds}] for the next race.
func card() -> Array:
	var r := RandomNumberGenerator.new()
	r.seed = hash([int(state.seed), "card", int(state.get("race", 0))])
	var pool: Array = shuffled(cfg().get("pool", []), r)
	var runners: Array = []
	var weights: Array = []
	var total_w := 0.0
	for i in mini(int(cfg().get("runners", 6)), pool.size()):
		var sp: String = pool[i]
		var speed := float(Data.species.get(sp, {}).get("base", [0, 0, 0, 0, 50])[4])
		var form := snappedf(r.randf_range(0.85, 1.15), 0.01)
		var w := pow((speed + float(cfg().get("speed_offset", 0))) * form, float(cfg().get("sharpness", 2.0)))
		weights.append(w)
		total_w += w
		runners.append({"species": sp, "speed": int(speed), "form": form})
	var edge := float(cfg().get("edge", 0.1))
	for i in runners.size():
		var chance: float = weights[i] / total_w
		runners[i]["chance"] = chance
		runners[i]["odds"] = maxf(1.1, floorf((1.0 - edge) / chance * 10.0) / 10.0)
	return runners

## Runs the race: winner drawn by chance, the rest of the order by chance too, plus a smooth
## path for each runner (fraction of the track at each checkpoint) that respects the order.
func run() -> Dictionary:
	var runners := card()
	var r := next_rng()
	var left: Array = range(runners.size())
	var order: Array = []
	while not left.is_empty():
		var tot := 0.0
		for i in left:
			tot += float(runners[i].chance)
		var x := r.randf() * tot
		var pick: int = left[-1]
		for i in left:
			x -= float(runners[i].chance)
			if x <= 0.0:
				pick = i
				break
		order.append(pick)
		left.erase(pick)
	var paths: Array = []
	paths.resize(runners.size())
	for place in order.size():
		var i: int = order[place]
		var finish := 1.0 - place * 0.035
		var path: Array = []
		var wobble := r.randf_range(0.0, TAU)
		for k in CHECKPOINTS:
			var t := float(k + 1) / CHECKPOINTS
			var lead := sin(t * PI * 1.5 + wobble) * 0.06 * (1.0 - t)
			path.append(clampf(t * finish + lead, 0.0, 1.0))
		path[-1] = finish
		paths[i] = path
	state["race"] = int(state.get("race", 0)) + 1
	return {"runners": runners, "order": order, "winner": order[0], "paths": paths}
