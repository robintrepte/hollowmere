extends Node
## Regenerates the old-format save fixtures from a fresh game, stripping every key that was added
## after that format shipped. Only rerun if a fixture must change; old saves are frozen by design.
##   godot --headless --path game res://tests/fixtures/make_fixtures.tscn

const M4_M5_WORLD := ["shrines", "mine_depth", "flags", "quest", "legends", "festival_done", "chains", "bounty", "bounty_week", "board", "board_week"]
const M2_CREATURE := ["show_rank", "ribbons", "starry_lineage", "morph", "learned", "grooming"]
const M2_PLAYER := ["skills", "stats", "cosmetics", "hat", "recipes", "relationships", "backpack_level"]

func _ready() -> void:
	GameState.new_game({"player_name": "Old Timer", "farm_name": "Heirloom", "starter": "puddlop", "seed": 2024})
	var p := GameState.local_player()
	p.inventory.add("parsnip_seeds", 10)
	p.inventory.add("parsnip", 4, 1)
	var g := GameState.grid("farm")
	for x in range(20, 26):
		var t := Vector2i(x, 20)
		if g.can_till(t):
			g.till(t)
			g.plant(t, "parsnip_seeds", "spring")
	for i in 3:
		GameState.end_day()
	var m3 := SaveManager.make_payload()
	for k in M4_M5_WORLD:
		m3.state.world.erase(k)
	m3.version = 1
	_write("save_v1_m3.json", m3)
	var m1: Dictionary = m3.duplicate(true)
	m1.version = 0
	m1.erase("meta")
	for k in ["farm", "pairs", "regions", "dex_claimed", "weekly", "weekly_week", "stats", "hatchery", "luck", "created", "played", "version"]:
		m1.state.world.erase(k)
	var pd: Dictionary = m1.state.players.values()[0]
	m1.state.players = {"local": pd}
	pd.id = "local"
	for k in M2_PLAYER:
		pd.erase(k)
	for c in pd.party:
		for k in M2_CREATURE:
			c.erase(k)
	m1.state.erase("sanctuary")
	_write("save_v0_m1.json", m1)
	get_tree().quit()

func _write(name: String, d: Dictionary) -> void:
	var f := FileAccess.open("res://tests/fixtures/" + name, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "\t"))
	f.close()
	print("wrote ", name)
