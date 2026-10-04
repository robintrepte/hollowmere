extends GutTest
## Shared UI building blocks: number formats, coin labels, floating windows, tab bar, modifiers.

func after_each() -> void:
	Settings.apply()
	Modifiers.unregister("test_a")
	Modifiers.unregister("test_b")

func test_number_grouping_follows_the_language() -> void:
	TranslationServer.set_locale("de")
	assert_eq(Num.group(1234567), "1.234.567")
	assert_eq(Num.group(-950), "-950")
	TranslationServer.set_locale("en")
	assert_eq(Num.group(1234567), "1,234,567")

func test_short_numbers_for_the_hud() -> void:
	TranslationServer.set_locale("en")
	assert_eq(Num.short(9999), "9,999")
	assert_eq(Num.short(12345), "12.3k")
	assert_eq(Num.short(250000), "250k")
	assert_eq(Num.short(1200000), "1.2M")
	TranslationServer.set_locale("de")
	assert_eq(Num.short(12345), "12,3k")
	assert_eq(Num.short(2000000), "2\u202fMio.")

func test_coin_label_shows_icon_and_amount() -> void:
	TranslationServer.set_locale("de")
	var c := CoinLabel.new(15000)
	add_child_autofree(c)
	assert_not_null(c.icon.texture, "the coin icon is drawn, not a 'g'")
	assert_eq(c.label.text, "15.000")
	assert_false(c.label.text.ends_with("g"))
	c.set_affordable(false)
	assert_eq(c.label.get_theme_color("font_color"), UITheme.HEART)

func test_modifiers_add_up_across_sources() -> void:
	GameState.new_game({"seed": 1})
	var p := GameState.local_player()
	Modifiers.register("test_a", func(_p): return {"crop_growth": 0.1})
	Modifiers.register("test_b", func(_p): return {"crop_growth": 0.15, "sell_price": 0.05})
	assert_almost_eq(Modifiers.mult(p, "crop_growth"), 1.25, 0.0001)
	assert_almost_eq(Modifiers.value(p, "sell_price"), 0.05, 0.0001)
	assert_eq(Modifiers.breakdown(p, "crop_growth").size(), 2)
	assert_almost_eq(Modifiers.mult(p, "nothing"), 1.0, 0.0001)

func test_floating_window_stays_on_screen_and_closes() -> void:
	var w := FloatingWindow.new("Seed Pouch", "")
	w.custom_minimum_size = Vector2(120, 80)
	add_child(w)
	await wait_frames(2)
	w.position = Vector2(-500, 9999)
	w._keep_on_screen()
	var view := w.get_viewport_rect().size
	assert_true(w.position.x >= 0.0 and w.position.y + w.size.y <= view.y + 0.5, "pulled back on screen: %s" % w.position)
	watch_signals(w)
	w.close()
	assert_signal_emitted(w, "closed")

func test_tab_bar_steps_and_wraps() -> void:
	var bar := IconTabBar.new()
	add_child_autofree(bar)
	for id in ["inventory", "party", "craft"]:
		bar.add_tab(id, id.capitalize(), Art.item("_star"))
	bar.select("inventory")
	bar.step(-1)
	assert_eq(bar.current, "craft")
	bar.step(1)
	assert_eq(bar.current, "inventory")
	assert_true(bar.button("inventory").button_pressed)
	assert_false(bar.button("craft").button_pressed)

func test_tab_bar_compact_keeps_the_open_tab_named() -> void:
	var bar := IconTabBar.new()
	add_child_autofree(bar)
	for id in ["inventory", "party", "craft"]:
		bar.add_tab(id, id.capitalize(), Art.item("_star"))
	var wide := bar.full_width()
	assert_gt(wide, 0.0)
	bar.select("party")
	bar.set_compact(true)
	assert_eq(bar.button("inventory").text, "")
	assert_ne(bar.button("party").text, "")
	bar.select("craft")
	assert_eq(bar.button("party").text, "")
	assert_ne(bar.button("craft").text, "")
	bar.set_compact(false)
	assert_ne(bar.button("inventory").text, "")
