extends GutTest
## Battle command bar layout.

func _screen_with_moves(n: int) -> BattleScreen:
	GameState.new_game({"player_name": "Hero", "farm_name": "T", "starter": "embercub", "seed": 5})
	var me: Creature = GameState.local_player().party[0]
	me.moves = Data.moves.keys().slice(0, n)
	var foe := Creature.create("sproutle", 5, GameState.rng)
	var s := BattleScreen.new({"kind": "wild", "team": [foe]})
	add_child_autofree(s)
	s.engine = BattleEngine.new(GameState.local_player().party, [foe], BattleEngine.Kind.WILD, 1, "", "Hero")
	return s

func _buttons_on_screen(s: BattleScreen) -> Array:
	var view := s.root.get_viewport_rect()
	var out: Array = []
	for b in s._cmd.get_children():
		if b.is_queued_for_deletion():
			continue
		out.append(view.encloses(b.get_global_rect()))
	return out

func test_four_moves_and_back_fit_on_screen() -> void:
	var s := _screen_with_moves(4)
	s._show_main_menu()
	s._show_moves()
	await wait_frames(3)
	var on := _buttons_on_screen(s)
	assert_eq(on.size(), 5, "4 moves + Back")
	assert_false(false in on, "every button is inside the screen: %s" % [on])

func test_main_menu_goes_back_to_two_columns() -> void:
	var s := _screen_with_moves(4)
	s._show_moves()
	s._show_main_menu()
	await wait_frames(3)
	assert_eq(s._cmd.columns, 2)
	assert_false(false in _buttons_on_screen(s))
