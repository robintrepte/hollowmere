class_name Breeding
extends RefCounted
## Egg creation, gene inheritance, mutation and Starry odds.

const BASE_EGG_CHANCE := 0.25
const MUTATION_CHANCE := 0.06

## Letter grade for a 0-15 gene, used wherever genes are shown to players.
static func gene_grade(v: int) -> String:
	if v >= 15:
		return "S"
	if v >= 12:
		return "A"
	if v >= 8:
		return "B"
	if v >= 4:
		return "C"
	return "D"

static func grade_color(g: String) -> Color:
	return {"S": Color("#d0a020"), "A": Color("#3a8a3a"), "B": Color("#3a6ab0"), "C": Color("#7a6a5a"), "D": Color("#b04040")}.get(g, Color.GRAY)

## Compatible Den partners for `a`, best egg odds first: [{creature, chance}].
static func partners(a: Creature, residents: Array) -> Array:
	var out: Array = []
	for b in residents:
		if compatible(a, b):
			out.append({"creature": b, "chance": egg_chance(a, b)})
	out.sort_custom(func(x, y): return x.chance > y.chance)
	return out

static func compatible(a: Creature, b: Creature) -> bool:
	if a == null or b == null or a.uid == b.uid:
		return false
	var ea: Array = a.species().egg
	var eb: Array = b.species().egg
	if "none" in ea or "none" in eb:
		return false
	for g in ea:
		if g in eb:
			return true
	return false

static func egg_chance(a: Creature, b: Creature) -> float:
	if not compatible(a, b):
		return 0.0
	var c := BASE_EGG_CHANCE + 0.25 * (float(a.happiness + b.happiness) / 510.0)
	if Data.base_form(a.species_id) == Data.base_form(b.species_id):
		c += 0.15
	for p in [a, b]:
		c += float(Data.traits.get(p.trait_id, {}).get("egg_bonus", 0.0))
	return clampf(c, 0.0, 0.95)

static func hatch_days(species_id: String) -> int:
	var rate: int = int(Data.get_species(species_id).rate)
	if rate >= 150:
		return 2
	if rate >= 100:
		return 3
	if rate >= 60:
		return 4
	return 5

## Creates egg metadata from two parents.
static func make_egg(a: Creature, b: Creature, rng: RandomNumberGenerator, opts: Dictionary = {}) -> Dictionary:
	var mother := a if rng.randf() < 0.5 else b
	var child_species := Data.base_form(mother.species_id)
	var genes := {}
	for s in Data.STATS:
		var roll := rng.randf()
		var v: int
		if roll < 0.45:
			v = int(a.genes[s])
		elif roll < 0.9:
			v = int(b.genes[s])
		else:
			v = rng.randi_range(0, Creature.MAX_GENE)
		if rng.randf() < MUTATION_CHANCE:
			v += rng.randi_range(1, 3) * (1 if rng.randf() < 0.7 else -1)
		genes[s] = clampi(v, 0, Creature.MAX_GENE)
	var nature: String = ""
	if opts.get("heirloom", false):
		nature = a.nature if rng.randf() < 0.5 else b.nature
	else:
		var keys: Array = Data.natures.keys()
		nature = keys[rng.randi() % keys.size()]
	var traits_list: Array = Data.get_species(child_species).traits
	var trait_id: String = traits_list[rng.randi() % traits_list.size()]
	if mother.trait_id in traits_list and rng.randf() < 0.7:
		trait_id = mother.trait_id
	var starry_mult := float(opts.get("starry_mult", 1.0))
	for p in [a, b]:
		if p.starry:
			starry_mult *= 4.0
		starry_mult *= float(Data.traits.get(p.trait_id, {}).get("starry_breed_mult", 1.0))
		starry_mult *= 1.0 + 0.25 * float(p.starry_lineage)
	var starry := rng.randf() * float(Creature.STARRY_ODDS) / starry_mult < 1.0
	var morph := ""
	if rng.randf() < 0.05:
		morph = String(opts.get("season", ""))
	elif a.morph != "" and a.morph == b.morph and rng.randf() < 0.5:
		morph = a.morph
	var egg_move := ""
	var egg_moves: Array = Data.get_species(child_species).egg_moves
	for m in egg_moves:
		if m in a.learned or m in b.learned:
			egg_move = m
			break
	if egg_move == "" and egg_moves.size() > 0 and rng.randf() < 0.15:
		egg_move = egg_moves[rng.randi() % egg_moves.size()]
	return {
		"species": child_species, "genes": genes, "nature": nature, "trait": trait_id,
		"starry": starry, "morph": morph, "egg_move": egg_move, "days": hatch_days(child_species),
		"lineage": maxi(a.starry_lineage, b.starry_lineage) + (1 if a.starry or b.starry else 0),
		"parents": [a.species_id, b.species_id],
	}

## Makes a wild egg (from rewards / Egg Hunt) of a species line.
static func wild_egg(species_id: String, rng: RandomNumberGenerator, starry_mult: float = 1.0) -> Dictionary:
	var base := Data.base_form(species_id)
	var genes := {}
	for s in Data.STATS:
		genes[s] = rng.randi_range(3, Creature.MAX_GENE)
	var keys: Array = Data.natures.keys()
	var tl: Array = Data.get_species(base).traits
	return {
		"species": base, "genes": genes, "nature": keys[rng.randi() % keys.size()], "trait": tl[rng.randi() % tl.size()],
		"starry": rng.randf() * float(Creature.STARRY_ODDS) / starry_mult < 1.0, "morph": "", "egg_move": "",
		"days": hatch_days(base), "lineage": 0, "parents": [],
	}

static func hatch(egg: Dictionary, rng: RandomNumberGenerator) -> Creature:
	var c := Creature.create(egg.species, 1, rng, {
		"genes": egg.genes, "nature": egg.nature, "trait": egg.trait, "starry": egg.starry, "morph": egg.get("morph", ""),
	})
	if egg.get("egg_move", "") != "":
		if not c.learned.has(egg.egg_move):
			c.learned.append(egg.egg_move)
		if c.moves.size() < 4:
			c.moves.append(egg.egg_move)
		else:
			c.moves[c.moves.size() - 1] = egg.egg_move
	c.happiness = 120
	c.starry_lineage = int(egg.get("lineage", 0))
	c.met = "Hatched"
	return c
