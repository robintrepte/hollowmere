extends GutTest
## Text size, translations, the symbol fallback font and gamepad grid navigation.

func after_each() -> void:
	Settings.set_text_scale(1.0)
	Settings.set_ui_scale(1.0)
	Settings.set_hud_scale(1.0)
	Settings.set_ui_font("pixel")
	UITheme.reset()
	TranslationServer.set_locale("en")

func test_text_scale_scales_fonts_and_rebuilds_the_theme() -> void:
	assert_eq(UITheme.fs(10), 10)
	Settings.set_text_scale(1.4)
	assert_eq(UITheme.fs(10), 14)
	UITheme.reset()
	assert_eq(UITheme.theme().default_font_size, 14)
	var l := UITheme.label("Hi", 10)
	assert_eq(l.get_theme_font_size("font_size"), 14)
	l.free()
	Settings.set_text_scale(1.0)
	UITheme.reset()
	assert_eq(UITheme.theme().default_font_size, 10)

func test_ui_and_hud_scale_clamp_and_stack() -> void:
	assert_true("ui_scale" in Settings.SYNCED)
	assert_true("hud_scale" in Settings.SYNCED)
	var hits := [0]
	var on_scale := func() -> void: hits[0] += 1
	Settings.ui_scale_changed.connect(on_scale)
	Settings.set_ui_scale(1.2)
	assert_almost_eq(Settings.ui_scale, 1.2, 0.001)
	assert_eq(hits[0], 1)
	Settings.set_ui_scale(1.2)
	assert_eq(hits[0], 1, "the same size does not signal again")
	Settings.set_ui_scale(4.0)
	assert_almost_eq(Settings.ui_scale, Settings.UI_SCALE_MAX, 0.001)
	Settings.set_hud_scale(0.1)
	assert_almost_eq(Settings.hud_scale, Settings.UI_SCALE_MIN, 0.001)
	assert_almost_eq(Settings.current_hud_scale(), Settings.UI_SCALE_MAX * Settings.UI_SCALE_MIN, 0.001)
	assert_almost_eq(Settings.current_ui_scale(), Settings.UI_SCALE_MAX, 0.001)
	Settings.ui_scale_changed.disconnect(on_scale)
	Settings.set_ui_scale(1.0)
	Settings.set_hud_scale(1.0)

func test_fit_scale_covers_the_screen_from_the_center() -> void:
	var root := Control.new()
	add_child_autofree(root)
	var child := ColorRect.new()
	child.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	child.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(child)
	UITheme.fit_scale(root, 1.5)
	await wait_process_frames(2)
	var view := root.get_viewport().get_visible_rect().size
	var r := child.get_global_rect()
	assert_almost_eq(r.position.x, 0.0, 2.0, "scaled UI still starts at the left edge")
	assert_almost_eq(r.position.y, 0.0, 2.0, "scaled UI still starts at the top edge")
	assert_almost_eq(r.end.x, view.x, 2.0, "scaled UI still reaches the right edge")
	assert_almost_eq(r.end.y, view.y, 2.0, "scaled UI still reaches the bottom edge")
	assert_almost_eq(r.get_center().x, view.x * 0.5, 2.0)
	UITheme.fit_scale(root, 0.75)
	await wait_process_frames(2)
	r = child.get_global_rect()
	assert_almost_eq(r.position.x, 0.0, 2.0)
	assert_almost_eq(r.end.x, view.x, 2.0)
	assert_almost_eq(r.end.y, view.y, 2.0)

func test_readable_font_swaps_the_face() -> void:
	assert_eq(Settings.ui_font, "pixel")
	UITheme.reset()
	assert_true(str(UITheme.font().base_font.resource_path).contains("Tiny5"))
	Settings.set_ui_font("readable")
	UITheme.reset()
	assert_eq(Settings.ui_font, "readable")
	assert_true(str(UITheme.font().base_font.resource_path).contains("Nunito"))
	assert_eq(UITheme.theme().default_font, UITheme.font())
	Settings.set_ui_font("pixel")
	UITheme.reset()
	assert_true(str(UITheme.font().base_font.resource_path).contains("Tiny5"))

func test_symbols_render_on_the_web_via_fallback() -> void:
	var f := UITheme.font()
	for ch in ["♥", "♡", "✓", "★"]:
		var ok := false
		for fb in f.fallbacks:
			if fb.has_char(ch.unicode_at(0)):
				ok = true
		assert_true(ok, "%s has a bundled glyph" % ch)

func test_german_catalog_is_loaded_and_used() -> void:
	if not "de" in Settings.available_locales():
		Settings.load_translations()
	assert_true("de" in Settings.available_locales(), "German catalog is registered")
	var prev := Settings.locale
	Settings.locale = "de"
	Settings.apply()
	assert_eq(tr("Settings"), "Einstellungen")
	assert_eq(tr("New Farm"), "Neuer Hof")
	assert_eq(Data.item_name("parsnip"), "Pastinake")
	assert_eq(Data.item_name("parsnip_seeds"), "Pastinake-Saat")
	assert_eq(Data.type_name("leaf"), "Blatt")
	assert_eq(Data.season_name("spring"), "Frühling")
	assert_eq(Endless.rank_name(0), "Anfänger")
	Settings.locale = "en"
	Settings.apply()
	assert_eq(Data.item_name("parsnip"), "Parsnip")
	Settings.locale = prev
	Settings.apply()

func test_data_names_go_through_translation() -> void:
	var t := Translation.new()
	t.locale = "de"
	t.add_message("Parsnip", "Pastinake")
	t.add_message("Gold", "Gold-")
	t.add_message("Leaf", "Blatt")
	TranslationServer.add_translation(t)
	TranslationServer.set_locale("de")
	assert_eq(Data.item_name("parsnip"), "Pastinake")
	assert_eq(Data.type_name("leaf"), "Blatt")
	TranslationServer.set_locale("en")
	assert_eq(Data.item_name("parsnip"), "Parsnip")
	TranslationServer.remove_translation(t)

func test_grid_view_cursor_moves_and_picks_with_a_pad() -> void:
	var inv := Inventory.new(4, 3)
	inv.add("parsnip", 3)
	var panel := Node.new()
	var v := GridView.new()
	v.setup(inv, panel)
	add_child_autofree(v)
	add_child_autofree(panel)
	var picked: Array = []
	v.cell_pressed.connect(func(_v, cell: Vector2i, button: int, _s, _double): picked.append([cell, button]))
	v.grab_focus()
	assert_eq(v.hover_cell, Vector2i.ZERO)
	var right := InputEventAction.new()
	right.action = "ui_right"
	right.pressed = true
	v._pad_input(right)
	assert_eq(v.hover_cell, Vector2i(1, 0))
	var accept := InputEventAction.new()
	accept.action = "ui_accept"
	accept.pressed = true
	v._pad_input(accept)
	assert_eq(picked, [[Vector2i(1, 0), MOUSE_BUTTON_LEFT]])
	var x := InputEventAction.new()
	x.action = "use_tool"
	x.pressed = true
	v._pad_input(x)
	assert_eq(picked[-1], [Vector2i(1, 0), MOUSE_BUTTON_RIGHT], "X opens the actions menu")

func test_colorblind_quality_pips_count_quality() -> void:
	Settings.colorblind = true
	assert_eq(ItemSlot.quality_pips(1), 1)
	assert_eq(ItemSlot.quality_pips(3), 3, "iridium reads as three pips, not just a color")
	Settings.colorblind = false
	assert_eq(ItemSlot.quality_pips(3), 1)
