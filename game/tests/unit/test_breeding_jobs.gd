extends GutTest
## All 10 farm jobs, breeding helpers, overnight evolution and the hatchery flow.

var rng := RandomNumberGenerator.new()

func before_each() -> void:
	rng.seed = 2024

func _worker_for(job: String) -> Creature:
	for sid in Data.species_order:
		var sp: Dictionary = Data.species[sid]
		if Data.types[sp.types[0]].job == job and not sp.get("legendary", false):
			var c := Creature.create(sid, 30, rng)
			c.job = job
			return c
	return null

func _farm() -> FarmGrid:
	var g := FarmGrid.new()
	g.map_id = "test"
	g.setup(12, 12)
	g.tillable = ["grass"]
	for x in 8:
		var p := Vector2i(x + 1, 2)
		g.till(p)
		g.plant(p, "parsnip_seeds", "spring")
	g.set_deco(Vector2i(2, 6), Tiles.DECO.weed)
	g.set_deco(Vector2i(3, 6), Tiles.DECO.rock)
	return g

func test_every_job_has_a_worker_species() -> void:
	for job in FarmJobs.JOBS:
		assert_not_null(_worker_for(job), "some species can do %s" % job)

func test_all_ten_jobs_do_something() -> void:
	var expect := {
		"water": "watered", "grow": "grown", "clear": "cleared", "smelt": "smelted", "pollinate": "pollinated",
		"power": "powered", "preserve": "preserved", "guard": "guarded", "luck": "luck", "harvest": "harvested",
	}
	for job in FarmJobs.JOBS:
		var g := _farm()
		var ready := Vector2i(1, 2)
		g.crop_at(ready).progress = 1.0
		var chest := Inventory.new(10, 8)
		chest.add("copper_ore", 10)
		chest.add("parsnip", 4)
		var w := _worker_for(job)
		var rep := FarmJobs.run([w], {"grids": [g], "chest": chest, "rng": rng, "season": "spring", "scale": 18.0})
		var v: Variant = rep[expect[job]]
		assert_true(v is bool and v or (not v is bool and float(v) > 0.0), "%s job produced %s" % [job, expect[job]])
		assert_eq(int(rep.workers), 1)

func test_harvester_flags_the_plant_so_it_stops_looking_ripe() -> void:
	var g := _farm()
	var p := Vector2i(1, 2)
	g.crop_at(p).progress = 1.0
	var w := _worker_for("harvest")
	FarmJobs.run([w], {"grids": [g], "chest": Inventory.new(8, 6), "rng": rng, "season": "spring", "scale": 18.0})
	assert_false(g.crop_ready(p), "the plant was picked and is growing again")
	assert_lt(g.crop_stage(p), 4)
	assert_true(Tiles.key(p) in g.take_look_dirty(), "the tile is queued for a redraw")

func test_harvester_refreshes_the_tile_on_the_farm() -> void:
	GameState.new_game({"seed": 12, "starter": "puddlop"})
	var g: FarmGrid = GameState.grids.farm
	var p := Vector2i(4, 12)
	assert_true(g.till(p))
	assert_true(g.plant(p, "parsnip_seeds"))
	var s: Dictionary = g.soil[Tiles.key(p)]
	s.watered = true
	s.watered_until = TimeService.now() + 999999.0
	g.crop_at(p).progress = 1.0
	var w := _worker_for("harvest")
	GameState.ranch.append(w)
	var seen := [false]
	var cb := func(m: String, t: Vector2i) -> void:
		if m == "farm" and t == p and not g.crop_ready(p):
			seen[0] = true
	EventBus.tile_changed.connect(cb)
	_advance(FarmJobs.TICK_SECONDS)
	EventBus.tile_changed.disconnect(cb)
	assert_false(g.crop_ready(p))
	assert_true(seen[0], "picking redraws the tile, so the ripe fruit sprite goes away")

func test_tired_workers_skip() -> void:
	var w := _worker_for("water")
	w.energy = 0.5
	var rep := FarmJobs.run([w], {"grids": [_farm()], "chest": Inventory.new(4, 4), "rng": rng, "season": "spring"})
	assert_eq(int(rep.tired), 1)
	assert_eq(int(rep.watered), 0)

func test_wrong_type_cannot_work() -> void:
	var c := Creature.create("embercub", 10, rng)
	assert_false(c.can_do_job("water"))
	c.job = "water"
	var rep := FarmJobs.run([c], {"grids": [_farm()], "chest": Inventory.new(4, 4), "rng": rng, "season": "spring"})
	assert_eq(int(rep.workers), 0)

func test_work_gives_xp_and_rest_restores() -> void:
	var w := _worker_for("water")
	var xp := w.xp
	FarmJobs.run([w], {"grids": [_farm()], "chest": Inventory.new(4, 4), "rng": rng, "season": "spring", "scale": 18.0})
	assert_gt(w.xp, xp, "three hours of work earn some XP")
	var e := w.energy
	FarmJobs.rest([w], false, 6.0)
	assert_gt(w.energy, e)

