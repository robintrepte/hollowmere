extends Node
## Integration test against a running Nakama (server/docker-compose.yml).
## Skips (exit 0) when no server answers, unless --require-server is passed.

var _fails := 0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var require := "--require-server" in args
	await get_tree().process_frame
	if not await Net.ping_server():
		print("SERVER TEST SKIPPED: no server at %s" % Net.server_label())
		get_tree().quit(1 if require else 0)
		return
	var tag := "%08x%04x" % [randi(), Time.get_ticks_msec() % 0xffff]
	# Every sign-in pulls the test account's profile; the player's own settings come back at the end.
	var keep := Settings.synced_values()
	var keep_stamps: Dictionary = Settings.stamps.duplicate()

	# Guest login, then upgrade the guest to an email account.
	_ok(await Net.login_device("test-device-%s" % tag) == "", "guest login")
	_ok(Net.is_guest, "fresh device account is a guest")
	_ok(await Net.set_display_name("Tester%s" % tag.substr(0, 4)) == "", "rename")
	var email := "t%s@hollowmere.test" % tag
	_ok(await Net.link_email(email, "password123") == "", "link email to guest")
	_ok(not Net.is_guest, "linked account is no longer a guest")

	# Cloud save round trip.
	var payload := {"version": 1, "meta": {"farm": "Test", "player": "T", "day": 3, "saved_at": 1000.0}, "state": {"x": 1}}
	_ok(await Net.cloud_save(2, payload), "cloud save")
	var list: Array = await Net.cloud_list()
	_ok(list.size() == 1 and int(list[0].slot) == 2 and list[0].payload.state.x == 1, "cloud list returns the save")
	_ok(SaveManager.newer_in_cloud(list).size() >= 0, "newer_in_cloud runs")
	await TimeService.sync_server()
	_ok(absf(TimeService.offset) < 120.0, "server clock offset is sane: %.1f s" % TimeService.offset)

	# Server-side validation rejects junk.
	var bad := NakamaWriteStorageObject.new("loot", "slot_0", 1, 1, "{}", "")
	var r1 = await Net.client.write_storage_objects_async(Net.session, [bad])
	_ok(r1.is_exception(), "writes outside 'saves' are rejected")
	var bad2 := NakamaWriteStorageObject.new("saves", "slot_9", 1, 1, JSON.stringify(payload), "")
	var r2 = await Net.client.write_storage_objects_async(Net.session, [bad2])
	_ok(r2.is_exception(), "bad slot keys are rejected")
	var bad3 := NakamaWriteStorageObject.new("saves", "slot_1", 1, 1, "{\"hello\":1}", "")
	var r3 = await Net.client.write_storage_objects_async(Net.session, [bad3])
	_ok(r3.is_exception(), "non-save payloads are rejected")

	await Net.cloud_delete(2)
	_ok((await Net.cloud_list()).is_empty(), "cloud delete")

	# Account profile: a setting changed on another device wins when it is newer.
	var later := Time.get_unix_time_from_system() + 60.0
	_ok(await Net.profile_save({"values": {"music_volume": 0.33}, "stamps": {"music_volume": later}}), "profile saved")
	var prof: Dictionary = await Net.profile_load()
	_ok(is_equal_approx(float(prof.get("values", {}).get("music_volume", 0.0)), 0.33), "profile round trip")
	await Settings.sync_profile()
	_ok(is_equal_approx(Settings.music_volume, 0.33), "newer account setting is applied on sign-in")
	prof = await Net.profile_load()
	_ok(prof.get("values", {}).has("text_scale"), "settings the account lacked are uploaded")
	var bad_key := NakamaWriteStorageObject.new("profile", "secrets", 1, 1, "{\"values\":{}}", "")
	_ok((await Net.client.write_storage_objects_async(Net.session, [bad_key])).is_exception(), "unknown profile keys are rejected")
	var bad_shape := NakamaWriteStorageObject.new("profile", "settings", 1, 1, "{\"x\":1}", "")
	_ok((await Net.client.write_storage_objects_async(Net.session, [bad_shape])).is_exception(), "profiles without values are rejected")
	var huge := NakamaWriteStorageObject.new("profile", "settings", 1, 1, JSON.stringify({"values": {"profile": {"x": "y".repeat(70000)}}, "stamps": {}}), "")
	_ok((await Net.client.write_storage_objects_async(Net.session, [huge])).is_exception(), "oversized profiles are rejected")

	# Invite codes.
	var code: Dictionary = await Net.call_rpc("create_coop_code", {"match_id": "fake-match-id.%s" % tag})
	_ok(str(code.get("code", "")).length() == 6, "invite code allocated: %s" % code)
	var res: Dictionary = await Net.call_rpc("resolve_coop_code", {"code": str(code.get("code", "")).to_lower()})
	_ok(res.get("match_id", "") == "fake-match-id.%s" % tag, "invite code resolves (case-insensitive)")
	await Net.call_rpc("close_coop_code", {"code": code.get("code", "")})
	var gone: Dictionary = await Net.call_rpc("resolve_coop_code", {"code": code.get("code", "")})
	_ok(gone.has("error"), "closed code no longer resolves")
	_ok((await Net.call_rpc("resolve_coop_code", {"code": "ZZ"})).has("error"), "short code rejected")

	# Error reports and opt-in play stats.
	Telemetry.queue.clear()
	Telemetry.record("script", "Invalid access to key 'x' (%s)" % tag, "res://scenes/test.gd:12 (_ready)")
	Telemetry.record("script", "Invalid access to key 'x' (%s)" % tag, "res://scenes/test.gd:12 (_ready)")
	_ok(Telemetry.queue.size() == 1 and Telemetry.queue.values()[0].count == 2, "repeated errors fold into one report")
	await Telemetry.flush()
	_ok(Telemetry.queue.is_empty(), "error reports delivered")
	_ok(not (await Net.call_rpc("report_errors", {"reports": [{"sig": "x".repeat(5000), "count": 99999}]})).has("error"), "oversized report is clipped, not rejected")
	Settings.analytics = true
	Telemetry._beat_minutes = 7.0
	await Telemetry.heartbeat()
	_ok(Telemetry._beat_minutes < 1.0 and not Telemetry._new_session, "play-stats heartbeat accepted")
	Settings.analytics = false
	Telemetry._beat_minutes = 5.0
	await Telemetry.heartbeat()
	_ok(Telemetry._beat_minutes == 5.0, "no play stats without opt-in")

	# Email sign in / errors.
	await Net.logout()
	_ok(not Net.has_session(), "logout")
	_ok(await Net.login_email(email, "password123", false) == "", "email sign in")
	await Net.logout()
	var wrong: String = await Net.login_email(email, "wrongpass99", false)
	_ok(wrong != "" and not wrong.contains("{"), "wrong password gives a friendly error: %s" % wrong)
	var short: String = await Net.login_email("n%s@hollowmere.test" % tag, "abc", true, "Shorty")
	_ok(short != "", "short password rejected: %s" % short)

	# Restore session from disk.
	_ok(await Net.login_email(email, "password123", false) == "", "sign in again")
	Net.session = null
	_ok(await Net.try_restore_session(), "session restores from disk")
	_ok(Net.session.refresh_token != "", "restored session keeps its refresh token")
	var refreshed: NakamaSession = await Net.client.session_refresh_async(Net.session)
	_ok(not refreshed.is_exception() and not refreshed.is_expired(), "restored session can refresh")
	await Net.logout()
	await get_tree().create_timer(1.0).timeout
	for k in keep:
		Settings.set(k, keep[k])
	Settings.stamps = keep_stamps
	Settings._write_cfg()
	Settings.apply()

	print("SERVER TEST DONE, %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)

func _ok(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)
