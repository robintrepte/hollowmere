extends GutTest
## Settings that follow the account: per-key merge by last change.

func test_newer_remote_value_wins() -> void:
	var m := Settings.merge({"music_volume": 0.6}, {"music_volume": 100.0}, {"music_volume": 0.2}, {"music_volume": 200.0})
	assert_almost_eq(float(m.values.music_volume), 0.2, 0.001)
	assert_true(m.local_changed)
	assert_eq(float(m.stamps.music_volume), 200.0)

func test_newer_local_value_stays_and_is_uploaded() -> void:
	var m := Settings.merge({"music_volume": 0.6}, {"music_volume": 300.0}, {"music_volume": 0.2}, {"music_volume": 200.0})
	assert_almost_eq(float(m.values.music_volume), 0.6, 0.001)
	assert_false(m.local_changed)
	assert_true(m.remote_stale)

func test_keys_merge_independently() -> void:
	var local := {"music_volume": 0.6, "locale": "de"}
	var remote := {"music_volume": 0.1, "locale": "en"}
	var m := Settings.merge(local, {"music_volume": 50.0, "locale": 500.0}, remote, {"music_volume": 100.0, "locale": 400.0})
	assert_almost_eq(float(m.values.music_volume), 0.1, 0.001, "the remote change to the volume wins")
	assert_eq(m.values.locale, "de", "the later local language choice stays")
	assert_true(m.local_changed)
	assert_true(m.remote_stale)

func test_empty_account_gets_this_devices_settings() -> void:
	var m := Settings.merge(Settings.synced_values(), {}, {}, {})
	assert_false(m.local_changed)
	assert_true(m.remote_stale, "a fresh account receives the local settings")

func test_device_settings_never_sync() -> void:
	for k in ["fullscreen", "server_host", "server_port", "server_key", "server_ssl", "touch_controls"]:
		assert_false(k in Settings.SYNCED, k)

func test_json_round_trip_restores_types() -> void:
	var keys = JSON.parse_string(JSON.stringify({"use_tool": [KEY_Q]}))
	var typed: Dictionary = Settings._typed("custom_keys", keys)
	assert_eq(typeof(typed.use_tool[0]), TYPE_INT)
	assert_eq(Settings._typed("twelve_hour", 0.0), false)
	assert_eq(typeof(Settings._typed("clock_speed", 1)), TYPE_FLOAT)
