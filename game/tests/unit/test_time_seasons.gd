extends GutTest
## Real-world clock and seasons.

func after_each() -> void:
	Seasons.override = "spring"
	TimeService.fixed_now = -1.0

func _unix(y: int, m: int, d: int) -> float:
	return float(Time.get_unix_time_from_datetime_dict({"year": y, "month": m, "day": d, "hour": 12, "minute": 0, "second": 0}))

func test_meteorological_boundaries() -> void:
	assert_eq(Seasons.for_unix(_unix(2026, 2, 28)), "winter")
	assert_eq(Seasons.for_unix(_unix(2026, 3, 1)), "spring")
	assert_eq(Seasons.for_unix(_unix(2026, 5, 31)), "spring")
	assert_eq(Seasons.for_unix(_unix(2026, 6, 1)), "summer")
	assert_eq(Seasons.for_unix(_unix(2026, 9, 1)), "fall")
	assert_eq(Seasons.for_unix(_unix(2026, 12, 1)), "winter")
	assert_eq(Seasons.for_unix(_unix(2027, 1, 15)), "winter")

func test_southern_hemisphere_is_flipped() -> void:
	assert_eq(Seasons.for_unix(_unix(2026, 7, 10), "south"), "winter")
	assert_eq(Seasons.for_unix(_unix(2026, 12, 24), "south"), "summer")
	assert_eq(Seasons.hemisphere_for_locale("en_AU"), "south")
	assert_eq(Seasons.hemisphere_for_locale("pt_BR"), "south")
	assert_eq(Seasons.hemisphere_for_locale("de_DE"), "north")
	assert_eq(Seasons.hemisphere_for_locale("de"), "north")
	assert_eq(Seasons.hemisphere("south", "de_DE"), "south", "the setting beats the locale")

func test_game_season_follows_the_clock() -> void:
	Seasons.override = ""
	TimeService.fixed_now = _unix(2026, 7, 10)
	assert_eq(Seasons.current(TimeService.now(), "north"), "summer")
	assert_eq(Seasons.current(TimeService.now(), "south"), "winter")

func test_next_change() -> void:
	assert_eq(Seasons.next_change(_unix(2026, 4, 10)), float(Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 6, "day": 1, "hour": 0, "minute": 0, "second": 0})))
	assert_eq(Seasons.next_change(_unix(2026, 12, 10)), float(Time.get_unix_time_from_datetime_dict({"year": 2027, "month": 3, "day": 1, "hour": 0, "minute": 0, "second": 0})))
	assert_eq(Seasons.next_change(_unix(2027, 1, 10)), float(Time.get_unix_time_from_datetime_dict({"year": 2027, "month": 3, "day": 1, "hour": 0, "minute": 0, "second": 0})))

func test_elapsed_never_runs_backwards_or_past_the_cap() -> void:
	assert_eq(TimeService.elapsed(1000.0, 900.0), 0.0, "a clock turned back gives nothing")
	assert_eq(TimeService.elapsed(0.0, 100.0 * 86400.0), float(TimeService.OFFLINE_CAP), "14 days at most")
	assert_eq(TimeService.elapsed(0.0, 3600.0), 3600.0)

func test_duration_text() -> void:
	TranslationServer.set_locale("en")
	assert_eq(TimeService.duration_text(45), "45 s")
	assert_eq(TimeService.duration_text(600), "10 min")
	assert_eq(TimeService.duration_text(3600 + 12 * 60), "1 h 12 min")
	assert_eq(TimeService.duration_text(2 * 86400 + 3 * 3600), "2 d 3 h")
	Settings.apply()

func test_cloud_payload_round_trip_is_compressed() -> void:
	GameState.new_game({"seed": 4})
	var p := SaveManager.make_payload()
	var packed := SaveManager.pack_cloud(p)
	assert_false(packed.has("state"))
	assert_lt(JSON.stringify(packed).length(), JSON.stringify(p).length() / 2, "at least halves the upload")
	var back := SaveManager.unpack_cloud(packed)
	assert_eq(JSON.stringify(back.state), JSON.stringify(JSON.parse_string(JSON.stringify(p.state))), "same as a local save after JSON")
	assert_eq(int(back.version), GameState.SAVE_VERSION)
