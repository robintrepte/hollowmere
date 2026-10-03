extends GutTest
## Battle command bar layout.

func _screen_with_moves(n: int, ids: Array = []) -> BattleScreen:
	GameState.new_game({"player_name": "Hero", "farm_name": "T", "starter": "embercub", "seed": 5})
	var me: Creature = GameState.local_player().party[0]
	me.moves = ids if not ids.is_empty() else Data.moves.keys().slice(0, n)
	var foe := Creature.create("sproutle", 5, GameState.rng)
	var s := BattleScreen.new({"kind": "wild", "team": [foe]})
	add_child_autofree(s)
	s.engine = BattleEngine.new(GameState.local_player().party, [foe], BattleEngine.Kind.WILD, 1, "", "Hero")
	return s

func _live_buttons(s: BattleScreen) -> Array:
	var out: Array = []
	for b in s._cmd.get_children():
		if not b.is_queued_for_deletion():
			out.append(b)
	return out

func _buttons_on_screen(s: BattleScreen) -> Array:
	var view := s.root.get_viewport_rect()
	var out: Array = []
	for b in _live_buttons(s):
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

func test_move_buttons_match_command_buttons() -> void:
	var locale := TranslationServer.get_locale()
	TranslationServer.set_locale("de")
	var s := _screen_with_moves(4, ["cozy_nap", "halo_bash", "radiant_burst", "eclipse_beam"])
	s._show_main_menu()
	await wait_frames(3)
	var menu_size: Vector2 = _live_buttons(s)[0].size
	var menu_prompt: Rect2 = s._msg.get_global_rect()
	s._show_moves()
	await wait_frames(3)
	TranslationServer.set_locale(locale)
	var view := s.root.get_viewport_rect()
	var prompt: Rect2 = s._msg.get_global_rect()
	assert_true(view.encloses(prompt), "prompt stays on screen: %s view %s" % [prompt, view])
	assert_lte(prompt.end.y, menu_prompt.end.y + 1.0, "move menu does not push the prompt lower than the command menu")
	for b in _live_buttons(s):
		assert_eq(b.size, menu_size, "same size as Fight/Bag/Party/Run: %s" % b.text)
		assert_true(view.encloses(b.get_global_rect()), b.text)
