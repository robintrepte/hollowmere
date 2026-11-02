extends Node
## The real game client against the real Nakama + fake Tretu issuer/platform: sign in with a
## Tretu-Konto, the Tretu menu (Tretu-Credits, notifications) and choosing a farm, through the same
## Net / Tretu / TretuMenu / FarmChoicePanel code the player uses.
## Started by server/nakama/tests/tretu_integration.mjs (which runs the server and the fakes):
##   godot --headless --path game res://tests/net/tretu_client_test.tscn -- --port=17350 \
##     --issuer=http://127.0.0.1:<fake> --token=tok-gina --discord-user=<uuid> [--shots=/abs/dir]

var _fails := 0
var _shots := ""

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	_shots = str(args.get("shots", ""))
	await get_tree().process_frame
	var keep := Settings.synced_values()
	var keep_stamps: Dictionary = Settings.stamps.duplicate()
	var keep_host := [Settings.server_host, Settings.server_port, Settings.server_ssl]
	Settings.server_host = "127.0.0.1"
	Settings.server_port = int(args.get("port", "17350"))
	Settings.server_ssl = false
	Net.reset_client()
	ProjectSettings.set_setting("tretu/auth_issuer", str(args.get("issuer", "")))
	ProjectSettings.set_setting("tretu/client_id", "hollowmere")
	_ok(Tretu.enabled(), "Tretu sign-in switched on for this run")
	var ui := UIRoot.new()
	add_child(ui)

	# Sign in: the farm chooser is requested because an old Discord farm exists.
	var asked := {"n": 0}
	Tretu.farm_choice_needed.connect(func(): asked.n += 1)
	var err: String = await Net.login_tretu(str(args.get("token", "")))
	_ok(err == "" and Net.is_tretu, "Tretu sign-in: %s" % err)
	var tretu_uid := Net.account_id
	_ok(await _until(func(): return Tretu.summary.state == "ok" and not Tretu.farm_choice.options.is_empty()), "menu data loaded")
	_ok(Tretu.summary.balance == 4321 and Tretu.summary.unread == 2, "balance and unread from the platform: %s" % Tretu.summary)
	_ok(asked.n == 1, "farm chooser requested once after sign-in")
	_ok(TitleScreen.account_text(true, Net.display_name, Net.is_tretu, Tretu.summary).ends_with("4.321 TC · 2 new") \
		or TitleScreen.account_text(true, Net.display_name, Net.is_tretu, Tretu.summary).ends_with("4,321 TC · 2 new"), "title indicator")

	# The account panel shows the Tretu menu with the numbers.
	var acc := AccountPanel.new()
	ui.open(acc)
	await _until(func(): return acc.find_child("Credits", true, false) != null)
	var credits := acc.find_child("Credits", true, false) as Label
	_ok(credits != null and credits.text.contains("4") and credits.text.contains("321 TC"), "account panel shows Tretu-Credits")
	_ok(acc.find_child("FarmNotice", true, false) != null, "account panel offers the farm choice")
	await _shot("t01_account_tretu_menu")
	ui.close_all()

	# Choose the old Discord farm through the panel (two clicks).
	var discord_uid := str(args.get("discord-user", ""))
	var panel := FarmChoicePanel.new()
	ui.open(panel)
	await get_tree().process_frame
	await _shot("t02_choose_farm")
	var card := panel.find_child("Farm_" + discord_uid.left(8), true, false)
	_ok(card != null, "Discord farm listed")
	var switched := {"done": false}
	panel.farm_switched.connect(func(): switched.done = true)
	(card.find_child("Pick", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	card = panel.find_child("Farm_" + discord_uid.left(8), true, false)
	(card.find_child("Confirm", true, false) as Button).pressed.emit()
	_ok(await _until(func(): return switched.done), "farm switched")
	_ok(Net.has_session() and Net.account_id == discord_uid and Net.is_tretu, "now signed in to the kept farm")
	var cloud: Array = await Net.cloud_list()
	_ok(cloud.size() == 1 and str(cloud[0].meta.get("farm", "")) == "Gina's Old Grove", "the kept farm's cloud save is there")
	_ok(await _until(func(): return not Tretu.farm_choice.pending and Tretu.archived_farms(Tretu.farm_choice).size() == 1), "nothing pending, one archived farm")
	_ok(Tretu.archived_farms(Tretu.farm_choice)[0].id == tretu_uid, "the old Tretu farm is the archived one")

	# Restore it again from the archived list.
	ui.close_all()
	panel = FarmChoicePanel.new()
	ui.open(panel)
	await get_tree().process_frame
	await _shot("t03_archived_farms")
	switched.done = false
	panel.farm_switched.connect(func(): switched.done = true)
	card = panel.find_child("Farm_" + tretu_uid.left(8), true, false)
	(card.find_child("Pick", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	card = panel.find_child("Farm_" + tretu_uid.left(8), true, false)
	(card.find_child("Confirm", true, false) as Button).pressed.emit()
	_ok(await _until(func(): return switched.done), "archived farm restored")
	_ok(Net.account_id == tretu_uid, "back on the first farm")

	# Signing out clears the menu.
	await Net.logout()
	_ok(Tretu.summary.state == "" and not Tretu.farm_choice.pending, "sign-out clears the Tretu menu")
	ui.queue_free()
	for k in keep:
		Settings.set(k, keep[k])
	Settings.stamps = keep_stamps
	Settings.server_host = keep_host[0]
	Settings.server_port = keep_host[1]
	Settings.server_ssl = keep_host[2]
	Settings._write_cfg()
	print("TRETU CLIENT TEST DONE, %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)

## Polls a condition (no fixed sleeps): true once it holds, false after `timeout` seconds.
func _until(cond: Callable, timeout := 30.0) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().create_timer(0.05).timeout
	return cond.call()

func _shot(name: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(_shots)
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shots.path_join(name + ".png"))

func _ok(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)