func test_gene_grades() -> void:
	assert_eq(Breeding.gene_grade(15), "S")
	assert_eq(Breeding.gene_grade(12), "A")
	assert_eq(Breeding.gene_grade(8), "B")
	assert_eq(Breeding.gene_grade(4), "C")
	assert_eq(Breeding.gene_grade(0), "D")

func test_partners_sorted_by_chance() -> void:
	var a := Creature.create("puddlop", 10, rng)
	var b := Creature.create("puddlop", 10, rng)
	var c := Creature.create("embercub", 10, rng)
	var list := Breeding.partners(a, [a, b, c])
	assert_gt(list.size(), 0)
	assert_false(list.any(func(o): return o.creature == a), "can't pair with itself")
	for i in range(1, list.size()):
		assert_true(list[i - 1].chance >= list[i].chance)

func test_pairing_eggs_and_hatching_flow() -> void:
	GameState.new_game({"seed": 5, "starter": "puddlop"})
	var a := Creature.create("puddlop", 12, rng)
	var b := Creature.create("puddlop", 12, rng)
	a.happiness = 255
	b.happiness = 255
	GameState.ranch.append(a)
	GameState.ranch.append(b)
	assert_true(GameState.set_pair(a.uid, b.uid).ok)
	assert_eq(GameState.pair_of(a.uid), b.uid)
	assert_eq(GameState.pair_of(b.uid), a.uid)
	var eggs := int(_advance(3 * 86400).eggs)
	assert_gt(eggs, 0, "a happy pair lays eggs within a few real days")
	GameState.world.buildings.append("hatchery")
	var egg: Dictionary = GameState.farm_chest.first_of("wildling_egg")
	assert_false(egg.is_empty())
	assert_true(GameState.add_egg_to_hatchery(GameState.local_player(), egg.uid), "eggs go in straight from the farm chest")
	var slot: Dictionary = GameState.world.hatchery[0]
	assert_gt(float(slot.hatch_at), TimeService.now())
	assert_eq(_advance(float(slot.hatch_at) - TimeService.now() - 5.0).hatched.size(), 0, "not yet")
	assert_eq(_advance(10.0).hatched.size(), 1, "hatches right on time")
	GameState.clear_pair(a.uid)
	assert_eq(GameState.pair_of(a.uid), "")

func test_overnight_evolution_from_farm_xp() -> void:
	GameState.new_game({"seed": 6})
	var c := Creature.create("sproutle", 15, rng)
	GameState.ranch.append(c)
	c.gain_xp(Creature.xp_for_level(17) - c.xp)
	assert_ne(c.can_evolve(), "")
	var rep := _advance(FarmJobs.TICK_SECONDS)
	assert_eq(c.species_id, "bramblet")
	assert_eq(rep.evolved.size(), 1)

func test_farm_wildlings_start_their_own_job() -> void:
	GameState.new_game({"seed": 8})
	var p := GameState.local_player()
	var c := Creature.create("puddlop", 10, rng)
	p.party.append(c)
	assert_true(GameState.move_creature(c.uid, "den", p))
	assert_eq(c.job, "water", "a Tide Wildling waters as soon as it reaches the farm")
	assert_true(GameState.move_creature(c.uid, "party", p))
	assert_eq(c.job, "", "it stops working when it leaves")

func test_resting_by_choice_survives_a_reload() -> void:
	GameState.new_game({"seed": 9})
	var c := Creature.create("embercub", 10, rng)
	GameState.ranch.append(c)
	assert_true(GameState.set_job(c.uid, ""))
	var d: Dictionary = JSON.parse_string(JSON.stringify(GameState.to_dict()))
	GameState.from_dict(d)
	assert_eq(GameState.find_creature(c.uid).job, "", "a chosen rest is not overridden")

func test_older_saves_put_idle_farm_wildlings_to_work() -> void:
	GameState.new_game({"seed": 10})
	var c := Creature.create("sproutle", 10, rng)
	GameState.ranch.append(c)
	var d: Dictionary = JSON.parse_string(JSON.stringify(GameState.to_dict()))
	for r in d.ranch:
		r.erase("job_manual")
		r.job = ""
	GameState.from_dict(d)
	assert_eq(GameState.find_creature(c.uid).job, "grow")

func test_befriended_overflow_goes_to_work_in_the_den() -> void:
	GameState.new_game({"seed": 11})
	var p := GameState.local_player()
	while p.party.size() < PlayerData.PARTY_MAX:
		p.party.append(Creature.create("mossbun", 5, rng))
	var c := Creature.create("puddlop", 5, rng)
	assert_eq(GameState.add_creature(p, c), "den")
	assert_eq(c.job, "water")

func after_each() -> void:
	TimeService.fixed_now = -1.0

## Moves the real clock forward and lets the farm catch up.
func _advance(seconds: float) -> Dictionary:
	var to := float(GameState.world.time.last) + seconds
	TimeService.fixed_now = to
	return GameState.idle_advance(to)
