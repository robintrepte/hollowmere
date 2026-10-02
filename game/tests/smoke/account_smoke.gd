extends Node
## Title + account panel screenshots, signed out and (if a server is up) signed in with a cloud-only farm.
##   godot --path game res://tests/smoke/account_smoke.tscn -- --out=/abs/dir

var out_dir := "user://shots"
var main: Node
var failures := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.6)
	await _shot("a01_title")
	var acc := AccountPanel.new()
	main.ui.open(acc)
	await _wait(1.0)
	await _shot("a02_account_signed_out")
	var online: bool = await Net.ping_server()
	if online:
		var err: String = await Net.login_device("smoke-%08x" % randi())
		_check(err == "", "guest sign in from the panel flow")
		await Net.set_display_name("Robin")
		await _wait(0.4)
		await _shot("a03_account_signed_in")
		main.ui.close_all()
		_check(main.title._account.text.contains("Robin"), "title chip shows the signed-in name")
		var slot := 5
		var had_local := not SaveManager.read_meta(slot).is_empty()
		var payload := {"version": 1, "meta": {"farm": "Cloudy", "player": "Robin", "day": 30, "money": 4200, "saved_at": Time.get_unix_time_from_system() + 60}, "state": {}}
		_check(await Net.cloud_save(slot, payload), "cloud save for load list")
		main.title._open_load()
		await _wait(1.0)
		await _shot("a04_load_with_cloud")
		main.ui.close_all()
		await Net.cloud_delete(slot)
		if not had_local:
			SaveManager.delete_slot(slot)
		await Net.logout()
		_check(main.title._account.text == "Sign in", "chip resets after sign out")
	else:
		print("SKIP signed-in shots: no server")
	print("ACCOUNT SMOKE DONE, %d failures" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
