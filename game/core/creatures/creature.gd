class_name Creature
extends RefCounted
## A single Wildling instance. Pure data + rules; no scene dependencies.

const MAX_LEVEL := 100
const MAX_GENE := 15
const STARRY_ODDS := 1024
const NON_HP_STATS := ["power", "guard", "focus", "speed"]

var uid: String = ""
var species_id: String = ""
var nickname: String = ""
var level: int = 1
var xp: int = 0
var genes: Dictionary = {"hp": 0, "power": 0, "guard": 0, "focus": 0, "speed": 0}
var nature: String = "hardy"
var trait_id: String = ""
var moves: Array = []
var learned: Array = []
var hp: int = 1
var status: String = ""
var status_turns: int = 0
var starry: bool = false
var morph: String = ""
var happiness: int = 70
var energy: int = 100
var grooming: int = 0
var job: String = ""
var owner: String = ""
var met: String = ""
var starry_lineage: int = 0

static func make_uid(rng: RandomNumberGenerator) -> String:
	return "%08x%08x" % [rng.randi(), rng.randi()]

## Creates a wild/new creature at `lvl`. `opts` may contain: starry_mult, morph, nature, trait, genes, min_gene.
static func create(species: String, lvl: int, rng: RandomNumberGenerator, opts: Dictionary = {}) -> Creature:
	var c := Creature.new()
	var sp: Dictionary = Data.get_species(species)
	assert(not sp.is_empty(), "Unknown species %s" % species)
	c.uid = make_uid(rng)
	c.species_id = species
	c.level = clampi(lvl, 1, MAX_LEVEL)
	c.xp = xp_for_level(c.level)
	var min_gene: int = int(opts.get("min_gene", 0))
	for s in Data.STATS:
		c.genes[s] = rng.randi_range(min_gene, MAX_GENE)
	if opts.has("genes"):
		for s in opts.genes:
			c.genes[s] = clampi(int(opts.genes[s]), 0, MAX_GENE)
	var nature_keys: Array = Data.natures.keys()
	c.nature = opts.get("nature", nature_keys[rng.randi() % nature_keys.size()])
	var trait_opts: Array = sp.traits
	c.trait_id = opts.get("trait", trait_opts[rng.randi() % trait_opts.size()])
	var odds := float(STARRY_ODDS) / float(opts.get("starry_mult", 1.0))
	c.starry = opts.get("starry", rng.randf() * odds < 1.0)
	c.morph = opts.get("morph", "")
	c.happiness = 70 if not sp.legendary else 40
	c._init_moves()
	c.hp = c.max_hp()
	return c

func _init_moves() -> void:
	learned.clear()
	for e in species().learnset:
		if int(e[0]) <= level and not learned.has(e[1]):
			learned.append(e[1])
	moves = pick_best_moves(learned)

static func pick_best_moves(pool: Array) -> Array:
	var damaging: Array = []
	var status_moves: Array = []
	for m in pool:
		if Data.get_move(m).cat == "status":
			status_moves.append(m)
		else:
			damaging.append(m)
	damaging.sort_custom(func(a, b): return Data.get_move(a).power > Data.get_move(b).power)
	var out: Array = []
	for m in damaging:
		if out.size() >= 3:
			break
		out.append(m)
	if status_moves.size() > 0:
		out.append(status_moves[status_moves.size() - 1])
	for m in damaging:
		if out.size() >= 4:
			break
		if not out.has(m):
			out.append(m)
	if out.is_empty():
		out.append("tackle")
	return out

func species() -> Dictionary:
	return Data.get_species(species_id)

func display_name() -> String:
	return nickname if nickname != "" else species().name

func types() -> Array:
	return species().types

func is_fainted() -> bool:
	return hp <= 0

static func xp_for_level(lvl: int) -> int:
	return lvl * lvl * lvl

func xp_to_next() -> int:
	if level >= MAX_LEVEL:
		return 0
	return xp_for_level(level + 1) - xp

func nature_mult(stat: String) -> float:
	var n: Dictionary = Data.natures.get(nature, {})
	if n.get("up", "") == stat:
		return 1.1
	if n.get("down", "") == stat:
		return 0.9
	return 1.0

func stat(s: String) -> int:
	var base: int = int(species().base_stats[s])
	var g: int = int(genes.get(s, 0))
	if s == "hp":
		return int(floor(float((base * 2 + g) * level) / 100.0)) + level + 10
	var v := int(floor(float((base * 2 + g) * level) / 100.0)) + 5
	var mult := nature_mult(s)
	if s == "speed":
		mult *= float(Data.traits.get(trait_id, {}).get("speed_mult", 1.0))
	return int(floor(v * mult))

func max_hp() -> int:
	return stat("hp")

func gene_total() -> int:
	var t := 0
	for s in Data.STATS:
		t += int(genes[s])
	return t

