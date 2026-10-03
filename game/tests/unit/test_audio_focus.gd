extends GutTest
## Music mutes when the game loses focus, and the volume slider still wins.

var _prev_music := 0.6

func before_each() -> void:
	_prev_music = Settings.music_volume

func after_each() -> void:
	Audio._set_away(false)
	Settings.music_volume = _prev_music
	Settings.apply()

func test_music_mutes_while_unfocused_and_returns() -> void:
	var idx := AudioServer.get_bus_index("Music")
	Settings.music_volume = 0.6
	Settings.apply()
	assert_false(AudioServer.is_bus_mute(idx))
	Audio._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_true(AudioServer.is_bus_mute(idx), "music is silent while the game is in the background")
	Settings.apply()
	assert_true(AudioServer.is_bus_mute(idx), "a settings refresh does not bring music back early")
	Audio._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	assert_false(AudioServer.is_bus_mute(idx), "music returns when the game is focused")

func test_zero_music_volume_stays_muted_after_focus() -> void:
	var idx := AudioServer.get_bus_index("Music")
	Settings.music_volume = 0.0
	Settings.apply()
	Audio._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	Audio._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	assert_true(AudioServer.is_bus_mute(idx))
