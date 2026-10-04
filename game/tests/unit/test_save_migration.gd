extends GutTest
## Every save format that ever shipped must still load and play. Fixtures are frozen old saves.

const FIXTURES := ["res://tests/fixtures/save_v0_m1.json", "res://tests/fixtures/save_v1_m3.json"]

var _slot := -1

func before_all() -> void:
	SaveManager.dir = "user://test_saves"
	DirAccess.make_dir_recursive_absolute(SaveManager.dir)

func after_all() -> void:
	SaveManager.dir = SaveManager.DIR

func after_each() -> void:
	_remove()

## Local files only: SaveManager.delete_slot would also delete that slot from a signed-in cloud.
func _remove() -> void:
	if _slot >= 0:
		for suffix in ["", ".bak", ".tmp"]:
			DirAccess.remove_absolute(SaveManager.slot_path(_slot) + suffix)
		_slot = -1

func _install(path: String) -> Dictionary:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_slot = SaveManager.first_free_slot()
	assert_gte(_slot, 0, "a free slot for the fixture")
	var f := FileAccess.open(SaveManager.slot_path(_slot), FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	return d

func test_old_saves_load_and_keep_progress() -> void:
	for path in FIXTURES:
		var d := _install(path)
		assert_true(SaveManager.load_game(_slot), "%s loads" % path)
		var p := GameState.local_player()
		assert_not_null(p, "%s: the host's farmer is found" % path)
		assert_eq(GameState.money(), int(d.state.world.money), "%s: money kept" % path)
		assert_eq(GameState.world.farm_name, "Heirloom")
		assert_gt(p.party.size(), 0, "%s: party kept" % path)
		assert_gt(p.inventory.count("parsnip_seeds"), 0, "%s: inventory kept" % path)
		assert_gt(GameState.grid("farm").planted_tiles().size(), 0, "%s: crops kept" % path)
		for k in GameState.default_world():
			assert_true(GameState.world.has(k), "%s: world.%s filled in" % [path, k])
		_remove()

func test_old_saves_play_every_system() -> void:
	for path in FIXTURES:
		_install(path)
		SaveManager.load_game(_slot)
		var p := GameState.local_player()
		assert_eq(Adventure.shrine_state(GameState.world, "whisperwood"), "dark", "%s: shrines start dark" % path)
		GameState.end_day()
		assert_false(GameState.bounty().is_empty(), "%s: weekly bounty rolls" % path)
		assert_true(GameState.chain_act(p.id, p.party[0].species_id).ok, "%s: Starry chains work" % path)
		while not Endless.show_open(GameState.day()):
			GameState.world.day += 1
		assert_true(GameState.show_act(p.id, p.party[0].uid).ok, "%s: the weekly show runs" % path)
		for i in 7:
			GameState.end_day()
		assert_eq(GameState.local_player().party.size(), p.party.size(), "%s: a week of days later the party is intact" % path)
		_remove()

func test_migrated_save_roundtrips() -> void:
	for path in FIXTURES:
		_install(path)
		SaveManager.load_game(_slot)
		GameState.end_day()
		var before := GameState.to_dict()
		var payload: Dictionary = JSON.parse_string(JSON.stringify(SaveManager.make_payload()))
		assert_eq(int(payload.version), GameState.SAVE_VERSION)
		assert_true(SaveManager.load_payload(payload, _slot))
		var after := GameState.to_dict()
		assert_eq(int(after.world.day), int(before.world.day))
		assert_eq(int(after.world.money), int(before.world.money))
		assert_eq(after.players.keys(), before.players.keys())
		assert_eq(after.grids.farm.soil.size(), before.grids.farm.soil.size(), "%s: soil survives a save" % path)
		_remove()