func heal_full() -> void:
	hp = max_hp()
	status = ""
	status_turns = 0

## Adds experience. Returns an array of event dicts: {t:"level", level}, {t:"learn", move}, {t:"evolve_ready", to}
func gain_xp(amount: int) -> Array:
	var events: Array = []
	if level >= MAX_LEVEL:
		return events
	xp += amount
	while level < MAX_LEVEL and xp >= xp_for_level(level + 1):
		var old_max := max_hp()
		level += 1
		hp += max_hp() - old_max
		events.append({"t": "level", "level": level})
		for e in species().learnset:
			if int(e[0]) == level and not learned.has(e[1]):
				learned.append(e[1])
				if moves.size() < 4:
					moves.append(e[1])
					events.append({"t": "learn", "move": e[1], "equipped": true})
				else:
					events.append({"t": "learn", "move": e[1], "equipped": false})
	var evo := can_evolve()
	if evo != "":
		events.append({"t": "evolve_ready", "to": evo})
	return events

func can_evolve() -> String:
	var evo = species().evo
	if evo == null:
		return ""
	if level >= int(evo[1]):
		return evo[0]
	return ""

func evolve() -> String:
	var to := can_evolve()
	if to == "":
		return ""
	var frac := float(hp) / float(max(1, max_hp()))
	species_id = to
	for e in species().learnset:
		if int(e[0]) <= level and not learned.has(e[1]):
			learned.append(e[1])
	hp = max(1, int(round(frac * max_hp())))
	if not Data.get_species(to).traits.has(trait_id):
		var pinch: String = Data.get_species(to).traits[0]
		if Data.traits.get(trait_id, {}).has("pinch"):
			trait_id = pinch
	happiness = mini(255, happiness + 20)
	return to

func change_happiness(delta: int) -> void:
	if delta < 0 and trait_id == "sunny":
		return
	if delta > 0:
		delta += int(Data.traits.get(trait_id, {}).get("happiness_bonus", 0))
		delta += int(Data.natures.get(nature, {}).get("happiness_bonus", 0))
	happiness = clampi(happiness + delta, 0, 255)

func job_type() -> String:
	return Data.types[types()[0]].job

## Farm job power for a given job id (e.g. "water").
func job_power(job_id: String) -> int:
	var p := 1 + int(level / 10)
	var tr: Dictionary = Data.traits.get(trait_id, {})
	var jb: Dictionary = tr.get("job_bonus", {})
	p += int(jb.get(job_id, 0)) + int(jb.get("*", 0))
	for t in types():
		if Data.types[t].job == job_id and t != types()[0]:
			p = max(p, 1 + int(level / 12))
	if happiness >= 200:
		p += 1
	if starry:
		p += 1
	return p

func can_do_job(job_id: String) -> bool:
	for t in types():
		if Data.types[t].job == job_id:
			return true
	return false

func to_dict() -> Dictionary:
	return {
		"uid": uid, "species": species_id, "nickname": nickname, "level": level, "xp": xp,
		"genes": genes.duplicate(), "nature": nature, "trait": trait_id, "moves": moves.duplicate(),
		"learned": learned.duplicate(), "hp": hp, "status": status, "status_turns": status_turns,
		"starry": starry, "morph": morph, "happiness": happiness, "energy": energy, "grooming": grooming,
		"job": job, "owner": owner, "met": met, "starry_lineage": starry_lineage,
	}

static func from_dict(d: Dictionary) -> Creature:
	var c := Creature.new()
	c.uid = d.get("uid", "")
	c.species_id = d.get("species", "nibblet")
	if Data.get_species(c.species_id).is_empty():
		c.species_id = "nibblet"
	c.nickname = d.get("nickname", "")
	c.level = int(d.get("level", 1))
	c.xp = int(d.get("xp", xp_for_level(c.level)))
	var g: Dictionary = d.get("genes", {})
	for s in Data.STATS:
		c.genes[s] = int(g.get(s, 0))
	c.nature = d.get("nature", "hardy")
	c.trait_id = d.get("trait", c.species().traits[0])
	c.moves = d.get("moves", []).duplicate()
	c.learned = d.get("learned", c.moves).duplicate()
	if c.moves.is_empty():
		c._init_moves()
	c.hp = int(d.get("hp", c.max_hp()))
	c.status = d.get("status", "")
	c.status_turns = int(d.get("status_turns", 0))
	c.starry = bool(d.get("starry", false))
	c.morph = d.get("morph", "")
	c.happiness = int(d.get("happiness", 70))
	c.energy = int(d.get("energy", 100))
	c.grooming = int(d.get("grooming", 0))
	c.job = d.get("job", "")
	c.owner = d.get("owner", "")
	c.met = d.get("met", "")
	c.starry_lineage = int(d.get("starry_lineage", 0))
	return c

func clone() -> Creature:
	return Creature.from_dict(to_dict())
