extends GutTest
## Stacked wild Wildlings must not chain a new battle the moment a flee ends.

var _hits := 0

func before_each() -> void:
	_hits = 0
	UIRoot.blocking = false

func after_each() -> void:
	if EventBus.battle_requested.is_connected(_on_battle):
		EventBus.battle_requested.disconnect(_on_battle)
	UIRoot.blocking = false

func _on_battle(_s: Dictionary) -> void:
	_hits += 1

func test_grace_stops_stacked_wildlings_from_chaining() -> void:
	EventBus.battle_requested.connect(_on_battle)
	var world := World.new()
	add_child_autofree(world)
	var player := Player.new()
	player.local = true
	player.position = Vector2(160, 160)
	player.encounter_grace = 2.0
	world.add_child(player)
	var a := _wild(world, player.position)
	var b := _wild(world, player.position + Vector2(4, 0))
	a._process(0.05)
	b._process(0.05)
	assert_eq(_hits, 0, "flee grace blocks the pile")
	player.encounter_grace = 0.0
	a._stun = 0.0
	b._stun = 0.0
	a._process(0.05)
	assert_eq(_hits, 1, "once grace ends, a touching Wildling starts a battle")

func _wild(world: World, pos: Vector2) -> WildCreature:
	var w := WildCreature.new()
	w.species = "sproutle"
	w.level = 3
	w.world = world
	w.position = pos
	world.add_child(w)
	world.creatures.append(w)
	w._wait = 5.0
	w._target = pos
	return w
