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
	assert_gt(menu_prompt.size.y, 20.0, "the prompt is tall enough to read")
	assert_lte(prompt.end.y, menu_prompt.end.y + 1.0, "move menu does not push the prompt lower than the command menu")
	for b in _live_buttons(s):
		assert_eq(b.size, menu_size, "same size as Fight/Bag/Party/Run: %s" % b.text)
		assert_true(view.encloses(b.get_global_rect()), b.text)

func _foe(s: BattleScreen, id: String) -> void:
	var foe := Creature.create(id, 5, GameState.rng)
	s.engine = BattleEngine.new(GameState.local_player().party, [foe], BattleEngine.Kind.WILD, 1, "", "Hero")

func test_recommends_the_super_effective_move() -> void:
	var s := _screen_with_moves(2, ["splash_jab", "vine_lash"])
	_foe(s, "embercub")
	assert_eq(s.recommended_move(), 0, "Tide beats Ember")
	s._show_moves()
	await wait_frames(2)
	var first: Button = _live_buttons(s)[0]
	assert_true(first.has_meta("recommended"), first.text)
	assert_true(first.text.contains("×2"), first.text)
	assert_true(first.text.contains("%"), "shows how much HP it takes: %s" % first.text)
	assert_false(_live_buttons(s)[1].has_meta("recommended"))

func test_highlighting_a_move_previews_it_on_the_foe_bar() -> void:
	var s := _screen_with_moves(2, ["splash_jab", "vine_lash"])
	_foe(s, "embercub")
	s._show_moves()
	s._show_move_detail(0, 0)
	assert_false(s._preview.is_empty())
	assert_true(s._msg.text.contains("×2"), s._msg.text)
	s._show_main_menu()
	assert_true(s._preview.is_empty(), "leaving the move list clears the preview")

func test_move_details_fit_in_german_at_large_text() -> void:
	var locale := TranslationServer.get_locale()
	var scale := Settings.text_scale
	TranslationServer.set_locale("de")
	Settings.set_text_scale(1.4)
	UITheme.reset()
	var s := _screen_with_moves(4, ["cozy_nap", "halo_bash", "radiant_burst", "eclipse_beam"])
	s.root.theme = UITheme.theme()
	s._show_moves()
	for i in 4:
		s._show_move_detail(i, 0)
		await wait_frames(2)
		var view := s.root.get_viewport_rect()
		assert_true(view.encloses(s._msg.get_global_rect()), "move %d detail stays on screen: %s" % [i, s._msg.get_global_rect()])
		assert_eq(s._msg.get_visible_line_count(), s._msg.get_line_count(), "move %d detail shows every line" % i)
		var bar: Control = s._msg.get_parent().get_parent()
		assert_true(view.encloses(bar.get_global_rect()), "move %d: the bar stays on screen: %s" % [i, bar.get_global_rect()])
	TranslationServer.set_locale(locale)
	Settings.set_text_scale(scale)
	UITheme.reset()
